import Foundation
import XCTest

@testable import Islet

final class T3ConnectCredentialTests: XCTestCase {
  func testPKCEUsesRequestedRandomBytesAndBuildsExactHostedFragment() throws {
    var nextByte = 0
    let transaction = try T3PKCETransaction { count in
      defer { nextByte += count }
      return Data((nextByte..<(nextByte + count)).map(UInt8.init))
    }

    XCTAssertEqual(transaction.verifier, "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8")
    XCTAssertEqual(transaction.state, "ICEiIyQlJicoKSorLC0uLw")
    XCTAssertEqual(transaction.challenge, "6oZqdX5MOLq_qBJ8vppAnT4fk6AP8UiP9zX8-Rev_9A")
    XCTAssertEqual(
      try transaction.hostedAuthorizationURL().absoluteString,
      "https://app.t3.codes/connect#state=ICEiIyQlJicoKSorLC0uLw&challenge="
        + "6oZqdX5MOLq_qBJ8vppAnT4fk6AP8UiP9zX8-Rev_9A&port=34338")
  }

  func testProductionConfigurationMatchesTheHostedContract() {
    let configuration = T3ConnectConfiguration.production

    XCTAssertEqual(T3ConnectCredentialStore.service, "dev.islet")
    XCTAssertEqual(
      configuration.hostedAuthorizationURL.absoluteString, "https://app.t3.codes/connect")
    XCTAssertEqual(configuration.tokenEndpoint.absoluteString, "https://clerk.t3.codes/oauth/token")
    XCTAssertEqual(configuration.clientID, "hzxSgY2cH10sDU2r")
    XCTAssertEqual(configuration.redirectURI.absoluteString, "http://127.0.0.1:34338/callback")
    XCTAssertEqual(configuration.scopes, ["openid", "profile", "email"])
    XCTAssertEqual(configuration.relayOrigin.absoluteString, "https://relay.t3.codes")
    XCTAssertEqual(configuration.relayClientID, "t3-web")
  }

  func testAuthorizationGrantCreatesANewIDAndRefreshPreservesIt() throws {
    let receivedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let firstID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let secondID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let first = try T3OAuthRecord.authorizationGrant(
      accessToken: "access-one", refreshToken: "refresh-one",
      expiresAt: receivedAt.addingTimeInterval(3_600), displayIdentity: "person@example.com",
      grantID: { firstID }, receivedAt: receivedAt)
    let second = try T3OAuthRecord.authorizationGrant(
      accessToken: "access-two", refreshToken: "refresh-two",
      expiresAt: receivedAt.addingTimeInterval(3_600), displayIdentity: nil,
      grantID: { secondID }, receivedAt: receivedAt)

    let refreshed = try first.refreshed(
      accessToken: "access-three", expiresAt: receivedAt.addingTimeInterval(7_200),
      receivedAt: receivedAt)

    XCTAssertEqual(first.grantID, firstID)
    XCTAssertEqual(second.grantID, secondID)
    XCTAssertNotEqual(first.grantID, second.grantID)
    XCTAssertEqual(refreshed.grantID, first.grantID)
    XCTAssertEqual(refreshed.refreshToken, "refresh-one")
    XCTAssertEqual(refreshed.displayIdentity, "person@example.com")
  }

  func testTokenResponseBoundsRejectOversizedValuesAndInvalidExpiry() throws {
    let receivedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let validExpiry = receivedAt.addingTimeInterval(60)

    XCTAssertThrowsError(
      try T3OAuthRecord.authorizationGrant(
        accessToken: String(repeating: "a", count: 16 * 1_024 + 1), refreshToken: "refresh",
        expiresAt: validExpiry, displayIdentity: nil, receivedAt: receivedAt))
    XCTAssertThrowsError(
      try T3OAuthRecord.authorizationGrant(
        accessToken: "", refreshToken: "refresh", expiresAt: validExpiry,
        displayIdentity: nil, receivedAt: receivedAt))
    XCTAssertThrowsError(
      try T3OAuthRecord.authorizationGrant(
        accessToken: "access", refreshToken: "", expiresAt: validExpiry,
        displayIdentity: nil, receivedAt: receivedAt))
    XCTAssertThrowsError(
      try T3OAuthRecord.authorizationGrant(
        accessToken: "access", refreshToken: "refresh", expiresAt: validExpiry,
        displayIdentity: String(repeating: "é", count: 257), receivedAt: receivedAt))
    XCTAssertThrowsError(
      try T3OAuthRecord.authorizationGrant(
        accessToken: "access", refreshToken: "refresh", expiresAt: receivedAt,
        displayIdentity: nil, receivedAt: receivedAt))
    XCTAssertThrowsError(
      try T3OAuthRecord.authorizationGrant(
        accessToken: "access", refreshToken: "refresh",
        expiresAt: receivedAt.addingTimeInterval(31 * 24 * 60 * 60 + 1), displayIdentity: nil,
        receivedAt: receivedAt))
  }

  func testFailedReplacementLeavesTheProcessCacheUnchanged() async throws {
    let oldRecord = try persistedRecord(accessToken: "old-access")
    let newRecord = try persistedRecord(accessToken: "new-access")
    let store = T3FakeSecureRecordStore(
      records: [T3ConnectCredentialStore.oauthAccount: try JSONEncoder().encode(oldRecord)])
    let credentials = T3ConnectCredentialStore(store: store)
    let initiallyLoaded = try await credentials.loadOAuthRecord()
    XCTAssertEqual(initiallyLoaded, oldRecord)
    await store.failNextReplacement()

    do {
      try await credentials.replaceOAuthRecord(newRecord)
      XCTFail("Expected the replacement to fail")
    } catch T3FakeSecureRecordStore.Failure.replace {
    }

    let loadedAfterFailure = try await credentials.loadOAuthRecord()
    XCTAssertEqual(loadedAfterFailure, oldRecord)
  }

  func testCorruptOAuthJSONRemainsStoredAndRaisesInvalidRecord() async throws {
    let corrupt = Data("not-json".utf8)
    let store = T3FakeSecureRecordStore(
      records: [T3ConnectCredentialStore.oauthAccount: corrupt])
    let credentials = T3ConnectCredentialStore(store: store)

    do {
      _ = try await credentials.loadOAuthRecord()
      XCTFail("Expected invalidRecord")
    } catch T3ConnectCredentialStoreError.invalidRecord {
    }

    let retainedData = await store.storedData(account: T3ConnectCredentialStore.oauthAccount)
    let deletedAccounts = await store.deletedAccounts()
    XCTAssertEqual(retainedData, corrupt)
    XCTAssertEqual(deletedAccounts, [])
  }

  func testFailedProofKeyReplacementLeavesTheProcessCacheUnchanged() async throws {
    let oldKey = Data("old-proof-key".utf8)
    let newKey = Data("new-proof-key".utf8)
    let store = T3FakeSecureRecordStore(
      records: [T3ConnectCredentialStore.dpopKeyAccount: oldKey])
    let credentials = T3ConnectCredentialStore(store: store)
    let initiallyLoaded = try await credentials.loadProofKey()
    XCTAssertEqual(initiallyLoaded, oldKey)
    await store.failNextReplacement()

    do {
      try await credentials.replaceProofKey(newKey)
      XCTFail("Expected the replacement to fail")
    } catch T3FakeSecureRecordStore.Failure.replace {
    }

    let loadedAfterFailure = try await credentials.loadProofKey()
    XCTAssertEqual(loadedAfterFailure, oldKey)
  }

  func testExpiredPersistedAccessTokenLoadsForRefresh() async throws {
    let expired = try T3OAuthRecord(
      grantID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
      accessToken: "expired-access", refreshToken: "usable-refresh",
      expiresAt: Date(timeIntervalSince1970: 1), displayIdentity: nil)
    let store = T3FakeSecureRecordStore(
      records: [T3ConnectCredentialStore.oauthAccount: try JSONEncoder().encode(expired)])
    let credentials = T3ConnectCredentialStore(store: store)

    let loaded = try await credentials.loadOAuthRecord()
    XCTAssertEqual(loaded, expired)
  }

  func testSignOutDeletesOAuthBeforeProofKey() async throws {
    let store = T3FakeSecureRecordStore(records: [
      T3ConnectCredentialStore.oauthAccount: Data("oauth".utf8),
      T3ConnectCredentialStore.dpopKeyAccount: Data("proof".utf8),
    ])
    let credentials = T3ConnectCredentialStore(store: store)

    try await credentials.signOut()

    let deletedAccounts = await store.deletedAccounts()
    XCTAssertEqual(
      deletedAccounts,
      [T3ConnectCredentialStore.oauthAccount, T3ConnectCredentialStore.dpopKeyAccount])
  }

  func testMalformedIDTokenClaimsProduceNoDisplayIdentity() {
    XCTAssertNil(T3ConnectAccount.displayIdentity(fromIDToken: "not-a-jwt"))
    XCTAssertNil(T3ConnectAccount.displayIdentity(fromIDToken: "header.bm90LWpzb24.signature"))
    XCTAssertNil(T3ConnectAccount.displayIdentity(fromIDToken: "header.W10.signature"))
  }

  func testIDTokenDisplayIdentityIsBoundedByUTF8Bytes() {
    let validPayload = #"{"email":"person@example.com"}"#.data(using: .utf8)!.base64URLString
    let oversizedPayload =
      try! JSONSerialization.data(withJSONObject: ["email": String(repeating: "é", count: 257)])
      .base64URLString

    XCTAssertEqual(
      T3ConnectAccount.displayIdentity(fromIDToken: "header.\(validPayload).signature"),
      "person@example.com")
    XCTAssertNil(
      T3ConnectAccount.displayIdentity(fromIDToken: "header.\(oversizedPayload).signature"))
  }

  private func persistedRecord(accessToken: String) throws -> T3OAuthRecord {
    try T3OAuthRecord(
      grantID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
      accessToken: accessToken, refreshToken: "refresh",
      expiresAt: Date(timeIntervalSince1970: 1_900_000_000), displayIdentity: nil)
  }
}

private actor T3FakeSecureRecordStore: T3SecureRecordStore {
  enum Failure: Error {
    case replace
  }

  private var records: [String: Data]
  private var failReplacement = false
  private var deletions: [String] = []

  init(records: [String: Data] = [:]) {
    self.records = records
  }

  func data(service: String, account: String) async throws -> Data? {
    records[account]
  }

  func replace(_ data: Data, service: String, account: String, label: String) async throws {
    if failReplacement {
      failReplacement = false
      throw Failure.replace
    }
    records[account] = data
  }

  func delete(service: String, account: String) async throws {
    deletions.append(account)
    records.removeValue(forKey: account)
  }

  func failNextReplacement() {
    failReplacement = true
  }

  func storedData(account: String) -> Data? {
    records[account]
  }

  func deletedAccounts() -> [String] {
    deletions
  }
}

extension Data {
  fileprivate var base64URLString: String {
    base64EncodedString().replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
  }
}
