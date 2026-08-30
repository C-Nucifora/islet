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

  func testTimerFormattingFailsClosedForInvalidValues() {
    XCTAssertEqual(TimerFormat.mmss(-5), "0:00")
    XCTAssertEqual(TimerFormat.mmss(.nan), "0:00")
    XCTAssertEqual(TimerFormat.accessible(3661), "1 hour, 1 minute, 1 second")
    XCTAssertEqual(TimerFormat.accessible(0), "0 seconds")
  }

  func testActiveAndCompletedPresentationsKeepTheSelectedTimerTheme() {
    XCTAssertEqual(TimerPresentation.tintRole(finished: false), .timer)
    XCTAssertEqual(TimerPresentation.tintRole(finished: true), .timer)
  }
}
