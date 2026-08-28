import XCTest

@testable import Islet

final class FullscreenDetectorTests: XCTestCase {
  func testWindowMustCoverTheTargetDisplaysPositionNotOnlyItsSize() {
    let left = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let right = CGRect(x: 1920, y: 0, width: 1920, height: 1080)

    XCTAssertTrue(FullscreenDetector.covers(window: left, display: left))
    XCTAssertFalse(FullscreenDetector.covers(window: left, display: right))
  }

  func testCoverageHandlesDisplaysAboveAndBelowThePrimary() {
    let above = CGRect(x: 300, y: -900, width: 1440, height: 900)
    let below = CGRect(x: -200, y: 1080, width: 1440, height: 900)

    XCTAssertTrue(FullscreenDetector.covers(window: above, display: above))
    XCTAssertTrue(FullscreenDetector.covers(window: below, display: below))
    XCTAssertFalse(FullscreenDetector.covers(window: above, display: below))
  }

  func testOnePixelWindowServerRoundingIsAcceptedButRealGapsAreNot() {
    let display = CGRect(x: 1920, y: 0, width: 2560, height: 1440)
    XCTAssertTrue(
      FullscreenDetector.covers(
        window: display.insetBy(dx: 1, dy: 1), display: display, tolerance: 1))
    XCTAssertFalse(
      FullscreenDetector.covers(
        window: display.insetBy(dx: 2, dy: 2), display: display, tolerance: 1))
  }
}
