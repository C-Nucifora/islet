import Combine
import Darwin
import Foundation
import Network
import Security

enum PulsePaths {
  static let defaultPort = NWEndpoint.Port(rawValue: 47_717)!
  static let fallbackPorts = (47_718...47_727).compactMap(NWEndpoint.Port.init(rawValue:))
  static let candidatePorts = [defaultPort] + fallbackPorts

  static var supportDirectory: URL {
    let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return root.appendingPathComponent("Islet", isDirectory: true)
  }

  static var tokenURL: URL { supportDirectory.appendingPathComponent("pulse-token") }
  static var activePortURL: URL { supportDirectory.appendingPathComponent("pulse-port") }
}

protocol PulseListening: AnyObject, Sendable {
  var newConnectionHandler: (@Sendable (NWConnection) -> Void)? { get set }
  var stateUpdateHandler: (@Sendable (NWListener.State) -> Void)? { get set }
  var port: NWEndpoint.Port? { get }

  func start(queue: DispatchQueue)
  func cancel()
}

extension NWListener: PulseListening {}

protocol PulseRetryCancellable: AnyObject {
  func cancel()
}

private final class PulseRetryTask: PulseRetryCancellable {
  private let task: Task<Void, Never>

  init(after delay: TimeInterval, action: @escaping @MainActor @Sendable () -> Void) {
    task = Task { @MainActor in
      try? await Task.sleep(for: .seconds(delay))
      guard !Task.isCancelled else { return }
      action()
    }
  }

  func cancel() { task.cancel() }
}

/// Authenticated, loopback-only newline-delimited JSON transport for out-of-process activity
/// providers. Providers never load code into Islet; they can only submit bounded data and web URLs.
@MainActor
final class PulseServer: ObservableObject {
  static let shared = PulseServer()
  nonisolated static let maximumMessageBytes = 64 * 1024
  nonisolated static let maximumCommandsPerConnection = 128
  nonisolated static let authenticationTimeout: Duration = .seconds(10)
  nonisolated static let retryInitialDelay: TimeInterval = 1
  nonisolated static let retryMaximumDelay: TimeInterval = 60
  nonisolated static let retryStableReadyPeriod: TimeInterval = 60
  private nonisolated static let maximumConnections = 16

  typealias ListenerFactory = (NWParameters, NWEndpoint.Port) throws -> any PulseListening
  typealias RetryScheduler = (
    TimeInterval, @escaping @MainActor @Sendable () -> Void
  ) -> any PulseRetryCancellable

  private var listener: (any PulseListening)?
  private var connections: [ObjectIdentifier: NWConnection] = [:]
  private var commandPipelines: [ObjectIdentifier: PulseCommandPipeline] = [:]
  private var commandTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
  private var authenticationTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
  private let queue = DispatchQueue(label: "dev.islet.pulse", qos: .utility)
  @Published private(set) var isRunning = false
  @Published private(set) var lastError: String?
  @Published private(set) var activePort: UInt16?
  @Published private(set) var portRecoveryMessage: String?
  @Published private(set) var tokenRotatedAt: Date?
  @Published private(set) var nextRetryAt: Date?
  private(set) var token: String?
  private var rateLimiter = PulseRateLimiter()
  private var candidateIndex = 0
  private var retryTask: (any PulseRetryCancellable)?
  private var stableReadyTask: (any PulseRetryCancellable)?
  private var retryAttempt = 0
  private var lifecycleGeneration = 0
  private let listenerFactory: ListenerFactory
  private let tokenLoader: () throws -> String
  private let activePortWriter: (UInt16) throws -> Void
  private let activePortRemover: () -> Void
  private let now: () -> Date
  private let retryScheduler: RetryScheduler

  init(
    listenerFactory: @escaping ListenerFactory = { parameters, port in
      try NWListener(using: parameters, on: port)
    },
    tokenLoader: (() throws -> String)? = nil,
    activePortWriter: ((UInt16) throws -> Void)? = nil,
    activePortRemover: (() -> Void)? = nil,
    now: @escaping () -> Date = Date.init,
    retryScheduler: @escaping RetryScheduler = { delay, action in
      PulseRetryTask(after: delay, action: action)
    }
  ) {
    self.listenerFactory = listenerFactory
    self.tokenLoader = tokenLoader ?? Self.loadOrCreateToken
    self.activePortWriter = activePortWriter ?? Self.writeActivePort
    self.activePortRemover = activePortRemover ?? Self.removeActivePort
    self.now = now
    self.retryScheduler = retryScheduler
  }

  var listeningAddress: String? {
    activePort.map { "127.0.0.1:\($0)" }
  }

  func start() {
    guard listener == nil else { return }
    lifecycleGeneration += 1
    cancelScheduledRetries()
    startFreshAttempt()
  }

  private func startFreshAttempt() {
    do {
      let token = try tokenLoader()
      self.token = token
      candidateIndex = 0
      lastError = nil
      portRecoveryMessage = nil
      activePort = nil
      isRunning = false
      try startCandidate()
    } catch {
      if Self.isAddressInUse(error) {
        recoverFromOccupiedPort()
      } else if Self.isRecoverableListenerFailure(error) {
        scheduleRetry(after: error)
      } else {
        fail(error)
      }
    }
  }

  private func startCandidate() throws {
    let port = PulsePaths.candidatePorts[candidateIndex]
    let parameters = NWParameters.tcp
    parameters.allowLocalEndpointReuse = true
    parameters.requiredLocalEndpoint = .hostPort(
      host: NWEndpoint.Host("127.0.0.1"), port: .any)
    let listener = try listenerFactory(parameters, port)
    listener.newConnectionHandler = { [weak self] connection in
      Task { @MainActor in self?.accept(connection) }
    }
    listener.stateUpdateHandler = { [weak self, weak listener] state in
      Task { @MainActor in
        guard let self, let listener, self.listener === listener else { return }
        self.handle(state, from: listener)
      }
    }
    self.listener = listener
    listener.start(queue: queue)
  }

  private func handle(_ state: NWListener.State, from listener: any PulseListening) {
    switch state {
    case .ready:
      guard let port = listener.port?.rawValue else {
        fail(PulseServerError.missingActivePort)
        return
      }
      do {
        try activePortWriter(port)
        activePort = port
        isRunning = true
        lastError = nil
        nextRetryAt = nil
        portRecoveryMessage =
          port == PulsePaths.defaultPort.rawValue
          ? nil
          : "Port 47717 is in use. Pulse moved to \(port); bundled clients discover it automatically."
        scheduleBackoffReset(for: listener)
      } catch {
        fail(error)
      }
    case .waiting(let error):
      if Self.isAddressInUse(error) {
        recoverFromOccupiedPort()
      } else if Self.isRecoverableListenerFailure(error) {
        scheduleRetry(after: error)
      } else {
        fail(error)
      }
    case .failed(let error):
      if Self.isAddressInUse(error) {
        recoverFromOccupiedPort()
      } else if Self.isRecoverableListenerFailure(error) {
        scheduleRetry(after: error)
      } else {
        fail(error)
      }
    case .cancelled:
      self.listener = nil
      isRunning = false
      activePort = nil
      portRecoveryMessage = nil
      activePortRemover()
      nextRetryAt = nil
      stableReadyTask?.cancel()
      stableReadyTask = nil
      lastError = "The Pulse listener stopped. Retry it from Settings."
    case .setup:
      break
    @unknown default:
      break
    }
  }

  private func recoverFromOccupiedPort() {
    listener?.cancel()
    listener = nil
    isRunning = false
    activePort = nil
    nextRetryAt = nil
    stableReadyTask?.cancel()
    stableReadyTask = nil
    activePortRemover()
    guard candidateIndex + 1 < PulsePaths.candidatePorts.count else {
      lastError =
        "Pulse could not start because ports 47717 through 47727 are in use. Free one, then retry."
      portRecoveryMessage = nil
      return
    }
    candidateIndex += 1
    do {
      try startCandidate()
    } catch {
      if Self.isAddressInUse(error) {
        recoverFromOccupiedPort()
      } else if Self.isRecoverableListenerFailure(error) {
        scheduleRetry(after: error)
      } else {
        fail(error)
      }
    }
  }

  private func fail(_ error: Error) {
    listener?.cancel()
    listener = nil
    isRunning = false
    activePort = nil
    portRecoveryMessage = nil
    nextRetryAt = nil
    stableReadyTask?.cancel()
    stableReadyTask = nil
    activePortRemover()
    lastError = "Pulse could not start: \(error.localizedDescription)"
    Log.app.error("Pulse server failed: \(error.localizedDescription, privacy: .public)")
  }

  nonisolated static func isAddressInUse(_ error: Error) -> Bool {
    if case .posix(.EADDRINUSE) = error as? NWError { return true }
    let nsError = error as NSError
    return nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(EADDRINUSE)
  }

  nonisolated static func isRecoverableListenerFailure(_ error: Error) -> Bool {
    guard let code = posixCode(for: error) else { return false }
    return switch code {
    case EAGAIN, ECONNABORTED, ECONNREFUSED, EINTR, ENETDOWN, ENETUNREACH, ENOBUFS, ETIMEDOUT:
      true
    default:
      false
    }
  }

  private nonisolated static func posixCode(for error: Error) -> Int32? {
    if case .posix(let code) = error as? NWError { return code.rawValue }
    let nsError = error as NSError
    guard nsError.domain == NSPOSIXErrorDomain else { return nil }
    return Int32(nsError.code)
  }

  nonisolated static func retryDelay(for attempt: Int) -> TimeInterval {
    guard attempt > 0 else { return 0 }
    let exponent = min(attempt - 1, 16)
    return min(retryInitialDelay * pow(2, Double(exponent)), retryMaximumDelay)
  }

  private func scheduleRetry(after error: Error) {
    listener?.cancel()
    listener = nil
    isRunning = false
    activePort = nil
    portRecoveryMessage = nil
    activePortRemover()
    stableReadyTask?.cancel()
    stableReadyTask = nil
    retryTask?.cancel()
    retryAttempt += 1
    let delay = Self.retryDelay(for: retryAttempt)
    let retryAt = now().addingTimeInterval(delay)
    nextRetryAt = retryAt
    lastError =
      "Pulse listener failed: \(error.localizedDescription). Retrying at \(retryAt.formatted(date: .omitted, time: .standard))."
    Log.app.error(
      "Pulse listener will retry in \(delay, privacy: .public)s: \(error.localizedDescription, privacy: .public)"
    )
    let generation = lifecycleGeneration
    retryTask = retryScheduler(delay) { [weak self] in
      guard let self, self.lifecycleGeneration == generation else { return }
      self.retryTask = nil
      self.nextRetryAt = nil
      self.startFreshAttempt()
    }
  }

  private func scheduleBackoffReset(for listener: any PulseListening) {
    stableReadyTask?.cancel()
    let generation = lifecycleGeneration
    stableReadyTask = retryScheduler(Self.retryStableReadyPeriod) {
      [weak self, weak listener] in
      guard let self, let listener, self.lifecycleGeneration == generation,
        self.listener === listener,
        self.isRunning
      else { return }
      self.retryAttempt = 0
      self.stableReadyTask = nil
    }
  }

  private func cancelScheduledRetries() {
    retryTask?.cancel()
    retryTask = nil
    stableReadyTask?.cancel()
    stableReadyTask = nil
    nextRetryAt = nil
  }

  func stop() {
    lifecycleGeneration += 1
    cancelScheduledRetries()
    listener?.cancel()
    listener = nil
    isRunning = false
    activePort = nil
    portRecoveryMessage = nil
    activePortRemover()
    for connection in connections.values { connection.cancel() }
    for pipeline in commandPipelines.values { pipeline.finish() }
    for task in commandTasks.values { task.cancel() }
    for task in authenticationTasks.values { task.cancel() }
    connections.removeAll()
    commandPipelines.removeAll()
    commandTasks.removeAll()
    authenticationTasks.removeAll()
  }

  func retryDefaultPort() {
    stop()
    start()
  }

  /// Invalidates the one shared provider credential, disconnects every current client, and
  /// atomically replaces the token before optionally restoring the listener.
  func rotateToken() throws {
    let shouldRestart = listener != nil
    stop()
    do {
      token = try Self.createToken(replacingExisting: true)
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
          self.send(response, on: connection)
          break commandLoop
        }
      }
      pipeline.finish()
      self.finishConnectionAfterResponses(connection, id: id)
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
      if error != nil {
        connection.cancel()
        pipeline.finish()
        Task { @MainActor in self.removeConnection(id) }
      } else if complete {
        // A peer half-close ends input only. Keep the connection counted and writable until the
        // pipeline has processed every accepted command and Network.framework has flushed the
        // matching responses.
        pipeline.finish()
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
          on: connection)
        return false
      }
      markAuthenticated(id)
      guard rateLimiter.accepts(ProcessInfo.processInfo.systemUptime) else {
        send(
          .failure(
            "provider command rate exceeded; retry later", code: .rateLimited,
            requestID: command.requestID),
          on: connection)
        return false
      }
      send(PulseCenter.shared.applyIfEnabled(command), on: connection)
      return true
    } catch {
      send(
        .failure("invalid command: \(error.localizedDescription)", code: .invalidCommand),
        on: connection)
      return false
    }
  }

  nonisolated private func send(_ response: PulseResponse, on connection: NWConnection) {
    let encoder = JSONEncoder()
    guard var data = try? encoder.encode(response) else { return }
    data.append(0x0A)
    connection.send(content: data, completion: .contentProcessed { _ in })
  }

  private func finishConnectionAfterResponses(
    _ connection: NWConnection, id: ObjectIdentifier
  ) {
    connection.send(
      content: nil, contentContext: .finalMessage, isComplete: true,
      completion: .contentProcessed { [weak self, weak connection] _ in
        connection?.cancel()
        Task { @MainActor in self?.detachConnection(id) }
      })
  }

  private static func loadOrCreateToken() throws -> String {
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

  private static func createToken(replacingExisting: Bool) throws -> String {
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

  private static func writeActivePort(_ port: UInt16) throws {
    try Data("\(port)\n".utf8).write(to: PulsePaths.activePortURL, options: .atomic)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: PulsePaths.activePortURL.path)
  }

  private static func removeActivePort() {
    try? FileManager.default.removeItem(at: PulsePaths.activePortURL)
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

private enum PulseServerError: LocalizedError {
  case missingActivePort

  var errorDescription: String? {
    switch self {
    case .missingActivePort: "The listener did not report its active port."
    }
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
