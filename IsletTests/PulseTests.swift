import Network
import XCTest

@testable import Islet

final class PulseTests: XCTestCase {
  @MainActor
  func testOrdersUrgentItemsAndUpdatesWithoutDuplicating() throws {
    let center = PulseCenter()
    let now = Date(timeIntervalSince1970: 1_000)
    let normal = PulsePayload(
      id: "normal", source: "tests", title: "Normal", subtitle: nil, symbol: nil,
      accentHex: nil, progress: nil, state: .active, priority: .normal,
      expiresAt: nil, actions: nil)
    let urgent = PulsePayload(
      id: "urgent", source: "tests", title: "Needs input", subtitle: nil, symbol: nil,
      accentHex: nil, progress: nil, state: .needsAction, priority: .high,
      expiresAt: nil, actions: nil)

    XCTAssertTrue(center.apply(command(.show, normal), now: now).ok)
    XCTAssertTrue(center.apply(command(.show, urgent), now: now).ok)
    XCTAssertEqual(center.items.map(\.id), ["urgent", "normal"])

    var updated = normal
    updated.title = "Updated"
    XCTAssertTrue(center.apply(command(.update, updated), now: now.addingTimeInterval(1)).ok)
    XCTAssertEqual(center.items.count, 2)
    XCTAssertEqual(center.items.first(where: { $0.id == "normal" })?.title, "Updated")
  }

  @MainActor
  func testEventGetsDefaultExpiryAndUnsafeActionIsRejected() throws {
    let center = PulseCenter()
    let now = Date(timeIntervalSince1970: 1_000)
    var payload = PulsePayload(
      id: "event", source: "tests", title: "Event", subtitle: nil, symbol: nil,
      accentHex: nil, progress: nil, state: nil, priority: nil, expiresAt: nil, actions: nil)
    XCTAssertTrue(center.apply(command(.event, payload), now: now).ok)
    XCTAssertEqual(center.items[0].expiresAt, now.addingTimeInterval(8))

    payload.id = "unsafe"
    payload.actions = [PulseAction(title: "Run", url: URL(string: "file:///tmp/nope")!)]
    XCTAssertFalse(center.apply(command(.show, payload), now: now).ok)
  }

  @MainActor
  func testRejectsInvalidAccentAndDuplicateActionIdentity() throws {
    let center = PulseCenter()
    let now = Date(timeIntervalSince1970: 1_000)
    var payload = PulsePayload(
      id: "invalid", source: "tests", title: "Invalid", subtitle: nil, symbol: nil,
      accentHex: "orange", progress: nil, state: nil, priority: nil,
      expiresAt: nil, actions: nil)
    XCTAssertFalse(center.apply(command(.show, payload), now: now).ok)

    let url = URL(string: "https://example.com/action")!
    payload.accentHex = "#FF9500"
    payload.actions = [
      PulseAction(id: "same", title: "One", url: url),
      PulseAction(id: "same", title: "Two", url: url),
    ]
    XCTAssertFalse(center.apply(command(.show, payload), now: now).ok)
  }

  @MainActor
  func testEndNormalizesIdentifier() throws {
    let center = PulseCenter()
    let now = Date(timeIntervalSince1970: 1_000)
    let payload = PulsePayload(
      id: "build", source: "tests", title: "Build", subtitle: nil, symbol: nil,
      accentHex: nil, progress: nil, state: nil, priority: nil,
      expiresAt: nil, actions: nil)
    XCTAssertTrue(center.apply(command(.show, payload), now: now).ok)
    let response = center.apply(
      PulseCommand(
        token: "test", operation: .end, activity: nil, id: "  build  ",
        requestID: "request-1", source: "tests"), now: now)
    XCTAssertTrue(response.ok)
    XCTAssertEqual(response.requestID, "request-1")
    XCTAssertTrue(center.items.isEmpty)
  }

  @MainActor
  func testCrossSourceIdentifierCollisionAndMismatchedEndAreRejected() throws {
    let center = PulseCenter()
    let now = Date(timeIntervalSince1970: 1_000)
    let first = PulsePayload(
      id: "shared", source: "build", title: "Build", subtitle: nil, symbol: nil,
      accentHex: nil, progress: nil, state: .active, priority: .normal,
      expiresAt: nil, actions: nil)
    var second = first
    second.source = "agent"

    XCTAssertTrue(center.apply(command(.show, first), now: now).ok)
    let collision = center.apply(command(.show, second), now: now)
    XCTAssertFalse(collision.ok)
    XCTAssertEqual(collision.errorCode, .identifierConflict)
    XCTAssertEqual(center.items.first?.source, "build")

    let mismatchedEnd = center.apply(
      PulseCommand(
        token: "test", operation: .end, activity: nil, id: "shared", source: "agent"),
      now: now)
    XCTAssertFalse(mismatchedEnd.ok)
    XCTAssertEqual(mismatchedEnd.errorCode, .sourceMismatch)
    XCTAssertEqual(center.items.map(\.id), ["shared"])
  }

  @MainActor
  func testProgressOutsideProtocolRangeIsRejected() {
    let center = PulseCenter()
    let payload = PulsePayload(
      id: "overflow", source: "tests", title: "Overflow", subtitle: nil, symbol: nil,
      accentHex: nil, progress: 1.01, state: .progress, priority: .normal,
      expiresAt: nil, actions: nil)
    let response = center.apply(command(.show, payload), now: Date(timeIntervalSince1970: 1_000))
    XCTAssertFalse(response.ok)
    XCTAssertEqual(response.errorCode, .validationFailed)
  }

  @MainActor
  func testFocusProfileSuppressesNormalUpdatesButKeepsUrgentWork() throws {
    let center = PulseCenter()
    center.deliveryProfile = .focused
    let now = Date(timeIntervalSince1970: 1_000)
    var payload = PulsePayload(
      id: "background", source: "tests", title: "Secret title", subtitle: "Secret details",
      symbol: nil, accentHex: nil, progress: 0.3, state: .progress, priority: .normal,
      expiresAt: nil, actions: nil)

    XCTAssertTrue(center.apply(command(.show, payload), now: now).ok)
    XCTAssertTrue(center.items.isEmpty)
    XCTAssertEqual(center.history.first?.result, .suppressed)

    center.deliveryProfile = .everything
    XCTAssertEqual(center.items.map(\.id), ["background"])
    center.deliveryProfile = .focused
    XCTAssertTrue(center.items.isEmpty)

    payload.id = "urgent"
    payload.priority = .high
    XCTAssertTrue(center.apply(command(.show, payload), now: now).ok)
    XCTAssertEqual(center.items.map(\.id), ["urgent"])
    XCTAssertEqual(center.history.first?.result, .shown)
  }

  @MainActor
  func testSourcePolicyCanMuteRevealAndRevokeAProvider() throws {
    let center = PulseCenter()
    let now = Date(timeIntervalSince1970: 1_000)
    let payload = PulsePayload(
      id: "build", source: "build", title: "Running", subtitle: nil, symbol: nil,
      accentHex: nil, progress: 0.2, state: .progress, priority: .normal,
      expiresAt: nil, actions: nil)

    center.setPolicy(.muted, for: "BUILD", now: now)
    XCTAssertTrue(center.apply(command(.show, payload), now: now).ok)
    XCTAssertTrue(center.items.isEmpty)
    XCTAssertEqual(center.history.first?.result, .suppressed)

    center.setPolicy(.allowed, for: "build", now: now)
    XCTAssertEqual(center.items.map(\.id), ["build"])

    center.setPolicy(.revoked, for: "build", now: now)
    XCTAssertTrue(center.items.isEmpty)
    XCTAssertFalse(center.apply(command(.update, payload), now: now).ok)
    XCTAssertEqual(center.history.first?.result, .rejected)
    XCTAssertNil(center.history.first?.source)
  }

  @MainActor
  func testHistoryIsBoundedAndStoresOnlyWireMetadata() throws {
    let center = PulseCenter()
    let now = Date(timeIntervalSince1970: 1_000)
    for index in 0..<(PulseCenter.maximumHistoryEntries + 25) {
      let payload = PulsePayload(
        id: "item-\(index % PulseCenter.maximumItems)", source: "cli",
        title: "Private title \(index)",
        subtitle: "Private subtitle \(index)", symbol: nil, accentHex: nil, progress: nil,
        state: .active, priority: .normal, expiresAt: nil, actions: nil)
      XCTAssertTrue(center.apply(command(.show, payload), now: now).ok)
    }

    XCTAssertEqual(center.history.count, PulseCenter.maximumHistoryEntries)
    let entry = try XCTUnwrap(center.history.first)
    XCTAssertEqual(entry.source, "cli")
    XCTAssertEqual(entry.operation, .show)
    XCTAssertEqual(entry.result, .updated)
  }

  @MainActor
  func testProviderHealthUsesActiveItemsThenSessionHistory() throws {
    let center = PulseCenter()
    let now = Date(timeIntervalSince1970: 1_000)
    let payload = PulsePayload(
      id: "cli-job", source: "CLI", title: "Running", subtitle: nil, symbol: nil,
      accentHex: nil, progress: 0.2, state: .progress, priority: .normal,
      expiresAt: nil, actions: nil)
    XCTAssertTrue(center.apply(command(.show, payload), now: now).ok)

    let active = try XCTUnwrap(center.providerStatuses.first { $0.id == "cli" })
    XCTAssertEqual(active.health, .active(1))
    center.dismiss("cli-job", now: now.addingTimeInterval(1))
    let seen = try XCTUnwrap(center.providerStatuses.first { $0.id == "cli" })
    XCTAssertEqual(seen.health, .seen(now.addingTimeInterval(1)))
  }

  @MainActor
  func testRejectedPayloadHistoryDoesNotRetainUnvalidatedContent() throws {
    let center = PulseCenter()
    let now = Date(timeIntervalSince1970: 1_000)
    let payload = PulsePayload(
      id: "invalid", source: "secret-source", title: "private", subtitle: "private",
      symbol: nil, accentHex: "not-a-colour", progress: nil, state: nil, priority: nil,
      expiresAt: nil, actions: nil)
    XCTAssertFalse(center.apply(command(.show, payload), now: now).ok)
    XCTAssertEqual(center.history.first?.result, .rejected)
    XCTAssertNil(center.history.first?.source)
  }

  func testWireValidatorRejectsUnknownFieldsAtEveryProtocolLevel() throws {
    let valid = Data(
      #"{"token":"token","operation":"show","activity":{"id":"id","source":"tests","title":"Title","actions":[{"id":"open","title":"Open","url":"https://example.com"}]}}"#
        .utf8)
    XCTAssertNoThrow(try PulseWireValidator.validate(valid))

    let unknownCommand = Data(#"{"token":"token","operation":"end","id":"id","typo":true}"#.utf8)
    XCTAssertThrowsError(try PulseWireValidator.validate(unknownCommand))
    let unknownAction = Data(
      #"{"token":"token","operation":"show","activity":{"id":"id","source":"tests","title":"Title","actions":[{"id":"open","title":"Open","url":"https://example.com","script":"no"}]}}"#
        .utf8)
    XCTAssertThrowsError(try PulseWireValidator.validate(unknownAction))
  }

  func testWireDecoderAcceptsFractionalISO8601Expiry() throws {
    let data = Data(
      #"{"token":"token","operation":"event","activity":{"id":"id","source":"tests","title":"Title","expiresAt":"2026-08-28T12:34:56.789Z"}}"#
        .utf8)
    let command = try PulseWireCodec.decoder().decode(PulseCommand.self, from: data)
    XCTAssertNotNil(command.activity?.expiresAt)
  }

  func testTokenWideRateLimiterDoesNotResetWhenAConnectionWouldReconnect() {
    var limiter = PulseRateLimiter(limit: 2, window: 60)
    let start: TimeInterval = 1_000
    XCTAssertTrue(limiter.accepts(start))
    XCTAssertTrue(limiter.accepts(start + 1))
    XCTAssertFalse(limiter.accepts(start + 2))
    XCTAssertTrue(limiter.accepts(start + 61))
  }

  func testRateLimiterRecoversIfItsMonotonicClockMovesBackward() {
    var limiter = PulseRateLimiter(limit: 1, window: 60)
    XCTAssertTrue(limiter.accepts(1_000))
    XCTAssertFalse(limiter.accepts(1_001))
    XCTAssertTrue(limiter.accepts(10))
  }

  @MainActor
  func testCapacityRejectionDoesNotReportAnImmediatelyEvictedItemAsShown() throws {
    let center = PulseCenter()
    let now = Date(timeIntervalSince1970: 1_000)
    for index in 0..<PulseCenter.maximumItems {
      let payload = PulsePayload(
        id: "high-\(index)", source: "tests", title: "High \(index)", subtitle: nil,
        symbol: nil, accentHex: nil, progress: nil, state: .active, priority: .high,
        expiresAt: nil, actions: nil)
      XCTAssertTrue(center.apply(command(.show, payload), now: now).ok)
    }

    let low = PulsePayload(
      id: "low", source: "tests", title: "Low", subtitle: nil, symbol: nil,
      accentHex: nil, progress: nil, state: .active, priority: .low,
      expiresAt: nil, actions: nil)
    let response = center.apply(command(.show, low), now: now.addingTimeInterval(1))

    XCTAssertFalse(response.ok)
    XCTAssertEqual(response.errorCode, .capacityExceeded)
    XCTAssertFalse(center.items.contains { $0.id == "low" })
    XCTAssertEqual(center.history.first?.result, .evicted)
  }

  func testPulseConnectionAdmissionIsConcurrentRatherThanLifetimeBounded() {
    XCTAssertTrue(PulseServer.canAcceptConnection(activeCount: 0))
    XCTAssertTrue(PulseServer.canAcceptConnection(activeCount: 15))
    XCTAssertFalse(PulseServer.canAcceptConnection(activeCount: 16))
    XCTAssertFalse(PulseServer.canAcceptConnection(activeCount: -1))
  }

  @MainActor
  func testOccupiedDefaultPortMovesToStableLoopbackFallbackAndPublishesIt() async throws {
    var requestedPorts: [UInt16] = []
    var requestedHosts: [NWEndpoint.Host] = []
    var listeners: [FakePulseListener] = []
    var publishedPorts: [UInt16] = []
    let server = PulseServer(
      listenerFactory: { parameters, port in
        requestedPorts.append(port.rawValue)
        if case .hostPort(let host, _) = parameters.requiredLocalEndpoint {
          requestedHosts.append(host)
        }
        let listener = FakePulseListener(port: port)
        listeners.append(listener)
        return listener
      },
      tokenLoader: { Self.testToken },
      activePortWriter: { publishedPorts.append($0) },
      activePortRemover: {})

    server.start()
    XCTAssertEqual(requestedPorts, [47_717])
    listeners[0].emit(.failed(.posix(.EADDRINUSE)))
    await Task.yield()

    XCTAssertEqual(requestedPorts, [47_717, 47_718])
    XCTAssertEqual(requestedHosts, ["127.0.0.1", "127.0.0.1"])
    XCTAssertFalse(server.isRunning)
    XCTAssertNil(server.activePort)

    listeners[1].emit(.ready)
    await Task.yield()

    XCTAssertTrue(server.isRunning)
    XCTAssertEqual(server.activePort, 47_718)
    XCTAssertEqual(server.listeningAddress, "127.0.0.1:47718")
    XCTAssertEqual(publishedPorts, [47_718])
    XCTAssertNil(server.lastError)
    XCTAssertNotNil(server.portRecoveryMessage)
    server.stop()
  }

  @MainActor
  func testOccupiedFallbacksEndInActionableStoppedState() {
    var requestedPorts: [UInt16] = []
    var removedPortFile = false
    let server = PulseServer(
      listenerFactory: { _, port in
        requestedPorts.append(port.rawValue)
        throw NWError.posix(.EADDRINUSE)
      },
      tokenLoader: { Self.testToken },
      activePortWriter: { _ in XCTFail("An occupied listener must not publish a port") },
      activePortRemover: { removedPortFile = true })

    server.start()

    XCTAssertEqual(requestedPorts, PulsePaths.candidatePorts.map(\.rawValue))
    XCTAssertFalse(server.isRunning)
    XCTAssertNil(server.activePort)
    XCTAssertEqual(
      server.lastError,
      "Pulse could not start because ports 47717 through 47727 are in use. Free one, then retry.")
    XCTAssertTrue(removedPortFile)
  }

  func testAddressInUseClassificationDoesNotConsumeOtherListenerFailures() {
    XCTAssertTrue(PulseServer.isAddressInUse(NWError.posix(.EADDRINUSE)))
    XCTAssertTrue(
      PulseServer.isAddressInUse(
        NSError(domain: NSPOSIXErrorDomain, code: Int(EADDRINUSE))))
    XCTAssertFalse(PulseServer.isAddressInUse(NWError.posix(.ECONNREFUSED)))
  }

  func testTerminalPipelineFailureStaysBehindAcceptedCommands() async {
    let pipeline = PulseCommandPipeline()
    let command = Data("accepted".utf8)
    let failure = PulseResponse.failure(
      "connection command limit exceeded", code: .commandLimitExceeded)
    pipeline.yield(command)
    pipeline.terminate(failure)

    var iterator = pipeline.stream.makeAsyncIterator()
    guard case .command(let received)? = await iterator.next() else {
      return XCTFail("Expected the accepted command first")
    }
    XCTAssertEqual(received, command)
    guard case .terminal(let response)? = await iterator.next() else {
      return XCTFail("Expected the terminal response second")
    }
    XCTAssertEqual(response, failure)
    let end = await iterator.next()
    XCTAssertNil(end)
  }

  func testHalfClosedPipelineDrainsAcceptedCommandsBeforeEnding() async {
    let pipeline = PulseCommandPipeline()
    let command = Data("accepted-before-eof".utf8)
    pipeline.yield(command)
    pipeline.finish()

    var iterator = pipeline.stream.makeAsyncIterator()
    guard case .command(let received)? = await iterator.next() else {
      return XCTFail("Expected the accepted command after input EOF")
    }
    XCTAssertEqual(received, command)
    let end = await iterator.next()
    XCTAssertNil(end)
  }

  @MainActor
  func testDisabledPulseRejectsAndDoesNotRetainPrivatePayload() {
    let center = PulseCenter()
    let payload = PulsePayload(
      id: "private", source: "shortcuts", title: "Private title", subtitle: "Private details",
      symbol: nil, accentHex: nil, progress: 0.5, state: .progress, priority: .normal,
      expiresAt: nil, actions: nil)

    let response = center.applyIfEnabled(command(.update, payload), featureEnabled: false)

    XCTAssertFalse(response.ok)
    XCTAssertEqual(response.errorCode, .featureDisabled)
    XCTAssertEqual(center.retainedItemCount, 0)
  }

  private func command(_ operation: PulseOperation, _ payload: PulsePayload) -> PulseCommand {
    PulseCommand(token: "test", operation: operation, activity: payload, id: nil)
  }

  private static let testToken = Data(repeating: 0, count: 32).base64EncodedString()
}

private final class FakePulseListener: PulseListening, @unchecked Sendable {
  var newConnectionHandler: (@Sendable (NWConnection) -> Void)?
  var stateUpdateHandler: (@Sendable (NWListener.State) -> Void)?
  let port: NWEndpoint.Port?

  init(port: NWEndpoint.Port) {
    self.port = port
  }

  func start(queue: DispatchQueue) {}
  func cancel() {}
  func emit(_ state: NWListener.State) { stateUpdateHandler?(state) }
}
