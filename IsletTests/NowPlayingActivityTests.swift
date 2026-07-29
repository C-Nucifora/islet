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
}
