import CryptoKit
import Foundation
import Network

enum T3URLAuthorityCanonicalizer {
  static func canonicalize(_ components: inout URLComponents) -> Bool {
    guard let scheme = components.scheme?.lowercased() else { return true }
    components.scheme = scheme
    if let host = components.host {
      guard let canonicalHost = canonicalHost(host) else { return false }
      components.host = canonicalHost
    }

    let defaultPort: Int?
    switch scheme {
    case "http", "ws": defaultPort = 80
    case "https", "wss": defaultPort = 443
    default: defaultPort = nil
    }
    if components.port == defaultPort { components.port = nil }
    return true
  }

  private static func canonicalHost(_ host: String) -> String? {
    if host.hasPrefix("["), host.hasSuffix("]") {
      let literal = String(host.dropFirst().dropLast())
      guard !literal.contains("%"), hasValidEmbeddedIPv4Suffix(literal),
        let address = IPv6Address(literal)
      else {
        return nil
      }
      return "[\(serializeIPv6(address.rawValue))]"
    }

    let candidate = host.hasSuffix(".") ? String(host.dropLast()) : host
    guard
      let lastPart = candidate.split(
        separator: ".", omittingEmptySubsequences: false
      ).last
    else {
      return host.lowercased()
    }
    if isIPv4Number(lastPart) {
      return serializeIPv4(candidate)
    }
    return host.lowercased()
  }

  private static func hasValidEmbeddedIPv4Suffix(_ literal: String) -> Bool {
    guard literal.contains(".") else { return true }
    guard let colon = literal.lastIndex(of: ":") else { return false }
    let suffix = literal[literal.index(after: colon)...]
    let octets = suffix.split(separator: ".", omittingEmptySubsequences: false)
    guard octets.count == 4 else { return false }
    return octets.allSatisfy { octet in
      let bytes = octet.utf8
      guard !bytes.isEmpty, bytes.allSatisfy({ (0x30...0x39).contains($0) }),
        bytes.count == 1 || bytes.first != 0x30,
        let value = UInt16(octet), value <= 255
      else {
        return false
      }
      return true
    }
  }

  private static func isIPv4Number(_ value: Substring) -> Bool {
    guard !value.isEmpty else { return false }
    if value.allSatisfy({ $0.isASCII && $0.isNumber }) { return true }
    let lowercase = value.lowercased()
    guard lowercase.hasPrefix("0x") else { return false }
    return lowercase.dropFirst(2).allSatisfy { $0.isASCII && $0.isHexDigit }
  }

  private static func serializeIPv4(_ value: String) -> String? {
    let parts = value.split(separator: ".", omittingEmptySubsequences: false)
    guard (1...4).contains(parts.count) else { return nil }
    let numbers = parts.compactMap(parseIPv4Number)
    guard numbers.count == parts.count,
      numbers.dropLast().allSatisfy({ $0 <= 255 })
    else {
      return nil
    }

    let lastLimit = UInt64(1) << UInt64(8 * (5 - parts.count))
    guard let last = numbers.last, last < lastLimit else { return nil }
    var address = last
    for (index, number) in numbers.dropLast().enumerated() {
      address += number << UInt64(8 * (3 - index))
    }
    return (0..<4).map { index in
      String((address >> UInt64(8 * (3 - index))) & 0xFF)
    }.joined(separator: ".")
  }

  private static func parseIPv4Number(_ value: Substring) -> UInt64? {
    guard !value.isEmpty else { return nil }
    let lowercase = value.lowercased()
    let radix: Int
    let digits: Substring
    if lowercase.hasPrefix("0x") {
      radix = 16
      digits = value.dropFirst(2)
    } else if value.count >= 2, value.first == "0" {
      radix = 8
      digits = value.dropFirst()
    } else {
      radix = 10
      digits = value
    }
    if digits.isEmpty { return 0 }
    return UInt64(digits, radix: radix)
  }

  private static func serializeIPv6(_ data: Data) -> String {
    let bytes = Array(data)
    let pieces = stride(from: 0, to: bytes.count, by: 2).map { index in
      UInt16(bytes[index]) << 8 | UInt16(bytes[index + 1])
    }

    var bestStart: Int?
    var bestLength = 1
    var currentStart: Int?
    for index in 0...pieces.count {
      if index < pieces.count, pieces[index] == 0 {
        if currentStart == nil { currentStart = index }
      } else if let start = currentStart {
        let length = index - start
        if length > bestLength {
          bestStart = start
          bestLength = length
        }
        currentStart = nil
      }
    }

    let values = pieces.map { String($0, radix: 16) }
    guard let bestStart else { return values.joined(separator: ":") }
    let before = values[..<bestStart].joined(separator: ":")
    let after = values[(bestStart + bestLength)...].joined(separator: ":")
    if before.isEmpty { return after.isEmpty ? "::" : "::\(after)" }
    return after.isEmpty ? "\(before)::" : "\(before)::\(after)"
  }
}

struct T3DPoPPublicJWK: Codable, Equatable, Sendable {
  let kty: String
  let crv: String
  let x: String
  let y: String

  func thumbprint() throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let canonical = try encoder.encode(
      ThumbprintInput(crv: crv, kty: kty, x: x, y: y))
    return Data(SHA256.hash(data: canonical)).base64URLString
  }

  private struct ThumbprintInput: Encodable {
    let crv: String
    let kty: String
    let x: String
    let y: String
  }
}

enum T3DPoPSignerError: Error, Equatable {
  case invalidStoredKey
  case invalidPublicKey
  case invalidURL
  case invalidTimestamp
  case inactive
  case reset
}

actor T3DPoPSigner: T3DPoPProofProviding {
  private let store: T3ConnectCredentialStore
  private let now: @Sendable () -> Date
  private let makeJTI: @Sendable () -> String
  private let onKeyLoadWaiterQueued: @Sendable () -> Void
  private var cachedKey: P256.Signing.PrivateKey?
  private var generation: UInt64 = 0
  private var isActive = true
  private var loadingGenerations: Set<UInt64> = []
  private var keyLoadWaiters: [UInt64: [KeyLoadContinuation]] = [:]

  init(
    store: T3ConnectCredentialStore,
    now: @escaping @Sendable () -> Date = Date.init,
    makeJTI: @escaping @Sendable () -> String = { UUID().uuidString },
    onKeyLoadWaiterQueued: @escaping @Sendable () -> Void = {}
  ) {
    self.store = store
    self.now = now
    self.makeJTI = makeJTI
    self.onKeyLoadWaiterQueued = onKeyLoadWaiterQueued
  }

  func keyThumbprint() async throws -> String {
    try await keyThumbprint(expectedGeneration: generation)
  }

  func proofLease() async throws -> any T3DPoPProofProviding {
    try Task.checkCancellation()
    guard isActive else { throw T3DPoPSignerError.inactive }
    return T3DPoPSignerLease(signer: self, generation: generation)
  }

  func activate() async {
    generation &+= 1
    isActive = true
    cachedKey = nil
  }

  func deactivate() async {
    generation &+= 1
    isActive = false
    cachedKey = nil
  }

  func reset() async {
    generation &+= 1
    cachedKey = nil
  }

  fileprivate func keyThumbprint(expectedGeneration: UInt64) async throws -> String {
    let key = try await privateKey(expectedGeneration: expectedGeneration)
    return try publicJWK(for: key).thumbprint()
  }

  func proof(method: String, url: URL, accessToken: String?) async throws -> String {
    try await proof(
      method: method, url: url, accessToken: accessToken, expectedGeneration: generation)
  }

  fileprivate func proof(
    method: String,
    url: URL,
    accessToken: String?,
    expectedGeneration: UInt64
  ) async throws -> String {
    let key = try await privateKey(expectedGeneration: expectedGeneration)
    let header = Header(jwk: try publicJWK(for: key))
    let payload = try Payload(
      htm: method.uppercased(),
      htu: normalizedHTU(url),
      iat: issuedAt(),
      jti: makeJTI(),
      ath: accessToken.map { token in
        Data(SHA256.hash(data: Data(token.utf8))).base64URLString
      })
    let encoder = JSONEncoder()
    encoder.outputFormatting = .withoutEscapingSlashes
    let encodedHeader = try encoder.encode(header).base64URLString
    let encodedPayload = try encoder.encode(payload).base64URLString
    let signingInput = "\(encodedHeader).\(encodedPayload)"
    let signature = try key.signature(for: Data(signingInput.utf8))
    return "\(signingInput).\(signature.rawRepresentation.base64URLString)"
  }

  private func privateKey(expectedGeneration: UInt64) async throws -> P256.Signing.PrivateKey {
    try Task.checkCancellation()
    guard isActive else { throw T3DPoPSignerError.inactive }
    guard expectedGeneration == generation else { throw T3DPoPSignerError.reset }
    if let cachedKey { return cachedKey }

    let capturedGeneration = expectedGeneration
    if loadingGenerations.contains(capturedGeneration) {
      let key = try await withCheckedThrowingContinuation { continuation in
        keyLoadWaiters[capturedGeneration, default: []].append(continuation)
        onKeyLoadWaiterQueued()
      }
      try Task.checkCancellation()
      guard isActive else { throw T3DPoPSignerError.inactive }
      guard capturedGeneration == generation else { throw T3DPoPSignerError.reset }
      return key
    }

    loadingGenerations.insert(capturedGeneration)
    do {
      let key = try await loadPrivateKey(generation: capturedGeneration)
      try Task.checkCancellation()
      guard isActive else { throw T3DPoPSignerError.inactive }
      guard capturedGeneration == generation else { throw T3DPoPSignerError.reset }
      cachedKey = key
      finishKeyLoad(generation: capturedGeneration, result: .success(key))
      return key
    } catch {
      finishKeyLoad(generation: capturedGeneration, result: .failure(error))
      throw error
    }
  }

  private func loadPrivateKey(generation capturedGeneration: UInt64) async throws
    -> P256.Signing.PrivateKey
  {
    let storedKey = try await store.loadProofKey()
    try Task.checkCancellation()
    guard isActive else { throw T3DPoPSignerError.inactive }
    guard capturedGeneration == generation else { throw T3DPoPSignerError.reset }

    let key: P256.Signing.PrivateKey
    if let storedKey {
      guard storedKey.count == 32,
        let restored = try? P256.Signing.PrivateKey(rawRepresentation: storedKey)
      else {
        throw T3DPoPSignerError.invalidStoredKey
      }
      key = restored
    } else {
      key = P256.Signing.PrivateKey()
      try await store.replaceProofKey(key.rawRepresentation)
      try Task.checkCancellation()
      guard isActive else { throw T3DPoPSignerError.inactive }
      guard capturedGeneration == generation else { throw T3DPoPSignerError.reset }
    }

    guard isActive else { throw T3DPoPSignerError.inactive }
    guard capturedGeneration == generation else { throw T3DPoPSignerError.reset }
    return key
  }

  private func finishKeyLoad(
    generation completedGeneration: UInt64,
    result: Result<P256.Signing.PrivateKey, any Error>
  ) {
    loadingGenerations.remove(completedGeneration)
    let waiters = keyLoadWaiters.removeValue(forKey: completedGeneration) ?? []
    for waiter in waiters {
      waiter.resume(with: result)
    }
  }

  private func publicJWK(for key: P256.Signing.PrivateKey) throws -> T3DPoPPublicJWK {
    let representation = key.publicKey.x963Representation
    guard representation.count == 65, representation.first == 4 else {
      throw T3DPoPSignerError.invalidPublicKey
    }
    return T3DPoPPublicJWK(
      kty: "EC",
      crv: "P-256",
      x: Data(representation[1..<33]).base64URLString,
      y: Data(representation[33..<65]).base64URLString)
  }

  private func normalizedHTU(_ url: URL) throws -> String {
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      throw T3DPoPSignerError.invalidURL
    }
    components.query = nil
    components.fragment = nil
    guard T3URLAuthorityCanonicalizer.canonicalize(&components) else {
      throw T3DPoPSignerError.invalidURL
    }
    guard let normalized = components.url?.absoluteString else {
      throw T3DPoPSignerError.invalidURL
    }
    return normalized
  }

  private func issuedAt() throws -> Int {
    let seconds = now().timeIntervalSince1970.rounded(.down)
    guard let issuedAt = Int(exactly: seconds) else {
      throw T3DPoPSignerError.invalidTimestamp
    }
    return issuedAt
  }

  private struct Header: Encodable {
    let typ = "dpop+jwt"
    let alg = "ES256"
    let jwk: T3DPoPPublicJWK
  }

  private struct Payload: Encodable {
    let htm: String
    let htu: String
    let iat: Int
    let jti: String
    let ath: String?
  }

  private typealias KeyLoadContinuation = CheckedContinuation<
    P256.Signing.PrivateKey, any Error
  >
}

private struct T3DPoPSignerLease: T3DPoPProofProviding {
  let signer: T3DPoPSigner
  let generation: UInt64

  func proof(method: String, url: URL, accessToken: String?) async throws -> String {
    try await signer.proof(
      method: method, url: url, accessToken: accessToken, expectedGeneration: generation)
  }

  func keyThumbprint() async throws -> String {
    try await signer.keyThumbprint(expectedGeneration: generation)
  }
}

extension Data {
  fileprivate var base64URLString: String {
    base64EncodedString().replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
  }
}
