import CryptoKit
import Foundation
import Security

struct T3ConnectConfiguration: Equatable, Sendable {
  static let production = T3ConnectConfiguration(
    hostedAuthorizationURL: URL(string: "https://app.t3.codes/connect")!,
    tokenEndpoint: URL(string: "https://clerk.t3.codes/oauth/token")!,
    clientID: "hzxSgY2cH10sDU2r",
    redirectURI: URL(string: "http://127.0.0.1:34338/callback")!,
    scopes: ["openid", "profile", "email"],
    relayOrigin: URL(string: "https://relay.t3.codes")!,
    relayClientID: "t3-web")

  let hostedAuthorizationURL: URL
  let tokenEndpoint: URL
  let clientID: String
  let redirectURI: URL
  let scopes: [String]
  let relayOrigin: URL
  let relayClientID: String
}

enum T3PKCETransactionError: Error, Equatable {
  case invalidRandomByteCount
  case invalidConfiguration
  case randomGeneration(OSStatus)
}

struct T3PKCETransaction: Equatable, Sendable {
  let verifier: String
  let state: String
  let challenge: String

  init(randomBytes: (Int) throws -> Data = T3PKCETransaction.secureRandomBytes) throws {
    let verifierBytes = try randomBytes(32)
    let stateBytes = try randomBytes(16)
    guard verifierBytes.count == 32, stateBytes.count == 16 else {
      throw T3PKCETransactionError.invalidRandomByteCount
    }

    verifier = verifierBytes.base64URLString
    state = stateBytes.base64URLString
    challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLString
  }

  func hostedAuthorizationURL(
    configuration: T3ConnectConfiguration = .production
  ) throws -> URL {
    guard let port = configuration.redirectURI.port,
      var components = URLComponents(
        url: configuration.hostedAuthorizationURL, resolvingAgainstBaseURL: false)
    else {
      throw T3PKCETransactionError.invalidConfiguration
    }
    components.percentEncodedFragment = "state=\(state)&challenge=\(challenge)&port=\(port)"
    guard let url = components.url else {
      throw T3PKCETransactionError.invalidConfiguration
    }
    return url
  }

  private static func secureRandomBytes(count: Int) throws -> Data {
    var bytes = [UInt8](repeating: 0, count: count)
    let status = bytes.withUnsafeMutableBytes { buffer in
      SecRandomCopyBytes(kSecRandomDefault, count, buffer.baseAddress!)
    }
    guard status == errSecSuccess else {
      throw T3PKCETransactionError.randomGeneration(status)
    }
    return Data(bytes)
  }
}

enum T3OAuthRecordError: Error, Equatable {
  case invalidToken
  case displayIdentityTooLong
  case invalidExpiry
}

struct T3OAuthRecord: Codable, Equatable, Sendable {
  static let maximumTokenBytes = 16 * 1_024
  static let maximumDisplayIdentityBytes = 512
  static let maximumResponseLifetime: TimeInterval = 31 * 24 * 60 * 60

  let grantID: UUID
  let accessToken: String
  let refreshToken: String
  let expiresAt: Date
  let displayIdentity: String?

  init(
    grantID: UUID, accessToken: String, refreshToken: String, expiresAt: Date,
    displayIdentity: String?
  ) throws {
    guard Self.isUsableToken(accessToken), Self.isUsableToken(refreshToken) else {
      throw T3OAuthRecordError.invalidToken
    }
    guard expiresAt.timeIntervalSince1970.isFinite else {
      throw T3OAuthRecordError.invalidExpiry
    }

    self.grantID = grantID
    self.accessToken = accessToken
    self.refreshToken = refreshToken
    self.expiresAt = expiresAt
    self.displayIdentity = try Self.normalizedDisplayIdentity(displayIdentity)
  }

  static func authorizationGrant(
    accessToken: String, refreshToken: String, expiresAt: Date, displayIdentity: String?,
    grantID: () -> UUID = UUID.init, receivedAt: Date
  ) throws -> Self {
    try validateResponseExpiry(expiresAt, receivedAt: receivedAt)
    return try Self(
      grantID: grantID(), accessToken: accessToken, refreshToken: refreshToken,
      expiresAt: expiresAt, displayIdentity: displayIdentity)
  }

  func refreshed(
    accessToken: String, refreshToken: String? = nil, expiresAt: Date,
    displayIdentity: String? = nil, receivedAt: Date
  ) throws -> Self {
    try Self.validateResponseExpiry(expiresAt, receivedAt: receivedAt)
    return try Self(
      grantID: grantID, accessToken: accessToken, refreshToken: refreshToken ?? self.refreshToken,
      expiresAt: expiresAt, displayIdentity: displayIdentity ?? self.displayIdentity)
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      grantID: container.decode(UUID.self, forKey: .grantID),
      accessToken: container.decode(String.self, forKey: .accessToken),
      refreshToken: container.decode(String.self, forKey: .refreshToken),
      expiresAt: container.decode(Date.self, forKey: .expiresAt),
      displayIdentity: container.decodeIfPresent(String.self, forKey: .displayIdentity))
  }

  private static func validateResponseExpiry(_ expiresAt: Date, receivedAt: Date) throws {
    let lifetime = expiresAt.timeIntervalSince(receivedAt)
    guard receivedAt.timeIntervalSince1970.isFinite, lifetime.isFinite, lifetime > 0,
      lifetime <= maximumResponseLifetime
    else {
      throw T3OAuthRecordError.invalidExpiry
    }
  }

  fileprivate static func normalizedDisplayIdentity(_ identity: String?) throws -> String? {
    guard let identity else { return nil }
    let normalized = identity.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { return nil }
    guard normalized.utf8.count <= maximumDisplayIdentityBytes else {
      throw T3OAuthRecordError.displayIdentityTooLong
    }
    return normalized
  }

  private static func isUsableToken(_ token: String) -> Bool {
    !token.isEmpty && token.utf8.count <= maximumTokenBytes
  }
}

struct T3ConnectAccount: Equatable, Sendable {
  let grantID: UUID
  let displayIdentity: String?

  init(record: T3OAuthRecord) {
    grantID = record.grantID
    displayIdentity = record.displayIdentity
  }

  static func displayIdentity(fromIDToken token: String) -> String? {
    guard token.utf8.count <= T3OAuthRecord.maximumTokenBytes else { return nil }
    let parts = token.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3, let payload = Data(base64URLString: String(parts[1])),
      let claims = try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
    else {
      return nil
    }

    for claim in ["email", "name", "preferred_username"] {
      guard let value = claims[claim] as? String else { continue }
      if let normalized = try? T3OAuthRecord.normalizedDisplayIdentity(value) {
        return normalized
      }
    }
    return nil
  }
}

extension Data {
  fileprivate init?(base64URLString: String) {
    var encoded = base64URLString.replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    let remainder = encoded.count % 4
    if remainder == 1 { return nil }
    if remainder > 0 {
      encoded.append(String(repeating: "=", count: 4 - remainder))
    }
    self.init(base64Encoded: encoded)
  }

  fileprivate var base64URLString: String {
    base64EncodedString().replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
  }
}
