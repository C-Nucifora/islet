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

  static func load(credentialID: String, legacyEnvironmentID: String? = nil) throws -> String? {
    var tokens = try loadVault()
    if let token = tokens[credentialID] { return token }
    guard let legacyEnvironmentID, let token = tokens[legacyEnvironmentID] else { return nil }

    // Same-service schema upgrade only: older builds keyed credentials by the server's
    // environment id. Endpoint-scoped keys prevent two machines with a duplicated id from sharing
    // or overwriting one another. This never reads another bundle/service identity.
    tokens[credentialID] = token
    tokens.removeValue(forKey: legacyEnvironmentID)
    try persist(tokens)
    cachedTokens = tokens
    return token
  }

  static func save(_ token: String, credentialID: String) throws {
    var tokens = try loadVault()
    tokens[credentialID] = token
    try persist(tokens)
    cachedTokens = tokens
  }

  static func delete(credentialID: String) throws {
    var tokens = try loadVault()
    guard tokens.removeValue(forKey: credentialID) != nil else { return }
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
