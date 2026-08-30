import CryptoKit
import Foundation
import XCTest

@testable import Islet

final class T3DPoPSignerTests: XCTestCase {
  private let fixedPrivateKey = Data((1...32).map(UInt8.init))

  func testRfc9449JwkHasExpectedRfc7638Thumbprint() throws {
    let jwk = T3DPoPPublicJWK(
      kty: "EC",
      crv: "P-256",
      x: "I8tFrhx-34tV3hRICRDY9zCkD1pBhF42UUQfWVAWBFs",
      y: "9VE4jf_Ok_o64zbTTlcuNJajHmt6v9TDVrU0CdvGRDA")

    XCTAssertEqual(
      try jwk.thumbprint(),
      "NVX_OqGUmb4l_q2B-t6dBpBlzduT5Z1FNR2xn-Cq-A8")
  }

  func testProofUsesPublicOnlyHeaderAndRawES256Signature() async throws {
    let secureStore = T3DPoPSignerSecureStore(proofKey: fixedPrivateKey)
    let signer = makeSigner(store: secureStore)

    let proof = try await signer.proof(
      method: "POST", url: URL(string: "https://server.example/token")!, accessToken: nil)
    let decoded = try decodeProof(proof)

    XCTAssertEqual(decoded.header["typ"] as? String, "dpop+jwt")
    XCTAssertEqual(decoded.header["alg"] as? String, "ES256")
    let jwk = try XCTUnwrap(decoded.header["jwk"] as? [String: Any])
    XCTAssertEqual(Set(jwk.keys), Set(["kty", "crv", "x", "y"]))
    XCTAssertEqual(jwk["kty"] as? String, "EC")
    XCTAssertEqual(jwk["crv"] as? String, "P-256")
    XCTAssertEqual(jwk["x"] as? String, "UVw9brnjlrkE0_7Kf1T9zQzB6Ze_N13KUVrQpsO0A18")
    XCTAssertEqual(jwk["y"] as? String, "RTa-OlDzGPv5pUdZAqIhUCvvDVfgjFOyzApW8X2fk1Q")

    let signatureData = try decodeBase64URL(decoded.parts[2])
    XCTAssertEqual(signatureData.count, 64)
    let signature = try P256.Signing.ECDSASignature(rawRepresentation: signatureData)
    let publicKey = try P256.Signing.PrivateKey(rawRepresentation: fixedPrivateKey).publicKey
    XCTAssertTrue(
      publicKey.isValidSignature(
        signature, for: Data("\(decoded.parts[0]).\(decoded.parts[1])".utf8)))
  }

  func testProofNormalizesPayloadClaimsAndOmitsUnboundTokenHash() async throws {
    let secureStore = T3DPoPSignerSecureStore(proofKey: fixedPrivateKey)
    let signer = T3DPoPSigner(
      store: T3ConnectCredentialStore(store: secureStore),
      now: { Date(timeIntervalSince1970: 1_800_000_000.875) },
      makeJTI: { "fixed-jti" })

    let proof = try await signer.proof(
      method: "post",
      url: URL(string: "https://server.example:8443/resource/path?secret=yes#section")!,
      accessToken: nil)
    let payload = try decodeProof(proof).payload

    XCTAssertEqual(payload["htm"] as? String, "POST")
    XCTAssertEqual(payload["htu"] as? String, "https://server.example:8443/resource/path")
    XCTAssertEqual(payload["iat"] as? Int, 1_800_000_000)
    XCTAssertEqual(payload["jti"] as? String, "fixed-jti")
    XCTAssertNil(payload["ath"])
  }

  func testProofHashesBoundAccessToken() async throws {
    let secureStore = T3DPoPSignerSecureStore(proofKey: fixedPrivateKey)
    let signer = makeSigner(store: secureStore)

    let proof = try await signer.proof(
      method: "GET", url: URL(string: "https://server.example/resource")!,
      accessToken: "access-token")
    let payload = try decodeProof(proof).payload

    XCTAssertEqual(payload["ath"] as? String, "Pxa-1wifRlPl7yG_0oJNfzqq7MelmOfonFgOFgapzFI")
  }

  func testEveryProofUsesNewJTI() async throws {
    let secureStore = T3DPoPSignerSecureStore(proofKey: fixedPrivateKey)
    let sequence = T3TestJTISequence()
    let signer = T3DPoPSigner(
      store: T3ConnectCredentialStore(store: secureStore),
      now: { Date(timeIntervalSince1970: 1_800_000_000) },
      makeJTI: { sequence.next() })
    let url = URL(string: "https://server.example/resource")!

    let first = try await decodeProof(signer.proof(method: "GET", url: url, accessToken: nil))
    let second = try await decodeProof(signer.proof(method: "GET", url: url, accessToken: nil))

    XCTAssertEqual(first.payload["jti"] as? String, "jti-1")
    XCTAssertEqual(second.payload["jti"] as? String, "jti-2")
  }

  func testInvalidStoredPrivateKeyFailsWithoutReplacement() async throws {
    let invalidKeys = [Data(repeating: 1, count: 31), Data(repeating: 0, count: 32)]

    for invalidKey in invalidKeys {
      let secureStore = T3DPoPSignerSecureStore(proofKey: invalidKey)
      let signer = makeSigner(store: secureStore)

      do {
        _ = try await signer.keyThumbprint()
        XCTFail("Expected invalid stored key material to fail")
      } catch {
      }

      let replacements = await secureStore.replacementPayloads()
      XCTAssertEqual(replacements, [])
    }
  }

  func testNewKeyPersistsOnlyRawPrivateRepresentation() async throws {
    let secureStore = T3DPoPSignerSecureStore()
    let signer = makeSigner(store: secureStore)

    let thumbprint = try await signer.keyThumbprint()
    let replacements = await secureStore.replacementPayloads()
    let persisted = try XCTUnwrap(replacements.only)

    XCTAssertEqual(persisted.count, 32)
    XCTAssertNoThrow(try P256.Signing.PrivateKey(rawRepresentation: persisted))
    XCTAssertEqual(thumbprint, try independentThumbprint(privateRaw: persisted))
  }

  func testConcurrentFirstUsePersistsOneSharedKey() async throws {
    let secureStore = T3DPoPSignerSecureStore(suspendFirstProofKeyRead: true)
    let signer = makeSigner(store: secureStore)
    let firstLoad = Task { try await signer.keyThumbprint() }
    await secureStore.waitForFirstProofKeyRead()

    let secondLoad = Task { try await signer.keyThumbprint() }
    for _ in 0..<10 { await Task.yield() }
    await secureStore.resumeFirstProofKeyRead()

    let firstThumbprint = try await firstLoad.value
    let secondThumbprint = try await secondLoad.value
    let replacements = await secureStore.replacementPayloads()
    XCTAssertEqual(firstThumbprint, secondThumbprint)
    XCTAssertEqual(replacements.count, 1)
  }

  func testResetBlocksStaleLoadFromReplacingCurrentGeneration() async throws {
    let firstKey = fixedPrivateKey
    let secondKey = Data((33...64).map(UInt8.init))
    let secureStore = T3DPoPSignerSecureStore(
      proofKey: firstKey, suspendFirstProofKeyRead: true)
    let signer = makeSigner(store: secureStore)
    let staleLoad = Task { try await signer.keyThumbprint() }
    await secureStore.waitForFirstProofKeyRead()

    await signer.reset()
    await secureStore.setProofKey(secondKey)
    let currentThumbprint = try await signer.keyThumbprint()
    XCTAssertEqual(currentThumbprint, try independentThumbprint(privateRaw: secondKey))

    await secureStore.resumeFirstProofKeyRead()
    _ = try? await staleLoad.value

    let thumbprintAfterStaleLoad = try await signer.keyThumbprint()
    XCTAssertEqual(thumbprintAfterStaleLoad, currentThumbprint)
  }

  private func makeSigner(store: T3DPoPSignerSecureStore) -> T3DPoPSigner {
    T3DPoPSigner(
      store: T3ConnectCredentialStore(store: store),
      now: { Date(timeIntervalSince1970: 1_800_000_000) },
      makeJTI: { "fixed-jti" })
  }

  private func decodeProof(_ proof: String) throws -> T3DecodedDPoPProof {
    let parts = proof.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    XCTAssertEqual(parts.count, 3)
    guard parts.count == 3 else { throw T3DPoPSignerTestError.invalidProof }
    let header = try XCTUnwrap(
      JSONSerialization.jsonObject(with: decodeBase64URL(parts[0])) as? [String: Any])
    let payload = try XCTUnwrap(
      JSONSerialization.jsonObject(with: decodeBase64URL(parts[1])) as? [String: Any])
    return T3DecodedDPoPProof(parts: parts, header: header, payload: payload)
  }

  private func independentThumbprint(privateRaw: Data) throws -> String {
    let publicRaw = try P256.Signing.PrivateKey(rawRepresentation: privateRaw)
      .publicKey.x963Representation
    guard publicRaw.count == 65, publicRaw.first == 4 else {
      throw T3DPoPSignerTestError.invalidPublicKey
    }
    let x = Data(publicRaw[1..<33]).base64URLString
    let y = Data(publicRaw[33..<65]).base64URLString
    let canonical = #"{"crv":"P-256","kty":"EC","x":"\#(x)","y":"\#(y)"}"#
    return Data(SHA256.hash(data: Data(canonical.utf8))).base64URLString
  }

  private func decodeBase64URL(_ value: String) throws -> Data {
    var encoded = value.replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    let remainder = encoded.count % 4
    guard remainder != 1 else { throw T3DPoPSignerTestError.invalidBase64URL }
    if remainder > 0 { encoded.append(String(repeating: "=", count: 4 - remainder)) }
    guard let data = Data(base64Encoded: encoded) else {
      throw T3DPoPSignerTestError.invalidBase64URL
    }
    return data
  }
}

private struct T3DecodedDPoPProof {
  let parts: [String]
  let header: [String: Any]
  let payload: [String: Any]
}

private enum T3DPoPSignerTestError: Error {
  case invalidBase64URL
  case invalidProof
  case invalidPublicKey
}

private actor T3DPoPSignerSecureStore: T3SecureRecordStore {
  private var records: [String: Data]
  private let suspendFirstProofKeyRead: Bool
  private var proofKeyReadCount = 0
  private var firstProofKeyReadStarted = false
  private var firstProofKeyReadWaiter: CheckedContinuation<Void, Never>?
  private var firstProofKeyReadContinuation: CheckedContinuation<Data?, Never>?
  private var firstProofKeyReadValue: Data?
  private var replacements: [Data] = []

  init(proofKey: Data? = nil, suspendFirstProofKeyRead: Bool = false) {
    records = proofKey.map { [T3ConnectCredentialStore.dpopKeyAccount: $0] } ?? [:]
    self.suspendFirstProofKeyRead = suspendFirstProofKeyRead
  }

  func data(service: String, account: String) async throws -> Data? {
    if account == T3ConnectCredentialStore.dpopKeyAccount {
      proofKeyReadCount += 1
      if suspendFirstProofKeyRead, proofKeyReadCount == 1 {
        firstProofKeyReadValue = records[account]
        firstProofKeyReadStarted = true
        firstProofKeyReadWaiter?.resume()
        firstProofKeyReadWaiter = nil
        return await withCheckedContinuation { continuation in
          firstProofKeyReadContinuation = continuation
        }
      }
    }
    return records[account]
  }

  func replace(_ data: Data, service: String, account: String, label: String) async throws {
    records[account] = data
    if account == T3ConnectCredentialStore.dpopKeyAccount { replacements.append(data) }
  }

  func delete(service: String, account: String) async throws {
    records.removeValue(forKey: account)
  }

  func waitForFirstProofKeyRead() async {
    if firstProofKeyReadStarted { return }
    await withCheckedContinuation { continuation in
      firstProofKeyReadWaiter = continuation
    }
  }

  func resumeFirstProofKeyRead() {
    firstProofKeyReadContinuation?.resume(returning: firstProofKeyReadValue)
    firstProofKeyReadContinuation = nil
    firstProofKeyReadValue = nil
  }

  func setProofKey(_ data: Data) {
    records[T3ConnectCredentialStore.dpopKeyAccount] = data
  }

  func replacementPayloads() -> [Data] {
    replacements
  }
}

private final class T3TestJTISequence: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0

  func next() -> String {
    lock.lock()
    defer { lock.unlock() }
    value += 1
    return "jti-\(value)"
  }
}

extension Array {
  fileprivate var only: Element? {
    count == 1 ? self[0] : nil
  }
}

extension Data {
  fileprivate var base64URLString: String {
    base64EncodedString().replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
  }
}
