import XCTest

@testable import Islet

final class TimerLogicTests: XCTestCase {
  func testRejectsInvalidDurations() {
    XCTAssertNil(TimerLogic.validatedDuration(0))
    XCTAssertNil(TimerLogic.validatedDuration(-1))
    XCTAssertNil(TimerLogic.validatedDuration(.infinity))
    XCTAssertNil(TimerLogic.validatedDuration(.nan))
  }

  func testDurationIsCappedAtOneWeek() {
    XCTAssertEqual(
      TimerLogic.validatedDuration(TimerLogic.maximumDuration + 60),
      TimerLogic.maximumDuration)
  }

  func testAdjustCannotFinishTimerAccidentally() {
    XCTAssertEqual(TimerLogic.adjustedRemaining(30, by: -60), 1)
  }

  func testAdjustCannotExceedMaximum() {
    XCTAssertEqual(
      TimerLogic.adjustedRemaining(TimerLogic.maximumDuration, by: 60),
      TimerLogic.maximumDuration)
  }
}
