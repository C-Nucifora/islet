import Defaults
import Network
import XCTest

@testable import Islet

final class PulseTests: XCTestCase {
  private let deliveryProfileSuiteName = "PulseTests.\(UUID().uuidString)"
  private lazy var deliveryProfileSuite = UserDefaults(suiteName: deliveryProfileSuiteName)!

  override func tearDown() {
    deliveryProfileSuite.removePersistentDomain(forName: deliveryProfileSuiteName)
    super.tearDown()
  }

  func testTransferProvidersRemainOutOfProcessGalleryEntries() throws {
    let chrome = try XCTUnwrap(
      PulseProviderDescriptor.gallery.first { $0.id == "chrome-downloads" })
    XCTAssertEqual(chrome.sourceIDs, ["chrome-downloads"])
    XCTAssertEqual(chrome.capabilities, [.events, .progress, .webActions])

    let rclone = try XCTUnwrap(PulseProviderDescriptor.gallery.first { $0.id == "rclone" })
    XCTAssertEqual(rclone.sourceIDs, ["rclone"])
    XCTAssertEqual(rclone.capabilities, [.events, .progress, .webActions])
  }

  @MainActor
  func testOrdersUrgentItemsAndUpdatesWithoutDuplicating() throws {
    let center = makeCenter()
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
    let center = makeCenter()
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
  func testCancelledStateIsAcceptedAsAProviderTerminalState() throws {
    let center = makeCenter()
    let now = Date(timeIntervalSince1970: 1_000)
    let payload = PulsePayload(
      id: "cancelled", source: "xcode", title: "Build cancelled", subtitle: "Islet · 4s",
      symbol: nil, accentHex: nil, progress: 0.25, state: .cancelled, priority: .normal,
      expiresAt: now.addingTimeInterval(15), actions: nil)

    XCTAssertTrue(center.apply(command(.event, payload), now: now).ok)
    let item = try XCTUnwrap(center.items.first)
    XCTAssertEqual(item.state, .cancelled)
    XCTAssertEqual(item.progress, 0.25)
    XCTAssertEqual(item.expiresAt, now.addingTimeInterval(15))
  }

  @MainActor
  func testRejectsInvalidAccentAndDuplicateActionIdentity() throws {
    let center = makeCenter()
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
    let center = makeCenter()
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
    let center = makeCenter()
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

  func testStableIdentifierDoesNotAliasDelimiterCharacters() throws {
    let sourceContainsDelimiter = try PulseItem.ID(source: "a:b", providerIdentifier: "c")
    let identifierContainsDelimiter = try PulseItem.ID(source: "a", providerIdentifier: "b:c")

    XCTAssertNotEqual(
      sourceContainsDelimiter.stableIdentifier,
      identifierContainsDelimiter.stableIdentifier)
  }

  @MainActor
  func testAmbiguousEndRequiresSourceAndScopedEndIsIsolated() throws {
    let center = makeCenter()
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
    let center = makeCenter()
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
  func testRevisionOrderingRejectsReorderedAndRetriedCommandsWithoutSideEffects() throws {
    let center = makeCenter()
    let now = Date(timeIntervalSince1970: 1_000)
    var payload = PulsePayload(
      id: "ordered", source: "build", title: "Revision 1", subtitle: nil, symbol: nil,
      accentHex: nil, progress: 0.1, state: .progress, priority: .normal,
      expiresAt: nil, actions: nil)
    XCTAssertTrue(center.apply(command(.show, payload, revision: 1), now: now).ok)

    payload.title = "Revision 3"
    payload.progress = 0.3
    XCTAssertTrue(
      center.apply(command(.update, payload, revision: 3), now: now.addingTimeInterval(3)).ok)
    let accepted = try XCTUnwrap(center.items.first)
    let historyCount = center.history.count

    payload.title = "Delayed revision 2"
    payload.progress = 0.2
    let delayed = center.apply(
      command(.update, payload, revision: 2), now: now.addingTimeInterval(4))
    XCTAssertFalse(delayed.ok)
    XCTAssertEqual(delayed.errorCode, .staleRevision)

    payload.title = "Retried revision 3"
    let firstRetry = center.apply(
      command(.update, payload, revision: 3), now: now.addingTimeInterval(5))
    let secondRetry = center.apply(
      command(.update, payload, revision: 3), now: now.addingTimeInterval(6))
    XCTAssertEqual(firstRetry, secondRetry)
    XCTAssertEqual(firstRetry.errorCode, .staleRevision)
    XCTAssertEqual(center.items.first, accepted)
    XCTAssertEqual(center.history.count, historyCount)
  }

  @MainActor
  func testDuplicateRevisionAfterExpiryRemainsAnIdempotentOrderingRejection() throws {
    let clock = TestPulseClock(now: Date(timeIntervalSince1970: 1_000))
    let scheduler = TestPulseDeadlineScheduler(clock: clock)
    let center = makeCenter(clock: clock, scheduler: scheduler)
    let payload = PulsePayload(
      id: "expiring-retry", source: "build", title: "Running", subtitle: nil, symbol: nil,
      accentHex: nil, progress: 0.5, state: .progress, priority: .normal,
      expiresAt: Date(timeIntervalSince1970: 1_005), actions: nil)
    let command = command(.update, payload, revision: 7)
    XCTAssertTrue(center.apply(command).ok)

    scheduler.advance(to: Date(timeIntervalSince1970: 1_005))
    XCTAssertTrue(center.items.isEmpty)
    let history = center.history
    scheduler.advance(to: Date(timeIntervalSince1970: 1_006))

    let retry = center.apply(command)

    XCTAssertFalse(retry.ok)
    XCTAssertEqual(retry.errorCode, .staleRevision)
    XCTAssertEqual(center.history, history)
  }

  @MainActor
  func testConcurrentRevisionArrivalConvergesOnTheHighestRevision() async throws {
    let center = makeCenter()
    let now = Date(timeIntervalSince1970: 2_000)

    await withTaskGroup(of: Void.self) { group in
      for revision in 1...40 {
        group.addTask { @MainActor in
          let payload = PulsePayload(
            id: "concurrent", source: "build", title: "Revision \(revision)", subtitle: nil,
            symbol: nil, accentHex: nil, progress: Double(revision) / 40, state: .progress,
            priority: .normal, expiresAt: nil, actions: nil)
          _ = center.apply(
            self.command(.update, payload, revision: UInt64(revision)), now: now)
        }
      }
    }

    let item = try XCTUnwrap(center.items.first)
    XCTAssertEqual(item.title, "Revision 40")
    XCTAssertEqual(item.progress, 1)
  }

  @MainActor
  func testLegacyStreamUsesArrivalOrderUntilItOptsIntoRevisions() throws {
    let center = makeCenter()
    let now = Date(timeIntervalSince1970: 3_000)
    var payload = PulsePayload(
      id: "legacy", source: "build", title: "First", subtitle: nil, symbol: nil,
      accentHex: nil, progress: nil, state: .active, priority: .normal,
      expiresAt: nil, actions: nil)
    XCTAssertTrue(center.apply(command(.show, payload), now: now).ok)
    payload.title = "Arrival order"
    XCTAssertTrue(center.apply(command(.update, payload), now: now).ok)
    XCTAssertEqual(center.items.first?.title, "Arrival order")

    payload.title = "Ordered"
    XCTAssertTrue(center.apply(command(.update, payload, revision: 8), now: now).ok)
    payload.title = "Late legacy request"
    let missingRevision = center.apply(command(.update, payload), now: now)
    XCTAssertEqual(missingRevision.errorCode, .revisionRequired)
    XCTAssertEqual(center.items.first?.title, "Ordered")
  }

  @MainActor
  func testOrderedEndClosesGenerationUntilANewerShow() throws {
    let center = makeCenter()
    let now = Date(timeIntervalSince1970: 4_000)
    var payload = PulsePayload(
      id: "generation", source: "build", title: "Running", subtitle: nil, symbol: nil,
      accentHex: nil, progress: 0.5, state: .progress, priority: .normal,
      expiresAt: nil, actions: nil)
    XCTAssertTrue(center.apply(command(.show, payload, revision: 10), now: now).ok)
    let end = PulseCommand(
      token: "test", operation: .end, activity: nil, id: payload.id,
      source: payload.source, revision: 11)
    XCTAssertTrue(center.apply(end, now: now).ok)
    XCTAssertTrue(center.items.isEmpty)

    payload.title = "Delayed"
    XCTAssertEqual(
      center.apply(command(.update, payload, revision: 10), now: now).errorCode,
      .staleRevision)
    payload.title = "Accidental revival"
    XCTAssertEqual(
      center.apply(command(.update, payload, revision: 12), now: now).errorCode,
      .generationEnded)
    XCTAssertTrue(center.items.isEmpty)

    payload.title = "New lifecycle"
    XCTAssertTrue(center.apply(command(.show, payload, revision: 12), now: now).ok)
    XCTAssertEqual(center.items.first?.title, "New lifecycle")
    XCTAssertEqual(center.apply(end, now: now).errorCode, .staleRevision)
  }

  @MainActor
  func testOrderedEndBeforeShowLeavesATombstone() {
    let center = makeCenter()
    let now = Date(timeIntervalSince1970: 5_000)
    let end = PulseCommand(
      token: "test", operation: .end, activity: nil, id: "queued", source: "build",
      revision: 5)
    XCTAssertTrue(center.apply(end, now: now).ok)

    let payload = PulsePayload(
      id: "queued", source: "build", title: "Old work", subtitle: nil, symbol: nil,
      accentHex: nil, progress: nil, state: .active, priority: .normal,
      expiresAt: nil, actions: nil)
    XCTAssertEqual(
      center.apply(command(.show, payload, revision: 4), now: now).errorCode,
      .staleRevision)
    XCTAssertEqual(
      center.apply(command(.update, payload, revision: 6), now: now).errorCode,
      .generationEnded)
    XCTAssertTrue(center.apply(command(.show, payload, revision: 6), now: now).ok)
  }

  @MainActor
  func testOrderedEndRequiresSourceEvenWhenIdentityIsActive() {
    let center = makeCenter()
    let payload = PulsePayload(
      id: "active", source: "build", title: "Running", subtitle: nil, symbol: nil,
      accentHex: nil, progress: nil, state: .active, priority: .normal,
      expiresAt: nil, actions: nil)
    XCTAssertTrue(center.apply(command(.show, payload, revision: 1)).ok)
    let end = PulseCommand(
      token: "test", operation: .end, activity: nil, id: "active", revision: 2)

    let response = center.apply(end)

    XCTAssertFalse(response.ok)
    XCTAssertEqual(response.errorCode, .invalidCommand)
    XCTAssertEqual(center.items.first?.title, "Running")
  }

  @MainActor
  func testEndedGenerationCannotReviveAcrossRestart() {
    let now = Date(timeIntervalSince1970: 6_000)
    let persistence = PulseRevisionPersistenceBox()
    let payload = PulsePayload(
      id: "restart", source: "build", title: "Current", subtitle: nil, symbol: nil,
      accentHex: nil, progress: nil, state: .active, priority: .normal,
      expiresAt: nil, actions: nil)
    let firstProcess = makeCenter(
      clock: TestPulseClock(now: now), revisionStore: persistence.store)
    XCTAssertTrue(firstProcess.apply(command(.show, payload, revision: 100), now: now).ok)
    XCTAssertTrue(
      firstProcess.apply(
        PulseCommand(
          token: "test", operation: .end, activity: nil, id: payload.id,
          source: payload.source, revision: 101), now: now
      ).ok)
    firstProcess.flushRevisionPersistence()

    let restartedProcess = makeCenter(
      clock: TestPulseClock(now: now), revisionStore: persistence.store)
    let delayed = restartedProcess.apply(command(.update, payload, revision: 102), now: now)
    XCTAssertFalse(delayed.ok)
    XCTAssertEqual(delayed.errorCode, .generationEnded)
    XCTAssertTrue(restartedProcess.items.isEmpty)
  }

  @MainActor
  func testPersistedRevisionStateExpiresAfterThirtyDays() {
    let persistence = PulseRevisionPersistenceBox()
    let initialDate = Date(timeIntervalSince1970: 7_000)
    let end = PulseCommand(
      token: "test", operation: .end, activity: nil, id: "old-generation", source: "build",
      revision: 50)
    let firstProcess = makeCenter(
      clock: TestPulseClock(now: initialDate), revisionStore: persistence.store)
    XCTAssertTrue(firstProcess.apply(end, now: initialDate).ok)
    firstProcess.flushRevisionPersistence()

    let afterRetention = initialDate.addingTimeInterval(31 * 24 * 60 * 60)
    let restartedProcess = makeCenter(
      clock: TestPulseClock(now: afterRetention), revisionStore: persistence.store)
    let payload = PulsePayload(
      id: "old-generation", source: "build", title: "Fresh baseline", subtitle: nil,
      symbol: nil, accentHex: nil, progress: nil, state: .active, priority: .normal,
      expiresAt: nil, actions: nil)

    let response = restartedProcess.apply(
      command(.update, payload, revision: 1), now: afterRetention)

    XCTAssertTrue(response.ok)
    XCTAssertEqual(restartedProcess.items.first?.title, "Fresh baseline")
  }

  @MainActor
  func testPersistedRevisionStateExcludesProviderPayloadAndToken() throws {
    let persistence = PulseRevisionPersistenceBox()
    let center = makeCenter(revisionStore: persistence.store)
    let payload = PulsePayload(
      id: "private-job", source: "build", title: "private title",
      subtitle: "private details", symbol: nil, accentHex: nil, progress: 0.4,
      state: .progress, priority: .normal, expiresAt: nil,
      actions: [
        PulseAction(
          title: "private action", url: URL(string: "https://example.com/private-path")!)
      ])
    let command = PulseCommand(
      token: "private-token", operation: .show, activity: payload, id: nil, revision: 4)

    XCTAssertTrue(center.apply(command, now: Date(timeIntervalSince1970: 8_000)).ok)
    center.flushRevisionPersistence()

    let data = try XCTUnwrap(persistence.data)
    let storedText = String(decoding: data, as: UTF8.self)
    XCTAssertFalse(storedText.contains("private title"))
    XCTAssertFalse(storedText.contains("private details"))
    XCTAssertFalse(storedText.contains("private action"))
    XCTAssertFalse(storedText.contains("private-path"))
    XCTAssertFalse(storedText.contains("private-token"))
  }

  @MainActor
  func testRevisionPersistenceCoalescesABurstAndKeepsTheNewestRevision() {
    let persistence = PulseRevisionPersistenceBox()
    let now = Date(timeIntervalSince1970: 8_500)
    let center = makeCenter(
      clock: TestPulseClock(now: now), revisionStore: persistence.store,
      revisionPersistenceDelay: 60)
    let payload = PulsePayload(
      id: "coalesced", source: "build", title: "Running", subtitle: nil, symbol: nil,
      accentHex: nil, progress: nil, state: .active, priority: .normal,
      expiresAt: nil, actions: nil)

    for revision in 1...50 {
      XCTAssertTrue(center.apply(command(.show, payload, revision: UInt64(revision)), now: now).ok)
    }
    XCTAssertEqual(persistence.writeCount, 0)

    center.flushRevisionPersistence()
    XCTAssertEqual(persistence.writeCount, 1)

    let restarted = makeCenter(
      clock: TestPulseClock(now: now), revisionStore: persistence.store,
      revisionPersistenceDelay: 60)
    XCTAssertEqual(
      restarted.apply(command(.show, payload, revision: 49), now: now).errorCode,
      .staleRevision)
    XCTAssertTrue(restarted.apply(command(.show, payload, revision: 51), now: now).ok)
  }

  @MainActor
  func testClearingItemsKeepsRevisionOrdering() {
    let center = makeCenter()
    let now = Date(timeIntervalSince1970: 6_500)
    var payload = PulsePayload(
      id: "disabled", source: "build", title: "Before disable", subtitle: nil, symbol: nil,
      accentHex: nil, progress: nil, state: .active, priority: .normal,
      expiresAt: nil, actions: nil)
    XCTAssertTrue(center.apply(command(.show, payload, revision: 5), now: now).ok)

    center.removeAll(now: now)
    XCTAssertTrue(center.items.isEmpty)
    payload.title = "Delayed while restarting"
    XCTAssertEqual(
      center.apply(command(.update, payload, revision: 4), now: now).errorCode,
      .staleRevision)

    payload.title = "Provider reconnected"
    XCTAssertTrue(center.apply(command(.update, payload, revision: 6), now: now).ok)
    XCTAssertEqual(center.items.first?.title, "Provider reconnected")
  }

  @MainActor
  func testRevisionOrderingIsIndependentPerSourceNamespace() {
    let center = makeCenter()
    let now = Date(timeIntervalSince1970: 7_000)
    let build = PulsePayload(
      id: "shared", source: "build", title: "Build", subtitle: nil, symbol: nil,
      accentHex: nil, progress: nil, state: .active, priority: .normal,
      expiresAt: nil, actions: nil)
    var agent = build
    agent.source = "agent"
    agent.title = "Agent"

    XCTAssertTrue(center.apply(command(.show, build, revision: 20), now: now).ok)
    XCTAssertTrue(center.apply(command(.show, agent, revision: 1), now: now).ok)
    XCTAssertEqual(center.items.count, 2)
  }

  func testRevisionIdentityLimitsUseUTF8Bytes() throws {
    XCTAssertThrowsError(
      try PulseItem.ID(
        source: String(repeating: "é", count: 41), providerIdentifier: "item"))
    XCTAssertThrowsError(
      try PulseItem.ID(
        source: "build",
        providerIdentifier: String(repeating: "é", count: 65)))

    XCTAssertNoThrow(
      try PulseItem.ID(
        source: String(repeating: "é", count: 40),
        providerIdentifier: String(repeating: "é", count: 64)))
  }

  func testRevisionPersistenceReportsAnOversizedSnapshot() throws {
    let persistence = PulseRevisionPersistenceBox()
    let id = try PulseItem.ID(source: "build", providerIdentifier: "item")
    let records = [
      id: PulseRevisionRecord(
        id: id, revision: 1, ended: false,
        acceptedAt: Date(timeIntervalSince1970: 8_000))
    ]

    XCTAssertFalse(
      PulseRevisionPersistence.save(records, to: persistence.store, maximumBytes: 1))
    XCTAssertEqual(persistence.writeCount, 0)
  }

  @MainActor
  func testRevisionTrackingCapacityKeepsExistingStreamsUsable() {
    let center = makeCenter()
    for index in 0..<PulseCenter.maximumRevisionRecords {
      let end = PulseCommand(
        token: "test", operation: .end, activity: nil, id: "item-\(index)",
        source: "build", revision: 0)
      XCTAssertTrue(center.apply(end).ok)
    }

    let overflow = PulseCommand(
      token: "test", operation: .end, activity: nil, id: "overflow", source: "build",
      revision: 0)
    XCTAssertEqual(center.apply(overflow).errorCode, .capacityExceeded)
    let existing = PulseCommand(
      token: "test", operation: .end, activity: nil, id: "item-0", source: "build",
      revision: 1)
    XCTAssertTrue(center.apply(existing).ok)
  }

  @MainActor
  func testDirectCommandsRejectRevisionsAboveThePortableJSONLimit() {
    let center = makeCenter()
    let payload = PulsePayload(
      id: "too-large", source: "build", title: "Too large", subtitle: nil, symbol: nil,
      accentHex: nil, progress: nil, state: .active, priority: .normal,
      expiresAt: nil, actions: nil)

    let response = center.apply(
      command(.show, payload, revision: PulseRevision.maximum + 1))

    XCTAssertFalse(response.ok)
    XCTAssertEqual(response.errorCode, .validationFailed)
    XCTAssertTrue(center.items.isEmpty)
  }

  @MainActor
  func testProgressOutsideProtocolRangeIsRejected() {
    let center = makeCenter()
    let payload = PulsePayload(
      id: "overflow", source: "tests", title: "Overflow", subtitle: nil, symbol: nil,
      accentHex: nil, progress: 1.01, state: .progress, priority: .normal,
      expiresAt: nil, actions: nil)
    let response = center.apply(command(.show, payload), now: Date(timeIntervalSince1970: 1_000))
    XCTAssertFalse(response.ok)
    XCTAssertEqual(response.errorCode, .validationFailed)
  }

  @MainActor
  func testCancelledStateRemainsDistinct() {
    let center = makeCenter()
    let payload = PulsePayload(
      id: "cancelled", source: "github-actions", title: "CI cancelled", subtitle: nil,
      symbol: nil, accentHex: nil, progress: nil, state: .cancelled, priority: .low,
      expiresAt: nil, actions: nil)

    XCTAssertTrue(
      center.apply(command(.event, payload), now: Date(timeIntervalSince1970: 1_000)).ok)
    XCTAssertEqual(center.items.first?.state, .cancelled)
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

    let center = makeCenter(symbolAvailability: { _ in false })
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

    let emptyCenter = makeCenter(symbolAvailability: { _ in true })
    let emptyResponse = emptyCenter.apply(command(.show, payload), now: now)
    XCTAssertTrue(emptyResponse.ok)
    XCTAssertEqual(emptyResponse.warning, PulseSymbolWarning.empty.localizedDescription)

    payload.id = "platform-unavailable-symbol"
    payload.symbol = "checkmark.circle.fill"
    let unavailable = try PulseItem(
      payload: payload, now: now, symbolAvailability: { _ in nil })
    XCTAssertEqual(unavailable.symbol, PulseSymbolValidator.fallbackSymbol)
    XCTAssertEqual(unavailable.symbolWarning, .platformUnavailable)

    let center = makeCenter(symbolAvailability: { _ in nil })
    let response = center.apply(command(.show, payload), now: now)
    XCTAssertTrue(response.ok)
    XCTAssertEqual(response.warning, PulseSymbolWarning.platformUnavailable.localizedDescription)
  }

  @MainActor
  func testProvidersCannotSetIsletManagedStaleState() {
    let center = makeCenter()
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
    let center = makeCenter()
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
  func testDeliveryProfileSurvivesCenterRecreationBeforeFirstItem() throws {
    let suiteName = "PulseTests.delivery-profile.\(UUID().uuidString)"
    let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { suite.removePersistentDomain(forName: suiteName) }
    let key = Defaults.Key<PulseDeliveryProfile>(
      "pulseDeliveryProfile", default: .everything, suite: suite)

    let firstLaunch = PulseCenter(deliveryProfileKey: key)
    firstLaunch.deliveryProfile = .focused

    let relaunched = PulseCenter(deliveryProfileKey: key)
    XCTAssertEqual(relaunched.deliveryProfile, .focused)
    let normal = PulsePayload(
      id: "background", source: "tests", title: "Background", subtitle: nil,
      symbol: nil, accentHex: nil, progress: nil, state: .active, priority: .normal,
      expiresAt: nil, actions: nil)
    XCTAssertTrue(relaunched.apply(command(.show, normal)).ok)
    XCTAssertTrue(relaunched.items.isEmpty)
    XCTAssertEqual(relaunched.history.first?.result, .suppressed)
  }

  @MainActor
  func testUnknownPersistedDeliveryProfileUsesSafeFallback() throws {
    let suiteName = "PulseTests.delivery-profile-fallback.\(UUID().uuidString)"
    let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { suite.removePersistentDomain(forName: suiteName) }
    let key = Defaults.Key<PulseDeliveryProfile>(
      "pulseDeliveryProfile", default: .everything, suite: suite)
    suite.set("future-profile", forKey: key.name)

    let center = PulseCenter(deliveryProfileKey: key)

    XCTAssertEqual(center.deliveryProfile, .everything)
  }

  @MainActor
  func testSourcePoliciesSurviveCenterRecreationBeforeTheFirstProviderItem() throws {
    let suiteName = "PulseTests.source-policies.\(UUID().uuidString)"
    let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { suite.removePersistentDomain(forName: suiteName) }
    let deliveryProfileKey = Defaults.Key<PulseDeliveryProfile>(
      "pulseDeliveryProfile", default: .everything, suite: suite)
    let sourcePoliciesKey = Defaults.Key<[String: String]>(
      "pulseSourcePolicies", default: [:], suite: suite)

    let firstLaunch = PulseCenter(
      deliveryProfileKey: deliveryProfileKey, sourcePoliciesKey: sourcePoliciesKey)
    firstLaunch.setPolicy(.muted, for: "  Build  ")
    firstLaunch.setPolicy(.revoked, for: "Agent")
    XCTAssertEqual(Defaults[sourcePoliciesKey], ["agent": "revoked", "build": "muted"])

    let relaunched = PulseCenter(
      deliveryProfileKey: deliveryProfileKey, sourcePoliciesKey: sourcePoliciesKey)
    let muted = PulsePayload(
      id: "build", source: "BUILD", title: "Build", subtitle: nil, symbol: nil,
      accentHex: nil, progress: nil, state: .active, priority: .normal,
      expiresAt: nil, actions: nil)
    let revoked = PulsePayload(
      id: "agent", source: "agent", title: "Agent", subtitle: nil, symbol: nil,
      accentHex: nil, progress: nil, state: .active, priority: .normal,
      expiresAt: nil, actions: nil)

    XCTAssertEqual(relaunched.policy(for: "build"), .muted)
    XCTAssertEqual(relaunched.policy(for: "AGENT"), .revoked)
    XCTAssertTrue(relaunched.apply(command(.show, muted)).ok)
    XCTAssertTrue(relaunched.items.isEmpty)
    XCTAssertEqual(relaunched.history.first?.result, .suppressed)
    XCTAssertFalse(relaunched.apply(command(.show, revoked)).ok)
    XCTAssertEqual(relaunched.history.first?.result, .rejected)
  }

  @MainActor
  func testSourcePolicyMigrationNormalizesEntriesAndDropsUnknownData() throws {
    let suiteName = "PulseTests.source-policy-migration.\(UUID().uuidString)"
    let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { suite.removePersistentDomain(forName: suiteName) }
    let deliveryProfileKey = Defaults.Key<PulseDeliveryProfile>(
      "pulseDeliveryProfile", default: .everything, suite: suite)
    let sourcePoliciesKey = Defaults.Key<[String: String]>(
      "pulseSourcePolicies", default: [:], suite: suite)
    suite.set(
      [
        " Build ": "muted",
        "build": "revoked",
        "agent": "allowed",
        "future": "blocked",
        "   ": "muted",
      ], forKey: sourcePoliciesKey.name)

    let center = PulseCenter(
      deliveryProfileKey: deliveryProfileKey, sourcePoliciesKey: sourcePoliciesKey)

    XCTAssertEqual(center.sourcePolicies, ["build": .revoked])
    XCTAssertEqual(Defaults[sourcePoliciesKey], ["build": "revoked"])
  }

  @MainActor
  func testCorruptSourcePolicyStorageFallsBackToAllowingUpdates() throws {
    let suiteName = "PulseTests.corrupt-source-policies.\(UUID().uuidString)"
    let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { suite.removePersistentDomain(forName: suiteName) }
    let deliveryProfileKey = Defaults.Key<PulseDeliveryProfile>(
      "pulseDeliveryProfile", default: .everything, suite: suite)
    let sourcePoliciesKey = Defaults.Key<[String: String]>(
      "pulseSourcePolicies", default: [:], suite: suite)
    suite.set("not a source-policy map", forKey: sourcePoliciesKey.name)

    let center = PulseCenter(
      deliveryProfileKey: deliveryProfileKey, sourcePoliciesKey: sourcePoliciesKey)
    let payload = PulsePayload(
      id: "build", source: "build", title: "Build", subtitle: nil, symbol: nil,
      accentHex: nil, progress: nil, state: .active, priority: .normal,
      expiresAt: nil, actions: nil)

    XCTAssertEqual(center.sourcePolicies, [:])
    XCTAssertEqual(Defaults[sourcePoliciesKey], [:])
    XCTAssertEqual(suite.dictionary(forKey: sourcePoliciesKey.name)?.count, 0)
    XCTAssertTrue(center.apply(command(.show, payload)).ok)
    XCTAssertEqual(center.items.map(\.providerIdentifier), ["build"])
  }

  @MainActor
  func testSourcePolicyCanMuteRevealAndRevokeOnlyItsProviderNamespace() throws {
    let center = makeCenter()
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
  func testHistoryIsBoundedAndStoresOnlyWireMetadata() throws {
    let center = makeCenter()
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
    let center = makeCenter()
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
  func testProviderHealthReportsNeedsAttentionFromProviderState() throws {
    let center = makeCenter()
    let now = Date(timeIntervalSince1970: 1_000)
    let payload = PulsePayload(
      id: "github-actions-health", source: "github-actions",
      title: "GitHub authentication required", subtitle: nil, symbol: nil,
      accentHex: nil, progress: nil, state: .needsAction, priority: .critical,
      expiresAt: now.addingTimeInterval(60), actions: nil)

    XCTAssertTrue(center.apply(command(.update, payload), now: now).ok)
    let status = try XCTUnwrap(center.providerStatuses.first { $0.id == "github-actions" })
    XCTAssertEqual(status.health, .needsAttention(1))
  }

  @MainActor
  func testRejectedPayloadHistoryDoesNotRetainUnvalidatedContent() throws {
    let center = makeCenter()
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

  func testWireValidatorAndDecoderEnforceSafeIntegerRevisions() throws {
    let valid = Data(
      #"{"token":"token","operation":"end","id":"id","source":"tests","revision":9007199254740991}"#
        .utf8)
    XCTAssertNoThrow(try PulseWireValidator.validate(valid))
    XCTAssertEqual(
      try PulseWireCodec.decoder().decode(PulseCommand.self, from: valid).revision,
      PulseRevision.maximum)

    for value in ["-1", "1.5", "true", "9007199254740992"] {
      let invalid = Data(
        "{\"token\":\"token\",\"operation\":\"end\",\"id\":\"id\",\"revision\":\(value)}"
          .utf8)
      XCTAssertThrowsError(try PulseWireValidator.validate(invalid))
    }
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
    let center = makeCenter()
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
    let center = makeCenter(
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
    let center = makeCenter(
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
    XCTAssertEqual(
      center.providerStatuses.first { $0.id == "cli" }?.health,
      .seen(Date(timeIntervalSince1970: 1_010)))
  }

  @MainActor
  func testValidUpdateRefreshesDeadlineAndRecoversStaleWork() throws {
    let clock = TestPulseClock(now: Date(timeIntervalSince1970: 2_000))
    let scheduler = TestPulseDeadlineScheduler(clock: clock)
    let center = makeCenter(
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
    let center = makeCenter(
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
    let center = makeCenter(
      staleTimeout: 10, staleRetention: 20, clock: clock, scheduler: scheduler)
    for state in [PulseState.succeeded, .failed, .cancelled] {
      let payload = PulsePayload(
        id: state.rawValue, source: "cli", title: state.rawValue, subtitle: nil, symbol: nil,
        accentHex: nil, progress: 1, state: state, priority: .normal,
        expiresAt: nil, actions: nil)

      XCTAssertTrue(center.apply(command(.show, payload)).ok)
      XCTAssertNil(center.items.first { $0.providerIdentifier == state.rawValue }?.staleAt)
    }
    XCTAssertEqual(scheduler.pendingCount, 0)
    scheduler.advance(to: Date(timeIntervalSince1970: 10_000))
    XCTAssertEqual(Set(center.items.map(\.state)), [.succeeded, .failed, .cancelled])
  }

  @MainActor
  func testChangingTimeoutRecomputesExistingLiveDeadline() {
    let clock = TestPulseClock(now: Date(timeIntervalSince1970: 6_000))
    let scheduler = TestPulseDeadlineScheduler(clock: clock)
    let center = makeCenter(
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
  func testPulseBindsNumericIPv4AndIPv6LoopbackAndAdvertisesLocalhost() async throws {
    var requestedPorts: [UInt16] = []
    var requestedEndpoints: [NWEndpoint] = []
    var listeners: [FakePulseListener] = []
    let server = PulseServer(
      listenerFactory: { parameters, port in
        requestedPorts.append(port.rawValue)
        if let endpoint = parameters.requiredLocalEndpoint { requestedEndpoints.append(endpoint) }
        let listener = FakePulseListener(port: port)
        listeners.append(listener)
        return listener
      },
      tokenLoader: { Self.testToken }, activePortWriter: { _ in }, activePortRemover: {})

    server.start()

    XCTAssertEqual(requestedPorts, [47_717, 47_717])
    XCTAssertEqual(
      requestedEndpoints,
      [
        .hostPort(host: "127.0.0.1", port: .any),
        .hostPort(host: "::1", port: .any),
      ])
    XCTAssertFalse(
      requestedEndpoints.contains(.hostPort(host: "localhost", port: .any)))
    listeners[0].emit(.ready)
    await Task.yield()
    XCTAssertFalse(server.isRunning)
    listeners[1].emit(.ready)
    await Task.yield()

    XCTAssertTrue(server.isRunning)
    XCTAssertEqual(server.listeningAddress, "localhost:47717")
    server.stop()
  }

  func testPulsePeerValidationAcceptsIPv4AndIPv6LoopbackButRejectsNonLoopback() {
    let port = PulsePaths.defaultPort
    XCTAssertTrue(PulseServer.isLoopbackPeer(.hostPort(host: "127.0.0.1", port: port)))
    XCTAssertTrue(PulseServer.isLoopbackPeer(.hostPort(host: "::1", port: port)))
    XCTAssertFalse(PulseServer.isLoopbackPeer(.hostPort(host: "192.168.1.2", port: port)))
    XCTAssertFalse(PulseServer.isLoopbackPeer(.hostPort(host: "fe80::1", port: port)))
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
    XCTAssertEqual(requestedPorts, [47_717, 47_717])
    listeners[0].emit(.failed(.posix(.EADDRINUSE)))
    await Task.yield()

    XCTAssertEqual(requestedPorts, [47_717, 47_717, 47_718, 47_718])
    XCTAssertEqual(requestedHosts, ["127.0.0.1", "::1", "127.0.0.1", "::1"])
    XCTAssertFalse(server.isRunning)
    XCTAssertNil(server.activePort)

    listeners[2].emit(.ready)
    listeners[3].emit(.ready)
    await Task.yield()

    XCTAssertTrue(server.isRunning)
    XCTAssertEqual(server.activePort, 47_718)
    XCTAssertEqual(server.listeningAddress, "localhost:47718")
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

  func testRecoverableListenerFailureClassificationExcludesPermanentErrors() {
    XCTAssertTrue(PulseServer.isRecoverableListenerFailure(NWError.posix(.ETIMEDOUT)))
    XCTAssertTrue(PulseServer.isRecoverableListenerFailure(NWError.posix(.ENETDOWN)))
    XCTAssertFalse(PulseServer.isRecoverableListenerFailure(NWError.posix(.EACCES)))
    XCTAssertFalse(PulseServer.isRecoverableListenerFailure(NWError.posix(.EADDRINUSE)))
  }

  func testRetryDelayUsesBoundedExponentialBackoff() {
    XCTAssertEqual(PulseServer.retryDelay(for: 0), 0)
    XCTAssertEqual(PulseServer.retryDelay(for: 1), 1)
    XCTAssertEqual(PulseServer.retryDelay(for: 2), 2)
    XCTAssertEqual(PulseServer.retryDelay(for: 6), 32)
    XCTAssertEqual(PulseServer.retryDelay(for: 7), 60)
    XCTAssertEqual(PulseServer.retryDelay(for: 100), 60)
  }

  @MainActor
  func testRecoverableFailureRetriesAtScheduledTimeAndPublishesIt() async {
    let scheduler = TestPulseRetryScheduler()
    let now = Date(timeIntervalSince1970: 1_000)
    var listeners: [FakePulseListener] = []
    let server = PulseServer(
      listenerFactory: { _, port in
        let listener = FakePulseListener(port: port)
        listeners.append(listener)
        return listener
      },
      tokenLoader: { Self.testToken }, activePortWriter: { _ in }, activePortRemover: {},
      now: { now }, retryScheduler: scheduler.schedule)

    server.start()
    listeners[0].emit(.failed(.posix(.ETIMEDOUT)))
    await Task.yield()

    XCTAssertEqual(scheduler.delays, [1])
    XCTAssertEqual(server.nextRetryAt, now.addingTimeInterval(1))
    XCTAssertTrue(server.lastError?.contains("Retrying at") ?? false)
    XCTAssertFalse(server.isRunning)

    scheduler.fire(at: 0)
    XCTAssertEqual(listeners.count, 4)
    XCTAssertNil(server.nextRetryAt)
    server.stop()
  }

  @MainActor
  func testStoppingOrRestartingPulseMakesQueuedRetryCallbacksHarmless() async {
    let scheduler = TestPulseRetryScheduler()
    var listeners: [FakePulseListener] = []
    let server = PulseServer(
      listenerFactory: { _, port in
        let listener = FakePulseListener(port: port)
        listeners.append(listener)
        return listener
      },
      tokenLoader: { Self.testToken }, activePortWriter: { _ in }, activePortRemover: {},
      retryScheduler: scheduler.schedule)

    server.start()
    listeners[0].emit(.failed(.posix(.ETIMEDOUT)))
    await Task.yield()
    server.stop()

    XCTAssertTrue(scheduler.tasks[0].cancelled)
    XCTAssertNil(server.nextRetryAt)
    scheduler.fire(at: 0)
    XCTAssertEqual(listeners.count, 2)

    server.start()
    XCTAssertEqual(listeners.count, 4)
    scheduler.fire(at: 0)
    XCTAssertEqual(listeners.count, 4)
    server.stop()
  }

  @MainActor
  func testRotatingTokenDuringBackoffRestartsPulseAndCancelsQueuedRetry() async throws {
    let scheduler = TestPulseRetryScheduler()
    var listeners: [FakePulseListener] = []
    var storedToken = Self.testToken
    let replacementToken = Data(repeating: 1, count: 32).base64EncodedString()
    let server = PulseServer(
      listenerFactory: { _, port in
        let listener = FakePulseListener(port: port)
        listeners.append(listener)
        return listener
      },
      tokenLoader: { storedToken },
      tokenRotator: {
        storedToken = replacementToken
        return replacementToken
      },
      activePortWriter: { _ in }, activePortRemover: {}, retryScheduler: scheduler.schedule)

    server.start()
    listeners[0].emit(.failed(.posix(.ETIMEDOUT)))
    await Task.yield()
    XCTAssertEqual(listeners.count, 2)
    XCTAssertNotNil(server.nextRetryAt)

    try server.rotateToken()

    XCTAssertEqual(server.token, replacementToken)
    XCTAssertEqual(listeners.count, 4)
    XCTAssertTrue(scheduler.tasks[0].cancelled)
    XCTAssertNil(server.nextRetryAt)
    scheduler.fire(at: 0)
    XCTAssertEqual(listeners.count, 4)
    server.stop()
  }

  @MainActor
  func testStableReadyPeriodResetsRetryBackoff() async {
    let scheduler = TestPulseRetryScheduler()
    var listeners: [FakePulseListener] = []
    let server = PulseServer(
      listenerFactory: { _, port in
        let listener = FakePulseListener(port: port)
        listeners.append(listener)
        return listener
      },
      tokenLoader: { Self.testToken }, activePortWriter: { _ in }, activePortRemover: {},
      retryScheduler: scheduler.schedule)

    server.start()
    listeners[0].emit(.failed(.posix(.ETIMEDOUT)))
    await Task.yield()
    scheduler.fire(at: 0)
    listeners[2].emit(.ready)
    listeners[3].emit(.ready)
    await Task.yield()

    XCTAssertEqual(scheduler.delays, [1, PulseServer.retryStableReadyPeriod])
    scheduler.fire(at: 1)
    listeners[2].emit(.failed(.posix(.ETIMEDOUT)))
    await Task.yield()

    XCTAssertEqual(scheduler.delays.last, 1)
    server.stop()
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
    let center = makeCenter()
    let payload = PulsePayload(
      id: "private", source: "shortcuts", title: "Private title", subtitle: "Private details",
      symbol: nil, accentHex: nil, progress: 0.5, state: .progress, priority: .normal,
      expiresAt: nil, actions: nil)

    let response = center.applyIfEnabled(command(.update, payload), activityEnabled: false)

    XCTAssertFalse(response.ok)
    XCTAssertEqual(response.errorCode, .featureDisabled)
    XCTAssertEqual(center.retainedItemCount, 0)
  }

  private func command(
    _ operation: PulseOperation, _ payload: PulsePayload, revision: UInt64? = nil
  ) -> PulseCommand {
    PulseCommand(
      token: "test", operation: operation, activity: payload, id: nil,
      revision: revision)
  }

  @MainActor
  private func makeCenter(
    staleTimeout: TimeInterval = PulseStalenessPolicy.defaultTimeout,
    staleRetention: TimeInterval = PulseStalenessPolicy.defaultRetention,
    clock: (any PulseClock)? = nil,
    scheduler: (any PulseDeadlineScheduling)? = nil,
    revisionStore: PulseRevisionPersistenceStore? = nil,
    revisionPersistenceDelay: TimeInterval = PulseRevisionPersistenceWriter.defaultCoalescingDelay,
    symbolAvailability: @escaping (String) -> Bool? = PulseSymbolValidator.platformAvailability
  ) -> PulseCenter {
    let key = Defaults.Key<PulseDeliveryProfile>(
      "pulseDeliveryProfile", default: .everything, suite: deliveryProfileSuite)
    let sourcePoliciesKey = Defaults.Key<[String: String]>(
      "pulseSourcePolicies", default: [:], suite: deliveryProfileSuite)
    return PulseCenter(
      staleTimeout: staleTimeout, staleRetention: staleRetention, clock: clock,
      scheduler: scheduler, revisionStore: revisionStore,
      revisionPersistenceDelay: revisionPersistenceDelay, symbolAvailability: symbolAvailability,
      deliveryProfileKey: key, sourcePoliciesKey: sourcePoliciesKey)
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

@MainActor
private final class TestPulseRetryScheduler {
  final class Task: PulseRetryCancellable {
    private(set) var cancelled = false
    let action: @MainActor @Sendable () -> Void

    init(action: @escaping @MainActor @Sendable () -> Void) {
      self.action = action
    }

    func cancel() { cancelled = true }
  }

  private(set) var delays: [TimeInterval] = []
  private(set) var tasks: [Task] = []

  func schedule(
    after delay: TimeInterval, action: @escaping @MainActor @Sendable () -> Void
  ) -> any PulseRetryCancellable {
    delays.append(delay)
    let task = Task(action: action)
    tasks.append(task)
    return task
  }

  func fire(at index: Int) { tasks[index].action() }
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

private final class PulseRevisionPersistenceBox: @unchecked Sendable {
  private let lock = NSLock()
  private var storedData: Data?
  private var writes = 0

  var data: Data? {
    lock.lock()
    defer { lock.unlock() }
    return storedData
  }

  var writeCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return writes
  }

  var store: PulseRevisionPersistenceStore {
    PulseRevisionPersistenceStore(
      readData: { [weak self] in self?.data },
      writeData: { [weak self] data in
        guard let self else { return }
        lock.lock()
        storedData = data
        writes += 1
        lock.unlock()
      })
  }
}
