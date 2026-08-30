import Combine
import Foundation
import Network

enum PulsePaths {
  static let port = NWEndpoint.Port(rawValue: 47_717)!

  static var supportDirectory: URL {
    let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return root.appendingPathComponent("Islet", isDirectory: true)
  }
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
  private var authenticatedCredentials: [ObjectIdentifier: String] = [:]
  private let queue = DispatchQueue(label: "dev.islet.pulse", qos: .utility)
  @Published private(set) var isRunning = false
  @Published private(set) var lastError: String?
  let credentialStore: PulseCredentialStore
  private var rateLimiters: [String: PulseRateLimiter] = [:]

  init(credentialStore: PulseCredentialStore = PulseCredentialStore()) {
    self.credentialStore = credentialStore
  }

  func start() {
    guard listener == nil else { return }
    do {
      try credentialStore.prepare()
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
    authenticatedCredentials.removeAll()
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
    rateLimiters[id] = nil
    disconnectProvider(id)
  }

  func revokeCredential(_ id: String) throws {
    let source = credentialStore.credentials.first { $0.id == id }?.source
    try credentialStore.revoke(id)
    rateLimiters[id] = nil
    if let source { PulseCenter.shared.removeItems(forSource: source) }
    disconnectProvider(id)
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
    authenticatedCredentials[id] = nil
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
      let incoming = try PulseWireCodec.decoder().decode(PulseCommand.self, from: data)
      let provider = try credentialStore.authenticate(incoming.token)
      if let pinnedCredential = authenticatedCredentials[id],
        pinnedCredential != provider.credentialID
      {
        throw PulseCredentialError.unauthorized
      }
      authenticatedCredentials[id] = provider.credentialID
      markAuthenticated(id)
      var limiter = rateLimiters[provider.credentialID] ?? PulseRateLimiter()
      guard limiter.accepts(ProcessInfo.processInfo.systemUptime) else {
        send(
          .failure(
            "provider command rate exceeded; retry later", code: .rateLimited,
            requestID: incoming.requestID),
          on: connection)
        return false
      }
      rateLimiters[provider.credentialID] = limiter
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
