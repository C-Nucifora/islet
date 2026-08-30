import Foundation
@preconcurrency import Network

enum T3OAuthCallbackResult: Equatable, Sendable {
  case authorizationCode(String)
  case denied(String)
}

enum T3OAuthLoopbackError: Error, Equatable, LocalizedError {
  case portInUse
  case timedOut
  case notStarted
  case alreadyWaiting
  case invalidLocalEndpoint
  case listenerFailed

  var errorDescription: String? {
    switch self {
    case .portInUse:
      "The T3 authorization port is busy. Close the other authorization attempt and try again."
    case .timedOut:
      "T3 authorization timed out."
    case .notStarted:
      "The T3 authorization listener has not started."
    case .alreadyWaiting:
      "The T3 authorization listener is already waiting for a callback."
    case .invalidLocalEndpoint:
      "The T3 authorization listener could not use IPv4 loopback."
    case .listenerFailed:
      "The T3 authorization listener failed."
    }
  }
}

protocol T3OAuthLoopbackListening: Sendable {
  func start(state: String) async throws
  func waitForCallback() async throws -> T3OAuthCallbackResult
  func cancel() async
}

actor T3OAuthLoopbackListener: T3OAuthLoopbackListening {
  nonisolated static let maximumHeaderBytes = 8 * 1_024
  private nonisolated static let productionPort: UInt16 = 34_338
  private nonisolated static let loopbackHost = NWEndpoint.Host("127.0.0.1")

  let configuredPort: UInt16

  private let timeout: Duration
  private let responseCompletionGate: @Sendable () async -> Void
  private let onResponseCompletionHandled: @Sendable () -> Void
  private let onWaitForCallbackEntered: @Sendable () -> Void
  private let queue = DispatchQueue(label: "dev.islet.t3-oauth-callback", qos: .userInitiated)
  private var listener: NWListener?
  private var connections: [ObjectIdentifier: NWConnection] = [:]
  private var startContinuation: CheckedContinuation<Void, any Error>?
  private var callbackContinuation: CheckedContinuation<T3OAuthCallbackResult, any Error>?
  private var timeoutTask: Task<Void, Never>?
  private var ready = false
  private var completing = false
  private var terminalError: (any Error)?
  private var terminalResult: T3OAuthCallbackResult?
  private var generation: UInt64 = 0

  static func production() -> T3OAuthLoopbackListener {
    T3OAuthLoopbackListener(port: productionPort, timeout: .seconds(10 * 60))
  }

  init(
    port: UInt16, timeout: Duration,
    responseCompletionGate: @escaping @Sendable () async -> Void = {},
    onResponseCompletionHandled: @escaping @Sendable () -> Void = {},
    onWaitForCallbackEntered: @escaping @Sendable () -> Void = {}
  ) {
    configuredPort = port
    self.timeout = timeout
    self.responseCompletionGate = responseCompletionGate
    self.onResponseCompletionHandled = onResponseCompletionHandled
    self.onWaitForCallbackEntered = onWaitForCallbackEntered
  }

  func start(state: String) async throws {
    try Task.checkCancellation()
    if ready { return }
    if let terminalError { throw terminalError }
    guard listener == nil, startContinuation == nil,
      let port = NWEndpoint.Port(rawValue: configuredPort)
    else {
      throw T3OAuthLoopbackError.listenerFailed
    }
    storedCallbackState = state

    let parameters = NWParameters.tcp
    parameters.allowLocalEndpointReuse = false
    parameters.requiredLocalEndpoint = .hostPort(host: Self.loopbackHost, port: .any)
    guard Self.isIPv4Loopback(parameters.requiredLocalEndpoint) else {
      throw T3OAuthLoopbackError.invalidLocalEndpoint
    }

    let newListener: NWListener
    do {
      newListener = try NWListener(using: parameters, on: port)
    } catch {
      throw Self.mapListenerError(error)
    }
    listener = newListener
    newListener.stateUpdateHandler = { [weak self, weak newListener] state in
      guard let self, let newListener else { return }
      Task { await self.handleListenerState(state, listener: newListener) }
    }
    newListener.newConnectionHandler = { [weak self] connection in
      guard let self else {
        connection.cancel()
        return
      }
      Task { await self.accept(connection) }
    }
    newListener.start(queue: queue)

    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        startContinuation = continuation
      }
    } onCancel: {
      Task { await self.cancel() }
    }
  }

  func waitForCallback() async throws -> T3OAuthCallbackResult {
    try Task.checkCancellation()
    onWaitForCallbackEntered()
    if let terminalResult {
      self.terminalResult = nil
      return terminalResult
    }
    if let terminalError { throw terminalError }
    guard ready else { throw T3OAuthLoopbackError.notStarted }
    guard callbackContinuation == nil else {
      throw T3OAuthLoopbackError.alreadyWaiting
    }
    timeoutTask = Task { [weak self, timeout] in
      do {
        try await Task.sleep(for: timeout)
      } catch {
        return
      }
      guard !Task.isCancelled else { return }
      await self?.finish(throwing: T3OAuthLoopbackError.timedOut)
    }

    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        callbackContinuation = continuation
      }
    } onCancel: {
      Task { await self.cancel() }
    }
  }

  func cancel() {
    finish(throwing: CancellationError())
  }

  private func handleListenerState(_ state: NWListener.State, listener: NWListener) {
    guard self.listener === listener else { return }
    switch state {
    case .ready:
      guard listener.port?.rawValue == configuredPort else {
        finish(throwing: T3OAuthLoopbackError.invalidLocalEndpoint)
        return
      }
      ready = true
      let continuation = startContinuation
      startContinuation = nil
      continuation?.resume()
    case .waiting(let error), .failed(let error):
      finish(throwing: Self.mapListenerError(error))
    case .cancelled:
      if !completing, terminalError == nil {
        finish(throwing: CancellationError())
      }
    case .setup:
      break
    @unknown default:
      finish(throwing: T3OAuthLoopbackError.listenerFailed)
    }
  }

  private func accept(_ connection: NWConnection) {
    guard ready, !completing, connections.isEmpty,
      Self.isIPv4Loopback(connection.endpoint)
    else {
      connection.cancel()
      return
    }
    let id = ObjectIdentifier(connection)
    connections[id] = connection
    connection.stateUpdateHandler = { [weak self, weak connection] state in
      guard let self, let connection else { return }
      Task { await self.handleConnectionState(state, connection: connection, id: id) }
    }
    connection.start(queue: queue)
  }

  private func handleConnectionState(
    _ state: NWConnection.State, connection: NWConnection, id: ObjectIdentifier
  ) {
    guard connections[id] === connection else { return }
    switch state {
    case .ready:
      guard let localEndpoint = connection.currentPath?.localEndpoint,
        Self.isIPv4Loopback(localEndpoint, port: configuredPort)
      else {
        connection.cancel()
        connections[id] = nil
        return
      }
      receive(on: connection, id: id, buffer: Data())
    case .failed, .cancelled:
      connections[id] = nil
    case .setup, .preparing, .waiting:
      break
    @unknown default:
      connection.cancel()
      connections[id] = nil
    }
  }

  private nonisolated func receive(
    on connection: NWConnection, id: ObjectIdentifier, buffer: Data
  ) {
    guard let maximumLength = Self.maximumReceiveLength(bufferedHeaderBytes: buffer.count) else {
      Task { await self.send(.headersTooLarge, on: connection, id: id, result: nil) }
      return
    }
    connection.receive(minimumIncompleteLength: 1, maximumLength: maximumLength) {
      [weak self, weak connection] data, _, complete, error in
      guard let self, let connection else { return }
      Task {
        await self.handleReceivedData(
          data, complete: complete, error: error, connection: connection, id: id,
          buffer: buffer)
      }
    }
  }

  private func handleReceivedData(
    _ data: Data?, complete: Bool, error: NWError?, connection: NWConnection,
    id: ObjectIdentifier, buffer: Data
  ) {
    guard connections[id] === connection, !completing else {
      connection.cancel()
      return
    }
    let remainingCapacity = Self.maximumHeaderBytes - buffer.count
    guard remainingCapacity >= 0, data?.count ?? 0 <= remainingCapacity else {
      send(.headersTooLarge, on: connection, id: id, result: nil)
      return
    }
    var accumulated = buffer
    if let data { accumulated.append(data) }

    if let headerRange = accumulated.range(of: Data("\r\n\r\n".utf8)) {
      guard headerRange.upperBound <= Self.maximumHeaderBytes else {
        send(.headersTooLarge, on: connection, id: id, result: nil)
        return
      }
      let body = accumulated[headerRange.upperBound...]
      guard body.isEmpty,
        let result = Self.parse(
          Data(accumulated[..<headerRange.lowerBound]), expectedState: expectedState)
      else {
        send(.invalid, on: connection, id: id, result: nil)
        return
      }
      completing = true
      timeoutTask?.cancel()
      timeoutTask = nil
      stopAccepting(except: id)
      let response: ResponseKind
      switch result {
      case .authorizationCode:
        response = .success
      case .denied:
        response = .denied
      }
      send(response, on: connection, id: id, result: result)
      return
    }

    guard accumulated.count < Self.maximumHeaderBytes else {
      send(.headersTooLarge, on: connection, id: id, result: nil)
      return
    }
    if error != nil || complete {
      send(.invalid, on: connection, id: id, result: nil)
    } else {
      receive(on: connection, id: id, buffer: accumulated)
    }
  }

  private var expectedState: String { storedCallbackState ?? "" }

  private var storedCallbackState: String?

  private func send(
    _ response: ResponseKind, on connection: NWConnection, id: ObjectIdentifier,
    result: T3OAuthCallbackResult?
  ) {
    let capturedGeneration = generation
    connection.send(
      content: response.data, contentContext: .finalMessage, isComplete: true,
      completion: .contentProcessed { [weak self, weak connection] _ in
        guard let self else { return }
        Task {
          await self.responseCompletionGate()
          await self.didSendResponse(
            id: id, result: result, capturedGeneration: capturedGeneration)
          self.onResponseCompletionHandled()
          connection?.cancel()
        }
      })
  }

  nonisolated static func maximumReceiveLength(bufferedHeaderBytes: Int) -> Int? {
    guard bufferedHeaderBytes >= 0, bufferedHeaderBytes < maximumHeaderBytes else { return nil }
    return min(2_048, maximumHeaderBytes - bufferedHeaderBytes)
  }

  private func didSendResponse(
    id: ObjectIdentifier, result: T3OAuthCallbackResult?, capturedGeneration: UInt64
  ) {
    connections[id] = nil
    guard capturedGeneration == generation, terminalError == nil, let result else { return }
    finish(returning: result)
  }

  private func stopAccepting(except preservedID: ObjectIdentifier) {
    let activeListener = listener
    listener = nil
    activeListener?.stateUpdateHandler = nil
    activeListener?.newConnectionHandler = nil
    activeListener?.cancel()
    for (id, connection) in connections where id != preservedID {
      connection.cancel()
      connections[id] = nil
    }
  }

  private func finish(returning result: T3OAuthCallbackResult) {
    generation &+= 1
    terminalError = nil
    cleanup()
    let continuation = callbackContinuation
    callbackContinuation = nil
    if let continuation {
      continuation.resume(returning: result)
    } else {
      terminalResult = result
    }
  }

  private func finish(throwing error: any Error) {
    generation &+= 1
    terminalError = error
    terminalResult = nil
    cleanup()
    let start = startContinuation
    let callback = callbackContinuation
    startContinuation = nil
    callbackContinuation = nil
    start?.resume(throwing: error)
    callback?.resume(throwing: error)
  }

  private func cleanup() {
    ready = false
    completing = true
    timeoutTask?.cancel()
    timeoutTask = nil
    storedCallbackState = nil
    let activeListener = listener
    listener = nil
    activeListener?.stateUpdateHandler = nil
    activeListener?.newConnectionHandler = nil
    activeListener?.cancel()
    for connection in connections.values { connection.cancel() }
    connections.removeAll()
  }

  private nonisolated static func parse(
    _ headerData: Data, expectedState: String
  ) -> T3OAuthCallbackResult? {
    guard let header = String(data: headerData, encoding: .utf8) else { return nil }
    let lines = header.components(separatedBy: "\r\n")
    guard let requestLine = lines.first else { return nil }
    let requestParts = requestLine.split(separator: " ", omittingEmptySubsequences: false)
    guard requestParts.count == 3, requestParts[0] == "GET",
      requestParts[2] == "HTTP/1.1" || requestParts[2] == "HTTP/1.0",
      let components = URLComponents(string: String(requestParts[1])),
      components.scheme == nil, components.host == nil, components.fragment == nil,
      components.percentEncodedPath == "/callback"
    else { return nil }

    var contentLengths: [String] = []
    for line in lines.dropFirst() {
      guard let colon = line.firstIndex(of: ":") else { return nil }
      let name = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      let value = line[line.index(after: colon)...]
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard !name.isEmpty, name != "transfer-encoding" else { return nil }
      if name == "content-length" { contentLengths.append(value) }
    }
    guard contentLengths.count <= 1,
      contentLengths.first.map({ $0 == "0" }) ?? true,
      let state = singleQueryValue("state", in: components),
      securelyEqual(state, expectedState)
    else { return nil }

    let code = singleQueryValue("code", in: components)
    let error = singleQueryValue("error", in: components)
    if let code, error == nil, !code.isEmpty { return .authorizationCode(code) }
    if let error, code == nil, isSafeOAuthError(error) { return .denied(error) }
    return nil
  }

  private nonisolated static func singleQueryValue(
    _ name: String, in components: URLComponents
  ) -> String? {
    let values = (components.queryItems ?? []).filter { $0.name == name }
    guard values.count == 1 else { return nil }
    return values[0].value
  }

  private nonisolated static func securelyEqual(_ left: String, _ right: String) -> Bool {
    let leftBytes = Array(left.utf8)
    let rightBytes = Array(right.utf8)
    guard leftBytes.count == rightBytes.count else { return false }
    var difference: UInt8 = 0
    for index in leftBytes.indices { difference |= leftBytes[index] ^ rightBytes[index] }
    return difference == 0
  }

  private nonisolated static func isSafeOAuthError(_ value: String) -> Bool {
    guard !value.isEmpty, value.utf8.count <= 128 else { return false }
    return value.unicodeScalars.allSatisfy {
      ("a"..."z").contains(Character($0)) || ("A"..."Z").contains(Character($0))
        || ("0"..."9").contains(Character($0)) || $0 == "_" || $0 == "-" || $0 == "."
    }
  }

  private nonisolated static func isIPv4Loopback(
    _ endpoint: NWEndpoint?, port: UInt16? = nil
  ) -> Bool {
    guard let endpoint, case .hostPort(let host, let endpointPort) = endpoint,
      host == loopbackHost, port.map({ endpointPort.rawValue == $0 }) ?? true
    else { return false }
    return true
  }

  private nonisolated static func mapListenerError(_ error: any Error) -> T3OAuthLoopbackError {
    if let networkError = error as? NWError,
      case .posix(let code) = networkError, code == .EADDRINUSE
    {
      return .portInUse
    }
    return .listenerFailed
  }

  private enum ResponseKind: Sendable {
    case success
    case denied
    case invalid
    case headersTooLarge

    var data: Data {
      let status: String
      let body: String
      switch self {
      case .success:
        status = "200 OK"
        body = "<html><body>Authorization complete. Return to Islet.</body></html>"
      case .denied:
        status = "200 OK"
        body = "<html><body>Authorization was denied. Return to Islet.</body></html>"
      case .invalid:
        status = "400 Bad Request"
        body = "<html><body>Invalid authorization callback.</body></html>"
      case .headersTooLarge:
        status = "431 Request Header Fields Too Large"
        body = "<html><body>Invalid authorization callback.</body></html>"
      }
      return Data(
        ("HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\n"
          + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)").utf8)
    }
  }
}
