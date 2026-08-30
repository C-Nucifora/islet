import CryptoKit
import Foundation
import Security

enum T3CredentialStoreError: Error, LocalizedError {
  case keychain(OSStatus)
  case invalidCredential
  case invalidVault
  case rollbackFailed

  var errorDescription: String? {
    switch self {
    case .keychain(let status):
      SecCopyErrorMessageString(status, nil) as String?
        ?? String(localized: "Keychain error \(status)")
    case .invalidCredential:
      String(
        localized:
          "A saved T3 Code credential is unreadable. Other saved environments are unchanged.")
    case .invalidVault:
      String(localized: "The saved T3 Code credential vault is unreadable. It was left unchanged.")
    case .rollbackFailed:
      String(
        localized:
          "The T3 Code credential operation failed and Keychain rollback could not be verified.")
    }
  }
}

enum LegacyInstallIdentifiers {
  static let applicationDomains = [
    "dev.nedlane.Islet",
    "dev.nedlane.islet",
    "dev.nedlane",
    "dev.cnucifora.Islet",
    "dev.cnucifora.islet",
    "dev.cnucifora",
  ]
  static let credentialServices = [
    "dev.nedlane.Islet",
    "dev.nedlane.islet.t3-code",
    "dev.nedlane",
    "dev.cnucifora.islet.t3-code",
    "dev.cnucifora.Islet",
    "dev.cnucifora",
  ]
}

struct T3StoredCredentialItem: Equatable {
  let account: String
  let data: Data
}

@MainActor
protocol T3CredentialRecordStore {
  func data(service: String, account: String) throws -> Data?
  func replace(_ data: Data, service: String, account: String, label: String) throws
  func delete(service: String, account: String) throws
  func items(service: String) throws -> [T3StoredCredentialItem]
  func itemExists(service: String, account: String) -> Bool
}

struct T3KeychainCredentialRecordStore: T3CredentialRecordStore {
  func data(service: String, account: String) throws -> Data? {
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecAttrAccount: account,
      kSecReturnData: true,
      kSecMatchLimit: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw T3CredentialStoreError.keychain(status) }
    guard let data = item as? Data else { throw T3CredentialStoreError.invalidCredential }
    return data
  }

  func replace(_ data: Data, service: String, account: String, label: String) throws {
    let key: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecAttrAccount: account,
    ]
    let values: [CFString: Any] = [
      kSecValueData: data,
      kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
      kSecAttrLabel: label,
    ]
    let status = SecItemUpdate(key as CFDictionary, values as CFDictionary)
    if status == errSecItemNotFound {
      var addition = key
      for (attribute, value) in values { addition[attribute] = value }
      let addStatus = SecItemAdd(addition as CFDictionary, nil)
      guard addStatus == errSecSuccess else {
        throw T3CredentialStoreError.keychain(addStatus)
      }
    } else if status != errSecSuccess {
      throw T3CredentialStoreError.keychain(status)
    }
  }

  func delete(service: String, account: String) throws {
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecAttrAccount: account,
    ]
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw T3CredentialStoreError.keychain(status)
    }
  }

  func items(service: String) throws -> [T3StoredCredentialItem] {
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecReturnAttributes: true,
      kSecMatchLimit: kSecMatchLimitAll,
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return [] }
    guard status == errSecSuccess else { throw T3CredentialStoreError.keychain(status) }
    guard let dictionaries = result as? [NSDictionary] else {
      throw T3CredentialStoreError.invalidCredential
    }
    return try dictionaries.compactMap { attributes in
      guard let account = attributes[kSecAttrAccount] as? String else {
        throw T3CredentialStoreError.invalidCredential
      }
      guard account.hasPrefix(T3CredentialVault.credentialAccountPrefix) else { return nil }
      guard let itemData = try data(service: service, account: account) else { return nil }
      return T3StoredCredentialItem(account: account, data: itemData)
    }
  }

  func itemExists(service: String, account: String) -> Bool {
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecAttrAccount: account,
      kSecMatchLimit: kSecMatchLimitOne,
    ]
    let status = SecItemCopyMatching(query as CFDictionary, nil)
    return status == errSecSuccess || status == errSecAuthFailed
      || status == errSecInteractionNotAllowed
  }
}

/// Serializes manual T3 credential access and stores each environment in a separate, stable
/// Keychain account. Aggregate vaults remain the transaction journal until every replacement has
/// been read back and verified.
@MainActor
final class T3CredentialVault {
  nonisolated static let vaultAccount = "read-only-environment-tokens-v1"
  nonisolated static let credentialAccountPrefix = "read-only-environment-token-v2-"
  nonisolated static let credentialLabel = "Islet T3 Code read-only credential"
  nonisolated static let vaultLabel = "Islet T3 Code read-only credentials"

  private let service: String
  private let legacyServices: [String]
  private let store: any T3CredentialRecordStore

  init(
    service: String, legacyServices: [String],
    store: any T3CredentialRecordStore = T3KeychainCredentialRecordStore()
  ) {
    self.service = service
    self.legacyServices = legacyServices
    self.store = store
  }

  var hasLegacyVault: Bool {
    legacyServices.contains {
      store.itemExists(service: $0, account: Self.vaultAccount)
    }
  }

  @discardableResult
  func migrateLegacyVaults() throws -> Int {
    try migrateAggregateVaults()
  }

  func load(credentialID: String) throws -> String? {
    let address = credentialAddress(for: credentialID)
    if let storedData = try store.data(service: address.service, account: address.account),
      let record = try? decodeCredential(storedData, expectedID: credentialID)
    {
      // A failed cleanup must not hide an independently readable environment. A later mutating
      // operation will retry the migration and report the failure.
      _ = try? migrateAggregateVaults()
      return record.token
    }

    _ = try migrateAggregateVaults()
    guard let storedData = try store.data(service: address.service, account: address.account) else {
      return nil
    }
    return try decodeCredential(storedData, expectedID: credentialID).token
  }

  func save(_ token: String, credentialID: String) throws {
    _ = try migrateAggregateVaults()
    let address = credentialAddress(for: credentialID)
    try applyTransaction(
      replacements: [address: try encodedCredential(token: token, credentialID: credentialID)],
      deletions: [])
  }

  func saveLocal(_ token: String, credentialID: String, environmentID: String) throws {
    _ = try migrateAggregateVaults()
    let destination = credentialAddress(for: credentialID)
    let staleAddresses = Set(
      try validCredentialItems().compactMap { item -> Address? in
        guard
          item.record.credentialID == environmentID
            || item.record.credentialID.hasPrefix("local|")
        else { return nil }
        return item.address == destination ? nil : item.address
      })
    try applyTransaction(
      replacements: [destination: try encodedCredential(token: token, credentialID: credentialID)],
      deletions: staleAddresses)
  }

  func delete(credentialIDs: Set<String>) throws {
    _ = try migrateAggregateVaults()
    let addresses = Set(credentialIDs.map(credentialAddress))
    let existingAddresses = try Set(
      addresses.compactMap { address in
        try store.data(service: address.service, account: address.account) == nil ? nil : address
      })
    guard !existingAddresses.isEmpty else { return }
    try applyTransaction(replacements: [:], deletions: existingAddresses)
  }

  nonisolated static func account(for credentialID: String) -> String {
    let digest = Data(SHA256.hash(data: Data(credentialID.utf8)))
      .base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
    return credentialAccountPrefix + digest
  }

  private func migrateAggregateVaults() throws -> Int {
    var sources: [(address: Address, vault: [String: String])] = []
    let sourceServices = [service] + legacyServices.filter { $0 != service }
    for sourceService in sourceServices {
      let address = Address(service: sourceService, account: Self.vaultAccount)
      guard let data = try store.data(service: sourceService, account: Self.vaultAccount) else {
        continue
      }
      guard let vault = try? JSONDecoder().decode([String: String].self, from: data) else {
        throw T3CredentialStoreError.invalidVault
      }
      sources.append((address, vault))
    }
    guard !sources.isEmpty else { return 0 }

    var merged: [String: String] = [:]
    for item in try validCredentialItems() where merged[item.record.credentialID] == nil {
      merged[item.record.credentialID] = item.record.token
    }
    for source in sources {
      for (credentialID, token) in source.vault where merged[credentialID] == nil {
        merged[credentialID] = token
      }
    }

    var replacements: [Address: Data] = [:]
    for (credentialID, token) in merged {
      let address = credentialAddress(for: credentialID)
      if let existingData = try store.data(service: address.service, account: address.account) {
        if (try? decodeCredential(existingData, expectedID: credentialID)) != nil {
          // A valid independently stored item is newer than any aggregate journal, including an
          // aggregate left behind by an interrupted migration.
          continue
        } else if let decoded = try? JSONDecoder().decode(
          CredentialRecord.self, from: existingData),
          decoded.credentialID != credentialID
        {
          throw T3CredentialStoreError.invalidCredential
        }
      }
      replacements[address] = try encodedCredential(token: token, credentialID: credentialID)
    }

    try applyTransaction(
      replacements: replacements, deletions: Set(sources.map(\.address)))
    return replacements.count
  }

  private func validCredentialItems() throws -> [DecodedItem] {
    try store.items(service: service).compactMap { item in
      guard item.account.hasPrefix(Self.credentialAccountPrefix),
        let record = try? JSONDecoder().decode(CredentialRecord.self, from: item.data),
        record.version == CredentialRecord.currentVersion,
        item.account == Self.account(for: record.credentialID)
      else { return nil }
      return DecodedItem(
        address: Address(service: service, account: item.account), record: record)
    }
  }

  private func applyTransaction(
    replacements: [Address: Data], deletions: Set<Address>
  ) throws {
    precondition(Set(replacements.keys).isDisjoint(with: deletions))
    let addresses = Set(replacements.keys).union(deletions)
    guard !addresses.isEmpty else { return }
    let orderedAddresses = addresses.sorted()
    var snapshots: [Address: Snapshot] = [:]
    for address in orderedAddresses {
      snapshots[address] = Snapshot(
        data: try store.data(service: address.service, account: address.account))
    }

    do {
      for address in replacements.keys.sorted() {
        try store.replace(
          replacements[address]!, service: address.service, account: address.account,
          label: label(for: address))
      }
      for address in replacements.keys.sorted() {
        guard
          try store.data(service: address.service, account: address.account)
            == replacements[address]
        else {
          throw T3CredentialStoreError.invalidCredential
        }
      }
      for address in deletions.sorted() {
        try store.delete(service: address.service, account: address.account)
      }
      for address in deletions.sorted() {
        guard try store.data(service: address.service, account: address.account) == nil else {
          throw T3CredentialStoreError.invalidCredential
        }
      }
    } catch let operationError {
      do {
        try restore(snapshots, orderedAddresses: orderedAddresses)
      } catch {
        throw T3CredentialStoreError.rollbackFailed
      }
      throw operationError
    }
  }

  private func restore(_ snapshots: [Address: Snapshot], orderedAddresses: [Address]) throws {
    let restorations = orderedAddresses.compactMap { address -> (Address, Data)? in
      guard let data = snapshots[address]?.data else { return nil }
      return (address, data)
    }
    for (address, data) in restorations {
      try store.replace(
        data, service: address.service, account: address.account,
        label: label(for: address))
    }
    for (address, data) in restorations {
      guard
        try store.data(service: address.service, account: address.account)
          == data
      else {
        throw T3CredentialStoreError.rollbackFailed
      }
    }

    // Newly created replacements are the only surviving copy after an aggregate source has been
    // deleted. Keep them until every prior item is back in place and verified.
    let removals = orderedAddresses.filter { snapshots[$0]?.data == nil }
    for address in removals {
      try store.delete(service: address.service, account: address.account)
    }
    for address in removals {
      guard try store.data(service: address.service, account: address.account) == nil else {
        throw T3CredentialStoreError.rollbackFailed
      }
    }
  }

  private func encodedCredential(token: String, credentialID: String) throws -> Data {
    try JSONEncoder().encode(CredentialRecord(credentialID: credentialID, token: token))
  }

  private func decodeCredential(_ data: Data, expectedID: String) throws -> CredentialRecord {
    guard let record = try? JSONDecoder().decode(CredentialRecord.self, from: data),
      record.version == CredentialRecord.currentVersion,
      record.credentialID == expectedID
    else {
      throw T3CredentialStoreError.invalidCredential
    }
    return record
  }

  private func credentialAddress(for credentialID: String) -> Address {
    Address(service: service, account: Self.account(for: credentialID))
  }

  private func label(for address: Address) -> String {
    address.account == Self.vaultAccount ? Self.vaultLabel : Self.credentialLabel
  }

  private struct CredentialRecord: Codable, Equatable {
    static let currentVersion = 2

    let version: Int
    let credentialID: String
    let token: String

    init(credentialID: String, token: String) {
      version = Self.currentVersion
      self.credentialID = credentialID
      self.token = token
    }
  }

  private struct DecodedItem {
    let address: Address
    let record: CredentialRecord
  }

  private struct Snapshot {
    let data: Data?
  }

  private struct Address: Hashable, Comparable {
    let service: String
    let account: String

    static func < (lhs: Address, rhs: Address) -> Bool {
      (lhs.service, lhs.account) < (rhs.service, rhs.account)
    }
  }
}

@MainActor
enum T3CredentialStore {
  static let service = "dev.islet"
  private static let vault = T3CredentialVault(
    service: service, legacyServices: LegacyInstallIdentifiers.credentialServices)

  static var hasLegacyVault: Bool { vault.hasLegacyVault }

  @discardableResult
  static func migrateLegacyVaults() throws -> Int {
    try vault.migrateLegacyVaults()
  }

  static func load(credentialID: String) throws -> String? {
    try vault.load(credentialID: credentialID)
  }

  static func saveLocal(_ token: String, credentialID: String, environmentID: String) throws {
    try vault.saveLocal(token, credentialID: credentialID, environmentID: environmentID)
  }

  static func save(_ token: String, credentialID: String) throws {
    try vault.save(token, credentialID: credentialID)
  }

  static func delete(credentialID: String) throws {
    try delete(credentialIDs: [credentialID])
  }

  static func delete(credentialIDs: Set<String>) throws {
    try vault.delete(credentialIDs: credentialIDs)
  }
}
