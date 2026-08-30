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

  func testProofCanonicalizesSchemeHostAndDefaultPortsLikeWHATWGURL() async throws {
    let secureStore = T3DPoPSignerSecureStore(proofKey: fixedPrivateKey)
    let signer = makeSigner(store: secureStore)
    let cases = [
      (
        input: "HTTPS://SERVER.EXAMPLE:443/resource?secret=yes#section",
        expected: "https://server.example/resource"
      ),
      (input: "HTTP://SERVER.EXAMPLE:80/resource", expected: "http://server.example/resource"),
      (
        input: "https://SERVER.EXAMPLE:8443/resource",
        expected: "https://server.example:8443/resource"
      ),
      (
        input: "http://SERVER.EXAMPLE:8080/resource",
        expected: "http://server.example:8080/resource"
      ),
      (
        input: "https://[2001:0db8:0:0:0:0:0:1]:443/resource",
        expected: "https://[2001:db8::1]/resource"
      ),
      (
        input: "https://[::ffff:192.0.2.128]:443/resource",
        expected: "https://[::ffff:c000:280]/resource"
      ),
      (
        input: "https://127.000.000.001:443/resource",
        expected: "https://127.0.0.1/resource"
      ),
      (input: "https://0x7f000001/resource", expected: "https://127.0.0.1/resource"),
      (
        input: "https://BÜCHER.EXAMPLE:443/resource",
        expected: "https://xn--bcher-kva.example/resource"
      ),
      (input: "https://%65XAMPLE.COM:443/resource", expected: "https://example.com/resource"),
      (input: "https://EXAMPLE.COM.:443/resource", expected: "https://example.com./resource"),
      (input: "https://EXAMPLE..:443/resource", expected: "https://example../resource"),
    ]

    for item in cases {
      let proof = try await signer.proof(
        method: "GET", url: try XCTUnwrap(URL(string: item.input)), accessToken: nil)
      let payload = try decodeProof(proof).payload

      XCTAssertEqual(payload["htu"] as? String, item.expected, item.input)
    }
  }

  func testProofRejectsHostsThatWHATWGURLRejects() async throws {
    let secureStore = T3DPoPSignerSecureStore(proofKey: fixedPrivateKey)
    let signer = makeSigner(store: secureStore)

    for value in [
      "https://example.123/resource", "https://1.2.3.256/resource",
      "https://1..2/resource", "https://.1/resource",
      "https://[fe80::1%25en0]/resource",
      "https://[::ffff:192.168.001.001]/resource",
    ] {
      do {
        _ = try await signer.proof(
          method: "GET", url: try XCTUnwrap(URL(string: value)), accessToken: nil)
        XCTFail("Expected \(value) to be rejected")
      } catch let error as T3DPoPSignerError {
        XCTAssertEqual(error, .invalidURL)
      }
    }
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

  func testIssuedAtAcceptsLargestExactlyRepresentableIntTimestamp() async throws {
    let secureStore = T3DPoPSignerSecureStore(proofKey: fixedPrivateKey)
    let signer = T3DPoPSigner(
      store: T3ConnectCredentialStore(store: secureStore),
      now: { Date(timeIntervalSince1970: Double(Int.max).nextDown) },
      makeJTI: { "fixed-jti" })

    let proof = try await signer.proof(
      method: "GET", url: URL(string: "https://server.example/resource")!, accessToken: nil)
    let payload = try decodeProof(proof).payload

    XCTAssertEqual(payload["iat"] as? Int, 9_223_372_036_854_774_784)
  }

  func testIssuedAtRejectsNonrepresentableIntTimestamp() async throws {
    let secureStore = T3DPoPSignerSecureStore(proofKey: fixedPrivateKey)
    let signer = T3DPoPSigner(
      store: T3ConnectCredentialStore(store: secureStore),
      now: { Date(timeIntervalSince1970: Double(Int.max)) },
      makeJTI: { "fixed-jti" })

    do {
      _ = try await signer.proof(
        method: "GET", url: URL(string: "https://server.example/resource")!, accessToken: nil)
      XCTFail("Expected the nonrepresentable timestamp to fail")
    } catch let error as T3DPoPSignerError {
      XCTAssertEqual(error, .invalidTimestamp)
    }
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
    let secondWaiterQueued = T3TestSignal()
    let signer = makeSigner(
      store: secureStore,
      onKeyLoadWaiterQueued: { secondWaiterQueued.signal() })
    let firstLoad = Task { try await signer.keyThumbprint() }
    await secureStore.waitForFirstProofKeyRead()

    let secondLoad = Task { try await signer.keyThumbprint() }
    await secondWaiterQueued.wait()
    await secureStore.resumeFirstProofKeyRead()

    let firstThumbprint = try await firstLoad.value
    let secondThumbprint = try await secondLoad.value
    let replacements = await secureStore.replacementPayloads()
    XCTAssertEqual(firstThumbprint, secondThumbprint)
    XCTAssertEqual(replacements.count, 1)
  }

  func testResetRejectsSuspendedStaleSignerLoad() async throws {
    let secureStore = T3DPoPSignerSecureStore(
      proofKey: fixedPrivateKey, suspendFirstProofKeyRead: true)
    let signer = makeSigner(store: secureStore)
    let staleLoad = Task { try await signer.keyThumbprint() }
    await secureStore.waitForFirstProofKeyRead()

    await signer.reset()
    await secureStore.resumeFirstProofKeyRead()
    do {
      _ = try await staleLoad.value
      XCTFail("Expected reset to reject the stale signer load")
    } catch let error as T3DPoPSignerError {
      XCTAssertEqual(error, .reset)
    }
  }

  func testDeactivationRevokesLeasesAndBlocksNewLeasesUntilActivation() async throws {
    let secureStore = T3DPoPSignerSecureStore()
    let signer = makeSigner(store: secureStore)
    let staleLease = try await signer.proofLease()

    await signer.deactivate()

    do {
      _ = try await staleLease.proof(
        method: "GET", url: URL(string: "https://example.com/agents")!, accessToken: "token")
      XCTFail("Expected the retained lease to be revoked")
    } catch T3DPoPSignerError.inactive {
    }
    do {
      _ = try await signer.proofLease()
      XCTFail("Expected proof leasing to remain disabled")
    } catch T3DPoPSignerError.inactive {
    }
    let replacementsWhileInactive = await secureStore.replacementPayloads()
    XCTAssertTrue(replacementsWhileInactive.isEmpty)

    await signer.activate()
    let currentLease = try await signer.proofLease()
    _ = try await currentLease.proof(
      method: "GET", url: URL(string: "https://example.com/agents")!, accessToken: "token")
    do {
      _ = try await staleLease.keyThumbprint()
      XCTFail("Expected activation to leave the old lease revoked")
    } catch T3DPoPSignerError.reset {
    }
    let replacementsAfterActivation = await secureStore.replacementPayloads()
    XCTAssertEqual(replacementsAfterActivation.count, 1)
  }

  func testSignOutCannotLetSuspendedProofKeyLoadRestoreDeletedKey() async throws {
    let secureStore = T3DPoPSignerSecureStore(
      proofKey: fixedPrivateKey, suspendFirstProofKeyRead: true)
    let credentials = T3ConnectCredentialStore(store: secureStore)
    let signer = makeSigner(credentials: credentials)
    let staleLoad = Task { try await signer.keyThumbprint() }
    await secureStore.waitForFirstProofKeyRead()

    let signOut = Task { try await credentials.signOut() }
    await secureStore.waitForOAuthDeletion()
    await secureStore.resumeFirstProofKeyRead()
    try await signOut.value
    _ = try? await staleLoad.value

    await signer.reset()
    let reloadedThumbprint = try await signer.keyThumbprint()
    XCTAssertNotEqual(reloadedThumbprint, try independentThumbprint(privateRaw: fixedPrivateKey))
  }

  func testSignOutDeletesProofKeyWrittenBySuspendedStaleReplacement() async throws {
    let secureStore = T3DPoPSignerSecureStore(suspendFirstProofKeyReplacement: true)
    let credentials = T3ConnectCredentialStore(store: secureStore)
    let signer = makeSigner(credentials: credentials)
    let staleGeneration = Task { try await signer.keyThumbprint() }
    await secureStore.waitForFirstProofKeyReplacement()

    let signOut = Task { try await credentials.signOut() }
    await secureStore.waitForOAuthDeletion()
    await secureStore.resumeFirstProofKeyReplacement()
    try await signOut.value
    _ = try? await staleGeneration.value
    let replacements = await secureStore.replacementPayloads()
    let staleKey = try XCTUnwrap(replacements.first)

    await signer.reset()
    let reloadedThumbprint = try await signer.keyThumbprint()
    XCTAssertNotEqual(reloadedThumbprint, try independentThumbprint(privateRaw: staleKey))
  }

  private func makeSigner(
    store: T3DPoPSignerSecureStore,
    onKeyLoadWaiterQueued: @escaping @Sendable () -> Void = {}
  ) -> T3DPoPSigner {
    makeSigner(
      credentials: T3ConnectCredentialStore(store: store),
      onKeyLoadWaiterQueued: onKeyLoadWaiterQueued)
  }

  private func makeSigner(
    credentials: T3ConnectCredentialStore,
    onKeyLoadWaiterQueued: @escaping @Sendable () -> Void = {}
  ) -> T3DPoPSigner {
    T3DPoPSigner(
      store: credentials,
      now: { Date(timeIntervalSince1970: 1_800_000_000) },
      makeJTI: { "fixed-jti" },
      onKeyLoadWaiterQueued: onKeyLoadWaiterQueued)
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
  private let suspendFirstProofKeyReplacement: Bool
  private var proofKeyReadCount = 0
  private var proofKeyReplacementCount = 0
  private var firstProofKeyReadStarted = false
  private var firstProofKeyReadWaiter: CheckedContinuation<Void, Never>?
  private var firstProofKeyReadContinuation: CheckedContinuation<Data?, Never>?
  private var firstProofKeyReadValue: Data?
  private var firstProofKeyReplacementStarted = false
  private var firstProofKeyReplacementWaiter: CheckedContinuation<Void, Never>?
  private var firstProofKeyReplacementContinuation: CheckedContinuation<Void, Never>?
  private var oauthDeletionStarted = false
  private var oauthDeletionWaiter: CheckedContinuation<Void, Never>?
  private var replacements: [Data] = []

  init(
    proofKey: Data? = nil,
    suspendFirstProofKeyRead: Bool = false,
    suspendFirstProofKeyReplacement: Bool = false
  ) {
    records = proofKey.map { [T3ConnectCredentialStore.dpopKeyAccount: $0] } ?? [:]
    self.suspendFirstProofKeyRead = suspendFirstProofKeyRead
    self.suspendFirstProofKeyReplacement = suspendFirstProofKeyReplacement
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
    if account == T3ConnectCredentialStore.dpopKeyAccount {
      proofKeyReplacementCount += 1
      if suspendFirstProofKeyReplacement, proofKeyReplacementCount == 1 {
        firstProofKeyReplacementStarted = true
        firstProofKeyReplacementWaiter?.resume()
        firstProofKeyReplacementWaiter = nil
        await withCheckedContinuation { continuation in
          firstProofKeyReplacementContinuation = continuation
        }
      }
      replacements.append(data)
    }
    records[account] = data
  }

  func delete(service: String, account: String) async throws {
    if account == T3ConnectCredentialStore.oauthAccount {
      oauthDeletionStarted = true
      oauthDeletionWaiter?.resume()
      oauthDeletionWaiter = nil
    }
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

  func waitForFirstProofKeyReplacement() async {
    if firstProofKeyReplacementStarted { return }
    await withCheckedContinuation { continuation in
      firstProofKeyReplacementWaiter = continuation
    }
  }

  func resumeFirstProofKeyReplacement() {
    firstProofKeyReplacementContinuation?.resume()
    firstProofKeyReplacementContinuation = nil
  }

  func waitForOAuthDeletion() async {
    if oauthDeletionStarted { return }
    await withCheckedContinuation { continuation in
      oauthDeletionWaiter = continuation
    }
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

private final class T3TestSignal: @unchecked Sendable {
  private let lock = NSLock()
  private var isSignaled = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func signal() {
    lock.lock()
    isSignaled = true
    let pendingWaiters = waiters
    waiters.removeAll()
    lock.unlock()
    for waiter in pendingWaiters {
      waiter.resume()
    }
  }

  func wait() async {
    await withCheckedContinuation { continuation in
      lock.lock()
      if isSignaled {
        lock.unlock()
        continuation.resume()
      } else {
        waiters.append(continuation)
        lock.unlock()
      }
    }
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
