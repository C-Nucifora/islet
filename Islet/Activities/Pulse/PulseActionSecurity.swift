import AppKit
import Darwin
import Foundation

enum PulseActionDestinationKind: String, Codable, Sendable {
  case external
  case loopback
}

struct PulseActionDestination: Equatable, Sendable {
  let url: URL
  let scheme: String
  let host: String
  let port: Int?
  let displayHost: String
  let canonicalOrigin: String
  let kind: PulseActionDestinationKind

  static func validate(_ url: URL) throws -> Self {
    let value = url.absoluteString
    guard value.count <= PulseItem.maximumActionURLLength else {
      throw PulseValidationError.tooLong("action URL", PulseItem.maximumActionURLLength)
    }
    guard
      !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
      !containsEncodedControl(value)
    else { throw PulseValidationError.unsafeActionURL }

    guard
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      let rawScheme = components.scheme,
      components.user == nil,
      components.password == nil,
      components.fragment?.unicodeScalars.contains(where: {
        CharacterSet.controlCharacters.contains($0)
      }) != true
    else { throw PulseValidationError.unsafeActionURL }

    let scheme = rawScheme.lowercased()
    guard scheme == "http" || scheme == "https" else {
      throw PulseValidationError.unsafeActionURL
    }
    let schemePrefix = "\(rawScheme)://"
    guard value.hasPrefix(schemePrefix) else { throw PulseValidationError.unsafeActionURL }
    let authorityStart = value.index(value.startIndex, offsetBy: schemePrefix.count)
    let authorityEnd =
      value[authorityStart...].firstIndex(where: { "/?#".contains($0) })
      ?? value.endIndex
    let authority = String(value[authorityStart..<authorityEnd])
    guard
      !authority.isEmpty,
      authority.unicodeScalars.allSatisfy(\.isASCII),
      !authority.contains("@"),
      !authority.contains("%"),
      !authority.contains("\\"),
      !authority.contains(where: \.isWhitespace)
    else { throw PulseValidationError.unsafeActionURL }

    let parsed = try parseAuthority(authority)
    let canonicalHost: String
    let formattedHost: String
    let kind: PulseActionDestinationKind
    if parsed.host.hasPrefix("[") {
      guard parsed.host.hasSuffix("]") else { throw PulseValidationError.unsafeActionURL }
      let literal = String(parsed.host.dropFirst().dropLast())
      canonicalHost = try canonicalIPv6(literal)
      formattedHost = "[\(canonicalHost)]"
      kind = try isIPv6Loopback(literal) ? .loopback : .external
    } else if parsed.host.first?.isNumber == true,
      parsed.host.allSatisfy({ $0.isNumber || $0 == "." })
    {
      canonicalHost = try canonicalIPv4(parsed.host)
      formattedHost = canonicalHost
      kind = canonicalHost.hasPrefix("127.") ? .loopback : .external
    } else if isLegacyNumericIPv4(parsed.host) {
      throw PulseValidationError.unsafeActionURL
    } else {
      canonicalHost = try canonicalDNSHost(parsed.host)
      formattedHost = canonicalHost
      kind =
        canonicalHost == "localhost" || canonicalHost.hasSuffix(".localhost")
        ? .loopback : .external
    }

    let port = try parsed.port.map(validatedPort)
    let defaultPort = scheme == "https" ? 443 : 80
    let canonicalPort = port == defaultPort ? nil : port
    let displayHost = canonicalPort.map { "\(formattedHost):\($0)" } ?? formattedHost
    return Self(
      url: url, scheme: scheme, host: canonicalHost, port: canonicalPort,
      displayHost: displayHost, canonicalOrigin: "\(scheme)://\(displayHost)", kind: kind)
  }

  private static func containsEncodedControl(_ value: String) -> Bool {
    let bytes = Array(value.utf8)
    guard bytes.count >= 3 else { return false }
    for index in 0...(bytes.count - 3) where bytes[index] == 0x25 {
      guard let high = hex(bytes[index + 1]), let low = hex(bytes[index + 2]) else { continue }
      let decoded = high << 4 | low
      if decoded < 0x20 || decoded == 0x7F { return true }
    }
    return false
  }

  private static func hex(_ byte: UInt8) -> UInt8? {
    switch byte {
    case 0x30...0x39: byte - 0x30
    case 0x41...0x46: byte - 0x41 + 10
    case 0x61...0x66: byte - 0x61 + 10
    default: nil
    }
  }

  private static func parseAuthority(_ authority: String) throws -> (host: String, port: String?) {
    if authority.hasPrefix("[") {
      guard let close = authority.firstIndex(of: "]") else {
        throw PulseValidationError.unsafeActionURL
      }
      let after = authority.index(after: close)
      if after == authority.endIndex { return (authority, nil) }
      guard authority[after] == ":" else { throw PulseValidationError.unsafeActionURL }
      let portStart = authority.index(after: after)
      guard portStart < authority.endIndex else { throw PulseValidationError.unsafeActionURL }
      return (String(authority[...close]), String(authority[portStart...]))
    }
    let parts = authority.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count <= 2, let host = parts.first, !host.isEmpty else {
      throw PulseValidationError.unsafeActionURL
    }
    if parts.count == 2 {
      guard !parts[1].isEmpty else { throw PulseValidationError.unsafeActionURL }
      return (String(host), String(parts[1]))
    }
    return (String(host), nil)
  }

  private static func validatedPort(_ value: String) throws -> Int {
    guard value.allSatisfy(\.isNumber), let port = Int(value), (1...65_535).contains(port)
    else { throw PulseValidationError.unsafeActionURL }
    return port
  }

  private static func canonicalIPv4(_ host: String) throws -> String {
    let parts = host.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 4 else { throw PulseValidationError.unsafeActionURL }
    var normalized: [String] = []
    for part in parts {
      guard !part.isEmpty, part.count == 1 || part.first != "0", let value = UInt8(part)
      else { throw PulseValidationError.unsafeActionURL }
      normalized.append(String(value))
    }
    return normalized.joined(separator: ".")
  }

  /// Darwin accepts legacy hexadecimal and shortened IPv4 spellings during name resolution.
  /// Reject them before the DNS branch so a loopback address cannot be presented as external.
  private static func isLegacyNumericIPv4(_ host: String) -> Bool {
    let labels = host.split(separator: ".", omittingEmptySubsequences: false)
    guard (1...4).contains(labels.count) else { return false }
    return labels.allSatisfy { label in
      if label.hasPrefix("0x") || label.hasPrefix("0X") {
        let digits = label.dropFirst(2)
        return !digits.isEmpty && digits.allSatisfy(\.isHexDigit)
      }
      return !label.isEmpty && label.allSatisfy(\.isNumber)
    }
  }

  private static func canonicalIPv6(_ host: String) throws -> String {
    guard !host.isEmpty, !host.contains("%") else { throw PulseValidationError.unsafeActionURL }
    var address = in6_addr()
    guard host.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else {
      throw PulseValidationError.unsafeActionURL
    }
    var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
    guard inet_ntop(AF_INET6, &address, &buffer, socklen_t(buffer.count)) != nil else {
      throw PulseValidationError.unsafeActionURL
    }
    let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return String(decoding: bytes, as: UTF8.self).lowercased()
  }

  private static func isIPv6Loopback(_ host: String) throws -> Bool {
    var address = in6_addr()
    guard host.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else {
      throw PulseValidationError.unsafeActionURL
    }
    let bytes = withUnsafeBytes(of: address) { Array($0) }
    let isNativeLoopback = bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1
    let isMappedIPv4Loopback =
      bytes.prefix(10).allSatisfy { $0 == 0 }
      && bytes[10] == 0xFF && bytes[11] == 0xFF && bytes[12] == 127
    return isNativeLoopback || isMappedIPv4Loopback
  }

  private static func canonicalDNSHost(_ host: String) throws -> String {
    let result = host.lowercased()
    guard
      !result.isEmpty,
      result.count <= 253,
      !result.hasSuffix("."),
      result.contains(".") || result == "localhost"
        || result.hasSuffix(".localhost")
    else { throw PulseValidationError.unsafeActionURL }
    let labels = result.split(separator: ".", omittingEmptySubsequences: false)
    guard
      labels.allSatisfy({ label in
        !label.isEmpty && label.count <= 63 && !label.hasPrefix("-") && !label.hasSuffix("-")
          && !label.lowercased().hasPrefix("xn--")
          && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
      })
    else { throw PulseValidationError.unsafeActionURL }
    return result
  }
}

struct PulseProviderIdentity: Codable, Equatable, Hashable, Sendable {
  let credentialID: String
  let sourceKey: String

  init(credentialID: String, source: String) throws {
    let identifier = credentialID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      !identifier.isEmpty, identifier.count <= 128,
      identifier.unicodeScalars.allSatisfy(\.isASCII),
      identifier.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == ":" })
    else {
      throw PulseValidationError.unsafeProviderIdentity
    }
    self.credentialID = identifier
    sourceKey = try PulseItem.normalizedSourceKey(source)
  }
}

struct PulseActionTrust: Codable, Equatable, Identifiable, Sendable {
  let provider: PulseProviderIdentity
  let scheme: String
  let host: String
  let port: Int?
  let kind: PulseActionDestinationKind
  let approvedAt: Date

  var id: String {
    "\(provider.credentialID)|\(provider.sourceKey)|\(canonicalOrigin)"
  }
  var displayHost: String {
    let formatted = host.contains(":") ? "[\(host)]" : host
    return port.map { "\(formatted):\($0)" } ?? formatted
  }
  var canonicalOrigin: String { "\(scheme)://\(displayHost)" }

  init(provider: PulseProviderIdentity, destination: PulseActionDestination, approvedAt: Date) {
    self.provider = provider
    scheme = destination.scheme
    host = destination.host
    port = destination.port
    kind = destination.kind
    self.approvedAt = approvedAt
  }
}

enum PulseActionTrustError: LocalizedError, Equatable {
  case corruptStore
  case unsafeStoreFile

  var errorDescription: String? {
    switch self {
    case .corruptStore:
      "The Pulse web destination allowlist is unreadable. No destinations are trusted."
    case .unsafeStoreFile: "The Pulse web destination allowlist has unsafe file permissions."
    }
  }
}

@MainActor
final class PulseActionTrustStore: ObservableObject {
  private struct Registry: Codable {
    let version: Int
    let trusts: [PulseActionTrust]
  }

  static let currentVersion = 1
  static let maximumRecords = 1_024
  static let maximumStoreBytes = 512 * 1_024

  @Published private(set) var trusts: [PulseActionTrust] = []
  @Published private(set) var lastError: String?

  let storeURL: URL
  private let lockURL: URL
  private let now: () -> Date
  private let maximumStoreBytes: Int
  private var hasPreparedDirectory = false

  init(
    supportDirectory: URL = PulsePaths.supportDirectory,
    now: @escaping () -> Date = Date.init,
    maximumStoreBytes: Int = PulseActionTrustStore.maximumStoreBytes
  ) {
    storeURL = supportDirectory.appendingPathComponent("pulse-action-hosts.json")
    lockURL = supportDirectory.appendingPathComponent("pulse-action-hosts.lock")
    self.now = now
    self.maximumStoreBytes = maximumStoreBytes
  }

  func prepare() throws {
    do {
      if !hasPreparedDirectory {
        try secureDirectory(at: storeURL.deletingLastPathComponent())
        hasPreparedDirectory = true
      }
      try withStoreLock {
        try reloadStoreLocked()
      }
      lastError = nil
    } catch {
      trusts = []
      lastError = error.localizedDescription
      throw error
    }
  }

  func isTrusted(_ destination: PulseActionDestination, for provider: PulseProviderIdentity) -> Bool
  {
    guard (try? prepare()) != nil else { return false }
    return trusts.contains {
      $0.provider == provider && $0.canonicalOrigin == destination.canonicalOrigin
    }
  }

  @discardableResult
  func trust(_ destination: PulseActionDestination, for provider: PulseProviderIdentity) throws
    -> PulseActionTrust
  {
    try prepare()
    return try withStoreLock {
      try reloadStoreLocked()
      if let existing = trusts.first(where: {
        $0.provider == provider && $0.canonicalOrigin == destination.canonicalOrigin
      }) {
        return existing
      }
      guard trusts.count < Self.maximumRecords else { throw PulseActionTrustError.corruptStore }
      let previous = trusts
      let record = PulseActionTrust(provider: provider, destination: destination, approvedAt: now())
      trusts.append(record)
      trusts.sort {
        ($0.provider.sourceKey, $0.canonicalOrigin) < ($1.provider.sourceKey, $1.canonicalOrigin)
      }
      do {
        try persist()
      } catch {
        trusts = previous
        throw error
      }
      return record
    }
  }

  func revoke(_ trust: PulseActionTrust) throws {
    try prepare()
    try withStoreLock {
      try reloadStoreLocked()
      let previous = trusts
      trusts.removeAll { $0.id == trust.id }
      guard trusts != previous else { return }
      do {
        try persist()
      } catch {
        trusts = previous
        throw error
      }
    }
  }

  func revokeAll(forCredentialID credentialID: String) throws {
    try prepare()
    try withStoreLock {
      try reloadStoreLocked()
      let previous = trusts
      trusts.removeAll { $0.provider.credentialID == credentialID }
      guard trusts != previous else { return }
      do {
        try persist()
      } catch {
        trusts = previous
        throw error
      }
    }
  }

  private func reloadStoreLocked() throws {
    if FileManager.default.fileExists(atPath: storeURL.path) {
      let registry = try readRegistry()
      guard registry.version == 0 || registry.version == Self.currentVersion else {
        throw PulseActionTrustError.corruptStore
      }
      trusts = try validate(registry.trusts)
      if registry.version == 0 { try persist() }
    } else {
      trusts = []
      try persist()
    }
  }

  private func validate(_ records: [PulseActionTrust]) throws -> [PulseActionTrust] {
    guard records.count <= Self.maximumRecords else { throw PulseActionTrustError.corruptStore }
    var identifiers: Set<String> = []
    for record in records {
      guard
        let provider = try? PulseProviderIdentity(
          credentialID: record.provider.credentialID, source: record.provider.sourceKey),
        provider == record.provider,
        record.scheme == "http" || record.scheme == "https",
        record.port.map({ (1...65_535).contains($0) }) ?? true,
        identifiers.insert(record.id).inserted,
        let url = URL(string: record.canonicalOrigin),
        let destination = try? PulseActionDestination.validate(url),
        destination.host == record.host,
        destination.port == record.port,
        destination.kind == record.kind
      else { throw PulseActionTrustError.corruptStore }
    }
    return records
  }

  private func readRegistry() throws -> Registry {
    let data = try readSecureData()
    do {
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      return try decoder.decode(Registry.self, from: data)
    } catch {
      throw PulseActionTrustError.corruptStore
    }
  }

  private func persist() throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(Registry(version: Self.currentVersion, trusts: trusts))
    guard data.count <= maximumStoreBytes else { throw PulseActionTrustError.corruptStore }
    let temporary = storeURL.deletingLastPathComponent().appendingPathComponent(
      ".\(storeURL.lastPathComponent)-\(UUID().uuidString).tmp")
    guard
      FileManager.default.createFile(
        atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600])
    else { throw CocoaError(.fileWriteUnknown) }
    defer { try? FileManager.default.removeItem(at: temporary) }
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
    let result = temporary.path.withCString { source in
      storeURL.path.withCString { destination in Darwin.rename(source, destination) }
    }
    guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
  }

  private func secureDirectory(at url: URL) throws {
    let createResult = url.path.withCString { Darwin.mkdir($0, 0o700) }
    guard createResult == 0 || errno == EEXIST else {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    let descriptor = url.path.withCString {
      Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    }
    guard descriptor >= 0 else { throw PulseActionTrustError.unsafeStoreFile }
    defer { Darwin.close(descriptor) }
    var info = stat()
    guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
      info.st_uid == getuid(), fchmod(descriptor, 0o700) == 0
    else { throw PulseActionTrustError.unsafeStoreFile }
  }

  private func withStoreLock<T>(_ operation: () throws -> T) throws -> T {
    let descriptor = lockURL.path.withCString {
      Darwin.open($0, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
    }
    guard descriptor >= 0 else { throw PulseActionTrustError.unsafeStoreFile }
    defer { Darwin.close(descriptor) }
    var info = stat()
    guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
      info.st_uid == getuid(), (info.st_mode & 0o077) == 0,
      fchmod(descriptor, 0o600) == 0
    else { throw PulseActionTrustError.unsafeStoreFile }
    var lock = Darwin.flock()
    lock.l_start = 0
    lock.l_len = 0
    lock.l_pid = 0
    lock.l_type = Int16(F_WRLCK)
    lock.l_whence = Int16(SEEK_SET)
    while fcntl(descriptor, F_SETLKW, &lock) != 0 {
      if errno == EINTR { continue }
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    defer {
      lock.l_type = Int16(F_UNLCK)
      _ = fcntl(descriptor, F_SETLK, &lock)
    }
    return try operation()
  }

  private func readSecureData() throws -> Data {
    let descriptor = storeURL.path.withCString {
      Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    }
    guard descriptor >= 0 else { throw PulseActionTrustError.unsafeStoreFile }
    defer { Darwin.close(descriptor) }
    var info = stat()
    guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
      info.st_uid == getuid(), (info.st_mode & 0o077) == 0
    else { throw PulseActionTrustError.unsafeStoreFile }
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
      guard result.count <= maximumStoreBytes - count else {
        throw PulseActionTrustError.unsafeStoreFile
      }
      result.append(contentsOf: buffer.prefix(count))
    }
  }
}

struct PulseActionConfirmation: Equatable, Sendable {
  let itemID: PulseItem.ID
  let actionID: String
  let expectedURL: String
  let provider: PulseProviderIdentity
  let destination: PulseActionDestination
}

enum PulseActionOpenDecision: Equatable, Sendable {
  case opened
  case confirmationRequired(PulseActionConfirmation)
  case rejected(String)
}

@MainActor
final class PulseActionGate {
  private struct ResolvedAction {
    let action: PulseAction
    let provider: PulseProviderIdentity
    let destination: PulseActionDestination
  }

  private enum Resolution {
    case success(ResolvedAction)
    case failure(String)
  }

  static let shared = PulseActionGate(
    center: .shared, trustStore: PulseServer.shared.actionTrustStore,
    providerValidator: { PulseServer.shared.credentialStore.isCurrentProvider($0) },
    opener: { NSWorkspace.shared.open($0) })

  private let center: PulseCenter
  private let trustStore: PulseActionTrustStore
  private let providerValidator: (PulseProviderIdentity) -> Bool
  private let opener: (URL) -> Bool

  init(
    center: PulseCenter, trustStore: PulseActionTrustStore,
    providerValidator: @escaping (PulseProviderIdentity) -> Bool,
    opener: @escaping (URL) -> Bool
  ) {
    self.center = center
    self.trustStore = trustStore
    self.providerValidator = providerValidator
    self.opener = opener
  }

  func requestOpen(itemID: PulseItem.ID, actionID: String) -> PulseActionOpenDecision {
    switch resolve(itemID: itemID, actionID: actionID) {
    case .failure(let message): return .rejected(message)
    case .success(let resolved):
      guard trustStore.isTrusted(resolved.destination, for: resolved.provider) else {
        return .confirmationRequired(
          PulseActionConfirmation(
            itemID: itemID, actionID: actionID, expectedURL: resolved.action.url.absoluteString,
            provider: resolved.provider, destination: resolved.destination))
      }
      return open(resolved.action.url)
    }
  }

  func confirm(_ confirmation: PulseActionConfirmation) -> PulseActionOpenDecision {
    switch resolve(itemID: confirmation.itemID, actionID: confirmation.actionID) {
    case .failure(let message): return .rejected(message)
    case .success(let resolved):
      guard resolved.provider == confirmation.provider,
        resolved.action.url.absoluteString == confirmation.expectedURL,
        resolved.destination == confirmation.destination
      else {
        return .rejected("The provider changed this action. Review its current destination again.")
      }
      do {
        try trustStore.trust(resolved.destination, for: resolved.provider)
      } catch {
        return .rejected(error.localizedDescription)
      }
      return open(resolved.action.url)
    }
  }

  private func resolve(itemID: PulseItem.ID, actionID: String) -> Resolution {
    guard let item = center.item(for: itemID),
      let action = item.actions.first(where: {
        $0.id == actionID
      })
    else { return .failure("This Pulse action is no longer available.") }
    guard providerValidator(item.providerIdentity) else {
      return .failure("This Pulse provider is no longer authorized for web actions.")
    }
    do {
      return .success(
        ResolvedAction(
          action: action, provider: item.providerIdentity,
          destination: try PulseActionDestination.validate(action.url)))
    } catch {
      return .failure("This Pulse action no longer has a safe web destination.")
    }
  }

  private func open(_ url: URL) -> PulseActionOpenDecision {
    opener(url) ? .opened : .rejected("macOS could not open this Pulse destination.")
  }
}
