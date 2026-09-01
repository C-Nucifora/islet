import Foundation

protocol T3OAuthCredentialStoring: Sendable {
  func loadOAuthRecord() async throws -> T3OAuthRecord?
  func replaceOAuthRecord(_ record: T3OAuthRecord) async throws
  func signOut() async throws
}

extension T3ConnectCredentialStore: T3OAuthCredentialStoring {}

enum T3ConnectSessionError: Error, Equatable, LocalizedError {
  case notLinked
  case invalidTokenResponse
  case reauthenticationRequired
  case httpStatus(Int)
  case staleOperation

  var errorDescription: String? {
    switch self {
    case .notLinked:
      "No T3 Connect account is linked."
    case .invalidTokenResponse:
      "T3 Connect returned an invalid token response."
    case .reauthenticationRequired:
      "T3 Connect requires authorization again."
    case .httpStatus(let status):
      "T3 Connect returned HTTP \(status)."
    case .staleOperation:
      "The T3 Connect operation was invalidated by sign-out."
    }
  }
}

actor T3ConnectSession {
  nonisolated static let maximumOAuthResponseBytes = 64 * 1_024
  private nonisolated static let refreshLeadTime: TimeInterval = 5 * 60
  private nonisolated static let requestDeadline: TimeInterval = 30

  private let credentialStore: any T3OAuthCredentialStoring
  private let transport: T3HTTPTransport
  private let configuration: T3ConnectConfiguration
  private let tokenOrigin: T3HTTPOrigin?
  private let now: @Sendable () -> Date
  private let grantID: @Sendable () -> UUID
  private let onRefreshTaskReused: @Sendable () -> Void
  private let onSignOutBegan: @Sendable () -> Void
  private let onOwnedRefreshCompleted: @Sendable () async -> Void
  private var refreshTask: PendingRefreshTask?
  private var refreshRevision: UInt64 = 0
  private var generation: UInt64 = 0
  private var accountTransitionInProgress = false

  init(
    credentialStore: any T3OAuthCredentialStoring = T3ConnectCredentialStore(),
    transport: T3HTTPTransport = .shared,
    configuration: T3ConnectConfiguration = .production,
    now: @escaping @Sendable () -> Date = Date.init,
    grantID: @escaping @Sendable () -> UUID = UUID.init,
    onRefreshTaskReused: @escaping @Sendable () -> Void = {},
    onSignOutBegan: @escaping @Sendable () -> Void = {},
    onOwnedRefreshCompleted: @escaping @Sendable () async -> Void = {}
  ) {
    self.credentialStore = credentialStore
    self.transport = transport
    self.configuration = configuration
    tokenOrigin = try? T3HTTPOrigin(configuration.tokenEndpoint)
    self.now = now
    self.grantID = grantID
    self.onRefreshTaskReused = onRefreshTaskReused
    self.onSignOutBegan = onSignOutBegan
    self.onOwnedRefreshCompleted = onOwnedRefreshCompleted
  }

  func loadStoredAccount() async throws -> T3ConnectAccount? {
    try await credentialStore.loadOAuthRecord().map(T3ConnectAccount.init(record:))
  }

  func exchangeAuthorizationCode(_ code: String, verifier: String) async throws -> T3OAuthRecord {
    let fields = [
      ("grant_type", "authorization_code"),
      ("client_id", configuration.clientID),
      ("code", code),
      ("code_verifier", verifier),
      ("redirect_uri", configuration.redirectURI.absoluteString),
    ]
    let response = try await sendTokenRequest(fields)
    return try authorizationRecord(from: response)
  }

  func validOAuthRecord() async throws -> T3OAuthRecord {
    let capturedGeneration = generation
    while true {
      try requireCurrent(capturedGeneration)
      if let refreshTask {
        onRefreshTaskReused()
        if refreshTask.cancellationRequested {
          try await waitForRefreshTaskTermination(refreshTask)
          try requireCurrent(capturedGeneration)
          continue
        }
        let refreshed = try await waitForRefreshTask(refreshTask)
        try requireCurrent(capturedGeneration)
        return refreshed
      }

      let capturedRefreshRevision = refreshRevision
      let loadedRecord = try await credentialStore.loadOAuthRecord()
      try requireCurrent(capturedGeneration)
      guard capturedRefreshRevision == refreshRevision else { continue }
      guard let record = loadedRecord else { throw T3ConnectSessionError.notLinked }
      if record.expiresAt.timeIntervalSince(now()) > Self.refreshLeadTime { return record }

      let taskID = UUID()
      let task = Task { [self] in
        try await refresh(record, capturedGeneration: capturedGeneration)
      }
      let pending = PendingRefreshTask(
        id: taskID, task: task, waiterIDs: [], cancellationRequested: false)
      refreshTask = pending
      refreshRevision &+= 1
      let refreshed = try await waitForRefreshTask(pending)
      await onOwnedRefreshCompleted()
      try requireCurrent(capturedGeneration)
      return refreshed
    }
  }

  func commit(_ candidate: T3OAuthRecord) async throws {
    try Task.checkCancellation()
    generation &+= 1
    let capturedGeneration = generation
    accountTransitionInProgress = true
    cancelRefreshTaskForAccountTransition()
    defer {
      if capturedGeneration == generation { accountTransitionInProgress = false }
    }
    try await credentialStore.replaceOAuthRecord(candidate)
    try Task.checkCancellation()
    guard capturedGeneration == generation else { throw T3ConnectSessionError.staleOperation }
  }

  func signOut() async throws {
    generation &+= 1
    let capturedGeneration = generation
    accountTransitionInProgress = true
    cancelRefreshTaskForAccountTransition()
    onSignOutBegan()
    defer {
      if capturedGeneration == generation { accountTransitionInProgress = false }
    }
    try await credentialStore.signOut()
  }

  private func refresh(
    _ record: T3OAuthRecord, capturedGeneration: UInt64
  ) async throws -> T3OAuthRecord {
    let fields = [
      ("grant_type", "refresh_token"),
      ("client_id", configuration.clientID),
      ("refresh_token", record.refreshToken),
    ]
    let response = try await sendTokenRequest(fields)
    try Task.checkCancellation()
    let candidate = try refreshedRecord(from: response, previous: record)
    guard capturedGeneration == generation else { throw T3ConnectSessionError.staleOperation }
    try await credentialStore.replaceOAuthRecord(candidate)
    try Task.checkCancellation()
    guard capturedGeneration == generation else { throw T3ConnectSessionError.staleOperation }
    return candidate
  }

  private func waitForRefreshTask(_ pending: PendingRefreshTask) async throws -> T3OAuthRecord {
    let waiterID = UUID()
    guard refreshTask?.id == pending.id else { throw T3ConnectSessionError.staleOperation }
    refreshTask?.waiterIDs.insert(waiterID)
    let waiter = T3SessionTaskWaiter<T3OAuthRecord>()
    Task { [self] in
      let result = await pending.task.result
      finishRefreshTask(id: pending.id)
      waiter.resolve(with: result)
      releaseRefreshWaiter(taskID: pending.id, waiterID: waiterID, cancelIfUnused: false)
    }
    return try await withTaskCancellationHandler {
      try await waiter.value()
    } onCancel: {
      Task {
        await self.releaseRefreshWaiter(
          taskID: pending.id, waiterID: waiterID, cancelIfUnused: true)
        waiter.resolve(with: .failure(CancellationError()))
      }
    }
  }

  private func waitForRefreshTaskTermination(_ pending: PendingRefreshTask) async throws {
    guard refreshTask?.id == pending.id else { return }
    let waiter = T3SessionTaskWaiter<Void>()
    Task { [self] in
      _ = await pending.task.result
      finishRefreshTask(id: pending.id)
      waiter.resolve(with: .success(()))
    }
    try await withTaskCancellationHandler {
      try await waiter.value()
    } onCancel: {
      waiter.resolve(with: .failure(CancellationError()))
    }
  }

  private func finishRefreshTask(id: UUID) {
    if refreshTask?.id == id {
      refreshTask = nil
      refreshRevision &+= 1
    }
  }

  private func releaseRefreshWaiter(
    taskID: UUID, waiterID: UUID, cancelIfUnused: Bool
  ) {
    guard var pending = refreshTask, pending.id == taskID,
      pending.waiterIDs.remove(waiterID) != nil
    else { return }
    if cancelIfUnused, pending.waiterIDs.isEmpty {
      pending.cancellationRequested = true
      refreshTask = pending
      refreshRevision &+= 1
      pending.task.cancel()
    } else {
      refreshTask = pending
    }
  }

  private func requireCurrent(_ capturedGeneration: UInt64) throws {
    try Task.checkCancellation()
    guard capturedGeneration == generation, !accountTransitionInProgress else {
      throw T3ConnectSessionError.staleOperation
    }
  }

  private func cancelRefreshTaskForAccountTransition() {
    guard let refreshTask else { return }
    self.refreshTask = nil
    refreshRevision &+= 1
    refreshTask.task.cancel()
  }

  private func sendTokenRequest(_ fields: [(String, String)]) async throws -> T3HTTPResponse {
    guard let tokenOrigin else { throw T3ClientError.invalidURL }
    var request = URLRequest(url: configuration.tokenEndpoint)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue(
      "application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.httpBody = Data(Self.formBody(fields).utf8)

    let response = try await transport.send(
      request, expectedOrigin: tokenOrigin, deadline: Self.requestDeadline)
    guard (200..<300).contains(response.statusCode) else {
      if response.statusCode == 401 {
        throw T3ConnectSessionError.reauthenticationRequired
      }
      guard response.data.count <= Self.maximumOAuthResponseBytes else {
        throw T3ConnectSessionError.invalidTokenResponse
      }
      if Self.oauthError(from: response.data) == "invalid_grant" {
        throw T3ConnectSessionError.reauthenticationRequired
      }
      throw T3ConnectSessionError.httpStatus(response.statusCode)
    }
    guard response.data.count <= Self.maximumOAuthResponseBytes else {
      throw T3ConnectSessionError.invalidTokenResponse
    }
    return response
  }

  private func authorizationRecord(from response: T3HTTPResponse) throws -> T3OAuthRecord {
    let token = try Self.decodeTokenResponse(response.data)
    guard let refreshToken = token.refreshToken else {
      throw T3ConnectSessionError.invalidTokenResponse
    }
    let receivedAt = now()
    do {
      return try T3OAuthRecord.authorizationGrant(
        accessToken: token.accessToken, refreshToken: refreshToken,
        expiresAt: receivedAt.addingTimeInterval(token.expiresIn),
        displayIdentity: token.idToken.flatMap(T3ConnectAccount.displayIdentity(fromIDToken:)),
        grantID: grantID, receivedAt: receivedAt)
    } catch {
      throw T3ConnectSessionError.invalidTokenResponse
    }
  }

  private func refreshedRecord(
    from response: T3HTTPResponse, previous: T3OAuthRecord
  ) throws -> T3OAuthRecord {
    let token = try Self.decodeTokenResponse(response.data)
    let receivedAt = now()
    do {
      return try previous.refreshed(
        accessToken: token.accessToken, refreshToken: token.refreshToken,
        expiresAt: receivedAt.addingTimeInterval(token.expiresIn),
        displayIdentity: token.idToken.flatMap(T3ConnectAccount.displayIdentity(fromIDToken:)),
        receivedAt: receivedAt)
    } catch {
      throw T3ConnectSessionError.invalidTokenResponse
    }
  }

  private nonisolated static func decodeTokenResponse(_ data: Data) throws -> OAuthTokenResponse {
    guard data.count <= maximumOAuthResponseBytes,
      let response = try? JSONDecoder().decode(OAuthTokenResponse.self, from: data),
      response.tokenType.caseInsensitiveCompare("Bearer") == .orderedSame,
      !response.accessToken.isEmpty,
      response.accessToken.utf8.count <= T3OAuthRecord.maximumTokenBytes,
      response.refreshToken.map({
        !$0.isEmpty && $0.utf8.count <= T3OAuthRecord.maximumTokenBytes
      }) ?? true,
      response.idToken.map({ $0.utf8.count <= T3OAuthRecord.maximumTokenBytes }) ?? true,
      response.expiresIn.isFinite, response.expiresIn > 0,
      response.expiresIn <= T3OAuthRecord.maximumResponseLifetime
    else {
      throw T3ConnectSessionError.invalidTokenResponse
    }
    return response
  }

  private nonisolated static func oauthError(from data: Data) -> String? {
    guard data.count <= maximumOAuthResponseBytes else { return nil }
    return try? JSONDecoder().decode(OAuthFailureResponse.self, from: data).error
  }

  private nonisolated static func formBody(_ fields: [(String, String)]) -> String {
    fields.map { "\(formEncode($0.0))=\(formEncode($0.1))" }.joined(separator: "&")
  }

  private nonisolated static func formEncode(_ value: String) -> String {
    let hexadecimal = Array("0123456789ABCDEF".utf8)
    var encoded = [UInt8]()
    encoded.reserveCapacity(value.utf8.count)
    for byte in value.utf8 {
      if (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
        || (byte >= 0x30 && byte <= 0x39) || byte == 0x2D || byte == 0x2E || byte == 0x5F
        || byte == 0x7E
      {
        encoded.append(byte)
      } else {
        encoded.append(0x25)
        encoded.append(hexadecimal[Int(byte >> 4)])
        encoded.append(hexadecimal[Int(byte & 0x0F)])
      }
    }
    return String(decoding: encoded, as: UTF8.self)
  }

  private struct OAuthTokenResponse: Decodable, Sendable {
    let accessToken: String
    let refreshToken: String?
    let tokenType: String
    let expiresIn: TimeInterval
    let idToken: String?

    enum CodingKeys: String, CodingKey {
      case accessToken = "access_token"
      case refreshToken = "refresh_token"
      case tokenType = "token_type"
      case expiresIn = "expires_in"
      case idToken = "id_token"
    }
  }

  private struct OAuthFailureResponse: Decodable, Sendable {
    let error: String?
  }

  private struct PendingRefreshTask: Sendable {
    let id: UUID
    let task: Task<T3OAuthRecord, any Error>
    var waiterIDs: Set<UUID>
    var cancellationRequested: Bool
  }
}

private final class T3SessionTaskWaiter<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Value, any Error>?
  private var result: Result<Value, any Error>?

  func value() async throws -> Value {
    try await withCheckedThrowingContinuation { continuation in
      lock.lock()
      if let result {
        lock.unlock()
        continuation.resume(with: result)
      } else {
        self.continuation = continuation
        lock.unlock()
      }
    }
  }

  func resolve(with result: Result<Value, any Error>) {
    lock.lock()
    guard self.result == nil else {
      lock.unlock()
      return
    }
    self.result = result
    let continuation = continuation
    self.continuation = nil
    lock.unlock()
    continuation?.resume(with: result)
  }
}
