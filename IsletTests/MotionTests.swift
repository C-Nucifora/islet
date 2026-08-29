import SwiftUI
import XCTest

@testable import Islet

final class MotionTests: XCTestCase {
  func testGatedPassesTheAnimationThroughWhenMotionIsAllowed() {
    XCTAssertEqual(Motion.gated(Motion.opening, reduceMotion: false), Motion.opening)
    XCTAssertEqual(Motion.gated(Motion.closing, reduceMotion: false), Motion.closing)
    XCTAssertEqual(Motion.gated(Motion.compact, reduceMotion: false), Motion.compact)
    XCTAssertEqual(Motion.gated(Motion.hudAppearing, reduceMotion: false), Motion.hudAppearing)
  }

  func testGatedCollapsesToNilUnderReduceMotion() {
    // nil is the "apply the change with no animation" argument for both withAnimation(_:_:)
    // and .animation(_:value:), so every call site gates by wrapping its animation.
    XCTAssertNil(Motion.gated(Motion.opening, reduceMotion: true))
    XCTAssertNil(Motion.gated(Motion.closing, reduceMotion: true))
    XCTAssertNil(Motion.gated(Motion.compact, reduceMotion: true))
    XCTAssertNil(Motion.gated(Motion.hudAppearing, reduceMotion: true))
  }

  func testHUDEntryIsShortAndExitUsesNormalCompactMotion() {
    XCTAssertEqual(Motion.compactChange(hudVisible: true), Motion.hudAppearing)
    XCTAssertEqual(Motion.compactChange(hudVisible: false), Motion.compact)
    XCTAssertNotEqual(Motion.hudAppearing, Motion.compact)
  }

  func testPanelShrinkDelayOutlastsTheClosingAnimation() {
    // The panel must stay oversized until the close has finished drawing, or the island is
    // clipped mid-collapse.
    XCTAssertGreaterThan(
      Motion.panelShrinkDelay,
      Duration.milliseconds(Int(Motion.closingDuration * 1000)))
  }

  func testMotionProfileNamesEverySourceAndRoundTrips() {
    XCTAssertEqual(MotionProfile.allCases.count, 15)
    for profile in MotionProfile.allCases {
      XCTAssertEqual(MotionProfile(rawValue: profile.rawValue), profile)
    }
    XCTAssertEqual(MotionProfile.volumeMount.rawValue, "volumeMount")
    XCTAssertEqual(MotionProfile.chargeComplete.rawValue, "chargeComplete")
  }
}
