import Combine
import Darwin
import Foundation
import Network
import Security

enum PulsePaths {
  static let port = NWEndpoint.Port(rawValue: 47_717)!

  static var supportDirectory: URL {
    let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return root.appendingPathComponent("Islet", isDirectory: true)
  }

  static var tokenURL: URL { supportDirectory.appendingPathComponent("pulse-token") }
}

/// Authenticated, loopback-only newline-delimited JSON transport for out-of-process activity
/// providers. Providers never load code into Islet; they can only submit bounded data and web URLs.
@MainActor
final class PulseServer: ObservableObject {
  static let shared = PulseServer()
  nonisolated static let maximumMessageBytes = 64 * 1024
  nonisolated static let maximumCommandsPerConnection = 128
  nonisolated static let authenticationTimeout: Duration = .seconds(10)
  private nonisolated static let maximumConnections = 16

  private var listener: NWListener?
  private var connections: [ObjectIdentifier: NWConnection] = [:]
  private var commandPipelines: [ObjectIdentifier: PulseCommandPipeline] = [:]
  private var commandTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
  private var authenticationTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
  private let queue = DispatchQueue(label: "dev.nedlane.Islet.pulse", qos: .utility)
  @Published private(set) var isRunning = false
  @Published private(set) var lastError: String?
  @Published private(set) var tokenRotatedAt: Date?
  private(set) var token: String?
  private var rateLimiter = PulseRateLimiter()

  func start() {
    guard listener == nil else { return }
    do {
      let token = try loadOrCreateToken()
      let parameters = NWParameters.tcp
      parameters.allowLocalEndpointReuse = true
      parameters.requiredLocalEndpoint = .hostPort(
        host: NWEndpoint.Host("127.0.0.1"), port: .any)
      let listener = try NWListener(using: parameters, on: PulsePaths.port)
      listener.newConnectionHandler = { [weak self] connection in
        Task { @MainActor in self?.accept(connection) }
      }
      listener.stateUpdateHandler = { [weak self, weak listener] state in
        Task { @MainActor in
          guard let self, let listener, self.listener === listener else { return }
          switch state {
          case .ready:
            self.isRunning = true
            self.lastError = nil
          case .waiting(let error):
            self.isRunning = false
            self.lastError = error.localizedDescription
          case .failed(let error):
            self.lastError = error.localizedDescription
            self.stop()
          case .cancelled:
            self.isRunning = false
          case .setup:
            break
          @unknown default:
            break
          }
        }
      }
      self.token = token
      self.listener = listener
      lastError = nil
      isRunning = false
      listener.start(queue: queue)
    } catch {
      lastError = error.localizedDescription
      Log.app.error("Pulse server failed: \(error.localizedDescription, privacy: .public)")
    }
  }

  func stop() {
    listener?.cancel()
    listener = nil
    isRunning = false
    for connection in connections.values { connection.cancel() }
    for pipeline in commandPipelines.values { pipeline.finish() }
    for task in commandTasks.values { task.cancel() }
    for task in authenticationTasks.values { task.cancel() }
    connections.removeAll()
    commandPipelines.removeAll()
    commandTasks.removeAll()
    authenticationTasks.removeAll()
  }

  /// Invalidates the one shared provider credential, disconnects every current client, and
  /// atomically replaces the token before optionally restoring the listener.
  func rotateToken() throws {
    let shouldRestart = listener != nil
    stop()
    do {
      token = try createToken(replacingExisting: true)
      rateLimiter = PulseRateLimiter()
      tokenRotatedAt = Date()
      if shouldRestart { start() }
    } catch {
      if shouldRestart { start() }
      throw error
    }
  }

  private func accept(_ connection: NWConnection) {
    guard Self.isLoopback(connection.endpoint) else {
      connection.cancel()
      return
    }
    guard Self.canAcceptConnection(activeCount: connections.count) else {
      connection.cancel()
      return
    }
    let id = ObjectIdentifier(connection)
    let pipeline = PulseCommandPipeline()
    connections[id] = connection
    commandPipelines[id] = pipeline
    commandTasks[id] = Task { @MainActor [weak self, weak connection] in
      guard let self, let connection else { return }
      commandLoop: for await event in pipeline.stream {
        guard !Task.isCancelled else { break }
        switch event {
        case .command(let data):
          guard self.process(data, on: connection, id: id) else { break commandLoop }
        case .terminal(let response):
          self.send(response, on: connection, closeAfterSend: true)
          break commandLoop
        }
      }
      pipeline.finish()
      self.detachConnection(id)
    }
    authenticationTasks[id] = Task { @MainActor [weak self, weak connection] in
      try? await Task.sleep(for: Self.authenticationTimeout)
      guard !Task.isCancelled, let self, let connection,
        let active = self.connections[id], active === connection
      else { return }
      connection.cancel()
      self.removeConnection(id)
    }
    connection.stateUpdateHandler = { [weak self, weak connection] state in
      guard case .failed = state else {
        if case .cancelled = state { Task { @MainActor in self?.removeConnection(id) } }
        return
      }
      connection?.cancel()
      Task { @MainActor in self?.removeConnection(id) }
    }
    connection.start(queue: queue)
    receive(on: connection, id: id, pipeline: pipeline, buffer: Data(), commandCount: 0)
  }

  private func removeConnection(_ id: ObjectIdentifier) {
    // A state callback can arrive while already-received commands are still queued. Finish the
    // stream and release our handles, but let its consumer drain in wire order. `stop()` is the
    // only path that deliberately cancels pending commands.
    detachConnection(id)
  }

  private func detachConnection(_ id: ObjectIdentifier) {
    connections[id] = nil
    commandPipelines.removeValue(forKey: id)?.finish()
    commandTasks[id] = nil
    authenticationTasks.removeValue(forKey: id)?.cancel()
  }

  private func markAuthenticated(_ id: ObjectIdentifier) {
    authenticationTasks.removeValue(forKey: id)?.cancel()
  }

  nonisolated private static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
    guard case .hostPort(let host, _) = endpoint else { return false }
    return host == NWEndpoint.Host("127.0.0.1") || host == NWEndpoint.Host("::1")
  }

  /// `NWListener.newConnectionLimit` is a decreasing lifetime admission allowance, not a
  /// concurrent-client ceiling. Keep the listener accepting indefinitely and enforce the bound
  /// against the connections Islet currently owns instead.
  nonisolated static func canAcceptConnection(activeCount: Int) -> Bool {
    activeCount >= 0 && activeCount < maximumConnections
  }

  nonisolated private func receive(
    on connection: NWConnection, id: ObjectIdentifier, pipeline: PulseCommandPipeline,
    buffer: Data, commandCount: Int
  ) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) {
      [weak self] data, _, complete, error in
      guard let self else { return }
      var next = buffer
      var nextCommandCount = commandCount
      if let data { next.append(data) }
      while let newline = next.firstIndex(of: 0x0A) {
        let line = next[..<newline]
        next.removeSubrange(...newline)
        guard !line.isEmpty else { continue }
        guard line.count <= Self.maximumMessageBytes else {
          pipeline.terminate(
            .failure(
              "message exceeds \(Self.maximumMessageBytes) bytes", code: .messageTooLarge))
          return
        }
        nextCommandCount += 1
        guard nextCommandCount <= Self.maximumCommandsPerConnection else {
          pipeline.terminate(
            .failure("connection command limit exceeded", code: .commandLimitExceeded))
          return
        }
        pipeline.yield(Data(line))
      }
      guard next.count <= Self.maximumMessageBytes else {
        pipeline.terminate(
          .failure("message exceeds \(Self.maximumMessageBytes) bytes", code: .messageTooLarge))
        return
      }
      if error != nil || complete {
        connection.cancel()
        pipeline.finish()
        Task { @MainActor in self.removeConnection(id) }
      } else {
        self.receive(
          on: connection, id: id, pipeline: pipeline, buffer: next,
          commandCount: nextCommandCount)
      }
    }
  }

  /// Runs only from the connection's one long-lived pipeline task. `show`, `update`, and `end`
  /// therefore reach the model—and write their responses—in exactly the order received on the wire.
  private func process(
    _ data: Data, on connection: NWConnection, id: ObjectIdentifier
  ) -> Bool {
    do {
      try PulseWireValidator.validate(data)
      let command = try PulseWireCodec.decoder().decode(PulseCommand.self, from: data)
      guard Self.securelyMatches(command.token, token) else {
        send(
          .failure("unauthorized", code: .unauthorized, requestID: command.requestID),
          on: connection, closeAfterSend: true)
        return false
      }
      markAuthenticated(id)
      guard rateLimiter.accepts(ProcessInfo.processInfo.systemUptime) else {
        send(
          .failure(
            "provider command rate exceeded; retry later", code: .rateLimited,
            requestID: command.requestID),
          on: connection, closeAfterSend: true)
        return false
      }
      send(PulseCenter.shared.apply(command), on: connection)
      return true
    } catch {
      send(
        .failure("invalid command: \(error.localizedDescription)", code: .invalidCommand),
        on: connection,
        closeAfterSend: true)
      return false
    }
  }

  nonisolated private func send(
    _ response: PulseResponse, on connection: NWConnection, closeAfterSend: Bool = false
  ) {
    let encoder = JSONEncoder()
    guard var data = try? encoder.encode(response) else { return }
    data.append(0x0A)
    connection.send(content: data, completion: .contentProcessed { _ in
      if closeAfterSend { connection.cancel() }
    })
  }

  private func loadOrCreateToken() throws -> String {
    let manager = FileManager.default
    try manager.createDirectory(
      at: PulsePaths.supportDirectory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    try manager.setAttributes(
      [.posixPermissions: 0o700], ofItemAtPath: PulsePaths.supportDirectory.path)
    var info = stat()
    if lstat(PulsePaths.tokenURL.path, &info) == 0,
      (info.st_mode & S_IFMT) == S_IFREG,
      info.st_uid == getuid(),
      let value = try? String(contentsOf: PulsePaths.tokenURL, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines),
      let decoded = Data(base64Encoded: value), decoded.count == 32
    {
      try manager.setAttributes(
        [.posixPermissions: 0o600], ofItemAtPath: PulsePaths.tokenURL.path)
      return value
    }
    return try createToken(replacingExisting: true)
  }

  private func createToken(replacingExisting: Bool) throws -> String {
    let manager = FileManager.default
    try manager.createDirectory(
      at: PulsePaths.supportDirectory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    try manager.setAttributes(
      [.posixPermissions: 0o700], ofItemAtPath: PulsePaths.supportDirectory.path)
    var bytes = [UInt8](repeating: 0, count: 32)
    let randomStatus = bytes.withUnsafeMutableBytes { buffer in
      SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
    }
    guard randomStatus == errSecSuccess else {
      throw CocoaError(.fileWriteUnknown)
    }
    let value = Data(bytes).base64EncodedString()
    let temporaryURL = PulsePaths.supportDirectory.appendingPathComponent(
      ".pulse-token-\(UUID().uuidString).tmp")
    guard
      manager.createFile(
        atPath: temporaryURL.path, contents: Data("\(value)\n".utf8),
        attributes: [.posixPermissions: 0o600])
    else { throw CocoaError(.fileWriteUnknown) }
    defer { try? manager.removeItem(at: temporaryURL) }
    try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporaryURL.path)
    if !replacingExisting, manager.fileExists(atPath: PulsePaths.tokenURL.path) {
      throw CocoaError(.fileWriteFileExists)
    }
    let renameResult = temporaryURL.path.withCString { source in
      PulsePaths.tokenURL.path.withCString { destination in Darwin.rename(source, destination) }
    }
    guard renameResult == 0 else {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    return value
  }

  nonisolated private static func securelyMatches(_ supplied: String, _ expected: String?) -> Bool {
    guard let expected, let left = Data(base64Encoded: supplied),
      let right = Data(base64Encoded: expected), left.count == right.count, left.count == 32
    else { return false }
    var difference: UInt8 = 0
    for index in left.indices { difference |= left[index] ^ right[index] }
    return difference == 0
  }
}

/// Thread-safe bridge from Network.framework's serial receive queue into one ordered MainActor
/// consumer. AsyncStream preserves yield order without creating one unstructured task per command.
enum PulseCommandPipelineEvent: Equatable, Sendable {
  case command(Data)
  case terminal(PulseResponse)
}

final class PulseCommandPipeline: @unchecked Sendable {
  let stream: AsyncStream<PulseCommandPipelineEvent>
  private let continuation: AsyncStream<PulseCommandPipelineEvent>.Continuation

  init() {
    (stream, continuation) = AsyncStream.makeStream(of: PulseCommandPipelineEvent.self)
  }

  func yield(_ data: Data) { continuation.yield(.command(data)) }
  func terminate(_ response: PulseResponse) {
    continuation.yield(.terminal(response))
    continuation.finish()
  }
  func finish() { continuation.finish() }
}
