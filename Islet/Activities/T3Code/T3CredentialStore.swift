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
  static var service: String { credentialService(for: Bundle.main.bundleIdentifier) }
  private static let vaultAccount = "read-only-environment-tokens-v1"

  private static var cachedTokens: [String: String]?

  /// The upstream identity keeps using its established Keychain service. Local bundle-ID
  /// overrides get an isolated service without changing or migrating an installed app's vault.
  nonisolated static func credentialService(for bundleIdentifier: String?) -> String {
    switch bundleIdentifier {
    case "dev.cnucifora.Islet":
      "dev.cnucifora.islet.t3-code"
    case let bundleIdentifier? where !bundleIdentifier.isEmpty:
      bundleIdentifier
    default:
      "dev.cnucifora.islet.t3-code"
    }
  }

  static func load(credentialID: String) throws -> String? {
    try loadVault()[credentialID]
  }

  /// Saves a credential obtained through an explicit local pairing link. Old entries are removed
  /// only after a fresh one-time credential has authenticated the new endpoint. Discovery never
  /// moves or releases a bearer token based on a public environment descriptor.
  static func saveLocal(_ token: String, credentialID: String, environmentID: String) throws {
    let tokens = replacingLocalCredentials(
      in: try loadVault(), token: token, credentialID: credentialID,
      environmentID: environmentID)
    try persist(tokens)
    cachedTokens = tokens
  }

  nonisolated static func replacingLocalCredentials(
    in tokens: [String: String], token: String, credentialID: String, environmentID: String
  ) -> [String: String] {
    var replaced = tokens
    let obsoleteIDs = replaced.keys.filter {
      $0 == environmentID || $0.hasPrefix("local|")
    }
    for id in obsoleteIDs { replaced.removeValue(forKey: id) }
    replaced[credentialID] = token
    return replaced
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
      for (key, value) in values { addition[key] = value }
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
