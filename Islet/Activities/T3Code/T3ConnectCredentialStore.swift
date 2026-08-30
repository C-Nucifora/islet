import Foundation
import Security

enum T3ConnectCredentialStoreError: Error, LocalizedError {
  case keychain(OSStatus)
  case invalidRecord

  var errorDescription: String? {
    switch self {
    case .keychain(let status):
      SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)"
    case .invalidRecord:
      "The saved T3 Connect credential is unreadable. It was left unchanged."
    }
  }
}

protocol T3SecureRecordStore: Sendable {
  func data(service: String, account: String) async throws -> Data?
  func replace(_ data: Data, service: String, account: String, label: String) async throws
  func delete(service: String, account: String) async throws
}

struct T3KeychainSecureRecordStore: T3SecureRecordStore {
  func data(service: String, account: String) async throws -> Data? {
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
    guard status == errSecSuccess else {
      throw T3ConnectCredentialStoreError.keychain(status)
    }
    guard let data = item as? Data else {
      throw T3ConnectCredentialStoreError.invalidRecord
    }
    return data
  }

  func replace(_ data: Data, service: String, account: String, label: String) async throws {
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
      for (attribute, value) in values {
        addition[attribute] = value
      }
      let addStatus = SecItemAdd(addition as CFDictionary, nil)
      guard addStatus == errSecSuccess else {
        throw T3ConnectCredentialStoreError.keychain(addStatus)
      }
    } else if status != errSecSuccess {
      throw T3ConnectCredentialStoreError.keychain(status)
    }
  }

  func delete(service: String, account: String) async throws {
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecAttrAccount: account,
    ]
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw T3ConnectCredentialStoreError.keychain(status)
    }
  }
}

actor T3ConnectCredentialStore {
  static let service = "dev.islet"
  static let oauthAccount = "t3-connect-oauth-v1"
  static let dpopKeyAccount = "t3-connect-dpop-p256-v1"

  private let store: any T3SecureRecordStore
  private var oauthCache: Cache<T3OAuthRecord> = .unloaded
  private var proofKeyCache: Cache<Data> = .unloaded

  init(store: any T3SecureRecordStore = T3KeychainSecureRecordStore()) {
    self.store = store
  }

  func loadOAuthRecord() async throws -> T3OAuthRecord? {
    if case .loaded(let record) = oauthCache { return record }
    guard let data = try await store.data(service: Self.service, account: Self.oauthAccount) else {
      oauthCache = .loaded(nil)
      return nil
    }
    guard let record = try? JSONDecoder().decode(T3OAuthRecord.self, from: data) else {
      throw T3ConnectCredentialStoreError.invalidRecord
    }
    oauthCache = .loaded(record)
    return record
  }

  func replaceOAuthRecord(_ record: T3OAuthRecord) async throws {
    let data = try JSONEncoder().encode(record)
    try await store.replace(
      data, service: Self.service, account: Self.oauthAccount,
      label: "Islet T3 Connect account")
    oauthCache = .loaded(record)
  }

  func loadProofKey() async throws -> Data? {
    if case .loaded(let key) = proofKeyCache { return key }
    let key = try await store.data(service: Self.service, account: Self.dpopKeyAccount)
    proofKeyCache = .loaded(key)
    return key
  }

  func replaceProofKey(_ key: Data) async throws {
    try await store.replace(
      key, service: Self.service, account: Self.dpopKeyAccount,
      label: "Islet T3 Connect proof key")
    proofKeyCache = .loaded(key)
  }

  func signOut() async throws {
    try await store.delete(service: Self.service, account: Self.oauthAccount)
    oauthCache = .loaded(nil)
    try await store.delete(service: Self.service, account: Self.dpopKeyAccount)
    proofKeyCache = .loaded(nil)
  }

  private enum Cache<Value: Sendable>: Sendable {
    case unloaded
    case loaded(Value?)
  }
}
