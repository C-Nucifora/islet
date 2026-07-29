import Defaults
import SwiftUI
import XCTest

@testable import Islet

final class SystemEventTests: XCTestCase {
  // MARK: - Identity and equality

  /// Two events describing the same thing must compare equal so the coalescer and the queue can
  /// deduplicate them. `id` is per-instance and deliberately excluded from `==`.
  func testEqualityIgnoresIdentity() {
    let a = SystemEvent(sourceID: "usb", icon: "cable.connector", title: "Keyboard connected")
    let b = SystemEvent(sourceID: "usb", icon: "cable.connector", title: "Keyboard connected")
    XCTAssertNotEqual(a.id, b.id)
    XCTAssertEqual(a, b)
  }

  func testEqualityDistinguishesContent() {
    let a = SystemEvent(sourceID: "usb", icon: "cable.connector", title: "Keyboard connected")
    let b = SystemEvent(sourceID: "usb", icon: "cable.connector", title: "Mouse connected")
    XCTAssertNotEqual(a, b)
  }

  // MARK: - Defaults

  func testDefaultsMatchTheExistingSneakDefaults() {
    let e = SystemEvent(sourceID: "x", icon: "circle", title: "T")
    XCTAssertEqual(e.duration, 2)  // Sneak.duration's default
    XCTAssertEqual(e.motion, .generic)
    XCTAssertEqual(e.urgency, .normal)
    XCTAssertNil(e.subtitle)
    XCTAssertEqual(e.accentHex, EventAccent.neutral)
  }

  /// The announcement is what VoiceOver speaks. Falling back to title + subtitle means a source that
  /// forgets to set one is still accessible rather than silent.
  func testAnnouncementFallsBackToTitleAndSubtitle() {
    let bare = SystemEvent(sourceID: "x", icon: "circle", title: "Wi-Fi connected")
    XCTAssertEqual(bare.spokenAnnouncement, "Wi-Fi connected")

    let withSub = SystemEvent(
      sourceID: "x", icon: "circle", title: "Wi-Fi connected", subtitle: "Home")
    XCTAssertEqual(withSub.spokenAnnouncement, "Wi-Fi connected, Home")

    let explicit = SystemEvent(
      sourceID: "x", icon: "circle", title: "Wi-Fi connected", subtitle: "Home",
      announcement: "Joined the Home network")
    XCTAssertEqual(explicit.spokenAnnouncement, "Joined the Home network")
  }

  // MARK: - Urgency ordering

  func testUrgencyOrders() {
    XCTAssertLessThan(SystemEventUrgency.ambient, SystemEventUrgency.normal)
    XCTAssertLessThan(SystemEventUrgency.normal, SystemEventUrgency.alert)
  }

  // MARK: - Accent palette

  /// Every accent must survive the round trip through ColorHex, or the sneak renders with no tint.
  func testEveryAccentParsesAsAColor() {
    for hex in [
      EventAccent.neutral, EventAccent.positive, EventAccent.warning,
      EventAccent.danger, EventAccent.info,
    ] {
      XCTAssertNotNil(Color(isletHex: hex), "accent \(hex) did not parse")
    }
  }

  // MARK: - Source catalogue

  /// The catalogue is the single list Settings, the Debug menu and the bus all read. A duplicate id
  /// would silently give two sources the same toggle.
  func testCatalogueIDsAreUnique() {
    let ids = SourceCatalog.all.map(\.id)
    XCTAssertEqual(Set(ids).count, ids.count, "duplicate source id in SourceCatalog")
  }

  func testCatalogueIsGroupedByTierWithNothingOrphaned() {
    let grouped = SystemEventTier.allCases.flatMap { SourceCatalog.ids(in: $0) }
    XCTAssertEqual(Set(grouped), Set(SourceCatalog.all.map(\.id)))
  }

  func testCatalogueLookupsFallBackToTheRawID() {
    XCTAssertEqual(SourceCatalog.name(for: "usb"), "USB devices")
    XCTAssertEqual(SourceCatalog.name(for: "nope"), "nope")
    XCTAssertEqual(SourceCatalog.tier(for: "nope"), .core)
  }

  /// Every Tier 3 source must be reachable through the tier query, because that is what puts the
  /// "may be late or wrong" caption above them in Settings.
  func testHeuristicTierContainsTheInferredSources() {
    let heuristic = Set(SourceCatalog.ids(in: .heuristic))
    XCTAssertTrue(heuristic.contains("airdropIn"))
    XCTAssertTrue(heuristic.contains("focus"))
    XCTAssertTrue(heuristic.contains("vpn"))
  }

  /// Every source object the app registers must have a catalogue row, or it silently has no
  /// Settings toggle and no Debug-menu entry.
  @MainActor func testEveryRegisteredSourceIsInTheCatalogue() {
    for source in AppState.eventSources {
      XCTAssertTrue(
        SourceCatalog.all.contains(where: { $0.id == source.id }),
        "\(source.id) is registered but missing from SourceCatalog")
      XCTAssertEqual(SourceCatalog.tier(for: source.id), source.tier, "tier mismatch: \(source.id)")
    }
  }

  // MARK: - Event to sneak

  /// The bus renders events into the existing Sneak type; the queue is untouched. Coalescing key,
  /// duration and announcement must all survive the trip.
  @MainActor
  func testSneakCarriesTheEventsCoalescingKeyDurationAndAnnouncement() {
    let e = SystemEvent(
      sourceID: "wifi", icon: "wifi", title: "Wi-Fi connected", subtitle: "Home",
      accentHex: EventAccent.positive, motion: .wifi, duration: 2.5)
    let sneak = Sneak(event: e)
    XCTAssertEqual(sneak.source, "wifi")
    XCTAssertEqual(sneak.duration, 2.5)
    XCTAssertEqual(sneak.announcement, "Wi-Fi connected, Home")
  }

  @MainActor
  func testSneakUsesTheExplicitAnnouncementWhenGiven() {
    let e = SystemEvent(
      sourceID: "vpn", icon: "lock.shield.fill", title: "Tunnel up",
      announcement: "A network tunnel came up")
    XCTAssertEqual(Sneak(event: e).announcement, "A network tunnel came up")
  }

  // MARK: - Bus

  /// A stub source that records whether the bus started and stopped it.
  @MainActor
  private final class StubSource: SystemEventSource {
    let id: String
    let displayName = "Stub"
    let tier: SystemEventTier
    private(set) var startCount = 0
    private(set) var stopCount = 0
    init(id: String, tier: SystemEventTier = .core) {
      self.id = id
      self.tier = tier
    }
    func start() { startCount += 1 }
    func stop() { stopCount += 1 }
  }

  @MainActor
  private func makeBus() -> SystemEventBus {
    Defaults[.disabledEventSources] = []
    return SystemEventBus(queue: nil)
  }

  @MainActor
  func testSourcesShipEnabled() {
    let bus = makeBus()
    XCTAssertTrue(bus.isEnabled("usb"))
    XCTAssertTrue(bus.isEnabled("airdropIn"))
  }

  /// Disabling must actually STOP the source, not merely silence it — a stopped source holds no
  /// notification registration, no run-loop source and no timer.
  @MainActor
  func testDisablingStopsTheSourceAndEnablingRestartsIt() {
    let bus = makeBus()
    defer { Defaults[.disabledEventSources] = [] }
    let stub = StubSource(id: "usb")
    bus.register(stub)
    bus.startEnabled()
    XCTAssertEqual(stub.startCount, 1)

    bus.setEnabled(false, for: "usb")
    XCTAssertEqual(stub.stopCount, 1)
    XCTAssertFalse(bus.isEnabled("usb"))

    bus.setEnabled(true, for: "usb")
    XCTAssertEqual(stub.startCount, 2)
    XCTAssertTrue(bus.isEnabled("usb"))
  }

  @MainActor
  func testStartEnabledSkipsDisabledSources() {
    Defaults[.disabledEventSources] = ["usb"]
    defer { Defaults[.disabledEventSources] = [] }
    let bus = SystemEventBus(queue: nil)
    let off = StubSource(id: "usb")
    let on = StubSource(id: "wifi", tier: .extended)
    bus.register(off)
    bus.register(on)
    bus.startEnabled()
    XCTAssertEqual(off.startCount, 0)
    XCTAssertEqual(on.startCount, 1)
  }

  /// An event from a disabled source must not reach the queue even if the source emits anyway —
  /// belt and braces, because a source with an in-flight callback can emit after stop().
  @MainActor
  func testEmitFromADisabledSourceIsDropped() {
    let bus = makeBus()
    defer { Defaults[.disabledEventSources] = [] }
    var delivered: [Sneak] = []
    bus.onSneak = { delivered.append($0) }

    bus.emit(SystemEvent(sourceID: "usb", icon: "cable.connector", title: "Keyboard"))
    XCTAssertEqual(delivered.count, 1)

    bus.setEnabled(false, for: "usb")
    bus.emit(SystemEvent(sourceID: "usb", icon: "cable.connector", title: "Mouse"))
    XCTAssertEqual(delivered.count, 1, "a disabled source's event reached the queue")
  }

  /// Registering twice must not double-start or double-deliver.
  @MainActor
  func testRegisteringTheSameSourceTwiceIsIdempotent() {
    let bus = makeBus()
    let stub = StubSource(id: "usb")
    bus.register(stub)
    bus.register(stub)
    XCTAssertEqual(bus.sources.count, 1)
    bus.startEnabled()
    XCTAssertEqual(stub.startCount, 1)
  }
}
