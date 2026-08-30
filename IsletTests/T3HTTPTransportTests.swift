import Foundation
import XCTest

@testable import Islet

@MainActor
final class T3HTTPTransportTests: XCTestCase {
  func testTransportRejectsDifferentOriginBeforeDispatch() async throws {
    let recorder = T3HTTPTransportRecorder()
    let transport = T3HTTPTransport(session: Self.session(recorder: recorder))
    let origin = try T3HTTPOrigin(URL(string: "https://relay.t3-unit.test")!)
    let request = URLRequest(url: URL(string: "https://attacker.t3-unit.test/v1/environments")!)

    do {
      _ = try await transport.send(request, expectedOrigin: origin, deadline: 1)
      XCTFail("Expected an origin mismatch")
    } catch T3ClientError.invalidURL {
    }

    XCTAssertEqual(recorder.snapshot().requestCount, 0)
  }

  func testTransportRefusesRedirectWithoutDispatchingRedirectTarget() async throws {
    let recorder = T3HTTPTransportRecorder()
    let transport = T3HTTPTransport(session: Self.session(recorder: recorder))
    let origin = try T3HTTPOrigin(URL(string: "https://redirect.t3-unit.test")!)
    let request = URLRequest(url: URL(string: "https://redirect.t3-unit.test/start")!)

    let response = try await transport.send(request, expectedOrigin: origin, deadline: 1)

    XCTAssertEqual(response.statusCode, 307)
    XCTAssertEqual(recorder.snapshot().requestCount, 1)
    XCTAssertEqual(recorder.snapshot().redirectTargetRequests, 0)
  }

  func testTransportRejectsDeclaredResponsesOverTwoMiB() async throws {
    let recorder = T3HTTPTransportRecorder()
    let transport = T3HTTPTransport(session: Self.session(recorder: recorder))
    let origin = try T3HTTPOrigin(URL(string: "https://declared-large.t3-unit.test")!)
    let request = URLRequest(url: URL(string: "https://declared-large.t3-unit.test/data")!)

    do {
      _ = try await transport.send(request, expectedOrigin: origin, deadline: 1)
      XCTFail("Expected the declared size limit to reject the response")
    } catch T3ClientError.responseTooLarge {
    }
  }

  func testTransportRejectsStreamedResponsesOverTwoMiB() async throws {
    let recorder = T3HTTPTransportRecorder()
    let transport = T3HTTPTransport(session: Self.session(recorder: recorder))
    let origin = try T3HTTPOrigin(URL(string: "https://streamed-large.t3-unit.test")!)
    let request = URLRequest(url: URL(string: "https://streamed-large.t3-unit.test/data")!)

    do {
      _ = try await transport.send(request, expectedOrigin: origin, deadline: 3)
      XCTFail("Expected the streamed size limit to reject the response")
    } catch T3ClientError.responseTooLarge {
    }
  }

  func testTransportDeadlineExpiresWhileBytesContinueArriving() async throws {
    let recorder = T3HTTPTransportRecorder()
    let transport = T3HTTPTransport(session: Self.session(recorder: recorder))
    let origin = try T3HTTPOrigin(URL(string: "https://slow.t3-unit.test")!)
    let request = URLRequest(url: URL(string: "https://slow.t3-unit.test/data")!)

    do {
      _ = try await transport.send(request, expectedOrigin: origin, deadline: 0.15)
      XCTFail("Expected the absolute deadline to expire")
    } catch T3ClientError.requestTimedOut {
    }
  }

  func testOriginTreatsDefaultPortsAsTheSameOrigin() throws {
    let origin = try T3HTTPOrigin(URL(string: "https://RELAY.t3-unit.test:443")!)

    XCTAssertTrue(origin.contains(URL(string: "https://relay.t3-unit.test/v1/environments")!))
    XCTAssertFalse(origin.contains(URL(string: "https://relay.t3-unit.test:8443/v1/environments")!))
  }

  func testShellRequestsCreateAFreshDPoPProofEachTime() async throws {
    let recorder = T3HTTPTransportRecorder()
    let signer = T3ProofRecorder()
    let endpoint = try T3Endpoint(URL(string: "https://shell.t3-unit.test")!)
    let client = T3Client(
      endpoint: endpoint,
      authorization: .dpop(accessToken: "access-token", signer: signer),
      session: Self.session(recorder: recorder))

    _ = try await client.fetchShell()
    _ = try await client.fetchShell()

    let proofCount = await signer.count()
    XCTAssertEqual(proofCount, 2)
    XCTAssertEqual(recorder.snapshot().dpopProofs, ["proof-1", "proof-2"])
    XCTAssertEqual(
      recorder.snapshot().authorizationHeaders, ["DPoP access-token", "DPoP access-token"])
  }

  private static func session(recorder: T3HTTPTransportRecorder) -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [T3HTTPTransportURLProtocol.self]
    T3HTTPTransportURLProtocol.recorder = recorder
    return URLSession(configuration: configuration)
  }
}

private final class T3HTTPTransportRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var requestCount = 0
  private var redirectTargetRequests = 0
  private var dpopProofs: [String] = []
  private var authorizationHeaders: [String] = []

  func record(_ request: URLRequest) {
    lock.lock()
    defer { lock.unlock() }
    requestCount += 1
    if request.url?.host == "redirect-target.t3-unit.test" { redirectTargetRequests += 1 }
    if let proof = request.value(forHTTPHeaderField: "DPoP") { dpopProofs.append(proof) }
    if let authorization = request.value(forHTTPHeaderField: "Authorization") {
      authorizationHeaders.append(authorization)
    }
  }

  func snapshot() -> (
    requestCount: Int, redirectTargetRequests: Int, dpopProofs: [String],
    authorizationHeaders: [String]
  ) {
    lock.lock()
    defer { lock.unlock() }
    return (requestCount, redirectTargetRequests, dpopProofs, authorizationHeaders)
  }
}

private actor T3ProofRecorder: T3DPoPProofProviding {
  private(set) var proofCount = 0

  func proof(method: String, url: URL, accessToken: String?) async throws -> String {
    proofCount += 1
    return "proof-\(proofCount)"
  }

  func keyThumbprint() async throws -> String { "thumbprint" }

  func count() -> Int { proofCount }
}

private final class T3HTTPTransportURLProtocol: URLProtocol, @unchecked Sendable {
  nonisolated(unsafe) static var recorder: T3HTTPTransportRecorder?

  private let lock = NSLock()
  private var stopped = false
  private let queue = DispatchQueue(label: "T3HTTPTransportURLProtocol")

  override class func canInit(with request: URLRequest) -> Bool {
    request.url?.host?.hasSuffix("t3-unit.test") == true
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let url = request.url else { return }
    let request = request
    Self.recorder?.record(request)

    if url.host == "declared-large.t3-unit.test" {
      let response = HTTPURLResponse(
        url: url, statusCode: 200, httpVersion: "HTTP/1.1",
        headerFields: ["Content-Length": String(T3HTTPTransport.maximumResponseBytes + 1)])!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocolDidFinishLoading(self)
      return
    }

    if url.host == "redirect.t3-unit.test" {
      let response = HTTPURLResponse(
        url: url, statusCode: 307, httpVersion: "HTTP/1.1",
        headerFields: ["Location": "https://redirect-target.t3-unit.test/secret"])!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocolDidFinishLoading(self)
      return
    }

    if url.host == "streamed-large.t3-unit.test" {
      let response = HTTPURLResponse(
        url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(
        self, didLoad: Data(repeating: 0, count: T3HTTPTransport.maximumResponseBytes + 1))
      client?.urlProtocolDidFinishLoading(self)
      return
    }

    if url.host == "slow.t3-unit.test" {
      let response = HTTPURLResponse(
        url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      for index in 1...20 {
        queue.asyncAfter(deadline: .now() + 0.05 * Double(index)) { [weak self] in
          guard let self, !self.isStopped else { return }
          self.client?.urlProtocol(self, didLoad: Data([0]))
        }
      }
      queue.asyncAfter(deadline: .now() + 1.1) { [weak self] in
        guard let self, !self.isStopped else { return }
        self.client?.urlProtocolDidFinishLoading(self)
      }
      return
    }

    let body = Data(
      #"{"snapshotSequence":1,"projects":[],"threads":[],"updatedAt":"2026-08-30T00:00:00.000Z"}"#
        .utf8)
    let response = HTTPURLResponse(
      url: url, statusCode: 200, httpVersion: "HTTP/1.1",
      headerFields: ["Content-Type": "application/json"])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: body)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {
    lock.lock()
    stopped = true
    lock.unlock()
  }

  private var isStopped: Bool {
    lock.lock()
    defer { lock.unlock() }
    return stopped
  }
}
