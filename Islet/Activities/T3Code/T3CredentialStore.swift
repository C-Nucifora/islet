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

/// T3 access tokens never enter UserDefaults. Profiles contain endpoints and labels only; the
/// corresponding read-only bearer credential is held in the user's login Keychain.
enum T3CredentialStore {
  private static let service = "dev.cnucifora.islet.t3-code"

  static func load(environmentID: String) -> String? {
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecAttrAccount: environmentID,
      kSecReturnData: true,
      kSecMatchLimit: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
      let data = item as? Data
    else { return nil }
    return String(data: data, encoding: .utf8)
  }

  static func save(_ token: String, environmentID: String) throws {
    let key: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecAttrAccount: environmentID,
    ]
    let values: [CFString: Any] = [
      kSecValueData: Data(token.utf8),
      kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
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

  static func delete(environmentID: String) {
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecAttrAccount: environmentID,
    ]
    SecItemDelete(query as CFDictionary)
  }
}
