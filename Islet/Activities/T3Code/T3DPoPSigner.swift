import CryptoKit
import Foundation

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
  case reset
}

actor T3DPoPSigner: T3DPoPProofProviding {
  private let store: T3ConnectCredentialStore
  private let now: @Sendable () -> Date
  private let makeJTI: @Sendable () -> String
  private var cachedKey: P256.Signing.PrivateKey?
  private var generation: UInt64 = 0
  private var loadingGenerations: Set<UInt64> = []
  private var keyLoadWaiters: [UInt64: [KeyLoadContinuation]] = [:]

  init(
    store: T3ConnectCredentialStore,
    now: @escaping @Sendable () -> Date = Date.init,
    makeJTI: @escaping @Sendable () -> String = { UUID().uuidString }
  ) {
    self.store = store
    self.now = now
    self.makeJTI = makeJTI
  }

  func keyThumbprint() async throws -> String {
    let key = try await privateKey()
    return try publicJWK(for: key).thumbprint()
  }

  func proof(method: String, url: URL, accessToken: String?) async throws -> String {
    let key = try await privateKey()
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

  func reset() async {
    generation &+= 1
    cachedKey = nil
  }

  private func privateKey() async throws -> P256.Signing.PrivateKey {
    if let cachedKey { return cachedKey }

    let capturedGeneration = generation
    if loadingGenerations.contains(capturedGeneration) {
      let key = try await withCheckedThrowingContinuation { continuation in
        keyLoadWaiters[capturedGeneration, default: []].append(continuation)
      }
      guard capturedGeneration == generation else { throw T3DPoPSignerError.reset }
      return key
    }

    loadingGenerations.insert(capturedGeneration)
    do {
      let key = try await loadPrivateKey(generation: capturedGeneration)
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
      guard capturedGeneration == generation else { throw T3DPoPSignerError.reset }
    }

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
    guard let normalized = components.url?.absoluteString else {
      throw T3DPoPSignerError.invalidURL
    }
    return normalized
  }

  private func issuedAt() throws -> Int {
    let seconds = now().timeIntervalSince1970.rounded(.down)
    guard seconds.isFinite, seconds >= Double(Int.min), seconds <= Double(Int.max) else {
      throw T3DPoPSignerError.invalidTimestamp
    }
    return Int(seconds)
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

extension Data {
  fileprivate var base64URLString: String {
    base64EncodedString().replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
  }
}
