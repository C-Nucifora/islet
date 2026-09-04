import CryptoKit
import Foundation
import XCTest

@testable import Islet

@MainActor
final class T3CredentialStoreTests: XCTestCase {
  private let service = "test.islet"
  private let legacyService = "test.islet.legacy"

  func testStableAccountsBoundPathologicalIDsWithoutEmbeddingThem() {
    let pathologicalID = "\0/../環境/" + String(repeating: "x", count: 32_768)
    let first = T3CredentialVault.account(for: pathologicalID)
    let second = T3CredentialVault.account(for: pathologicalID)
    let distinct = T3CredentialVault.account(for: pathologicalID + "!")

    XCTAssertEqual(first, second)
    XCTAssertNotEqual(first, distinct)
    XCTAssertTrue(first.hasPrefix(T3CredentialVault.credentialAccountPrefix))
    XCTAssertEqual(first.count, T3CredentialVault.credentialAccountPrefix.count + 43)
    XCTAssertFalse(first.contains("環境"))
    XCTAssertEqual(
      T3CredentialVault.account(for: "").count,
      T3CredentialVault.credentialAccountPrefix.count + 43)
  }

  func testCorruptEntryDoesNotHideHealthyOrMissingEnvironments() throws {
    let store = T3MemoryCredentialRecordStore()
    let vault = makeVault(store: store)
    let healthyID = "remote|healthy"
    let damagedID = "remote|damaged"
    let healthySecret = secret(1)

    try vault.save(healthySecret, credentialID: healthyID)
    try vault.save(secret(2), credentialID: damagedID)
    store.set(
      Data([0x00, 0xFF]), service: service,
      account: T3CredentialVault.account(for: damagedID))

    assertSecret(try vault.load(credentialID: healthyID), matches: healthySecret)
    XCTAssertNil(try vault.load(credentialID: "remote|missing"))
    XCTAssertThrowsError(try vault.load(credentialID: damagedID)) { error in
      guard case T3CredentialStoreError.invalidCredential = error else {
        return XCTFail("Expected an isolated invalid-credential error")
      }
    }
  }

  func testMigrationWritesAndVerifiesEveryItemBeforeRemovingAggregateVaults() throws {
    let currentSecret = secret(3)
    let sharedSecret = secret(4)
    let legacySecret = secret(5)
    let canonicalData = try aggregateData([
      "remote|current": currentSecret,
      "remote|shared": sharedSecret,
    ])
    let legacyData = try aggregateData([
      "remote|shared": secret(6),
      "remote|legacy": legacySecret,
    ])
    let store = T3MemoryCredentialRecordStore(records: [
      .init(service: service, account: T3CredentialVault.vaultAccount): canonicalData,
      .init(service: legacyService, account: T3CredentialVault.vaultAccount): legacyData,
    ])
    let vault = makeVault(store: store)

    XCTAssertEqual(try vault.migrateLegacyVaults(), 3)

    assertSecret(try vault.load(credentialID: "remote|current"), matches: currentSecret)
    assertSecret(try vault.load(credentialID: "remote|shared"), matches: sharedSecret)
    assertSecret(try vault.load(credentialID: "remote|legacy"), matches: legacySecret)
    XCTAssertNil(store.value(service: service, account: T3CredentialVault.vaultAccount))
    XCTAssertNil(store.value(service: legacyService, account: T3CredentialVault.vaultAccount))

    let operations = store.operations
    let firstDeletion = try XCTUnwrap(operations.firstIndex(where: { $0.isDeletion }))
    let credentialAccounts = ["remote|current", "remote|shared", "remote|legacy"].map(
      T3CredentialVault.account)
    for account in credentialAccounts {
      let replacement = try XCTUnwrap(
        operations.firstIndex(of: .replace(service: service, account: account)))
      let verification = try XCTUnwrap(
        operations[(replacement + 1)...].firstIndex(of: .read(service: service, account: account)))
      XCTAssertLessThan(replacement, verification)
      XCTAssertLessThan(verification, firstDeletion)
    }
  }

  func testFirstLoadAutomaticallyMigratesTheCurrentAggregateVault() throws {
    let storedSecret = secret(19)
    let store = T3MemoryCredentialRecordStore(records: [
      .init(service: service, account: T3CredentialVault.vaultAccount): try aggregateData([
        "remote|automatic": storedSecret
      ])
    ])
    let vault = makeVault(store: store)

    assertSecret(try vault.load(credentialID: "remote|automatic"), matches: storedSecret)
    XCTAssertNil(store.value(service: service, account: T3CredentialVault.vaultAccount))
    XCTAssertNotNil(
      store.value(
        service: service, account: T3CredentialVault.account(for: "remote|automatic")))
  }

  func testInterruptedMigrationRetriesWithoutOverwritingRecoveredItem() throws {
    let recoveredSecret = secret(7)
    let pendingSecret = secret(8)
    let store = T3MemoryCredentialRecordStore()
    let vault = makeVault(store: store)
    try vault.save(recoveredSecret, credentialID: "remote|recovered")
    store.set(
      try aggregateData([
        "remote|recovered": secret(9),
        "remote|pending": pendingSecret,
      ]), service: service, account: T3CredentialVault.vaultAccount)
    store.clearOperations()

    XCTAssertEqual(try vault.migrateLegacyVaults(), 1)

    assertSecret(try vault.load(credentialID: "remote|recovered"), matches: recoveredSecret)
    assertSecret(try vault.load(credentialID: "remote|pending"), matches: pendingSecret)
    XCTAssertFalse(
      store.operations.contains(
        .replace(
          service: service, account: T3CredentialVault.account(for: "remote|recovered"))))
    XCTAssertNil(store.value(service: service, account: T3CredentialVault.vaultAccount))
  }

  func testFailedMigrationReplacementRollsBackAndRetryCompletes() throws {
    let sourceData = try aggregateData([
      "remote|first": secret(10),
      "remote|second": secret(11),
    ])
    let source = T3MemoryCredentialRecordStore.Key(
      service: service, account: T3CredentialVault.vaultAccount)
    let store = T3MemoryCredentialRecordStore(records: [source: sourceData])
    let vault = makeVault(store: store)
    store.failReplacement(number: 2)

    XCTAssertThrowsError(try vault.migrateLegacyVaults())

    XCTAssertEqual(
      store.value(service: source.service, account: source.account)?.sha256, sourceData.sha256)
    XCTAssertNil(
      store.value(
        service: service, account: T3CredentialVault.account(for: "remote|first")))
    XCTAssertNil(
      store.value(
        service: service, account: T3CredentialVault.account(for: "remote|second")))

    XCTAssertEqual(try vault.migrateLegacyVaults(), 2)
    XCTAssertNil(store.value(service: source.service, account: source.account))
  }

  func testFailedAggregateDeletionRestoresSourceAndNewItems() throws {
    let sourceData = try aggregateData(["remote|rollback": secret(12)])
    let source = T3MemoryCredentialRecordStore.Key(
      service: legacyService, account: T3CredentialVault.vaultAccount)
    let store = T3MemoryCredentialRecordStore(records: [source: sourceData])
    let vault = makeVault(store: store)
    store.failDeletion(of: source)

    XCTAssertThrowsError(try vault.migrateLegacyVaults())

    XCTAssertEqual(
      store.value(service: source.service, account: source.account)?.sha256, sourceData.sha256)
    XCTAssertNil(
      store.value(
        service: service, account: T3CredentialVault.account(for: "remote|rollback")))
    XCTAssertEqual(try vault.migrateLegacyVaults(), 1)
  }

  func testRollbackKeepsVerifiedReplacementWhenADeletedVaultCannotBeRestored() throws {
    let credentialID = "remote|survivor"
    let storedSecret = secret(20)
    let canonical = T3MemoryCredentialRecordStore.Key(
      service: service, account: T3CredentialVault.vaultAccount)
    let legacy = T3MemoryCredentialRecordStore.Key(
      service: legacyService, account: T3CredentialVault.vaultAccount)
    let sourceData = try aggregateData([credentialID: storedSecret])
    let store = T3MemoryCredentialRecordStore(records: [
      canonical: sourceData,
      legacy: sourceData,
    ])
    let vault = makeVault(store: store)
    store.failDeletion(of: legacy)
    // The first replacement writes the isolated credential. The second attempts to restore the
    // canonical vault after its deletion succeeds and legacy-vault deletion fails.
    store.failReplacement(number: 2)

    XCTAssertThrowsError(try vault.migrateLegacyVaults()) { error in
      guard case T3CredentialStoreError.rollbackFailed = error else {
        return XCTFail("Expected rollbackFailed, got \(error)")
      }
    }

    XCTAssertNil(store.value(service: canonical.service, account: canonical.account))
    XCTAssertNotNil(store.value(service: legacy.service, account: legacy.account))
    XCTAssertNotNil(
      store.value(service: service, account: T3CredentialVault.account(for: credentialID)))

    // The surviving isolated item is preferred on retry, so source cleanup completes without
    // rewriting or losing the credential.
    XCTAssertEqual(try vault.migrateLegacyVaults(), 0)
    assertSecret(try vault.load(credentialID: credentialID), matches: storedSecret)
    XCTAssertNil(store.value(service: legacy.service, account: legacy.account))
  }

  func testLocalReplacementDeletesOnlyIdentifiableStaleItems() throws {
    let store = T3MemoryCredentialRecordStore()
    let vault = makeVault(store: store)
    let oldLocalID = "local|old-origin"
    let legacyLocalID = "local-environment-id"
    let remoteID = "remote|kept"
    let remoteSecret = secret(13)
    let corruptAccount =
      T3CredentialVault.credentialAccountPrefix + String(repeating: "z", count: 43)
    try vault.save(secret(14), credentialID: oldLocalID)
    try vault.save(secret(15), credentialID: legacyLocalID)
    try vault.save(remoteSecret, credentialID: remoteID)
    store.set(Data([0xFF]), service: service, account: corruptAccount)

    try vault.saveLocal(
      secret(16), credentialID: "local|new-origin", environmentID: legacyLocalID)

    XCTAssertNil(try vault.load(credentialID: oldLocalID))
    XCTAssertNil(try vault.load(credentialID: legacyLocalID))
    assertSecret(try vault.load(credentialID: remoteID), matches: remoteSecret)
    XCTAssertNotNil(store.value(service: service, account: corruptAccount))
  }

  func testMainActorSerializesConcurrentWritesWithoutLostEntries() async throws {
    let store = T3MemoryCredentialRecordStore()
    let vault = makeVault(store: store)
    let firstSecret = secret(17)
    let secondSecret = secret(18)

    let first = Task { @MainActor in
      try vault.save(firstSecret, credentialID: "remote|concurrent-first")
    }
    let second = Task { @MainActor in
      try vault.save(secondSecret, credentialID: "remote|concurrent-second")
    }
    try await first.value
    try await second.value

    assertSecret(
      try vault.load(credentialID: "remote|concurrent-first"), matches: firstSecret)
    assertSecret(
      try vault.load(credentialID: "remote|concurrent-second"), matches: secondSecret)
  }

  private func makeVault(store: T3MemoryCredentialRecordStore) -> T3CredentialVault {
    T3CredentialVault(service: service, legacyServices: [legacyService], store: store)
  }

  private func aggregateData(_ values: [String: String]) throws -> Data {
    try JSONEncoder().encode(values)
  }

  private func secret(_ marker: UInt8) -> String {
    Data([0xC0, marker, 0x5A, marker &+ 1]).base64EncodedString()
  }

  private func assertSecret(
    _ actual: String?, matches expected: String, file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertEqual(
      actual.map { Data($0.utf8).sha256 }, Data(expected.utf8).sha256, file: file, line: line)
  }
}

@MainActor
private final class T3MemoryCredentialRecordStore: T3CredentialRecordStore {
  struct Key: Hashable {
    let service: String
    let account: String
  }

  enum Operation: Equatable {
    case read(service: String, account: String)
    case replace(service: String, account: String)
    case delete(service: String, account: String)

    var isDeletion: Bool {
      if case .delete = self { return true }
      return false
    }
  }

  enum Failure: Error {
    case replace
    case delete
  }

  private var records: [Key: Data]
  private var replacementCount = 0
  private var failedReplacementNumber: Int?
  private var failedDeletion: Key?
  private(set) var operations: [Operation] = []

  init(records: [Key: Data] = [:]) {
    self.records = records
  }

  func data(service: String, account: String) throws -> Data? {
    operations.append(.read(service: service, account: account))
    return records[Key(service: service, account: account)]
  }

  func replace(_ data: Data, service: String, account: String, label: String) throws {
    replacementCount += 1
    if failedReplacementNumber == replacementCount {
      failedReplacementNumber = nil
      throw Failure.replace
    }
    operations.append(.replace(service: service, account: account))
    records[Key(service: service, account: account)] = data
  }

  func delete(service: String, account: String) throws {
    let key = Key(service: service, account: account)
    operations.append(.delete(service: service, account: account))
    if failedDeletion == key {
      failedDeletion = nil
      throw Failure.delete
    }
    records.removeValue(forKey: key)
  }

  func items(service: String) throws -> [T3StoredCredentialItem] {
    records.compactMap { key, data in
      guard key.service == service else { return nil }
      return T3StoredCredentialItem(account: key.account, data: data)
    }
  }

  func itemExists(service: String, account: String) -> Bool {
    records[Key(service: service, account: account)] != nil
  }

  func set(_ data: Data, service: String, account: String) {
    records[Key(service: service, account: account)] = data
  }

  func value(service: String, account: String) -> Data? {
    records[Key(service: service, account: account)]
  }

  func failReplacement(number: Int) {
    failedReplacementNumber = replacementCount + number
  }

  func failDeletion(of key: Key) {
    failedDeletion = key
  }

  func clearOperations() {
    operations.removeAll()
  }
}

extension Data {
  fileprivate var sha256: Data { Data(SHA256.hash(data: self)) }
}
