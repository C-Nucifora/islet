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
    XCTAssertEqual(center.items.map(\.providerIdentifier), ["urgent", "normal"])

    var updated = normal
    updated.title = "Updated"
    XCTAssertTrue(center.apply(command(.update, updated), now: now.addingTimeInterval(1)).ok)
    XCTAssertEqual(center.items.count, 2)
    XCTAssertEqual(
      center.items.first(where: { $0.providerIdentifier == "normal" })?.title, "Updated")
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
  func testLegacyUnscopedEndNormalizesUniqueIdentifier() throws {
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
        requestID: "request-1", source: nil), now: now)
    XCTAssertTrue(response.ok)
    XCTAssertEqual(response.requestID, "request-1")
    XCTAssertTrue(center.items.isEmpty)
  }

  @MainActor
  func testSameProviderIdentifierCanCoexistAndUpdatesStayWithinTheirSource() throws {
    let center = PulseCenter()
    let now = Date(timeIntervalSince1970: 1_000)
    let first = PulsePayload(
      id: "shared", source: "build", title: "Build", subtitle: nil, symbol: nil,
      accentHex: nil, progress: nil, state: .active, priority: .normal,
      expiresAt: nil, actions: nil)
    var second = first
    second.source = "agent"
    second.title = "Agent"

    let firstResponse = center.apply(command(.show, first), now: now)
    let secondResponse = center.apply(command(.show, second), now: now)
    XCTAssertTrue(firstResponse.ok)
    XCTAssertTrue(secondResponse.ok)
    XCTAssertEqual(firstResponse.id, "shared")
    XCTAssertEqual(secondResponse.id, "shared")
    XCTAssertEqual(center.items.count, 2)
    XCTAssertEqual(Set(center.items.map(\.providerIdentifier)), ["shared"])
    XCTAssertEqual(Set(center.items.map(\.source)), ["build", "agent"])

    var buildUpdate = first
    buildUpdate.title = "Build updated"
    buildUpdate.progress = 0.7
    buildUpdate.state = .progress
    XCTAssertTrue(
      center.apply(command(.update, buildUpdate), now: now.addingTimeInterval(1)).ok)
    XCTAssertEqual(center.items.first { $0.source == "build" }?.title, "Build updated")
    XCTAssertEqual(center.items.first { $0.source == "agent" }?.title, "Agent")
    XCTAssertEqual(center.history.first?.providerIdentifier, "shared")
  }

  @MainActor
  func testAmbiguousEndRequiresSourceAndScopedEndIsIsolated() throws {
    let center = PulseCenter()
    let now = Date(timeIntervalSince1970: 1_000)
    let first = PulsePayload(
      id: "shared", source: "build", title: "Build", subtitle: nil, symbol: nil,
      accentHex: nil, progress: nil, state: .active, priority: .normal,
      expiresAt: nil, actions: nil)
    var second = first
    second.source = "agent"
    second.title = "Agent"
    XCTAssertTrue(center.apply(command(.show, first), now: now).ok)
    XCTAssertTrue(center.apply(command(.show, second), now: now).ok)

    let ambiguous = center.apply(
      PulseCommand(token: "test", operation: .end, activity: nil, id: "shared"), now: now)
    XCTAssertFalse(ambiguous.ok)
    XCTAssertEqual(ambiguous.errorCode, .ambiguousIdentifier)
    XCTAssertEqual(center.items.count, 2)

    let mismatchedEnd = center.apply(
      PulseCommand(
        token: "test", operation: .end, activity: nil, id: "shared", source: "other"),
      now: now)
    XCTAssertFalse(mismatchedEnd.ok)
    XCTAssertEqual(mismatchedEnd.errorCode, .sourceMismatch)
    XCTAssertEqual(center.items.count, 2)

    let scopedEnd = center.apply(
      PulseCommand(
        token: "test", operation: .end, activity: nil, id: "shared", source: " AGENT "),
      now: now)
    XCTAssertTrue(scopedEnd.ok)
    XCTAssertEqual(center.items.map(\.source), ["build"])

    let legacyEnd = center.apply(
      PulseCommand(token: "test", operation: .end, activity: nil, id: "shared"), now: now)
    XCTAssertTrue(legacyEnd.ok)
    XCTAssertTrue(center.items.isEmpty)
  }

  @MainActor
  func testSourceNormalizationCollisionUpdatesOneNamespacedItem() throws {
    let center = PulseCenter()
    let now = Date(timeIntervalSince1970: 1_000)
    let first = PulsePayload(
      id: "job", source: " Build ", title: "First", subtitle: nil, symbol: nil,
      accentHex: nil, progress: nil, state: .active, priority: .normal,
      expiresAt: nil, actions: nil)
    var update = first
    update.source = "build"
    update.title = "Updated"

    XCTAssertTrue(center.apply(command(.show, first), now: now).ok)
    XCTAssertTrue(center.apply(command(.update, update), now: now.addingTimeInterval(1)).ok)
    XCTAssertEqual(center.items.count, 1)
    XCTAssertEqual(center.items.first?.title, "Updated")
    XCTAssertEqual(center.items.first?.id.normalizedSource, "build")

    let end = center.apply(
      PulseCommand(
        token: "test", operation: .end, activity: nil, id: "job", source: "BUILD"),
      now: now.addingTimeInterval(2))
    XCTAssertTrue(end.ok)
    XCTAssertTrue(center.items.isEmpty)
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
  func testPulseSymbolValidationKeepsValidSymbolsAndReplacesInvalidSymbols() throws {
    let now = Date(timeIntervalSince1970: 1_000)
    let validPayload = PulsePayload(
      id: "valid-symbol", source: "tests", title: "Valid", subtitle: nil,
      symbol: "checkmark.circle.fill", accentHex: nil, progress: nil, state: nil,
      priority: nil, expiresAt: nil, actions: nil)
    let valid = try PulseItem(
      payload: validPayload, now: now, symbolAvailability: { $0 == "checkmark.circle.fill" })
    XCTAssertEqual(valid.symbol, "checkmark.circle.fill")
    XCTAssertNil(valid.symbolWarning)

    var invalidPayload = validPayload
    invalidPayload.id = "invalid-symbol"
    invalidPayload.symbol = "not.a.real.sf.symbol"
    let invalid = try PulseItem(
      payload: invalidPayload, now: now, symbolAvailability: { _ in false })
    XCTAssertEqual(invalid.symbol, PulseSymbolValidator.fallbackSymbol)
    XCTAssertEqual(invalid.symbolWarning, .invalid)

    let center = PulseCenter(symbolAvailability: { _ in false })
    let response = center.apply(command(.show, invalidPayload), now: now)
    XCTAssertTrue(response.ok)
    XCTAssertEqual(center.items.first?.symbol, PulseSymbolValidator.fallbackSymbol)
    XCTAssertEqual(response.warning, PulseSymbolWarning.invalid.localizedDescription)
  }

  @MainActor
  func testPulseSymbolValidationReplacesEmptyAndPlatformUnavailableSymbols() throws {
    let now = Date(timeIntervalSince1970: 1_000)
    var payload = PulsePayload(
      id: "empty-symbol", source: "tests", title: "Empty", subtitle: nil, symbol: "  ",
      accentHex: nil, progress: nil, state: nil, priority: nil, expiresAt: nil, actions: nil)
    let empty = try PulseItem(payload: payload, now: now, symbolAvailability: { _ in true })
    XCTAssertEqual(empty.symbol, PulseSymbolValidator.fallbackSymbol)
    XCTAssertEqual(empty.symbolWarning, .empty)

    let emptyCenter = PulseCenter(symbolAvailability: { _ in true })
    let emptyResponse = emptyCenter.apply(command(.show, payload), now: now)
    XCTAssertTrue(emptyResponse.ok)
    XCTAssertEqual(emptyResponse.warning, PulseSymbolWarning.empty.localizedDescription)

    payload.id = "platform-unavailable-symbol"
    payload.symbol = "checkmark.circle.fill"
    let unavailable = try PulseItem(
      payload: payload, now: now, symbolAvailability: { _ in nil })
    XCTAssertEqual(unavailable.symbol, PulseSymbolValidator.fallbackSymbol)
    XCTAssertEqual(unavailable.symbolWarning, .platformUnavailable)

    let center = PulseCenter(symbolAvailability: { _ in nil })
    let response = center.apply(command(.show, payload), now: now)
    XCTAssertTrue(response.ok)
    XCTAssertEqual(response.warning, PulseSymbolWarning.platformUnavailable.localizedDescription)
  }

  @MainActor
  func testProvidersCannotSetIsletManagedStaleState() {
    let center = PulseCenter()
    let payload = PulsePayload(
      id: "forged-stale", source: "tests", title: "Forged", subtitle: nil, symbol: nil,
      accentHex: nil, progress: 0.5, state: .stale, priority: .normal,
      expiresAt: nil, actions: nil)

    let response = center.apply(command(.update, payload))

    XCTAssertFalse(response.ok)
    XCTAssertEqual(response.errorCode, .validationFailed)
    XCTAssertTrue(center.items.isEmpty)
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
    XCTAssertEqual(center.items.map(\.providerIdentifier), ["background"])
    center.deliveryProfile = .focused
    XCTAssertTrue(center.items.isEmpty)

    payload.id = "urgent"
    payload.priority = .high
    XCTAssertTrue(center.apply(command(.show, payload), now: now).ok)
    XCTAssertEqual(center.items.map(\.providerIdentifier), ["urgent"])
    XCTAssertEqual(center.history.first?.result, .shown)
  }

  @MainActor
  func testSourcePolicyCanMuteRevealAndRevokeOnlyItsProviderNamespace() throws {
    let center = PulseCenter()
    let now = Date(timeIntervalSince1970: 1_000)
    let payload = PulsePayload(
      id: "build", source: "build", title: "Running", subtitle: nil, symbol: nil,
      accentHex: nil, progress: 0.2, state: .progress, priority: .normal,
      expiresAt: nil, actions: nil)
    var agentPayload = payload
    agentPayload.source = "agent"
    agentPayload.title = "Agent running"

    center.setPolicy(.muted, for: "BUILD", now: now)
    XCTAssertTrue(center.apply(command(.show, payload), now: now).ok)
    XCTAssertTrue(center.items.isEmpty)
    XCTAssertEqual(center.history.first?.result, .suppressed)

    center.setPolicy(.allowed, for: "build", now: now)
    XCTAssertEqual(center.items.map(\.providerIdentifier), ["build"])
    XCTAssertTrue(center.apply(command(.show, agentPayload), now: now).ok)

    center.setPolicy(.revoked, for: "build", now: now)
    XCTAssertEqual(center.items.map(\.source), ["agent"])
    XCTAssertFalse(center.apply(command(.update, payload), now: now).ok)
    XCTAssertEqual(center.history.first?.result, .rejected)
    XCTAssertNil(center.history.first?.source)
    XCTAssertNil(center.history.first?.providerIdentifier)
  }

  @MainActor
  func testCredentialRevocationCleanupRemovesOnlyItsBoundSourceItems() throws {
    let center = PulseCenter()
    let now = Date(timeIntervalSince1970: 1_000)
    let build = PulsePayload(
      id: "job", source: "build", title: "Build", subtitle: nil, symbol: nil,
      accentHex: nil, progress: nil, state: .active, priority: .normal,
      expiresAt: nil, actions: nil)
    var tests = build
    tests.source = "tests"
    tests.title = "Tests"
    XCTAssertTrue(center.apply(command(.show, build), now: now).ok)
    XCTAssertTrue(center.apply(command(.show, tests), now: now).ok)

    center.removeItems(forSource: " BUILD ", now: now.addingTimeInterval(1))

    XCTAssertEqual(center.items.map(\.source), ["tests"])
    XCTAssertEqual(center.history.first?.source, "build")
    XCTAssertEqual(center.history.first?.result, .dismissed)
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
    XCTAssertEqual(entry.providerIdentifier, "item-24")
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
    center.dismiss(try XCTUnwrap(center.items.first).id, now: now.addingTimeInterval(1))
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
    XCTAssertNil(center.history.first?.providerIdentifier)
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
    XCTAssertFalse(center.items.contains { $0.providerIdentifier == "low" })
    XCTAssertEqual(center.history.first?.result, .evicted)
  }

  @MainActor
  func testExpiryRemovesOnlyTheMatchingNamespacedIdentifier() throws {
    let clock = TestPulseClock(now: Date(timeIntervalSince1970: 900))
    let scheduler = TestPulseDeadlineScheduler(clock: clock)
    let center = PulseCenter(
      staleTimeout: 100, staleRetention: 20, clock: clock, scheduler: scheduler)
    let expiring = PulsePayload(
      id: "shared", source: "build", title: "Build", subtitle: nil, symbol: nil,
      accentHex: nil, progress: nil, state: .active, priority: .normal,
      expiresAt: Date(timeIntervalSince1970: 905), actions: nil)
    var retained = expiring
    retained.source = "agent"
    retained.title = "Agent"
    retained.expiresAt = nil

    XCTAssertTrue(center.apply(command(.show, expiring)).ok)
    XCTAssertTrue(center.apply(command(.show, retained)).ok)
    scheduler.advance(to: Date(timeIntervalSince1970: 905))

    XCTAssertEqual(center.items.map(\.source), ["agent"])
    XCTAssertEqual(center.items.first?.providerIdentifier, "shared")
    XCTAssertEqual(center.history.first?.result, .expired)
    XCTAssertEqual(center.history.first?.source, "build")
    XCTAssertEqual(center.history.first?.providerIdentifier, "shared")
  }

  @MainActor
  func testProviderSilenceMarksNonterminalWorkStale() throws {
    let clock = TestPulseClock(now: Date(timeIntervalSince1970: 1_000))
    let scheduler = TestPulseDeadlineScheduler(clock: clock)
    let center = PulseCenter(
      staleTimeout: 10, staleRetention: 20, clock: clock, scheduler: scheduler)
    let payload = PulsePayload(
      id: "silent", source: "cli", title: "Running", subtitle: nil, symbol: nil,
      accentHex: nil, progress: 0.4, state: .progress, priority: .normal,
      expiresAt: nil, actions: nil)

    XCTAssertTrue(center.apply(command(.show, payload)).ok)
    XCTAssertEqual(center.items.first?.staleAt, clock.now.addingTimeInterval(10))

    scheduler.advance(to: clock.now.addingTimeInterval(9))
    XCTAssertEqual(center.items.first?.state, .progress)

    scheduler.advance(to: Date(timeIntervalSince1970: 1_010))
    let stale = try XCTUnwrap(center.items.first)
    XCTAssertEqual(stale.state, .stale)
    XCTAssertNil(stale.staleAt)
    XCTAssertEqual(stale.staleRemovalAt, Date(timeIntervalSince1970: 1_030))
    XCTAssertEqual(center.history.first?.result, .stale)
    XCTAssertEqual(center.history.first?.state, .stale)
  }

  @MainActor
  func testValidUpdateRefreshesDeadlineAndRecoversStaleWork() throws {
    let clock = TestPulseClock(now: Date(timeIntervalSince1970: 2_000))
    let scheduler = TestPulseDeadlineScheduler(clock: clock)
    let center = PulseCenter(
      staleTimeout: 10, staleRetention: 20, clock: clock, scheduler: scheduler)
    var payload = PulsePayload(
      id: "recovering", source: "cli", title: "Running", subtitle: nil, symbol: nil,
      accentHex: nil, progress: 0.2, state: .progress, priority: .normal,
      expiresAt: nil, actions: nil)

    XCTAssertTrue(center.apply(command(.show, payload)).ok)
    scheduler.advance(to: Date(timeIntervalSince1970: 2_005))
    payload.progress = 0.5
    XCTAssertTrue(center.apply(command(.update, payload)).ok)
    XCTAssertEqual(center.items.first?.staleAt, Date(timeIntervalSince1970: 2_015))

    scheduler.advance(to: Date(timeIntervalSince1970: 2_010))
    XCTAssertEqual(center.items.first?.state, .progress)
    scheduler.advance(to: Date(timeIntervalSince1970: 2_015))
    XCTAssertEqual(center.items.first?.state, .stale)

    scheduler.advance(to: Date(timeIntervalSince1970: 2_016))
    payload.progress = 0.8
    XCTAssertTrue(center.apply(command(.update, payload)).ok)
    let recovered = try XCTUnwrap(center.items.first)
    XCTAssertEqual(recovered.state, .progress)
    XCTAssertEqual(recovered.staleAt, Date(timeIntervalSince1970: 2_026))
    XCTAssertNil(recovered.staleRemovalAt)
    XCTAssertFalse(recovered.isStaleKept)

    scheduler.advance(to: Date(timeIntervalSince1970: 2_020))
    payload.progress = 2
    XCTAssertFalse(center.apply(command(.update, payload)).ok)
    XCTAssertEqual(center.items.first?.staleAt, Date(timeIntervalSince1970: 2_026))
    scheduler.advance(to: Date(timeIntervalSince1970: 2_026))
    XCTAssertEqual(center.items.first?.state, .stale)
  }

  @MainActor
  func testStaleWorkCanBeKeptOrDismissedAndOtherwiseHasBoundedRetention() throws {
    let clock = TestPulseClock(now: Date(timeIntervalSince1970: 3_000))
    let scheduler = TestPulseDeadlineScheduler(clock: clock)
    let center = PulseCenter(
      staleTimeout: 10, staleRetention: 20, clock: clock, scheduler: scheduler)
    var payload = PulsePayload(
      id: "kept", source: "cli", title: "Keep me", subtitle: nil, symbol: nil,
      accentHex: nil, progress: 0.2, state: .progress, priority: .normal,
      expiresAt: Date(timeIntervalSince1970: 3_500), actions: nil)

    XCTAssertTrue(center.apply(command(.show, payload)).ok)
    scheduler.advance(to: Date(timeIntervalSince1970: 3_010))
    center.keepStale(try XCTUnwrap(center.items.first).id)
    XCTAssertTrue(try XCTUnwrap(center.items.first).isStaleKept)
    XCTAssertNil(center.items.first?.expiresAt)
    XCTAssertNil(center.items.first?.staleRemovalAt)
    XCTAssertEqual(center.history.first?.result, .kept)

    scheduler.advance(to: Date(timeIntervalSince1970: 4_000))
    XCTAssertEqual(center.items.map(\.providerIdentifier), ["kept"])
    center.dismiss(try XCTUnwrap(center.items.first).id)
    XCTAssertTrue(center.items.isEmpty)
    XCTAssertEqual(center.history.first?.result, .dismissed)

    payload.id = "unclaimed"
    payload.title = "Remove me"
    payload.expiresAt = nil
    XCTAssertTrue(center.apply(command(.show, payload)).ok)
    scheduler.advance(to: Date(timeIntervalSince1970: 4_010))
    XCTAssertEqual(center.items.first?.state, .stale)
    scheduler.advance(to: Date(timeIntervalSince1970: 4_030))
    XCTAssertTrue(center.items.isEmpty)
    XCTAssertEqual(center.history.first?.result, .expired)
    XCTAssertEqual(center.history.first?.state, .stale)
  }

  @MainActor
  func testTerminalWorkDoesNotReceiveAStaleDeadline() throws {
    let clock = TestPulseClock(now: Date(timeIntervalSince1970: 5_000))
    let scheduler = TestPulseDeadlineScheduler(clock: clock)
    let center = PulseCenter(
      staleTimeout: 10, staleRetention: 20, clock: clock, scheduler: scheduler)
    let payload = PulsePayload(
      id: "done", source: "cli", title: "Done", subtitle: nil, symbol: nil,
      accentHex: nil, progress: 1, state: .succeeded, priority: .normal,
      expiresAt: nil, actions: nil)

    XCTAssertTrue(center.apply(command(.show, payload)).ok)
    XCTAssertNil(center.items.first?.staleAt)
    XCTAssertEqual(scheduler.pendingCount, 0)
    scheduler.advance(to: Date(timeIntervalSince1970: 10_000))
    XCTAssertEqual(center.items.first?.state, .succeeded)
  }

  @MainActor
  func testChangingTimeoutRecomputesExistingLiveDeadline() {
    let clock = TestPulseClock(now: Date(timeIntervalSince1970: 6_000))
    let scheduler = TestPulseDeadlineScheduler(clock: clock)
    let center = PulseCenter(
      staleTimeout: 30, staleRetention: 20, clock: clock, scheduler: scheduler)
    let payload = PulsePayload(
      id: "reconfigured", source: "cli", title: "Running", subtitle: nil, symbol: nil,
      accentHex: nil, progress: 0.1, state: .progress, priority: .normal,
      expiresAt: nil, actions: nil)

    XCTAssertTrue(center.apply(command(.show, payload)).ok)
    scheduler.advance(to: Date(timeIntervalSince1970: 6_010))
    center.setStaleTimeout(5)

    XCTAssertEqual(center.staleTimeout, 5)
    XCTAssertEqual(center.items.first?.state, .stale)
    XCTAssertEqual(center.history.first?.result, .stale)
  }

  func testPulseConnectionAdmissionIsConcurrentRatherThanLifetimeBounded() {
    XCTAssertTrue(PulseServer.canAcceptConnection(activeCount: 0))
    XCTAssertTrue(PulseServer.canAcceptConnection(activeCount: 15))
    XCTAssertFalse(PulseServer.canAcceptConnection(activeCount: 16))
    XCTAssertFalse(PulseServer.canAcceptConnection(activeCount: -1))
  }

  @MainActor
  func testOccupiedDefaultPortMovesToStableLoopbackFallbackAndPublishesIt() async throws {
    let supportDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "islet-pulse-port-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: supportDirectory) }
    var requestedPorts: [UInt16] = []
    var requestedHosts: [NWEndpoint.Host] = []
    var listeners: [FakePulseListener] = []
    var publishedPorts: [UInt16] = []
    let server = PulseServer(
      credentialStore: PulseCredentialStore(supportDirectory: supportDirectory),
      listenerFactory: { parameters, port in
        requestedPorts.append(port.rawValue)
        if case .hostPort(let host, _) = parameters.requiredLocalEndpoint {
          requestedHosts.append(host)
        }
        let listener = FakePulseListener(port: port)
        listeners.append(listener)
        return listener
      },
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
    let supportDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "islet-pulse-port-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: supportDirectory) }
    var requestedPorts: [UInt16] = []
    var removedPortFile = false
    let server = PulseServer(
      credentialStore: PulseCredentialStore(supportDirectory: supportDirectory),
      listenerFactory: { _, port in
        requestedPorts.append(port.rawValue)
        throw NWError.posix(.EADDRINUSE)
      },
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

    let response = center.applyIfEnabled(command(.update, payload), activityEnabled: false)

    XCTAssertFalse(response.ok)
    XCTAssertEqual(response.errorCode, .featureDisabled)
    XCTAssertEqual(center.retainedItemCount, 0)
  }

  private func command(_ operation: PulseOperation, _ payload: PulsePayload) -> PulseCommand {
    PulseCommand(token: "test", operation: operation, activity: payload, id: nil)
  }
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

@MainActor
private final class TestPulseClock: PulseClock {
  var now: Date

  init(now: Date) {
    self.now = now
  }
}

@MainActor
private final class TestPulseDeadlineScheduler: PulseDeadlineScheduling {
  private struct Entry {
    let id: UUID
    let deadline: Date
    let action: @MainActor @Sendable () -> Void
  }

  private let clock: TestPulseClock
  private var entries: [Entry] = []

  init(clock: TestPulseClock) {
    self.clock = clock
  }

  var pendingCount: Int { entries.count }

  func schedule(
    at deadline: Date, action: @escaping @MainActor @Sendable () -> Void
  ) -> PulseDeadlineTask {
    let id = UUID()
    entries.append(Entry(id: id, deadline: deadline, action: action))
    return PulseDeadlineTask { [weak self] in
      self?.entries.removeAll { $0.id == id }
    }
  }

  func advance(to date: Date) {
    precondition(date >= clock.now)
    clock.now = date
    while let index = entries.indices.min(by: { entries[$0].deadline < entries[$1].deadline }),
      entries[index].deadline <= date
    {
      let entry = entries.remove(at: index)
      entry.action()
    }
  }
}
