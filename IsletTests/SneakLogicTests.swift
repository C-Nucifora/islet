import SwiftUI
import XCTest

@testable import Islet

final class SneakLogicTests: XCTestCase {
  func sneak(_ source: String, urgency: SystemEventUrgency = .normal) -> Sneak {
    Sneak(
      source: source,
      urgency: urgency,
      leading: AnyView(EmptyView()),
      trailing: AnyView(EmptyView()))
  }

  func testFIFOOrder() {
    var q = SneakLogic()
    q.enqueue(sneak("a"))
    q.enqueue(sneak("b"))
    XCTAssertEqual(q.popNext()?.source, "a")
    XCTAssertEqual(q.popNext()?.source, "b")
    XCTAssertNil(q.popNext())
  }

  func testCoalescingReplacesSameSourceInPlace() {
    var q = SneakLogic()
    q.enqueue(sneak("battery"))
    q.enqueue(sneak("track"))
    let replacement = sneak("battery")
    q.enqueue(replacement)
    XCTAssertEqual(q.pending.count, 2)
    XCTAssertEqual(q.popNext()?.id, replacement.id)  // kept battery's slot, new content
    XCTAssertEqual(q.popNext()?.source, "track")
  }

  func testDistinctSourcesBothKept() {
    var q = SneakLogic()
    q.enqueue(sneak("a"))
    q.enqueue(sneak("b"))
    XCTAssertEqual(q.pending.count, 2)
  }

  func testUrgencyOrdersQueuedSneaksAndPreservesFIFOWithinEachLevel() {
    var q = SneakLogic()
    q.enqueue(sneak("ambient-first", urgency: .ambient))
    q.enqueue(sneak("normal-first"))
    q.enqueue(sneak("alert-first", urgency: .alert))
    q.enqueue(sneak("ambient-second", urgency: .ambient))
    q.enqueue(sneak("normal-second"))
    q.enqueue(sneak("alert-second", urgency: .alert))

    XCTAssertEqual(q.popNext()?.source, "alert-first")
    XCTAssertEqual(q.popNext()?.source, "alert-second")
    XCTAssertEqual(q.popNext()?.source, "normal-first")
    XCTAssertEqual(q.popNext()?.source, "normal-second")
    XCTAssertEqual(q.popNext()?.source, "ambient-first")
    XCTAssertEqual(q.popNext()?.source, "ambient-second")
  }

  func testQueuedAlertPreemptsAmbientWithoutReplacingIt() {
    var q = SneakLogic()
    q.enqueue(sneak("track", urgency: .ambient))
    q.enqueue(sneak("wifi", urgency: .ambient))
    q.enqueue(sneak("battery", urgency: .alert))

    XCTAssertEqual(q.popNext()?.source, "battery")
    XCTAssertEqual(q.popNext()?.source, "track")
    XCTAssertEqual(q.popNext()?.source, "wifi")
  }

  func testPriorityChangingReplacementKeepsOneSourceAndJoinsItsNewUrgencyLevelInFIFOOrder() {
    var q = SneakLogic()
    q.enqueue(sneak("battery", urgency: .ambient))
    q.enqueue(sneak("existing-alert", urgency: .alert))
    let replacement = sneak("battery", urgency: .alert)
    q.enqueue(replacement)

    XCTAssertEqual(q.pending.count, 2)
    XCTAssertEqual(q.popNext()?.source, "existing-alert")
    XCTAssertEqual(q.popNext()?.id, replacement.id)
  }

  func testAmbientGetsATurnAfterTheAlertStarvationBound() {
    var q = SneakLogic()
    q.enqueue(sneak("ambient", urgency: .ambient))
    for index in 0...SneakLogic.maximumConsecutiveAlerts {
      q.enqueue(sneak("alert-\(index)", urgency: .alert))
    }

    for index in 0..<SneakLogic.maximumConsecutiveAlerts {
      XCTAssertEqual(q.popNext()?.source, "alert-\(index)")
    }
    XCTAssertEqual(q.popNext()?.source, "ambient")
    XCTAssertEqual(q.popNext()?.source, "alert-\(SneakLogic.maximumConsecutiveAlerts)")
  }

  func testAnIdleQueueResetsTheAlertBurstCount() {
    var q = SneakLogic()
    for index in 0..<SneakLogic.maximumConsecutiveAlerts {
      q.enqueue(sneak("old-alert-\(index)", urgency: .alert))
      XCTAssertEqual(q.popNext()?.source, "old-alert-\(index)")
    }
    XCTAssertNil(q.popNext())

    q.enqueue(sneak("ambient", urgency: .ambient))
    q.enqueue(sneak("new-alert", urgency: .alert))

    XCTAssertEqual(q.popNext()?.source, "new-alert")
    XCTAssertEqual(q.popNext()?.source, "ambient")
  }

  func testMarqueeDoesNotTravelWhenContentFitsViewport() {
    let motion = MarqueeMotion(viewportWidth: 120, contentWidth: 90)

    XCTAssertEqual(motion.travelDistance, 0)
    XCTAssertEqual(motion.offset(at: 20), 0)
  }

  func testMarqueePausesScrollsAndPausesBeforeReset() {
    let motion = MarqueeMotion(
      viewportWidth: 120, contentWidth: 180, pointsPerSecond: 30,
      startPause: 1, endPause: 1, resetPause: 0.5)

    XCTAssertEqual(motion.travelDistance, 60)
    XCTAssertEqual(motion.cycleDuration, 4.5, accuracy: 0.001)
    XCTAssertEqual(motion.offset(at: 0.5), 0, accuracy: 0.001)
    XCTAssertEqual(motion.offset(at: 2), -30, accuracy: 0.001)
    XCTAssertEqual(motion.offset(at: 3.5), -60, accuracy: 0.001)
    XCTAssertEqual(motion.offset(at: 4.25), -60, accuracy: 0.001)
    XCTAssertEqual(motion.offset(at: 4.5), 0, accuracy: 0.001)
  }
}
