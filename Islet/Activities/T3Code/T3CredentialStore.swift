import Foundation
import Security

enum T3CredentialStoreError: Error, LocalizedError {
  case keychain(OSStatus)

  var errorDescription: String? {
    switch self {
    case .keychain(let status):
      SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)"
    }
  }
}

/// All T3 bearer tokens live in one Keychain item and are cached for the process lifetime. That
/// means macOS can ask for Keychain access at most once per launch, regardless of how many local or
/// remote T3 environments Islet watches. The old per-environment items are imported lazily.
@MainActor
enum T3CredentialStore {
  private static let service = "dev.cnucifora.islet.t3-code"
  private static let legacyService = "dev.nedlane.islet.t3-code"
  private static let vaultAccount = "read-only-environment-tokens-v1"

  private static var cachedTokens: [String: String]?
  private static var attemptedLegacyIDs: Set<String> = []

  static func load(environmentID: String, migrateLegacy: Bool = true) -> String? {
    var tokens = loadVault()
    if let token = tokens[environmentID] { return token }

    // One release-cycle migration path for credentials created by the feature-fork identity.
    // Local T3 can mint a fresh token without interaction, so only remote credentials need this
    // lookup. Each remote environment is queried no more than once, even if monitors restart.
    guard migrateLegacy, attemptedLegacyIDs.insert(environmentID).inserted,
      let token = read(service: legacyService, account: environmentID)
    else { return nil }
    tokens[environmentID] = token
    cachedTokens = tokens
    try? persist(tokens)
    return token
  }

  static func save(_ token: String, environmentID: String) throws {
    var tokens = loadVault()
    tokens[environmentID] = token
    try persist(tokens)
    cachedTokens = tokens
  }

  static func delete(environmentID: String) {
    var tokens = loadVault()
    tokens.removeValue(forKey: environmentID)
    try? persist(tokens)
    cachedTokens = tokens
  }

  private static func loadVault() -> [String: String] {
    if let cachedTokens { return cachedTokens }
    let tokens: [String: String]
    if let data = readData(service: service, account: vaultAccount),
      let decoded = try? JSONDecoder().decode([String: String].self, from: data)
    {
      tokens = decoded
    } else if let data = readData(service: legacyService, account: vaultAccount),
      let decoded = try? JSONDecoder().decode([String: String].self, from: data)
    {
      // The feature fork already used the consolidated vault format. Copy it under the upstream
      // service name once so switching bundle identity does not make paired remotes disappear.
      tokens = decoded
      try? persist(decoded)
    } else {
      tokens = [:]
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

  private static func read(service: String, account: String) -> String? {
    guard let data = readData(service: service, account: account) else { return nil }
    return String(data: data, encoding: .utf8)
  }

  private static func readData(service: String, account: String) -> Data? {
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecAttrAccount: account,
      kSecReturnData: true,
      kSecMatchLimit: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
    return item as? Data
  }
}
