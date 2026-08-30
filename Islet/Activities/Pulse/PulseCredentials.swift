import CryptoKit
import Darwin
import Foundation
import Security

enum PulseCredentialPermission: String, Codable, CaseIterable, Identifiable, Sendable {
  case events
  case persistentActivities
  case progress
  case webActions

  var id: Self { self }

  var title: String {
    switch self {
    case .events: "Events"
    case .persistentActivities: "Persistent activities"
    case .progress: "Progress"
    case .webActions: "Web actions"
    }
  }

  var detail: String {
    switch self {
    case .events: "Publish transient eight-second events"
    case .persistentActivities: "Create, update, and end retained activities"
    case .progress: "Attach numeric progress and progress state"
    case .webActions: "Attach validated HTTP and HTTPS actions"
    }
  }
}

struct PulseCredentialSummary: Codable, Equatable, Identifiable, Sendable {
  let id: String
  var name: String
  var source: String
  var permissions: Set<PulseCredentialPermission>
  let createdAt: Date
  var rotatedAt: Date?
  var lastUsedAt: Date?
  var revokedAt: Date?
  let isLegacy: Bool

  var credentialAgeDate: Date { rotatedAt ?? createdAt }
  var isRevoked: Bool { revokedAt != nil }
}

struct PulseAuthenticatedProvider: Equatable, Sendable {
  let credentialID: String
  let source: String
  let permissions: Set<PulseCredentialPermission>
  let isLegacy: Bool
}

enum PulseCredentialError: LocalizedError, Equatable {
  case corruptRegistry
  case duplicateSource
  case providerLimitReached
  case invalidName
  case invalidSource
  case notFound
  case revoked
  case unauthorized
  case requestIDRequired
  case replayedRequest
  case sourceSpoofing
  case permissionDenied(PulseCredentialPermission)
  case unsafeCredentialFile

  var errorDescription: String? {
    switch self {
    case .corruptRegistry: "The Pulse provider registry is unreadable. It was left unchanged."
    case .duplicateSource: "An active credential already owns this provider source."
    case .providerLimitReached: "Pulse already has the maximum number of provider credentials."
    case .invalidName: "Provider name must contain 1 through 80 characters."
    case .invalidSource: "Provider source must contain 1 through 80 characters."
    case .notFound: "Provider credential was not found."
    case .revoked: "Provider credential is revoked."
    case .unauthorized: "Provider credential is invalid."
    case .requestIDRequired: "requestID is required for provider credentials."
    case .replayedRequest: "requestID was already used with this credential."
    case .sourceSpoofing: "Command source does not match the provider credential."
    case .permissionDenied(let permission):
      "Provider credential does not allow \(permission.title.lowercased())."
    case .unsafeCredentialFile: "Provider credential file is missing or has unsafe permissions."
    }
  }
}

@MainActor
final class PulseCredentialStore: ObservableObject {
  private struct Registry: Codable {
    let version: Int
    var credentials: [PulseCredentialSummary]
  }

  private struct ParsedCredential {
    let id: String
    let secret: Data
  }

  static let currentVersion = 1
  static let legacyCredentialID = "legacy-shared"
  static let maximumRememberedRequestIDs = 512
  static let maximumActiveProviders = 256
  static let maximumProviderRecords = 1_024
  static let maximumRegistryBytes = 1_048_576
  static let maximumCredentialBytes = 4_096
  static let lastUsePersistenceInterval: TimeInterval = 60

  @Published private(set) var credentials: [PulseCredentialSummary] = []
  @Published private(set) var lastError: String?

  private let supportDirectory: URL
  private let now: () -> Date
  private var hasLoaded = false
  private var replayOrder: [String: [String]] = [:]
  private var replaySets: [String: Set<String>] = [:]
  private var persistedLastUsedAt: [String: Date] = [:]

  init(
    supportDirectory: URL = PulsePaths.supportDirectory,
    now: @escaping () -> Date = Date.init
  ) {
    self.supportDirectory = supportDirectory
    self.now = now
  }

  var credentialDirectory: URL {
    supportDirectory.appendingPathComponent("pulse-credentials", isDirectory: true)
  }

  var registryURL: URL { supportDirectory.appendingPathComponent("pulse-providers.json") }
  var legacyTokenURL: URL { supportDirectory.appendingPathComponent("pulse-token") }

  func credentialFileURL(for id: String) -> URL? {
    guard let credential = credentials.first(where: { $0.id == id }), !credential.isRevoked
    else { return nil }
    return credential.isLegacy ? legacyTokenURL : credentialURL(for: id)
  }

  func prepare() throws {
    guard !hasLoaded else { return }
    do {
      try secureDirectories()
      if FileManager.default.fileExists(atPath: registryURL.path) {
        let registry = try readRegistry()
        guard registry.version == Self.currentVersion else {
          throw PulseCredentialError.corruptRegistry
        }
        credentials = try validatedCredentials(registry.credentials)
      } else {
        credentials = try migratedLegacyCredential().map { [$0] } ?? []
        try persistRegistry()
      }
      hasLoaded = true
      lastError = nil
    } catch {
      lastError = error.localizedDescription
      throw error
    }
  }

  @discardableResult
  func createProvider(
    name rawName: String, source rawSource: String,
    permissions: Set<PulseCredentialPermission>
  ) throws -> PulseCredentialSummary {
    try prepare()
    let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, name.count <= 80 else { throw PulseCredentialError.invalidName }
    guard credentials.count < Self.maximumProviderRecords,
      credentials.lazy.filter({ !$0.isRevoked }).count < Self.maximumActiveProviders
    else { throw PulseCredentialError.providerLimitReached }
    let source = try normalizedSource(rawSource)
    guard
      !credentials.contains(where: { !$0.isRevoked && sourceKey($0.source) == sourceKey(source) })
    else { throw PulseCredentialError.duplicateSource }

    let date = now()
    let summary = PulseCredentialSummary(
      id: UUID().uuidString.lowercased(), name: name, source: source,
      permissions: permissions, createdAt: date, rotatedAt: nil, lastUsedAt: nil,
      revokedAt: nil, isLegacy: false)
    let material = try makeCredential(id: summary.id)
    try writeCredential(material, id: summary.id)
    credentials.append(summary)
    do {
      try persistRegistry()
    } catch {
      credentials.removeAll { $0.id == summary.id }
      try? FileManager.default.removeItem(at: credentialURL(for: summary.id))
      throw error
    }
    return summary
  }

  func setPermissions(_ permissions: Set<PulseCredentialPermission>, for id: String) throws {
    try prepare()
    guard let index = credentials.firstIndex(where: { $0.id == id }) else {
      throw PulseCredentialError.notFound
    }
    guard !credentials[index].isRevoked else { throw PulseCredentialError.revoked }
    let previous = credentials[index].permissions
    credentials[index].permissions = permissions
    do {
      try persistRegistry()
    } catch {
      credentials[index].permissions = previous
      throw error
    }
  }

  func rotate(_ id: String) throws {
    try prepare()
    guard let index = credentials.firstIndex(where: { $0.id == id }) else {
      throw PulseCredentialError.notFound
    }
    guard !credentials[index].isRevoked, !credentials[index].isLegacy else {
      throw PulseCredentialError.revoked
    }
    let previousSummary = credentials[index]
    let previousMaterial = try readCredential(id: id)
    let material = try makeCredential(id: id)
    try writeCredential(material, id: id)
    credentials[index].rotatedAt = now()
    credentials[index].lastUsedAt = nil
    do {
      try persistRegistry()
      clearReplayState(for: id)
    } catch {
      credentials[index] = previousSummary
      try writeCredential(previousMaterial, id: id)
      throw error
    }
  }

  func revoke(_ id: String) throws {
    try prepare()
    guard let index = credentials.firstIndex(where: { $0.id == id }) else {
      throw PulseCredentialError.notFound
    }
    guard !credentials[index].isRevoked else { return }
    let previous = credentials[index]
    credentials[index].revokedAt = now()
    do {
      try persistRegistry()
      clearReplayState(for: id)
    } catch {
      credentials[index] = previous
      throw error
    }
    let url = credentials[index].isLegacy ? legacyTokenURL : credentialURL(for: id)
    try? FileManager.default.removeItem(at: url)
  }

  func authorize(_ incoming: PulseCommand, at suppliedDate: Date? = nil) throws
    -> (PulseCommand, PulseAuthenticatedProvider)
  {
    try prepare()
    let provider = try authenticate(incoming.token)
    return try authorize(incoming, as: provider, at: suppliedDate)
  }

  func authorize(
    _ incoming: PulseCommand, as provider: PulseAuthenticatedProvider,
    at suppliedDate: Date? = nil
  ) throws -> (PulseCommand, PulseAuthenticatedProvider) {
    try prepare()
    let date = suppliedDate ?? now()
    guard let index = credentials.firstIndex(where: { $0.id == provider.credentialID }) else {
      throw PulseCredentialError.notFound
    }
    guard !credentials[index].isRevoked else { throw PulseCredentialError.revoked }
    guard credentials[index].source == provider.source,
      credentials[index].permissions == provider.permissions,
      credentials[index].isLegacy == provider.isLegacy
    else { throw PulseCredentialError.unauthorized }

    var command = incoming
    if provider.isLegacy {
      command.activity?.source = provider.source
      command.source = provider.source
    } else {
      if let source = command.activity?.source,
        sourceKey(source) != sourceKey(provider.source)
      {
        throw PulseCredentialError.sourceSpoofing
      }
      if let source = command.source, sourceKey(source) != sourceKey(provider.source) {
        throw PulseCredentialError.sourceSpoofing
      }
      command.activity?.source = provider.source
      command.source = provider.source
    }

    try requirePermissions(for: command, provider: provider)
    if !provider.isLegacy {
      guard let requestID = command.requestID?.trimmingCharacters(in: .whitespacesAndNewlines),
        !requestID.isEmpty
      else { throw PulseCredentialError.requestIDRequired }
      guard remember(requestID: requestID, for: provider.credentialID) else {
        throw PulseCredentialError.replayedRequest
      }
    }

    credentials[index].lastUsedAt = date
    let shouldPersist =
      persistedLastUsedAt[provider.credentialID].map {
        date < $0 || date.timeIntervalSince($0) >= Self.lastUsePersistenceInterval
      } ?? true
    guard shouldPersist else { return (command, provider) }
    do {
      try persistRegistry()
      lastError = nil
    } catch {
      lastError = "Could not save Pulse provider last use: \(error.localizedDescription)"
    }
    return (command, provider)
  }

  func authenticate(_ token: String) throws -> PulseAuthenticatedProvider {
    try prepare()
    if let parsed = Self.parseCredential(token) {
      guard let record = credentials.first(where: { $0.id == parsed.id }) else {
        throw PulseCredentialError.unauthorized
      }
      guard !record.isRevoked else { throw PulseCredentialError.revoked }
      let stored = try readCredential(id: record.id)
      guard let expected = Self.parseCredential(stored), expected.id == parsed.id,
        Self.constantTimeEqual(parsed.secret, expected.secret)
      else { throw PulseCredentialError.unauthorized }
      return PulseAuthenticatedProvider(
        credentialID: record.id, source: record.source, permissions: record.permissions,
        isLegacy: false)
    }

    guard let legacy = credentials.first(where: { $0.id == Self.legacyCredentialID }),
      !legacy.isRevoked,
      let supplied = Data(base64Encoded: token), supplied.count == 32,
      let storedToken = try? readSecureString(at: legacyTokenURL),
      let expected = Data(base64Encoded: storedToken), expected.count == 32,
      Self.constantTimeEqual(supplied, expected)
    else { throw PulseCredentialError.unauthorized }
    return PulseAuthenticatedProvider(
      credentialID: legacy.id, source: legacy.source, permissions: legacy.permissions,
      isLegacy: true)
  }

  private func requirePermissions(
    for command: PulseCommand, provider: PulseAuthenticatedProvider
  ) throws {
    let base: PulseCredentialPermission =
      command.operation == .event ? .events : .persistentActivities
    guard provider.permissions.contains(base) else {
      throw PulseCredentialError.permissionDenied(base)
    }
    if command.activity?.progress != nil || command.activity?.state == .progress {
      guard provider.permissions.contains(.progress) else {
        throw PulseCredentialError.permissionDenied(.progress)
      }
    }
    if command.activity?.actions?.isEmpty == false {
      guard provider.permissions.contains(.webActions) else {
        throw PulseCredentialError.permissionDenied(.webActions)
      }
    }
  }

  private func migratedLegacyCredential() throws -> PulseCredentialSummary? {
    guard FileManager.default.fileExists(atPath: legacyTokenURL.path) else { return nil }
    let token = try readSecureString(at: legacyTokenURL)
    guard let data = Data(base64Encoded: token), data.count == 32 else {
      throw PulseCredentialError.unsafeCredentialFile
    }
    let attributes = try? FileManager.default.attributesOfItem(atPath: legacyTokenURL.path)
    let createdAt = attributes?[.creationDate] as? Date ?? now()
    return PulseCredentialSummary(
      id: Self.legacyCredentialID, name: "Legacy shared token", source: "legacy",
      permissions: [.events], createdAt: createdAt, rotatedAt: nil, lastUsedAt: nil,
      revokedAt: nil, isLegacy: true)
  }

  private func secureDirectories() throws {
    try secureDirectory(at: supportDirectory)
    try secureDirectory(at: credentialDirectory)
  }

  private func secureDirectory(at url: URL) throws {
    let createResult = url.path.withCString { Darwin.mkdir($0, 0o700) }
    guard createResult == 0 || errno == EEXIST else {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    let descriptor = url.path.withCString {
      Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    }
    guard descriptor >= 0 else { throw PulseCredentialError.unsafeCredentialFile }
    defer { Darwin.close(descriptor) }
    var info = stat()
    guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
      info.st_uid == getuid(), fchmod(descriptor, 0o700) == 0
    else { throw PulseCredentialError.unsafeCredentialFile }
  }

  private func readRegistry() throws -> Registry {
    let data = try readSecureData(at: registryURL, maximumBytes: Self.maximumRegistryBytes)
    do {
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      return try decoder.decode(Registry.self, from: data)
    } catch {
      throw PulseCredentialError.corruptRegistry
    }
  }

  private func persistRegistry() throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let registry = Registry(
      version: Self.currentVersion,
      credentials: credentials.sorted { $0.createdAt < $1.createdAt })
    try atomicWrite(try encoder.encode(registry), to: registryURL)
    persistedLastUsedAt = Dictionary(
      uniqueKeysWithValues: credentials.compactMap { summary in
        summary.lastUsedAt.map { (summary.id, $0) }
      })
  }

  private func makeCredential(id: String) throws -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    let status = bytes.withUnsafeMutableBytes { buffer in
      SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
    }
    guard status == errSecSuccess else { throw CocoaError(.fileWriteUnknown) }
    let secret = Data(bytes).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
    return "islet-pulse-v1.\(id).\(secret)"
  }

  private func writeCredential(_ material: String, id: String) throws {
    try atomicWrite(Data("\(material)\n".utf8), to: credentialURL(for: id))
  }

  private func readCredential(id: String) throws -> String {
    try readSecureString(at: credentialURL(for: id), maximumBytes: Self.maximumCredentialBytes)
  }

  private func credentialURL(for id: String) -> URL {
    credentialDirectory.appendingPathComponent("\(id).credential")
  }

  private func atomicWrite(_ data: Data, to destination: URL) throws {
    let temporary = destination.deletingLastPathComponent().appendingPathComponent(
      ".\(destination.lastPathComponent)-\(UUID().uuidString).tmp")
    guard
      FileManager.default.createFile(
        atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600])
    else { throw CocoaError(.fileWriteUnknown) }
    defer { try? FileManager.default.removeItem(at: temporary) }
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
    let result = temporary.path.withCString { source in
      destination.path.withCString { target in Darwin.rename(source, target) }
    }
    guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
  }

  private func readSecureString(
    at url: URL, maximumBytes: Int = PulseCredentialStore.maximumCredentialBytes
  ) throws -> String {
    String(decoding: try readSecureData(at: url, maximumBytes: maximumBytes), as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func readSecureData(at url: URL, maximumBytes: Int) throws -> Data {
    let descriptor = url.path.withCString {
      Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    }
    guard descriptor >= 0 else { throw PulseCredentialError.unsafeCredentialFile }
    defer { Darwin.close(descriptor) }
    var info = stat()
    guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
      info.st_uid == getuid(), (info.st_mode & 0o077) == 0
    else { throw PulseCredentialError.unsafeCredentialFile }
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while true {
      let count = buffer.withUnsafeMutableBytes { bytes in
        Darwin.read(descriptor, bytes.baseAddress, bytes.count)
      }
      if count == 0 { return result }
      if count < 0 {
        if errno == EINTR { continue }
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
      }
      guard result.count <= maximumBytes - count else {
        throw PulseCredentialError.unsafeCredentialFile
      }
      result.append(contentsOf: buffer.prefix(count))
    }
  }

  private func validatedCredentials(_ stored: [PulseCredentialSummary]) throws
    -> [PulseCredentialSummary]
  {
    guard stored.count <= Self.maximumProviderRecords,
      stored.lazy.filter({ !$0.isRevoked }).count <= Self.maximumActiveProviders
    else {
      throw PulseCredentialError.corruptRegistry
    }
    var identifiers: Set<String> = []
    var activeSources: Set<String> = []
    for summary in stored {
      let name = summary.name.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !name.isEmpty, name.count <= 80, identifiers.insert(summary.id).inserted else {
        throw PulseCredentialError.corruptRegistry
      }
      let isLegacyID = summary.id == Self.legacyCredentialID
      guard summary.isLegacy == isLegacyID else { throw PulseCredentialError.corruptRegistry }
      if !summary.isLegacy {
        guard let uuid = UUID(uuidString: summary.id), uuid.uuidString.lowercased() == summary.id
        else { throw PulseCredentialError.corruptRegistry }
      }
      let normalized = try normalizedSource(summary.source)
      guard normalized == summary.source else { throw PulseCredentialError.corruptRegistry }
      if !summary.isRevoked {
        guard activeSources.insert(sourceKey(summary.source)).inserted else {
          throw PulseCredentialError.corruptRegistry
        }
      }
    }
    return stored
  }

  private func normalizedSource(_ source: String) throws -> String {
    do {
      return try PulseItem.normalizedSource(source)
    } catch {
      throw PulseCredentialError.invalidSource
    }
  }

  private func sourceKey(_ source: String) -> String {
    (try? PulseItem.normalizedSourceKey(source)) ?? ""
  }

  private func remember(requestID: String, for credentialID: String) -> Bool {
    let digest = Data(SHA256.hash(data: Data(requestID.utf8))).base64EncodedString()
    guard replaySets[credentialID]?.contains(digest) != true else { return false }
    replaySets[credentialID, default: []].insert(digest)
    replayOrder[credentialID, default: []].append(digest)
    while replayOrder[credentialID, default: []].count > Self.maximumRememberedRequestIDs {
      let removed = replayOrder[credentialID, default: []].removeFirst()
      replaySets[credentialID]?.remove(removed)
    }
    return true
  }

  private func clearReplayState(for credentialID: String) {
    replayOrder[credentialID] = nil
    replaySets[credentialID] = nil
  }

  private static func parseCredential(_ value: String) -> ParsedCredential? {
    let parts = value.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3, parts[0] == "islet-pulse-v1",
      UUID(uuidString: String(parts[1])) != nil
    else { return nil }
    var encoded = String(parts[2]).replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
    guard let secret = Data(base64Encoded: encoded), secret.count == 32 else { return nil }
    return ParsedCredential(id: String(parts[1]).lowercased(), secret: secret)
  }

  private static func constantTimeEqual(_ supplied: Data, _ expected: Data) -> Bool {
    guard supplied.count == expected.count, supplied.count == 32 else { return false }
    var difference: UInt8 = 0
    for index in supplied.indices { difference |= supplied[index] ^ expected[index] }
    return difference == 0
  }
}
