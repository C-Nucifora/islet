import Foundation
import Security

enum T3CredentialStoreError: Error, LocalizedError {
  case keychain(OSStatus)
  case invalidVault

  var errorDescription: String? {
    switch self {
    case .keychain(let status):
      SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)"
    case .invalidVault:
      "The saved T3 Code credential vault is unreadable. It was left unchanged."
    }
  }
}

/// All T3 bearer tokens live in one Keychain item and are cached for the process lifetime. That
/// means macOS can ask for Keychain access at most once per launch, regardless of how many local or
/// remote T3 environments Islet watches.
@MainActor
enum T3CredentialStore {
  private static let service = "dev.cnucifora.islet.t3-code"
  private static let vaultAccount = "read-only-environment-tokens-v1"

  private static var cachedTokens: [String: String]?

  static func load(credentialID: String) throws -> String? {
    try loadVault()[credentialID]
  }

  /// Local T3 is constrained to loopback, so an endpoint-port change can safely carry the token
  /// for the same environment forward. Collapse old port-scoped and ID-only entries at the same
  /// time so runtime restarts cannot leave live bearer tokens accumulating in the vault.
  static func loadLocal(credentialID: String, environmentID: String) throws -> String? {
    let tokens = try loadVault()
    let migration = migratingLocalCredential(
      in: tokens, credentialID: credentialID, environmentID: environmentID)
    guard let token = migration.token else { return nil }
    guard migration.tokens != tokens else { return token }

    try persist(migration.tokens)
    cachedTokens = migration.tokens
    return token
  }

  nonisolated static func migratingLocalCredential(
    in tokens: [String: String], credentialID: String, environmentID: String
  ) -> (tokens: [String: String], token: String?) {
    var migrated = tokens
    let prefix = "local|\(environmentID)|"
    let obsoleteIDs = migrated.keys.filter {
      $0 == environmentID || ($0.hasPrefix(prefix) && $0 != credentialID)
    }
    let oldScopedIDs = obsoleteIDs.filter { $0.hasPrefix(prefix) }.sorted()
    let token = migrated[credentialID]
      ?? oldScopedIDs.compactMap { migrated[$0] }.first
      ?? migrated[environmentID]
    guard let token else { return (migrated, nil) }

    migrated[credentialID] = token
    for id in obsoleteIDs { migrated.removeValue(forKey: id) }
    return (migrated, token)
  }

  static func save(_ token: String, credentialID: String) throws {
    var tokens = try loadVault()
    tokens[credentialID] = token
    try persist(tokens)
    cachedTokens = tokens
  }

  static func delete(credentialID: String) throws {
    try delete(credentialIDs: [credentialID])
  }

  static func delete(credentialIDs: Set<String>) throws {
    var tokens = try loadVault()
    var changed = false
    for credentialID in credentialIDs {
      changed = tokens.removeValue(forKey: credentialID) != nil || changed
    }
    guard changed else { return }
    try persist(tokens)
    cachedTokens = tokens
  }

  private static func loadVault() throws -> [String: String] {
    if let cachedTokens { return cachedTokens }
    guard let data = try readData(service: service, account: vaultAccount) else {
      cachedTokens = [:]
      return [:]
    }
    guard let tokens = try? JSONDecoder().decode([String: String].self, from: data) else {
      throw T3CredentialStoreError.invalidVault
    }
    cachedTokens = tokens
    return tokens
  }

  private static func persist(_ tokens: [String: String]) throws {
    let data = try JSONEncoder().encode(tokens)
    let key: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecAttrAccount: vaultAccount,
    ]
    let values: [CFString: Any] = [
      kSecValueData: data,
      kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
      kSecAttrLabel: "Islet T3 Code read-only credentials",
    ]
    let status = SecItemUpdate(key as CFDictionary, values as CFDictionary)
    if status == errSecItemNotFound {
      var addition = key
      values.forEach { addition[$0.key] = $0.value }
      let addStatus = SecItemAdd(addition as CFDictionary, nil)
      guard addStatus == errSecSuccess else { throw T3CredentialStoreError.keychain(addStatus) }
    } else if status != errSecSuccess {
      throw T3CredentialStoreError.keychain(status)
    }
  }

  private static func readData(service: String, account: String) throws -> Data? {
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
    guard let data = item as? Data else { throw T3CredentialStoreError.invalidVault }
    return data
  }
}
