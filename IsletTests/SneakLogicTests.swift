import SwiftUI
import XCTest

@testable import Islet

final class SneakLogicTests: XCTestCase {
  func sneak(_ source: String) -> Sneak {
    Sneak(source: source, leading: AnyView(EmptyView()), trailing: AnyView(EmptyView()))
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
