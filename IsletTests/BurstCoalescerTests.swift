import XCTest

@testable import Islet

final class BurstCoalescerTests: XCTestCase {
  private func event(_ source: String, _ title: String) -> SystemEvent {
    SystemEvent(sourceID: source, icon: "circle", title: title)
  }

  /// Isolated events are the common case and must pass straight through untouched.
  func testEventsBelowTheThresholdPassThrough() {
    var c = BurstCoalescer(window: 2.5, threshold: 3)
    XCTAssertEqual(c.accept(event("usb", "Keyboard"), at: 0), .pass(event("usb", "Keyboard")))
    XCTAssertEqual(c.accept(event("usb", "Mouse"), at: 0.4), .pass(event("usb", "Mouse")))
    XCTAssertFalse(c.isHolding)
  }

  /// The third event inside the window turns the burst on: it and everything after it are held.
  func testTheThirdEventInsideTheWindowStartsHolding() {
    var c = BurstCoalescer(window: 2.5, threshold: 3)
    _ = c.accept(event("usb", "Keyboard"), at: 0)
    _ = c.accept(event("display", "Studio Display"), at: 0.3)
    XCTAssertEqual(c.accept(event("volume", "Backup"), at: 0.6), .hold)
    XCTAssertEqual(c.accept(event("usb", "Hub"), at: 0.9), .hold)
    XCTAssertTrue(c.isHolding)
  }

  /// Flushing after the window closes yields one summary naming what arrived.
  func testFlushSummarisesTheHeldBurst() {
    var c = BurstCoalescer(window: 2.5, threshold: 3)
    _ = c.accept(event("usb", "Keyboard"), at: 0)
    _ = c.accept(event("display", "Studio Display"), at: 0.3)
    _ = c.accept(event("volume", "Backup"), at: 0.6)
    _ = c.accept(event("usb", "Hub"), at: 0.9)

    let summary = c.flush(at: 3.5)
    XCTAssertNotNil(summary)
    XCTAssertEqual(summary?.sourceID, "burst")
    // Two, not four: the first `threshold - 1` events were already presented, so the summary
    // covers only what was actually withheld.
    XCTAssertEqual(summary?.title, "2 system events")
    XCTAssertEqual(summary?.subtitle, "Backup, Hub")
    XCTAssertEqual(summary?.duration, 3)
    XCTAssertFalse(c.isHolding)
  }

  /// Flushing before the window closes yields nothing: the burst may still be growing.
  func testFlushBeforeTheWindowClosesYieldsNothing() {
    var c = BurstCoalescer(window: 2.5, threshold: 3)
    _ = c.accept(event("usb", "Keyboard"), at: 0)
    _ = c.accept(event("display", "Studio"), at: 0.3)
    _ = c.accept(event("volume", "Backup"), at: 0.6)
    XCTAssertNil(c.flush(at: 1.0))
    XCTAssertTrue(c.isHolding)
  }

  /// Nothing held means nothing to flush — the timer firing on a quiet system is a no-op.
  func testFlushWithNothingHeldYieldsNothing() {
    var c = BurstCoalescer(window: 2.5, threshold: 3)
    XCTAssertNil(c.flush(at: 10))
  }

  /// Events spread out beyond the window are not a burst, however many there are.
  func testEventsOutsideTheWindowNeverAccumulate() {
    var c = BurstCoalescer(window: 2.5, threshold: 3)
    for i in 0..<10 {
      let e = event("usb", "Device \(i)")
      XCTAssertEqual(c.accept(e, at: Double(i) * 5), .pass(e), "event \(i) should pass")
    }
    XCTAssertFalse(c.isHolding)
  }

  /// An alert must never be swallowed by a burst. Low battery during docking is exactly when you
  /// need to see it.
  func testAlertsAlwaysPassEvenMidBurst() {
    var c = BurstCoalescer(window: 2.5, threshold: 3)
    _ = c.accept(event("usb", "Keyboard"), at: 0)
    _ = c.accept(event("display", "Studio"), at: 0.3)
    _ = c.accept(event("volume", "Backup"), at: 0.6)
    XCTAssertTrue(c.isHolding)

    var alert = event("battery", "Low battery")
    alert.urgency = .alert
    XCTAssertEqual(c.accept(alert, at: 0.7), .pass(alert))
    XCTAssertTrue(c.isHolding)  // the burst is still held; the alert jumped it
  }

  /// A pathological storm must not grow the held array without bound.
  func testHeldEventsAreCappedButStillCounted() {
    var c = BurstCoalescer(window: 100, threshold: 3, maxHeld: 5)
    for i in 0..<50 { _ = c.accept(event("usb", "Device \(i)"), at: Double(i) * 0.01) }
    let summary = c.flush(at: 200)
    XCTAssertEqual(summary?.title, "48 system events")  // the count is exact ...
    XCTAssertEqual(summary?.subtitle?.contains("+45"), true)  // ... even though only 5 were kept
  }

  func testResetDropsHeldEventsAndRecentThresholdHistory() {
    var c = BurstCoalescer(window: 2.5, threshold: 3)
    _ = c.accept(event("usb", "Keyboard"), at: 0)
    _ = c.accept(event("display", "Studio"), at: 0.2)
    _ = c.accept(event("volume", "Backup"), at: 0.4)
    XCTAssertTrue(c.isHolding)

    c.reset()
    XCTAssertFalse(c.isHolding)
    XCTAssertNil(c.flush(at: 10))
    XCTAssertEqual(c.accept(event("usb", "Mouse"), at: 10), .pass(event("usb", "Mouse")))
  }

  func testBackwardsClockInputStartsAFreshWindow() {
    var c = BurstCoalescer(window: 2.5, threshold: 3)
    _ = c.accept(event("usb", "Keyboard"), at: 100)
    _ = c.accept(event("display", "Studio"), at: 100.2)
    XCTAssertEqual(
      c.accept(event("volume", "Backup"), at: 20), .pass(event("volume", "Backup")))
    XCTAssertFalse(c.isHolding)
  }

  func testSingleHeldEventUsesSingularSummaryTitle() {
    var c = BurstCoalescer(window: 2.5, threshold: 3)
    _ = c.accept(event("usb", "Keyboard"), at: 0)
    _ = c.accept(event("display", "Studio"), at: 0.2)
    _ = c.accept(event("volume", "Backup"), at: 0.4)
    XCTAssertEqual(c.flush(at: 3)?.title, "1 system event")
  }
}
