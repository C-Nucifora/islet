import XCTest

@testable import Islet

final class MediaWatcherTests: XCTestCase {
  func testBackoffDoublesAndCaps() {
    XCTAssertEqual(MediaWatcher.backoffDelay(failureCount: 1), 1)
    XCTAssertEqual(MediaWatcher.backoffDelay(failureCount: 2), 2)
    XCTAssertEqual(MediaWatcher.backoffDelay(failureCount: 4), 8)
    XCTAssertEqual(MediaWatcher.backoffDelay(failureCount: 10), 60)
  }
}
