import Combine
import Darwin
import Foundation
import Network

enum PulsePaths {
  static let defaultPort = NWEndpoint.Port(rawValue: 47_717)!
  static let fallbackPorts = (47_718...47_727).compactMap(NWEndpoint.Port.init(rawValue:))
  static let candidatePorts = [defaultPort] + fallbackPorts

  static var supportDirectory: URL {
    let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return root.appendingPathComponent("Islet", isDirectory: true)
  }
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
  nonisolated static let loopbackHosts = [
    NWEndpoint.Host("127.0.0.1"),
    NWEndpoint.Host("::1"),
  ]
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

  private var listeners: [any PulseListening] = []
  private var readyListenerIDs: Set<ObjectIdentifier> = []
  private var connections: [ObjectIdentifier: NWConnection] = [:]
  private var commandPipelines: [ObjectIdentifier: PulseCommandPipeline] = [:]
  private var commandTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
  private var authenticationTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
  private var authenticatedCredentials: [ObjectIdentifier: String] = [:]
  private let queue = DispatchQueue(label: "dev.islet.pulse", qos: .utility)
  @Published private(set) var isRunning = false
  @Published private(set) var lastError: String?
  @Published private(set) var activePort: UInt16?
  @Published private(set) var portRecoveryMessage: String?
  @Published private(set) var nextRetryAt: Date?
  let credentialStore: PulseCredentialStore
  private var rateLimiters = PulseProviderRateLimiters()
  private var candidateIndex = 0
  private var retryTask: (any PulseRetryCancellable)?
  private var stableReadyTask: (any PulseRetryCancellable)?
  private var retryAttempt = 0
  private var lifecycleGeneration = 0
  private let listenerFactory: ListenerFactory
  private let activePortWriter: (UInt16) throws -> Void
  private let activePortRemover: () -> Void
  private let now: () -> Date
  private let retryScheduler: RetryScheduler

  init(
    credentialStore: PulseCredentialStore = PulseCredentialStore(),
    listenerFactory: @escaping ListenerFactory = { parameters, port in
      try NWListener(using: parameters, on: port)
    },
    activePortWriter: ((UInt16) throws -> Void)? = nil,
    activePortRemover: (() -> Void)? = nil,
    now: @escaping () -> Date = Date.init,
    retryScheduler: @escaping RetryScheduler = { delay, action in
      PulseRetryTask(after: delay, action: action)
    }
  ) {
    self.credentialStore = credentialStore
    self.listenerFactory = listenerFactory
    self.activePortWriter = activePortWriter ?? Self.writeActivePort
    self.activePortRemover = activePortRemover ?? Self.removeActivePort
    self.now = now
    self.retryScheduler = retryScheduler
  }

  var listeningAddress: String? {
    activePort.map { "localhost:\($0)" }
  }

  func start() {
    guard listeners.isEmpty else { return }
    lifecycleGeneration += 1
    cancelScheduledRetries()
    startFreshAttempt()
  }

  private func startFreshAttempt() {
    do {
      try credentialStore.prepare()
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
    var createdListeners: [any PulseListening] = []
    do {
      for host in Self.loopbackHosts {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        // `requiredLocalEndpoint` constrains the address, while `NWListener(on:)` selects the
        // candidate port. Use one numeric listener per family rather than `localhost` or an
        // unspecified address, either of which could select a wildcard/LAN binding.
        parameters.requiredLocalEndpoint = .hostPort(host: host, port: .any)
        createdListeners.append(try listenerFactory(parameters, port))
      }
    } catch {
      for listener in createdListeners { listener.cancel() }
      throw error
    }
    readyListenerIDs.removeAll()
    listeners = createdListeners
    for listener in createdListeners {
      listener.newConnectionHandler = { [weak self] connection in
        Task { @MainActor in self?.accept(connection) }
      }
      listener.stateUpdateHandler = { [weak self, weak listener] state in
        Task { @MainActor in
          guard let self, let listener,
            self.listeners.contains(where: { $0 === listener })
          else { return }
          self.handle(state, from: listener)
        }
      }
      listener.start(queue: queue)
    }
  }

  private func handle(_ state: NWListener.State, from listener: any PulseListening) {
    switch state {
    case .ready:
      let expectedPort = PulsePaths.candidatePorts[candidateIndex].rawValue
      // Network.framework reports the port selected by `NWListener(on:)`; the required endpoint
      // intentionally uses `.any` because specifying the port in both places is invalid.
      guard listener.port?.rawValue == expectedPort else {
        fail(PulseServerError.missingActivePort)
        return
      }
      guard readyListenerIDs.insert(ObjectIdentifier(listener)).inserted,
        readyListenerIDs.count == listeners.count
      else { return }
      do {
        try activePortWriter(expectedPort)
        activePort = expectedPort
        isRunning = true
        lastError = nil
        nextRetryAt = nil
        portRecoveryMessage =
          expectedPort == PulsePaths.defaultPort.rawValue
          ? nil
          : "Port 47717 is in use. Pulse moved to \(expectedPort); bundled clients discover it automatically."
        scheduleBackoffReset()
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
      cancelListeners()
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
    cancelListeners()
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
    cancelListeners()
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
    cancelListeners()
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

  private func scheduleBackoffReset() {
    stableReadyTask?.cancel()
    let generation = lifecycleGeneration
    stableReadyTask = retryScheduler(Self.retryStableReadyPeriod) {
      [weak self] in
      guard let self, self.lifecycleGeneration == generation,
        !self.listeners.isEmpty, self.isRunning
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

  private func cancelListeners() {
    let activeListeners = listeners
    listeners.removeAll()
    readyListenerIDs.removeAll()
    for listener in activeListeners { listener.cancel() }
  }

  func stop() {
    lifecycleGeneration += 1
    cancelScheduledRetries()
    cancelListeners()
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
    authenticatedCredentials.removeAll()
  }

  func retryDefaultPort() {
    stop()
    start()
  }

  @discardableResult
  func createProvider(
    name: String, source: String, permissions: Set<PulseCredentialPermission>
  ) throws -> PulseCredentialSummary {
    try credentialStore.createProvider(name: name, source: source, permissions: permissions)
  }

  func setPermissions(_ permissions: Set<PulseCredentialPermission>, for id: String) throws {
    let previous = credentialStore.credentials.first { $0.id == id }
    try credentialStore.setPermissions(permissions, for: id)
    if previous?.permissions.contains(.persistentActivities) == true,
      !permissions.contains(.persistentActivities), let source = previous?.source
    {
      PulseCenter.shared.removeItems(forSource: source)
    }
    disconnectProvider(id)
  }

  func rotateCredential(_ id: String) throws {
    try credentialStore.rotate(id)
    rateLimiters.removeProvider(id)
    disconnectProvider(id)
  }

  func revokeCredential(_ id: String) throws {
    let source = credentialStore.credentials.first { $0.id == id }?.source
    defer {
      if credentialStore.credentials.first(where: { $0.id == id })?.isRevoked == true {
        rateLimiters.removeProvider(id)
        if let source { PulseCenter.shared.removeItems(forSource: source) }
        disconnectProvider(id)
      }
    }
    try credentialStore.revoke(id)
  }

  private func disconnectProvider(_ credentialID: String) {
    let ids = authenticatedCredentials.compactMap { entry in
      entry.value == credentialID ? entry.key : nil
    }
    for id in ids {
      connections[id]?.cancel()
      removeConnection(id)
    }
  }

  private func accept(_ connection: NWConnection) {
    guard Self.isLoopbackPeer(connection.endpoint) else {
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
    authenticatedCredentials[id] = nil
  }

  private func markAuthenticated(_ id: ObjectIdentifier) {
    authenticationTasks.removeValue(forKey: id)?.cancel()
  }

  nonisolated static func isLoopbackPeer(_ endpoint: NWEndpoint) -> Bool {
    guard case .hostPort(let host, _) = endpoint else { return false }
    return loopbackHosts.contains(host)
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
      let incoming = try PulseWireCodec.decoder().decode(PulseCommand.self, from: data)
      let provider = try credentialStore.authenticate(incoming.token)
      if let pinnedCredential = authenticatedCredentials[id],
        pinnedCredential != provider.credentialID
      {
        throw PulseCredentialError.unauthorized
      }
      authenticatedCredentials[id] = provider.credentialID
      markAuthenticated(id)
      switch rateLimiters.admit(
        providerID: provider.credentialID, at: ProcessInfo.processInfo.systemUptime)
      {
      case .accepted:
        break
      case .rateLimited(let scope, let retryAfter):
        let subject = scope == .provider ? "provider" : "Pulse process"
        send(
          .failure(
            "\(subject) command rate exceeded",
            code: .rateLimited, requestID: incoming.requestID, retryAfter: retryAfter),
          on: connection)
        return false
      }
      let (command, _) = try credentialStore.authorize(incoming, as: provider)
      send(PulseCenter.shared.applyIfEnabled(command), on: connection)
      return true
    } catch let error as PulseCredentialError {
      send(
        .failure(
          error.localizedDescription, code: Self.errorCode(for: error),
          requestID: Self.requestID(in: data)),
        on: connection)
      return false
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

  nonisolated private static func requestID(in data: Data) -> String? {
    (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["requestID"] as? String
  }

  nonisolated private static func errorCode(for error: PulseCredentialError) -> PulseErrorCode {
    switch error {
    case .revoked: .credentialRevoked
    case .requestIDRequired: .requestIDRequired
    case .replayedRequest: .replayedRequest
    case .sourceSpoofing: .sourceMismatch
    case .permissionDenied: .permissionDenied
    case .unauthorized, .notFound, .unsafeCredentialFile, .corruptRegistry, .duplicateSource,
      .providerLimitReached, .invalidName, .invalidSource:
      .unauthorized
    }
  }

  private static func writeActivePort(_ port: UInt16) throws {
    try Data("\(port)\n".utf8).write(to: PulsePaths.activePortURL, options: .atomic)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: PulsePaths.activePortURL.path)
  }

  private static func removeActivePort() {
    try? FileManager.default.removeItem(at: PulsePaths.activePortURL)
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
