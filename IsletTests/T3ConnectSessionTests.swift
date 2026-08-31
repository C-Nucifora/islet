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

  func testCancelingOnlyRefreshWaiterStopsRequestAndPreservesStoredGrant() async throws {
    let callerReturned = expectation(description: "canceled refresh caller returned")
    let refreshStopped = expectation(description: "refresh request stopped")
    let expiringRecord = try record(expiresIn: 1)
    let secureStore = try secureStore(oauthRecord: expiringRecord)
    let recorder = T3OAuthHTTPRecorder(
      responses: [
        .json(
          status: 200,
          #"{"access_token":"discarded","token_type":"Bearer","expires_in":3600}"#)
      ],
      suspended: true,
      onStop: { refreshStopped.fulfill() })
    let session = makeSession(store: secureStore, recorder: recorder)
    let caller = Task {
      do {
        _ = try await session.validOAuthRecord()
        XCTFail("Expected cancellation")
      } catch is CancellationError {
      } catch {
        XCTFail("Expected cancellation, got \(error)")
      }
      callerReturned.fulfill()
    }
    await recorder.waitForRequestCount(1)

    caller.cancel()
    await fulfillment(of: [callerReturned, refreshStopped], timeout: 2)

    let persistedRecord = try await secureStore.oauthRecord()
    XCTAssertEqual(persistedRecord, expiringRecord)
    recorder.resumeAll()
    await caller.value
  }

  func testCancelingOneRefreshWaiterKeepsRequestAliveForSurvivor() async throws {
    let canceledCallerReturned = expectation(description: "canceled refresh caller returned")
    let reused = T3SessionSignal()
    let expiringRecord = try record(expiresIn: 1)
    let secureStore = try secureStore(oauthRecord: expiringRecord)
    let recorder = T3OAuthHTTPRecorder(
      responses: [
        .json(
          status: 200,
          #"{"access_token":"survivor","token_type":"Bearer","expires_in":3600}"#)
      ],
      suspended: true)
    let session = makeSession(
      store: secureStore, recorder: recorder, onRefreshTaskReused: { reused.signal() })
    let canceledCaller = Task {
      do {
        _ = try await session.validOAuthRecord()
        XCTFail("Expected cancellation")
      } catch is CancellationError {
      } catch {
        XCTFail("Expected cancellation, got \(error)")
      }
      canceledCallerReturned.fulfill()
    }
    await recorder.waitForRequestCount(1)
    let survivor = Task { try await session.validOAuthRecord() }
    await reused.wait()

    canceledCaller.cancel()
    await fulfillment(of: [canceledCallerReturned], timeout: 2)
    XCTAssertEqual(recorder.stopCount(), 0)
    recorder.resumeAll()

    await canceledCaller.value
    let refreshed = try await survivor.value
    XCTAssertEqual(refreshed.accessToken, "survivor")
    XCTAssertEqual(recorder.requests().count, 1)
  }

  func testCanceledRefreshCreatorCannotStrandCompletedRefreshState() async throws {
    let clock = T3SessionTestClock(now: now)
    let ownerGate = T3SessionGate()
    let expiringRecord = try record(expiresIn: 1)
    let secureStore = try secureStore(oauthRecord: expiringRecord)
    let recorder = T3OAuthHTTPRecorder(responses: [
      .json(
        status: 200,
        #"{"access_token":"first-refresh","token_type":"Bearer","expires_in":3600}"#),
      .json(
        status: 200,
        #"{"access_token":"second-refresh","token_type":"Bearer","expires_in":3600}"#),
    ])
    let session = makeSession(
      store: secureStore, recorder: recorder, currentTime: { clock.value() },
      onOwnedRefreshCompleted: { await ownerGate.suspend() })
    let creator = Task { try await session.validOAuthRecord() }
    await ownerGate.waitUntilSuspended()

    creator.cancel()
    clock.advance(by: 3_301)
    let refreshedAgain = try await session.validOAuthRecord()

    XCTAssertEqual(refreshedAgain.accessToken, "second-refresh")
    XCTAssertEqual(recorder.requests().count, 2)
    await ownerGate.resume()
    do {
      _ = try await creator.value
      XCTFail("Expected the creating caller to be canceled")
    } catch is CancellationError {
    }
  }

  func testCallerWaitsForCanceledRefreshTerminationBeforeRetrying() async throws {
    let expiringRecord = try record(expiresIn: 1)
    let credentialStore = T3RefreshRaceCredentialStore(
      record: expiringRecord, suspendFirstReplacement: true)
    let terminationWaitEntered = T3SessionSignal()
    let recorder = T3OAuthHTTPRecorder(responses: [
      .json(
        status: 200,
        #"{"access_token":"first-refresh","token_type":"Bearer","expires_in":3600}"#),
      .json(
        status: 200,
        #"{"access_token":"duplicate-refresh","token_type":"Bearer","expires_in":3600}"#),
    ])
    let session = makeSession(
      credentialStore: credentialStore, recorder: recorder,
      onRefreshTaskReused: { terminationWaitEntered.signal() })
    let canceledCaller = Task { try await session.validOAuthRecord() }
    await credentialStore.waitForReplacement()

    canceledCaller.cancel()
    await credentialStore.waitForReplacementCancellation()
    let retryingCaller = Task { try await session.validOAuthRecord() }
    await terminationWaitEntered.wait()
    let loadCountWhileWaiting = await credentialStore.recordedLoadCount()
    XCTAssertEqual(loadCountWhileWaiting, 1)
    await credentialStore.resumeReplacement()

    do {
      _ = try await canceledCaller.value
      XCTFail("Expected the first caller to be canceled")
    } catch is CancellationError {
    }
    let refreshed = try await retryingCaller.value
    XCTAssertEqual(refreshed.accessToken, "first-refresh")
    XCTAssertEqual(recorder.requests().count, 1)
    let finalLoadCount = await credentialStore.recordedLoadCount()
    XCTAssertEqual(finalLoadCount, 2)
  }

  func testStoredRecordLoadRetriesWhenRefreshStateChangesBeforeResume() async throws {
    let expiringRecord = try record(expiresIn: 1)
    let credentialStore = T3RefreshRaceCredentialStore(
      record: expiringRecord, suspendFirstLoad: true)
    let recorder = T3OAuthHTTPRecorder(responses: [
      .json(
        status: 200,
        #"{"access_token":"first-refresh","token_type":"Bearer","expires_in":3600}"#),
      .json(
        status: 200,
        #"{"access_token":"stale-refresh","token_type":"Bearer","expires_in":3600}"#),
    ])
    let session = makeSession(credentialStore: credentialStore, recorder: recorder)
    let staleLoadCaller = Task { try await session.validOAuthRecord() }
    await credentialStore.waitForLoadSuspension()

    let currentCaller = Task { try await session.validOAuthRecord() }
    let currentRecord = try await currentCaller.value
    await credentialStore.resumeLoad()
    let reloadedRecord = try await staleLoadCaller.value

    XCTAssertEqual(currentRecord.accessToken, "first-refresh")
    XCTAssertEqual(reloadedRecord.accessToken, "first-refresh")
    XCTAssertEqual(recorder.requests().count, 1)
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
    let oauthReplacements = await secureStore.replacementPayloads(
      account: T3ConnectCredentialStore.oauthAccount)
    XCTAssertNil(persistedRecord)
    XCTAssertEqual(oauthReplacements.count, 2)
    XCTAssertEqual(
      oauthReplacements.last,
      Data(#"{"type":"t3-connect-sign-out-pending","version":1}"#.utf8))
    XCTAssertEqual(
      deletedAccounts,
      [T3ConnectCredentialStore.dpopKeyAccount, T3ConnectCredentialStore.oauthAccount])
  }

  func testSignOutInvalidatesAStoredRecordLoadSuspendedBeforeSessionResume() async throws {
    let stored = try record(expiresIn: 3_600)
    let credentialStore = T3SuspendedOAuthCredentialStore(record: stored)
    let recorder = T3OAuthHTTPRecorder(responses: [])
    let session = makeSession(credentialStore: credentialStore, recorder: recorder)
    let validTask = Task { try await session.validOAuthRecord() }
    await credentialStore.waitForLoad()

    try await session.signOut()
    await credentialStore.resumeLoad()

    do {
      _ = try await validTask.value
      XCTFail("Expected the pre-sign-out load to become stale")
    } catch T3ConnectSessionError.staleOperation {
    }
    let persistedRecord = await credentialStore.record()
    XCTAssertNil(persistedRecord)
    XCTAssertTrue(recorder.requests().isEmpty)
  }

  func testCommittingNewGrantPreventsOldSuspendedRefreshFromOverwritingIt() async throws {
    let oldRecord = try record(expiresIn: 1)
    let secureStore = try secureStore(oauthRecord: oldRecord)
    let recorder = T3OAuthHTTPRecorder(
      responses: [
        .json(
          status: 200,
          #"{"access_token":"stale-access","token_type":"Bearer","expires_in":3600}"#)
      ],
      suspended: true)
    let session = makeSession(store: secureStore, recorder: recorder)
    let refreshTask = Task { try await session.validOAuthRecord() }
    await recorder.waitForRequestCount(1)
    let candidate = try T3OAuthRecord(
      grantID: newGrantID, accessToken: "linked-access", refreshToken: "linked-refresh",
      expiresAt: now.addingTimeInterval(3_600), displayIdentity: "linked@example.com")

    try await session.commit(candidate)
    let recordAfterCommit = try await secureStore.oauthRecord()
    recorder.resumeAll()
    _ = try? await refreshTask.value

    let finalRecord = try await secureStore.oauthRecord()
    XCTAssertEqual(recordAfterCommit, candidate)
    XCTAssertEqual(finalRecord, candidate)
  }

  func testOwnedRefreshBecomesStaleWhenCommitFinishesBeforeOwnerReturns() async throws {
    let expiringRecord = try record(expiresIn: 1)
    let secureStore = try secureStore(oauthRecord: expiringRecord)
    let recorder = T3OAuthHTTPRecorder(
      responses: [
        .json(
          status: 200,
          #"{"access_token":"old-grant-refresh","token_type":"Bearer","expires_in":3600}"#)
      ])
    let ownerGate = T3SessionGate()
    let session = makeSession(
      store: secureStore, recorder: recorder,
      onOwnedRefreshCompleted: { await ownerGate.suspend() })
    let refreshTask = Task { try await session.validOAuthRecord() }
    await ownerGate.waitUntilSuspended()
    let completedRefresh = try await secureStore.oauthRecord()
    let candidate = try T3OAuthRecord(
      grantID: newGrantID, accessToken: "linked-access", refreshToken: "linked-refresh",
      expiresAt: now.addingTimeInterval(3_600), displayIdentity: "linked@example.com")

    XCTAssertEqual(completedRefresh?.accessToken, "old-grant-refresh")
    try await session.commit(candidate)
    await ownerGate.resume()

    do {
      _ = try await refreshTask.value
      XCTFail("Expected the completed old-grant refresh to become stale")
    } catch T3ConnectSessionError.staleOperation {
    }
    let finalRecord = try await secureStore.oauthRecord()
    XCTAssertEqual(finalRecord, candidate)
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
    currentTime: (@Sendable () -> Date)? = nil,
    onRefreshTaskReused: @escaping @Sendable () -> Void = {},
    onSignOutBegan: @escaping @Sendable () -> Void = {},
    onOwnedRefreshCompleted: @escaping @Sendable () async -> Void = {}
  ) -> T3ConnectSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [T3OAuthURLProtocol.self]
    T3OAuthURLProtocol.recorder = recorder
    let transport = T3HTTPTransport(session: URLSession(configuration: configuration))
    let fixedNow = now
    let resolvedNow = currentTime ?? { fixedNow }
    return T3ConnectSession(
      credentialStore: T3ConnectCredentialStore(store: store),
      transport: transport,
      configuration: .test,
      now: resolvedNow,
      grantID: { grantID ?? UUID() },
      onRefreshTaskReused: onRefreshTaskReused,
      onSignOutBegan: onSignOutBegan,
      onOwnedRefreshCompleted: onOwnedRefreshCompleted)
  }

  private func makeSession(
    credentialStore: any T3OAuthCredentialStoring,
    recorder: T3OAuthHTTPRecorder,
    onRefreshTaskReused: @escaping @Sendable () -> Void = {}
  ) -> T3ConnectSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [T3OAuthURLProtocol.self]
    T3OAuthURLProtocol.recorder = recorder
    let fixedNow = now
    return T3ConnectSession(
      credentialStore: credentialStore,
      transport: T3HTTPTransport(session: URLSession(configuration: configuration)),
      configuration: .test,
      now: { fixedNow },
      onRefreshTaskReused: onRefreshTaskReused)
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
  private let onStop: @Sendable () -> Void
  private var stoppedRequests = 0

  init(
    responses: [T3OAuthHTTPResponse], suspended: Bool = false,
    onStop: @escaping @Sendable () -> Void = {}
  ) {
    self.responses = responses
    self.suspended = suspended
    self.onStop = onStop
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

  func recordStop() {
    lock.lock()
    stoppedRequests += 1
    lock.unlock()
    onStop()
  }

  func stopCount() -> Int {
    lock.lock()
    defer { lock.unlock() }
    return stoppedRequests
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
    guard !stopped else {
      lock.unlock()
      return
    }
    stopped = true
    lock.unlock()
    Self.recorder?.recordStop()
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
  private var replacements: [(account: String, data: Data)] = []

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
    replacements.append((account, data))
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

  func replacementPayloads(account: String) -> [Data] {
    replacements.compactMap { $0.account == account ? $0.data : nil }
  }

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

private actor T3SuspendedOAuthCredentialStore: T3OAuthCredentialStoring {
  private var storedRecord: T3OAuthRecord?
  private var loadStarted = false
  private var loadWaiter: CheckedContinuation<Void, Never>?
  private var loadContinuation: CheckedContinuation<Void, Never>?

  init(record: T3OAuthRecord) {
    storedRecord = record
  }

  func loadOAuthRecord() async throws -> T3OAuthRecord? {
    let capturedRecord = storedRecord
    loadStarted = true
    loadWaiter?.resume()
    loadWaiter = nil
    await withCheckedContinuation { continuation in
      loadContinuation = continuation
    }
    return capturedRecord
  }

  func replaceOAuthRecord(_ record: T3OAuthRecord) async throws {
    storedRecord = record
  }

  func signOut() async throws {
    storedRecord = nil
  }

  func waitForLoad() async {
    if loadStarted { return }
    await withCheckedContinuation { continuation in
      loadWaiter = continuation
    }
  }

  func resumeLoad() {
    loadContinuation?.resume()
    loadContinuation = nil
  }

  func record() -> T3OAuthRecord? { storedRecord }
}

private actor T3RefreshRaceCredentialStore: T3OAuthCredentialStoring {
  private var storedRecord: T3OAuthRecord
  private let suspendFirstLoad: Bool
  private let suspendFirstReplacement: Bool
  private var loadCount = 0
  private var didSuspendLoad = false
  private var loadStarted = false
  private var loadWaiter: CheckedContinuation<Void, Never>?
  private var loadContinuation: CheckedContinuation<Void, Never>?
  private var didSuspendReplacement = false
  private var replacementStarted = false
  private var replacementWaiter: CheckedContinuation<Void, Never>?
  private var replacementContinuation: CheckedContinuation<Void, Never>?
  private let replacementCanceled = T3SessionSignal()

  init(
    record: T3OAuthRecord, suspendFirstLoad: Bool = false,
    suspendFirstReplacement: Bool = false
  ) {
    storedRecord = record
    self.suspendFirstLoad = suspendFirstLoad
    self.suspendFirstReplacement = suspendFirstReplacement
  }

  func loadOAuthRecord() async throws -> T3OAuthRecord? {
    let record = storedRecord
    loadCount += 1
    if suspendFirstLoad, !didSuspendLoad {
      didSuspendLoad = true
      loadStarted = true
      loadWaiter?.resume()
      loadWaiter = nil
      await withCheckedContinuation { continuation in
        loadContinuation = continuation
      }
    }
    return record
  }

  func replaceOAuthRecord(_ record: T3OAuthRecord) async throws {
    if suspendFirstReplacement, !didSuspendReplacement {
      didSuspendReplacement = true
      replacementStarted = true
      replacementWaiter?.resume()
      replacementWaiter = nil
      let replacementCanceled = replacementCanceled
      await withTaskCancellationHandler {
        await withCheckedContinuation { continuation in
          replacementContinuation = continuation
        }
      } onCancel: {
        replacementCanceled.signal()
      }
    }
    storedRecord = record
  }

  func signOut() async throws {}

  func recordedLoadCount() -> Int {
    loadCount
  }

  func waitForReplacement() async {
    if replacementStarted { return }
    await withCheckedContinuation { continuation in
      replacementWaiter = continuation
    }
  }

  func waitForReplacementCancellation() async {
    await replacementCanceled.wait()
  }

  func waitForLoadSuspension() async {
    if loadStarted { return }
    await withCheckedContinuation { continuation in
      loadWaiter = continuation
    }
  }

  func resumeLoad() {
    loadContinuation?.resume()
    loadContinuation = nil
  }

  func resumeReplacement() {
    replacementContinuation?.resume()
    replacementContinuation = nil
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

private actor T3SessionGate {
  private var suspended = false
  private var suspendedWaiter: CheckedContinuation<Void, Never>?
  private var resumeContinuation: CheckedContinuation<Void, Never>?

  func suspend() async {
    if suspended { return }
    suspended = true
    suspendedWaiter?.resume()
    suspendedWaiter = nil
    await withCheckedContinuation { continuation in
      resumeContinuation = continuation
    }
  }

  func waitUntilSuspended() async {
    if suspended { return }
    await withCheckedContinuation { continuation in
      suspendedWaiter = continuation
    }
  }

  func resume() {
    resumeContinuation?.resume()
    resumeContinuation = nil
  }
}

private final class T3SessionTestClock: @unchecked Sendable {
  private let lock = NSLock()
  private var now: Date

  init(now: Date) {
    self.now = now
  }

  func value() -> Date {
    lock.lock()
    defer { lock.unlock() }
    return now
  }

  func advance(by interval: TimeInterval) {
    lock.lock()
    now = now.addingTimeInterval(interval)
    lock.unlock()
  }
}

extension Data {
  fileprivate var base64URLString: String {
    base64EncodedString().replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
  }
}
