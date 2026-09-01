import Darwin
import Foundation
import XCTest

@testable import Islet

final class T3OAuthLoopbackTests: XCTestCase, @unchecked Sendable {
  func testProductionFactoryUsesTheRegisteredIPv4Port() async {
    let listener = T3OAuthLoopbackListener.production()

    let port = await listener.configuredPort

    XCTAssertEqual(port, 34_338)
  }

  func testSystemAssignedPortAcceptsCallbackOnReportedPort() async throws {
    let listener = T3OAuthLoopbackListener(port: 0, timeout: .seconds(2))
    defer { Task { await listener.cancel() } }
    try await listener.start(state: "expected-state")
    let reportedPort = await listener.boundPort
    let selectedPort = try XCTUnwrap(reportedPort)
    XCTAssertNotEqual(selectedPort, 0)
    let resultTask = Task { try await listener.waitForCallback() }

    let response = try await send(
      "GET /callback?state=expected-state&code=assigned-port-code HTTP/1.1\r\n"
        + "Host: 127.0.0.1\r\n\r\n",
      port: selectedPort)
    let result = try await resultTask.value

    XCTAssertTrue(response.hasPrefix("HTTP/1.1 200"))
    XCTAssertEqual(result, .authorizationCode("assigned-port-code"))
  }

  func testExactCallbackReturnsTheCodeWithoutEchoingIt() async throws {
    let fixture = try await LoopbackFixture()
    defer { Task { await fixture.listener.cancel() } }
    let resultTask = Task { try await fixture.listener.waitForCallback() }

    let response = try await send(
      "GET /callback?state=expected-state&code=private-code HTTP/1.1\r\n"
        + "Host: 127.0.0.1\r\n\r\n",
      port: fixture.port)
    let result = try await resultTask.value

    XCTAssertEqual(result, .authorizationCode("private-code"))
    XCTAssertTrue(response.hasPrefix("HTTP/1.1 200"))
    XCTAssertFalse(response.contains("private-code"))
    XCTAssertFalse(response.contains("expected-state"))
  }

  func testSafeDenialCompletesWithoutAnAuthorizationCode() async throws {
    let fixture = try await LoopbackFixture()
    defer { Task { await fixture.listener.cancel() } }
    let resultTask = Task { try await fixture.listener.waitForCallback() }

    let response = try await send(
      "GET /callback?state=expected-state&error=access_denied&error_description=private HTTP/1.1\r\n"
        + "Host: 127.0.0.1\r\n\r\n",
      port: fixture.port)
    let result = try await resultTask.value

    XCTAssertEqual(result, .denied("access_denied"))
    XCTAssertTrue(response.hasPrefix("HTTP/1.1 200"))
    XCTAssertFalse(response.contains("access_denied"))
    XCTAssertFalse(response.contains("private"))
  }

  func testWrongMethodAndPathDoNotCompleteTheWait() async throws {
    let fixture = try await LoopbackFixture()
    defer { Task { await fixture.listener.cancel() } }
    let resultTask = Task { try await fixture.listener.waitForCallback() }

    let methodResponse = try await send(
      "POST /callback?state=expected-state&code=wrong HTTP/1.1\r\n"
        + "Host: 127.0.0.1\r\nContent-Length: 0\r\n\r\n",
      port: fixture.port)
    let pathResponse = try await send(
      "GET /callback/extra?state=expected-state&code=wrong HTTP/1.1\r\n"
        + "Host: 127.0.0.1\r\n\r\n",
      port: fixture.port)
    let validResponse = try await send(
      "GET /callback?state=expected-state&code=right HTTP/1.1\r\n"
        + "Host: 127.0.0.1\r\n\r\n",
      port: fixture.port)

    XCTAssertTrue(methodResponse.hasPrefix("HTTP/1.1 400"))
    XCTAssertTrue(pathResponse.hasPrefix("HTTP/1.1 400"))
    XCTAssertTrue(validResponse.hasPrefix("HTTP/1.1 200"))
    let result = try await resultTask.value
    XCTAssertEqual(result, .authorizationCode("right"))
  }

  func testBodyAndOversizedHeadersAreRejectedBeforeAValidCallback() async throws {
    let fixture = try await LoopbackFixture()
    defer { Task { await fixture.listener.cancel() } }
    let resultTask = Task { try await fixture.listener.waitForCallback() }

    let bodyResponse = try await send(
      "GET /callback?state=expected-state&code=wrong HTTP/1.1\r\n"
        + "Host: 127.0.0.1\r\nContent-Length: 1\r\n\r\nx",
      port: fixture.port)
    let oversizedResponse = try await send(
      "GET /callback?state=expected-state&code=wrong HTTP/1.1\r\nX-Fill: "
        + String(repeating: "a", count: T3OAuthLoopbackListener.maximumHeaderBytes)
        + "\r\n\r\n",
      port: fixture.port)
    _ = try await send(
      "GET /callback?state=expected-state&code=right HTTP/1.1\r\n"
        + "Host: 127.0.0.1\r\n\r\n",
      port: fixture.port)

    XCTAssertTrue(bodyResponse.hasPrefix("HTTP/1.1 400"))
    XCTAssertTrue(oversizedResponse.hasPrefix("HTTP/1.1 431"))
    let result = try await resultTask.value
    XCTAssertEqual(result, .authorizationCode("right"))
  }

  func testMismatchedStateMalformedRequestAndUnsafeDenialKeepWaiting() async throws {
    let fixture = try await LoopbackFixture()
    defer { Task { await fixture.listener.cancel() } }
    let resultTask = Task { try await fixture.listener.waitForCallback() }

    _ = try await send("not-http\r\n\r\n", port: fixture.port)
    _ = try await send(
      "GET /callback?state=wrong&code=wrong HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n",
      port: fixture.port)
    _ = try await send(
      "GET /callback?state=expected-state&error=unsafe%20value HTTP/1.1\r\n"
        + "Host: 127.0.0.1\r\n\r\n",
      port: fixture.port)
    _ = try await send(
      "GET /callback?state=expected-state HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n",
      port: fixture.port)
    _ = try await send(
      "GET /callback?state=expected-state&code=wrong#fragment HTTP/1.1\r\n"
        + "Host: 127.0.0.1\r\n\r\n",
      port: fixture.port)
    _ = try await send(
      "GET /callback?state=expected-state&code=right HTTP/1.1\r\n"
        + "Host: 127.0.0.1\r\n\r\n",
      port: fixture.port)

    let result = try await resultTask.value
    XCTAssertEqual(result, .authorizationCode("right"))
  }

  func testCancelingTheWaitStopsTheListener() async throws {
    let fixture = try await LoopbackFixture()
    let resultTask = Task { try await fixture.listener.waitForCallback() }

    resultTask.cancel()

    do {
      _ = try await resultTask.value
      XCTFail("Expected cancellation")
    } catch is CancellationError {
    }
  }

  func testTimeoutStopsTheListener() async throws {
    let listener = T3OAuthLoopbackListener(port: 0, timeout: .milliseconds(40))
    try await listener.start(state: "expected-state")

    do {
      _ = try await listener.waitForCallback()
      XCTFail("Expected a callback timeout")
    } catch T3OAuthLoopbackError.timedOut {
    }
  }

  func testPortInUseIsReportedBeforeWaitingForTheBrowser() async throws {
    let reservation = try LoopbackPortReservation()
    let listener = T3OAuthLoopbackListener(port: reservation.port, timeout: .seconds(1))

    do {
      try await listener.start(state: "expected-state")
      XCTFail("Expected a port conflict")
    } catch T3OAuthLoopbackError.portInUse {
    }
  }

  func testCallbackAfterStartBeforeWaitIsRetained() async throws {
    let fixture = try await LoopbackFixture()
    defer { Task { await fixture.listener.cancel() } }

    let response = try await send(
      "GET /callback?state=expected-state&code=early-code HTTP/1.1\r\n"
        + "Host: 127.0.0.1\r\n\r\n",
      port: fixture.port)
    let result = try await fixture.listener.waitForCallback()

    XCTAssertTrue(response.hasPrefix("HTTP/1.1 200"))
    XCTAssertEqual(result, .authorizationCode("early-code"))
  }

  func testFirstWaiterMayJoinCallbackWhileResponseCompletionIsInProgress() async throws {
    let completionGate = T3LoopbackGate()
    let waitEntered = T3LoopbackSignal()
    let fixture = try await LoopbackFixture(
      responseCompletionGate: { await completionGate.suspend() },
      onWaitForCallbackEntered: { waitEntered.signal() })
    defer { Task { await fixture.listener.cancel() } }
    let responseTask = Task {
      try await send(
        "GET /callback?state=expected-state&code=in-progress-code HTTP/1.1\r\n"
          + "Host: 127.0.0.1\r\n\r\n",
        port: fixture.port)
    }
    await completionGate.waitUntilSuspended()

    let resultTask = Task { try await fixture.listener.waitForCallback() }
    await waitEntered.wait()
    await completionGate.resume()

    let response = try await responseTask.value
    let result = try await resultTask.value
    XCTAssertTrue(response.hasPrefix("HTTP/1.1 200"))
    XCTAssertEqual(result, .authorizationCode("in-progress-code"))
  }

  func testCancellationWhileSuccessSendCompletionIsSuspendedCannotRetainCode() async throws {
    let completionGate = T3LoopbackGate()
    let completionHandled = T3LoopbackSignal()
    let fixture = try await LoopbackFixture(
      responseCompletionGate: { await completionGate.suspend() },
      onResponseCompletionHandled: { completionHandled.signal() })
    let resultTask = Task { try await fixture.listener.waitForCallback() }
    let responseTask = Task {
      try await send(
        "GET /callback?state=expected-state&code=canceled-code HTTP/1.1\r\n"
          + "Host: 127.0.0.1\r\n\r\n",
        port: fixture.port)
    }
    await completionGate.waitUntilSuspended()

    await fixture.listener.cancel()
    do {
      _ = try await resultTask.value
      XCTFail("Expected cancellation")
    } catch is CancellationError {
    }
    await completionGate.resume()
    _ = try? await responseTask.value
    await completionHandled.wait()

    do {
      _ = try await fixture.listener.waitForCallback()
      XCTFail("Expected cancellation to remain terminal")
    } catch is CancellationError {
    }
  }

  func testReceiveCapacityNeverExceedsRemainingHeaderBudget() {
    XCTAssertEqual(
      T3OAuthLoopbackListener.maximumReceiveLength(bufferedHeaderBytes: 0), 2_048)
    XCTAssertEqual(
      T3OAuthLoopbackListener.maximumReceiveLength(bufferedHeaderBytes: 8_191), 1)
    XCTAssertNil(T3OAuthLoopbackListener.maximumReceiveLength(bufferedHeaderBytes: 8_192))
    XCTAssertNil(T3OAuthLoopbackListener.maximumReceiveLength(bufferedHeaderBytes: 8_193))
  }

  func testUnterminatedHeaderAtEightKiBIsRejectedBeforeAnotherRead() async throws {
    let fixture = try await LoopbackFixture()
    defer { Task { await fixture.listener.cancel() } }
    let resultTask = Task { try await fixture.listener.waitForCallback() }
    let prefix = "GET /callback HTTP/1.1\r\nX-Fill: "
    let request =
      prefix
      + String(
        repeating: "a", count: T3OAuthLoopbackListener.maximumHeaderBytes - prefix.utf8.count)
    XCTAssertEqual(request.utf8.count, T3OAuthLoopbackListener.maximumHeaderBytes)

    let cappedResponse = try await send(request, port: fixture.port)
    _ = try await send(
      "GET /callback?state=expected-state&code=right HTTP/1.1\r\n"
        + "Host: 127.0.0.1\r\n\r\n",
      port: fixture.port)

    XCTAssertTrue(cappedResponse.hasPrefix("HTTP/1.1 431"))
    let result = try await resultTask.value
    XCTAssertEqual(result, .authorizationCode("right"))
  }

  func testIdleConnectionExpiresBeforeValidBrowserCallback() async throws {
    let deadlineGate = T3FirstHeaderDeadlineGate()
    let deadlineExpired = T3LoopbackSignal()
    let fixture = try await LoopbackFixture(
      waitForHeaderDeadline: { await deadlineGate.wait() },
      onHeaderDeadlineExpired: { deadlineExpired.signal() })
    defer { Task { await fixture.listener.cancel() } }
    let resultTask = Task { try await fixture.listener.waitForCallback() }
    let idleConnection = try await openIdleConnection(port: fixture.port)
    defer { idleConnection.close() }

    await deadlineGate.waitUntilSuspended()
    await deadlineGate.resume()
    await deadlineExpired.wait()
    let response = try await send(
      "GET /callback?state=expected-state&code=right HTTP/1.1\r\n"
        + "Host: 127.0.0.1\r\n\r\n",
      port: fixture.port)
    guard response.hasPrefix("HTTP/1.1 200") else {
      resultTask.cancel()
      _ = try? await resultTask.value
      XCTFail("The idle connection blocked the browser callback")
      return
    }

    let result = try await resultTask.value
    XCTAssertEqual(result, .authorizationCode("right"))
  }

  private func openIdleConnection(port: UInt16) async throws -> T3IdleLoopbackConnection {
    try await Task.detached {
      let descriptor = socket(AF_INET, SOCK_STREAM, 0)
      guard descriptor >= 0 else { throw POSIXError(.ENETDOWN) }
      var address = sockaddr_in()
      address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
      address.sin_family = sa_family_t(AF_INET)
      address.sin_port = port.bigEndian
      address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
      let connectResult = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
      }
      guard connectResult == 0 else {
        close(descriptor)
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECONNREFUSED)
      }
      return T3IdleLoopbackConnection(descriptor: descriptor)
    }.value
  }

  private func send(_ request: String, port: UInt16) async throws -> String {
    try await Task.detached {
      let descriptor = socket(AF_INET, SOCK_STREAM, 0)
      guard descriptor >= 0 else { throw POSIXError(.ENETDOWN) }
      defer { close(descriptor) }
      var noSignal: Int32 = 1
      setsockopt(
        descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal,
        socklen_t(MemoryLayout.size(ofValue: noSignal)))

      var address = sockaddr_in()
      address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
      address.sin_family = sa_family_t(AF_INET)
      address.sin_port = port.bigEndian
      address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
      let connectResult = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
      }
      guard connectResult == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECONNREFUSED)
      }

      let requestData = Data(request.utf8)
      try requestData.withUnsafeBytes { bytes in
        var sent = 0
        while sent < bytes.count {
          let count = Darwin.send(descriptor, bytes.baseAddress! + sent, bytes.count - sent, 0)
          guard count > 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPIPE)
          }
          sent += count
        }
      }
      Darwin.shutdown(descriptor, SHUT_WR)

      var response = Data()
      var buffer = [UInt8](repeating: 0, count: 2_048)
      while true {
        let count = Darwin.recv(descriptor, &buffer, buffer.count, 0)
        if count == 0 { break }
        guard count > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECONNRESET) }
        response.append(contentsOf: buffer.prefix(count))
      }
      return String(decoding: response, as: UTF8.self)
    }.value
  }
}

private final class T3IdleLoopbackConnection: @unchecked Sendable {
  private let lock = NSLock()
  private var descriptor: Int32?

  init(descriptor: Int32) {
    self.descriptor = descriptor
  }

  func close() {
    lock.lock()
    let descriptor = descriptor
    self.descriptor = nil
    lock.unlock()
    if let descriptor { Darwin.close(descriptor) }
  }

  deinit { close() }
}

private struct LoopbackFixture {
  let listener: T3OAuthLoopbackListener
  let port: UInt16

  init(
    waitForHeaderDeadline: @escaping @Sendable () async -> Void = {
      try? await Task.sleep(for: .seconds(5))
    },
    onHeaderDeadlineExpired: @escaping @Sendable () -> Void = {},
    responseCompletionGate: @escaping @Sendable () async -> Void = {},
    onResponseCompletionHandled: @escaping @Sendable () -> Void = {},
    onWaitForCallbackEntered: @escaping @Sendable () -> Void = {}
  ) async throws {
    let listener = T3OAuthLoopbackListener(
      port: 0, timeout: .seconds(2),
      waitForHeaderDeadline: waitForHeaderDeadline,
      onHeaderDeadlineExpired: onHeaderDeadlineExpired,
      responseCompletionGate: responseCompletionGate,
      onResponseCompletionHandled: onResponseCompletionHandled,
      onWaitForCallbackEntered: onWaitForCallbackEntered)
    try await listener.start(state: "expected-state")
    guard let port = await listener.boundPort else {
      await listener.cancel()
      throw T3OAuthLoopbackError.invalidLocalEndpoint
    }
    self.listener = listener
    self.port = port
  }
}

private actor T3LoopbackGate {
  private var suspended = false
  private var suspendedWaiter: CheckedContinuation<Void, Never>?
  private var resumeContinuation: CheckedContinuation<Void, Never>?

  func suspend() async {
    suspended = true
    suspendedWaiter?.resume()
    suspendedWaiter = nil
    await withCheckedContinuation { continuation in
      resumeContinuation = continuation
    }
  }

  func waitUntilSuspended() async {
    if suspended { return }
    await withCheckedContinuation { continuation in
      suspendedWaiter = continuation
    }
  }

  func resume() {
    resumeContinuation?.resume()
    resumeContinuation = nil
  }
}

private actor T3FirstHeaderDeadlineGate {
  private var isFirstWait = true
  private var suspended = false
  private var suspendedWaiter: CheckedContinuation<Void, Never>?
  private var resumeContinuation: CheckedContinuation<Void, Never>?

  func wait() async {
    guard isFirstWait else {
      try? await Task.sleep(for: .seconds(5))
      return
    }
    isFirstWait = false
    suspended = true
    suspendedWaiter?.resume()
    suspendedWaiter = nil
    await withCheckedContinuation { resumeContinuation = $0 }
  }

  func waitUntilSuspended() async {
    if suspended { return }
    await withCheckedContinuation { suspendedWaiter = $0 }
  }

  func resume() {
    resumeContinuation?.resume()
    resumeContinuation = nil
  }
}

private final class T3LoopbackSignal: @unchecked Sendable {
  private let lock = NSLock()
  private var signaled = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func signal() {
    lock.lock()
    signaled = true
    let waiting = waiters
    waiters.removeAll()
    lock.unlock()
    for waiter in waiting { waiter.resume() }
  }

  func wait() async {
    await withCheckedContinuation { continuation in
      lock.lock()
      if signaled {
        lock.unlock()
        continuation.resume()
      } else {
        waiters.append(continuation)
        lock.unlock()
      }
    }
  }
}

private final class LoopbackPortReservation {
  private(set) var port: UInt16 = 0
  private var descriptor: Int32

  init() throws {
    descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw POSIXError(.ENETDOWN) }

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let bindResult = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bindResult == 0 else {
      let code = POSIXErrorCode(rawValue: errno) ?? .EADDRINUSE
      release()
      throw POSIXError(code)
    }
    guard Darwin.listen(descriptor, 1) == 0 else {
      let code = POSIXErrorCode(rawValue: errno) ?? .EADDRINUSE
      release()
      throw POSIXError(code)
    }

    var boundAddress = sockaddr_in()
    var boundLength = socklen_t(MemoryLayout<sockaddr_in>.size)
    let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        getsockname(descriptor, $0, &boundLength)
      }
    }
    guard nameResult == 0 else {
      let code = POSIXErrorCode(rawValue: errno) ?? .EINVAL
      release()
      throw POSIXError(code)
    }
    port = UInt16(bigEndian: boundAddress.sin_port)
  }

  deinit { release() }

  func release() {
    guard descriptor >= 0 else { return }
    close(descriptor)
    descriptor = -1
  }
}
