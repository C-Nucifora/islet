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
  private nonisolated static let maximumConnections = 16

  private var listener: NWListener?
  private var connections: [ObjectIdentifier: NWConnection] = [:]
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
        host: NWEndpoint.Host("127.0.0.1"), port: PulsePaths.port)
      let listener = try NWListener(using: parameters, on: PulsePaths.port)
      listener.newConnectionLimit = Self.maximumConnections
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
    connections.removeAll()
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
    let id = ObjectIdentifier(connection)
    connections[id] = connection
    connection.stateUpdateHandler = { [weak self, weak connection] state in
      guard case .failed = state else {
        if case .cancelled = state { Task { @MainActor in self?.connections[id] = nil } }
        return
      }
      connection?.cancel()
      Task { @MainActor in self?.connections[id] = nil }
    }
    connection.start(queue: queue)
    receive(on: connection, id: id, buffer: Data(), commandCount: 0)
  }

  nonisolated private static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
    guard case .hostPort(let host, _) = endpoint else { return false }
    return host == NWEndpoint.Host("127.0.0.1") || host == NWEndpoint.Host("::1")
  }

  nonisolated private func receive(
    on connection: NWConnection, id: ObjectIdentifier, buffer: Data, commandCount: Int
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
          self.send(
            .failure(
              "message exceeds \(Self.maximumMessageBytes) bytes", code: .messageTooLarge),
            on: connection,
            closeAfterSend: true)
          return
        }
        nextCommandCount += 1
        guard nextCommandCount <= Self.maximumCommandsPerConnection else {
          self.send(
            .failure("connection command limit exceeded", code: .commandLimitExceeded),
            on: connection,
            closeAfterSend: true)
          return
        }
        self.decode(Data(line), on: connection)
      }
      guard next.count <= Self.maximumMessageBytes else {
        self.send(
          .failure("message exceeds \(Self.maximumMessageBytes) bytes", code: .messageTooLarge),
          on: connection,
          closeAfterSend: true)
        return
      }
      if error != nil || complete {
        connection.cancel()
        Task { @MainActor in self.connections[id] = nil }
      } else {
        self.receive(
          on: connection, id: id, buffer: next, commandCount: nextCommandCount)
      }
    }
  }

  nonisolated private func decode(_ data: Data, on connection: NWConnection) {
    do {
      try PulseWireValidator.validate(data)
      let command = try PulseWireCodec.decoder().decode(PulseCommand.self, from: data)
      Task { @MainActor in
        guard Self.securelyMatches(command.token, self.token) else {
          self.send(
            .failure(
              "unauthorized", code: .unauthorized, requestID: command.requestID),
            on: connection, closeAfterSend: true)
          return
        }
        guard self.rateLimiter.accepts(Date()) else {
          self.send(
            .failure(
              "provider command rate exceeded; retry later", code: .rateLimited,
              requestID: command.requestID),
            on: connection, closeAfterSend: true)
          return
        }
        self.send(PulseCenter.shared.apply(command), on: connection)
      }
    } catch {
      send(
        .failure("invalid command: \(error.localizedDescription)", code: .invalidCommand),
        on: connection,
        closeAfterSend: true)
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
