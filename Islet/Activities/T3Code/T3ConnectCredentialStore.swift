import Foundation
import Security

enum T3ConnectCredentialStoreError: Error, LocalizedError {
  case keychain(OSStatus)
  case invalidRecord
  case staleOperation

  var errorDescription: String? {
    switch self {
    case .keychain(let status):
      SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)"
    case .invalidRecord:
      "The saved T3 Connect credential is unreadable. It was left unchanged."
    case .staleOperation:
      "The T3 Connect credential operation was invalidated by sign-out."
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
  private static let signOutPendingRecord = Data(
    #"{"type":"t3-connect-sign-out-pending","version":1}"#.utf8)

  private let store: any T3SecureRecordStore
  private let onSignOutWaiterQueued: @Sendable () -> Void
  private var oauthCache: Cache<T3OAuthRecord> = .unloaded
  private var proofKeyCache: Cache<Data> = .unloaded
  private var generation: UInt64 = 0
  private var signOutInProgress = false
  private var signOutWaiters: [CheckedContinuation<Void, Never>] = []
  private var oauthOperationInProgress = false
  private var oauthOperationWaiters: [CheckedContinuation<Void, Never>] = []
  private var proofKeyOperationInProgress = false
  private var proofKeyOperationWaiters: [CheckedContinuation<Void, Never>] = []

  init(
    store: any T3SecureRecordStore = T3KeychainSecureRecordStore(),
    onSignOutWaiterQueued: @escaping @Sendable () -> Void = {}
  ) {
    self.store = store
    self.onSignOutWaiterQueued = onSignOutWaiterQueued
  }

  func loadOAuthRecord() async throws -> T3OAuthRecord? {
    let capturedGeneration = try await admitOperation()
    if case .loaded(let record) = oauthCache { return record }
    let store = store
    let storedData = try await withStoreLock(.oauth) {
      try await store.data(service: Self.service, account: Self.oauthAccount)
    }
    guard let data = storedData else {
      guard capturedGeneration == generation else {
        throw T3ConnectCredentialStoreError.staleOperation
      }
      oauthCache = .loaded(nil)
      return nil
    }
    guard capturedGeneration == generation else {
      throw T3ConnectCredentialStoreError.staleOperation
    }
    if data == Self.signOutPendingRecord {
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
    let capturedGeneration = try await admitOperation()
    let data = try JSONEncoder().encode(record)
    let store = store
    try await withStoreLock(.oauth) {
      try await store.replace(
        data, service: Self.service, account: Self.oauthAccount,
        label: "Islet T3 Connect account")
    }
    guard capturedGeneration == generation else {
      throw T3ConnectCredentialStoreError.staleOperation
    }
    oauthCache = .loaded(record)
  }

  func loadProofKey() async throws -> Data? {
    let capturedGeneration = try await admitOperation()
    if case .loaded(let key) = proofKeyCache { return key }
    let store = store
    let key = try await withStoreLock(.proofKey) {
      try await store.data(service: Self.service, account: Self.dpopKeyAccount)
    }
    guard capturedGeneration == generation else {
      throw T3ConnectCredentialStoreError.staleOperation
    }
    proofKeyCache = .loaded(key)
    return key
  }

  func replaceProofKey(_ key: Data) async throws {
    let capturedGeneration = try await admitOperation()
    let store = store
    try await withStoreLock(.proofKey) {
      try await store.replace(
        key, service: Self.service, account: Self.dpopKeyAccount,
        label: "Islet T3 Connect proof key")
    }
    guard capturedGeneration == generation else {
      throw T3ConnectCredentialStoreError.staleOperation
    }
    proofKeyCache = .loaded(key)
  }

  func signOut() async throws {
    guard !signOutInProgress else { throw T3ConnectCredentialStoreError.staleOperation }
    signOutInProgress = true
    generation &+= 1

    let cleanupTask = Task { [self] in await performSignOutCleanup() }
    let result = await cleanupTask.value
    if result.tombstonedOAuth { oauthCache = .loaded(nil) }
    if result.deletedProofKey { proofKeyCache = .loaded(nil) }
    finishSignOut()
    if let firstError = result.firstError { throw firstError }
  }

  private func performSignOutCleanup() async -> SignOutCleanupResult {
    let store = store
    var result = SignOutCleanupResult()
    do {
      try await withStoreLock(.oauth) {
        try await store.replace(
          Self.signOutPendingRecord, service: Self.service, account: Self.oauthAccount,
          label: "Islet T3 Connect cleanup")
      }
      result.tombstonedOAuth = true
    } catch {
      result.firstError = error
      return result
    }
    do {
      try await withStoreLock(.proofKey) {
        try await store.delete(service: Self.service, account: Self.dpopKeyAccount)
      }
      result.deletedProofKey = true
    } catch {
      if result.firstError == nil { result.firstError = error }
      return result
    }
    do {
      try await withStoreLock(.oauth) {
        try await store.delete(service: Self.service, account: Self.oauthAccount)
      }
    } catch {
      if result.firstError == nil { result.firstError = error }
    }
    return result
  }

  private func waitForSignOutCompletion() async {
    await withCheckedContinuation { continuation in
      signOutWaiters.append(continuation)
      onSignOutWaiterQueued()
    }
  }

  private func admitOperation() async throws -> UInt64 {
    let capturedGeneration = generation
    let signOutWasInProgress = signOutInProgress
    if signOutWasInProgress { await waitForSignOutCompletion() }
    try Task.checkCancellation()
    guard !signOutWasInProgress, capturedGeneration == generation else {
      throw T3ConnectCredentialStoreError.staleOperation
    }
    return capturedGeneration
  }

  private func finishSignOut() {
    signOutInProgress = false
    let waiters = signOutWaiters
    signOutWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
  }

  private func withStoreLock<Value: Sendable>(
    _ operationKind: StoreOperationKind,
    operation: @escaping @Sendable () async throws -> Value
  ) async throws -> Value {
    await acquireStoreOperation(operationKind)
    defer { releaseStoreOperation(operationKind) }
    try Task.checkCancellation()
    return try await operation()
  }

  private func acquireStoreOperation(_ operationKind: StoreOperationKind) async {
    switch operationKind {
    case .oauth:
      if !oauthOperationInProgress {
        oauthOperationInProgress = true
        return
      }
      await withCheckedContinuation { continuation in
        oauthOperationWaiters.append(continuation)
      }
    case .proofKey:
      if !proofKeyOperationInProgress {
        proofKeyOperationInProgress = true
        return
      }
      await withCheckedContinuation { continuation in
        proofKeyOperationWaiters.append(continuation)
      }
    }
  }

  private func releaseStoreOperation(_ operationKind: StoreOperationKind) {
    switch operationKind {
    case .oauth:
      if oauthOperationWaiters.isEmpty {
        oauthOperationInProgress = false
      } else {
        oauthOperationWaiters.removeFirst().resume()
      }
    case .proofKey:
      if proofKeyOperationWaiters.isEmpty {
        proofKeyOperationInProgress = false
      } else {
        proofKeyOperationWaiters.removeFirst().resume()
      }
    }
  }

  private enum StoreOperationKind: Sendable {
    case oauth
    case proofKey
  }

  private struct SignOutCleanupResult: Sendable {
    var tombstonedOAuth = false
    var deletedProofKey = false
    var firstError: (any Error)?
  }

  private enum Cache<Value: Sendable>: Sendable {
    case unloaded
    case loaded(Value?)
  }
}
