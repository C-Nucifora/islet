import XCTest

@testable import Islet

@MainActor
final class NowPlayingActivityTests: XCTestCase {
  func testFreshActivityIsInactiveAndHasNoPrimary() {
    let activity = NowPlayingActivity()
    XCTAssertTrue(activity.sources.isEmpty)
    XCTAssertTrue(activity.strip.isEmpty)
    XCTAssertNil(activity.primaryKey)
    XCTAssertNil(activity.primary)
    XCTAssertNil(activity.playback)  // the shim the existing views read
    XCTAssertFalse(activity.isActive)
  }

  func testElapsedPositionIsClampedToTrackBounds() {
    var state = PlaybackState()
    state.duration = 60
    state.elapsed = -10
    XCTAssertEqual(state.currentElapsed, 0)

    state.elapsed = 90
    XCTAssertEqual(state.currentElapsed, 60)
  }

  func testInvalidElapsedPositionFailsClosed() {
    var state = PlaybackState()
    state.elapsed = .nan
    XCTAssertEqual(state.currentElapsed, 0)
  }
}
