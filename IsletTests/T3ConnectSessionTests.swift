import Foundation
import XCTest

@testable import Islet

final class T3ConnectSessionTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)
  private let oldGrantID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
  private let newGrantID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

  func testAuthorizationCodeExchangeSendsExactFormAndStaysUncommittedUntilCommit() async throws {
    let oldRecord = try record(expiresIn: 3_600)
    let secureStore = try secureStore(oauthRecord: oldRecord)
    let recorder = T3OAuthHTTPRecorder(
      responses: [
        .json(
          status: 200,
          #"{"access_token":"new-access","refresh_token":"new-refresh","token_type":"Bearer","expires_in":3600,"id_token":"\#(idToken(email: "person@example.com"))"}"#
        )
      ])
    let session = makeSession(store: secureStore, recorder: recorder, grantID: newGrantID)

    let candidate = try await session.exchangeAuthorizationCode(
      "code +/?", verifier: "verifier +/?")

    XCTAssertEqual(candidate.grantID, newGrantID)
    XCTAssertEqual(candidate.accessToken, "new-access")
    XCTAssertEqual(candidate.refreshToken, "new-refresh")
    XCTAssertEqual(candidate.displayIdentity, "person@example.com")
    let uncommittedRecord = try await secureStore.oauthRecord()
    let recordedRequests = recorder.requests()
    let request = try XCTUnwrap(recordedRequests.first)
    XCTAssertEqual(uncommittedRecord, oldRecord)
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
    XCTAssertEqual(
      request.value(forHTTPHeaderField: "Content-Type"),
      "application/x-www-form-urlencoded")
    XCTAssertEqual(
      String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self),
      "grant_type=authorization_code&client_id=test-client&code=code%20%2B%2F%3F"
        + "&code_verifier=verifier%20%2B%2F%3F"
        + "&redirect_uri=http%3A%2F%2F127.0.0.1%3A34338%2Fcallback")

    try await session.commit(candidate)

    let committedRecord = try await secureStore.oauthRecord()
    XCTAssertEqual(committedRecord, candidate)
  }

  func testAuthorizationResponseRequiresBearerNonemptyBoundedTokensAndFiniteExpiry() async throws {
    let invalidBodies = [
      #"{"access_token":"access","refresh_token":"refresh","token_type":"MAC","expires_in":3600}"#,
      #"{"access_token":"","refresh_token":"refresh","token_type":"Bearer","expires_in":3600}"#,
      #"{"access_token":"access","refresh_token":"","token_type":"Bearer","expires_in":3600}"#,
      #"{"access_token":"access","refresh_token":"refresh","token_type":"Bearer","expires_in":0}"#,
      #"{"access_token":"access","refresh_token":"refresh","token_type":"Bearer","expires_in":1e309}"#,
    ]

    for body in invalidBodies {
      let secureStore = T3SessionSecureRecordStore()
      let recorder = T3OAuthHTTPRecorder(responses: [.json(status: 200, body)])
      let session = makeSession(store: secureStore, recorder: recorder, grantID: newGrantID)

      do {
        _ = try await session.exchangeAuthorizationCode("code", verifier: "verifier")
        XCTFail("Expected an invalid OAuth response for \(body)")
      } catch T3ConnectSessionError.invalidTokenResponse {
      }
    }

    let oversizedToken = String(repeating: "a", count: T3OAuthRecord.maximumTokenBytes + 1)
    let tokenStore = T3SessionSecureRecordStore()
    let tokenRecorder = T3OAuthHTTPRecorder(
      responses: [
        .json(
          status: 200,
          #"{"access_token":"\#(oversizedToken)","refresh_token":"refresh","token_type":"Bearer","expires_in":3600}"#
        )
      ])
    let tokenSession = makeSession(store: tokenStore, recorder: tokenRecorder, grantID: newGrantID)
    do {
      _ = try await tokenSession.exchangeAuthorizationCode("code", verifier: "verifier")
      XCTFail("Expected an oversized token to fail")
    } catch T3ConnectSessionError.invalidTokenResponse {
    }

    let bodyStore = T3SessionSecureRecordStore()
    let oversizedBody = Data(repeating: 0x20, count: T3ConnectSession.maximumOAuthResponseBytes + 1)
    let bodyRecorder = T3OAuthHTTPRecorder(responses: [.init(status: 200, data: oversizedBody)])
    let bodySession = makeSession(store: bodyStore, recorder: bodyRecorder, grantID: newGrantID)
    do {
      _ = try await bodySession.exchangeAuthorizationCode("code", verifier: "verifier")
      XCTFail("Expected an oversized OAuth body to fail")
    } catch T3ConnectSessionError.invalidTokenResponse {
    }
  }

  func testRefreshStartsFiveMinutesEarlyAndSendsTheExactForm() async throws {
    let freshRecord = try record(expiresIn: 301)
    let freshStore = try secureStore(oauthRecord: freshRecord)
    let freshRecorder = T3OAuthHTTPRecorder(responses: [])
    let freshSession = makeSession(store: freshStore, recorder: freshRecorder)

    let stillFreshRecord = try await freshSession.validOAuthRecord()
    let freshRequests = freshRecorder.requests()
    XCTAssertEqual(stillFreshRecord, freshRecord)
    XCTAssertTrue(freshRequests.isEmpty)

    let expiringRecord = try record(expiresIn: 300, refreshToken: "refresh +/?")
    let expiringStore = try secureStore(oauthRecord: expiringRecord)
    let expiringRecorder = T3OAuthHTTPRecorder(
      responses: [
        .json(
          status: 200,
          #"{"access_token":"refreshed","token_type":"Bearer","expires_in":3600}"#)
      ])
    let expiringSession = makeSession(store: expiringStore, recorder: expiringRecorder)

    _ = try await expiringSession.validOAuthRecord()

    let expiringRequests = expiringRecorder.requests()
    let request = try XCTUnwrap(expiringRequests.first)
    XCTAssertEqual(
      String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self),
      "grant_type=refresh_token&client_id=test-client&refresh_token=refresh%20%2B%2F%3F")
  }

  func testConcurrentCallersShareOneSuspendedRefresh() async throws {
    let expiringRecord = try record(expiresIn: 1)
    let secureStore = try secureStore(oauthRecord: expiringRecord)
    let recorder = T3OAuthHTTPRecorder(
      responses: [
        .json(
          status: 200,
          #"{"access_token":"refreshed","token_type":"Bearer","expires_in":3600}"#)
      ],
      suspended: true)
    let reused = T3SessionSignal()
    let session = makeSession(
      store: secureStore, recorder: recorder, onRefreshTaskReused: { reused.signal() })

    async let first = session.validOAuthRecord()
    await recorder.waitForRequestCount(1)
    async let second = session.validOAuthRecord()
    await reused.wait()
    recorder.resumeAll()

    let records = try await [first, second]
    XCTAssertEqual(records[0], records[1])
    let requestCount = recorder.requests().count
    XCTAssertEqual(requestCount, 1)
  }

  func testRefreshPreservesGrantRefreshTokenAndIdentityWhenOmitted() async throws {
    let expiringRecord = try record(
      expiresIn: 1, refreshToken: "old-refresh", displayIdentity: "old@example.com")
    let secureStore = try secureStore(oauthRecord: expiringRecord)
    let recorder = T3OAuthHTTPRecorder(
      responses: [
        .json(
          status: 200,
          #"{"access_token":"new-access","token_type":"Bearer","expires_in":3600}"#)
      ])
    let session = makeSession(store: secureStore, recorder: recorder)

    let refreshed = try await session.validOAuthRecord()

    XCTAssertEqual(refreshed.grantID, oldGrantID)
    XCTAssertEqual(refreshed.refreshToken, "old-refresh")
    XCTAssertEqual(refreshed.displayIdentity, "old@example.com")
    let persistedRecord = try await secureStore.oauthRecord()
    XCTAssertEqual(persistedRecord, refreshed)
  }

  func testInvalidGrantAndUnauthorizedRequireReauthenticationWithoutDeletingGrant() async throws {
    for response in [
      T3OAuthHTTPResponse.json(status: 400, #"{"error":"invalid_grant","extra":"private"}"#),
      T3OAuthHTTPResponse.json(status: 401, #"{"error":"anything"}"#),
      T3OAuthHTTPResponse(
        status: 401,
        data: Data(repeating: 0x78, count: T3ConnectSession.maximumOAuthResponseBytes + 1)),
    ] {
      let expiringRecord = try record(expiresIn: 1)
      let secureStore = try secureStore(oauthRecord: expiringRecord)
      let recorder = T3OAuthHTTPRecorder(responses: [response])
      let session = makeSession(store: secureStore, recorder: recorder)

      do {
        _ = try await session.validOAuthRecord()
        XCTFail("Expected reauthentication")
      } catch T3ConnectSessionError.reauthenticationRequired {
      }

      let persistedRecord = try await secureStore.oauthRecord()
      let deletedAccounts = await secureStore.deletedAccounts()
      XCTAssertEqual(persistedRecord, expiringRecord)
      XCTAssertTrue(deletedAccounts.isEmpty)
    }
  }

  func testTransientRefreshFailureRetainsThePersistedGrant() async throws {
    let expiringRecord = try record(expiresIn: 1)
    let secureStore = try secureStore(oauthRecord: expiringRecord)
    let recorder = T3OAuthHTTPRecorder(
      responses: [.json(status: 503, #"{"error":"temporarily_unavailable"}"#)])
    let session = makeSession(store: secureStore, recorder: recorder)

    do {
      _ = try await session.validOAuthRecord()
      XCTFail("Expected a transient OAuth failure")
    } catch T3ConnectSessionError.httpStatus(503) {
    }

    let persistedRecord = try await secureStore.oauthRecord()
    let deletedAccounts = await secureStore.deletedAccounts()
    XCTAssertEqual(persistedRecord, expiringRecord)
    XCTAssertTrue(deletedAccounts.isEmpty)
  }

  func testSignOutDuringSuspendedRefreshCannotRewriteDeletedCredentials() async throws {
    let expiringRecord = try record(expiresIn: 1)
    let secureStore = try secureStore(oauthRecord: expiringRecord, suspendOAuthReplacement: true)
    let recorder = T3OAuthHTTPRecorder(
      responses: [
        .json(
          status: 200,
          #"{"access_token":"stale-access","token_type":"Bearer","expires_in":3600}"#)
      ])
    let signOutBegan = T3SessionSignal()
    let session = makeSession(
      store: secureStore, recorder: recorder, onSignOutBegan: { signOutBegan.signal() })
    let refreshTask = Task { try await session.validOAuthRecord() }
    await secureStore.waitForOAuthReplacement()

    let signOutTask = Task { try await session.signOut() }
    await signOutBegan.wait()
    await secureStore.resumeOAuthReplacement()
    try await signOutTask.value
    _ = try? await refreshTask.value

    let persistedRecord = try await secureStore.oauthRecord()
    let deletedAccounts = await secureStore.deletedAccounts()
    XCTAssertNil(persistedRecord)
    XCTAssertEqual(
      deletedAccounts,
      [T3ConnectCredentialStore.oauthAccount, T3ConnectCredentialStore.dpopKeyAccount])
  }

  func testLoadStoredAccountReturnsPersistedDisplayIdentity() async throws {
    let stored = try record(expiresIn: 1, displayIdentity: "person@example.com")
    let secureStore = try secureStore(oauthRecord: stored)
    let session = makeSession(store: secureStore, recorder: T3OAuthHTTPRecorder(responses: []))

    let account = try await session.loadStoredAccount()

    XCTAssertEqual(account, T3ConnectAccount(record: stored))
  }

  private func makeSession(
    store: T3SessionSecureRecordStore,
    recorder: T3OAuthHTTPRecorder,
    grantID: UUID? = nil,
    onRefreshTaskReused: @escaping @Sendable () -> Void = {},
    onSignOutBegan: @escaping @Sendable () -> Void = {}
  ) -> T3ConnectSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [T3OAuthURLProtocol.self]
    T3OAuthURLProtocol.recorder = recorder
    let transport = T3HTTPTransport(session: URLSession(configuration: configuration))
    let fixedNow = now
    return T3ConnectSession(
      credentialStore: T3ConnectCredentialStore(store: store),
      transport: transport,
      configuration: .test,
      now: { fixedNow },
      grantID: { grantID ?? UUID() },
      onRefreshTaskReused: onRefreshTaskReused,
      onSignOutBegan: onSignOutBegan)
  }

  private func record(
    expiresIn: TimeInterval,
    refreshToken: String = "old-refresh",
    displayIdentity: String? = "old@example.com"
  ) throws -> T3OAuthRecord {
    try T3OAuthRecord(
      grantID: oldGrantID, accessToken: "old-access", refreshToken: refreshToken,
      expiresAt: now.addingTimeInterval(expiresIn), displayIdentity: displayIdentity)
  }

  private func secureStore(
    oauthRecord: T3OAuthRecord,
    suspendOAuthReplacement: Bool = false
  ) throws -> T3SessionSecureRecordStore {
    T3SessionSecureRecordStore(
      records: [T3ConnectCredentialStore.oauthAccount: try JSONEncoder().encode(oauthRecord)],
      suspendOAuthReplacement: suspendOAuthReplacement)
  }

  private func idToken(email: String) -> String {
    let payload = try! JSONSerialization.data(withJSONObject: ["email": email])
    return "header.\(payload.base64URLString).signature"
  }
}

extension T3ConnectConfiguration {
  fileprivate static let test = T3ConnectConfiguration(
    hostedAuthorizationURL: URL(string: "https://app.t3-unit.test/connect")!,
    tokenEndpoint: URL(string: "https://oauth.t3-unit.test/token")!,
    clientID: "test-client",
    redirectURI: URL(string: "http://127.0.0.1:34338/callback")!,
    scopes: ["openid", "profile", "email"],
    relayOrigin: URL(string: "https://relay.t3-unit.test")!,
    relayClientID: "test-relay-client")
}

private struct T3OAuthHTTPResponse: Sendable {
  let status: Int
  let data: Data

  static func json(status: Int, _ body: String) -> Self {
    Self(status: status, data: Data(body.utf8))
  }
}

private final class T3OAuthHTTPRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var responses: [T3OAuthHTTPResponse]
  private var recordedRequests: [URLRequest] = []
  private var pendingLoaders: [T3OAuthURLProtocol] = []
  private var requestWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
  private let suspended: Bool

  init(responses: [T3OAuthHTTPResponse], suspended: Bool = false) {
    self.responses = responses
    self.suspended = suspended
  }

  func handle(_ loader: T3OAuthURLProtocol) {
    var recordedRequest = loader.request
    if recordedRequest.httpBody == nil, let stream = recordedRequest.httpBodyStream {
      recordedRequest.httpBody = Self.read(stream)
    }
    lock.lock()
    recordedRequests.append(recordedRequest)
    let satisfied = requestWaiters.filter { recordedRequests.count >= $0.0 }
    requestWaiters.removeAll { recordedRequests.count >= $0.0 }
    if suspended {
      pendingLoaders.append(loader)
      lock.unlock()
    } else {
      let response = nextResponse()
      lock.unlock()
      deliver(response, to: loader)
    }
    for waiter in satisfied { waiter.1.resume() }
  }

  func requests() -> [URLRequest] {
    lock.lock()
    defer { lock.unlock() }
    return recordedRequests
  }

  func waitForRequestCount(_ count: Int) async {
    await withCheckedContinuation { continuation in
      lock.lock()
      if recordedRequests.count >= count {
        lock.unlock()
        continuation.resume()
        return
      }
      requestWaiters.append((count, continuation))
      lock.unlock()
    }
  }

  func resumeAll() {
    lock.lock()
    let loaders = pendingLoaders
    pendingLoaders.removeAll()
    let deliveries = loaders.map { ($0, nextResponse()) }
    lock.unlock()
    for (loader, response) in deliveries { deliver(response, to: loader) }
  }

  private func nextResponse() -> T3OAuthHTTPResponse? {
    responses.isEmpty ? nil : responses.removeFirst()
  }

  private func deliver(_ response: T3OAuthHTTPResponse?, to loader: T3OAuthURLProtocol) {
    guard let response else {
      loader.fail(URLError(.badServerResponse))
      return
    }
    loader.deliver(response)
  }

  private static func read(_ stream: InputStream) -> Data {
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 1_024)
    while stream.hasBytesAvailable {
      let count = stream.read(&buffer, maxLength: buffer.count)
      guard count > 0 else { break }
      data.append(contentsOf: buffer.prefix(count))
    }
    return data
  }
}

private final class T3OAuthURLProtocol: URLProtocol, @unchecked Sendable {
  nonisolated(unsafe) static var recorder: T3OAuthHTTPRecorder?

  private let lock = NSLock()
  private var stopped = false

  override class func canInit(with request: URLRequest) -> Bool {
    request.url?.host == "oauth.t3-unit.test"
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let recorder = Self.recorder else { return }
    recorder.handle(self)
  }

  override func stopLoading() {
    lock.lock()
    stopped = true
    lock.unlock()
  }

  func deliver(_ response: T3OAuthHTTPResponse) {
    guard !isStopped, let url = request.url else { return }
    let http = HTTPURLResponse(
      url: url, statusCode: response.status, httpVersion: "HTTP/1.1",
      headerFields: ["Content-Type": "application/json"])!
    client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: response.data)
    client?.urlProtocolDidFinishLoading(self)
  }

  func fail(_ error: Error) {
    guard !isStopped else { return }
    client?.urlProtocol(self, didFailWithError: error)
  }

  private var isStopped: Bool {
    lock.lock()
    defer { lock.unlock() }
    return stopped
  }
}

private actor T3SessionSecureRecordStore: T3SecureRecordStore {
  private var records: [String: Data]
  private let suspendOAuthReplacement: Bool
  private var didSuspendOAuthReplacement = false
  private var oauthReplacementStarted = false
  private var oauthReplacementWaiter: CheckedContinuation<Void, Never>?
  private var oauthReplacementContinuation: CheckedContinuation<Void, Never>?
  private var deletions: [String] = []

  init(records: [String: Data] = [:], suspendOAuthReplacement: Bool = false) {
    self.records = records
    self.suspendOAuthReplacement = suspendOAuthReplacement
  }

  func data(service: String, account: String) async throws -> Data? { records[account] }

  func replace(_ data: Data, service: String, account: String, label: String) async throws {
    if account == T3ConnectCredentialStore.oauthAccount, suspendOAuthReplacement,
      !didSuspendOAuthReplacement
    {
      didSuspendOAuthReplacement = true
      oauthReplacementStarted = true
      oauthReplacementWaiter?.resume()
      oauthReplacementWaiter = nil
      await withCheckedContinuation { continuation in
        oauthReplacementContinuation = continuation
      }
    }
    records[account] = data
  }

  func delete(service: String, account: String) async throws {
    deletions.append(account)
    records.removeValue(forKey: account)
  }

  func oauthRecord() throws -> T3OAuthRecord? {
    guard let data = records[T3ConnectCredentialStore.oauthAccount] else { return nil }
    return try JSONDecoder().decode(T3OAuthRecord.self, from: data)
  }

  func deletedAccounts() -> [String] { deletions }

  func waitForOAuthReplacement() async {
    if oauthReplacementStarted { return }
    await withCheckedContinuation { continuation in
      oauthReplacementWaiter = continuation
    }
  }

  func resumeOAuthReplacement() {
    oauthReplacementContinuation?.resume()
    oauthReplacementContinuation = nil
  }
}

private final class T3SessionSignal: @unchecked Sendable {
  private let lock = NSLock()
  private var signaled = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func signal() {
    lock.lock()
    signaled = true
    let waiting = waiters
    waiters.removeAll()
    lock.unlock()
    for waiter in waiting { waiter.resume() }
  }

  func wait() async {
    await withCheckedContinuation { continuation in
      lock.lock()
      if signaled {
        lock.unlock()
        continuation.resume()
      } else {
        waiters.append(continuation)
        lock.unlock()
      }
    }
  }
}

extension Data {
  fileprivate var base64URLString: String {
    base64EncodedString().replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
  }
}
