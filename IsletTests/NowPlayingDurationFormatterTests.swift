import XCTest

@testable import Islet

final class NowPlayingDurationFormatterTests: XCTestCase {
  private let locale = Locale(identifier: "en_US_POSIX")

  func testKeepsDurationsUnderAnHourInMinutesAndSeconds() {
    XCTAssertEqual(MediaDurationFormatter.string(for: 0, locale: locale), "0:00")
    XCTAssertEqual(MediaDurationFormatter.string(for: 3_599, locale: locale), "59:59")
  }

  func testUsesHoursAtOneHour() {
    XCTAssertEqual(MediaDurationFormatter.string(for: 3_600, locale: locale), "1:00:00")
    XCTAssertEqual(MediaDurationFormatter.string(for: 5_401, locale: locale), "1:30:01")
  }

  func testRoundsToTheNearestSecond() {
    XCTAssertEqual(MediaDurationFormatter.string(for: 3_599.6, locale: locale), "1:00:00")
    XCTAssertEqual(MediaDurationFormatter.string(for: 3_600.4, locale: locale), "1:00:00")
  }

  func testClampsNegativeAndRejectsNonFiniteDurations() {
    XCTAssertEqual(MediaDurationFormatter.string(for: -1, locale: locale), "0:00")
    XCTAssertEqual(MediaDurationFormatter.string(for: .nan, locale: locale), "0:00")
    XCTAssertEqual(MediaDurationFormatter.string(for: .infinity, locale: locale), "0:00")
  }

  func testHandlesVeryLargeFiniteDurationsWithoutIntegerOverflow() {
    let formatted = MediaDurationFormatter.string(
      for: Double.greatestFiniteMagnitude, locale: locale)
    let components = formatted.split(separator: ":")
    XCTAssertEqual(components.count, 3)
    XCTAssertTrue(components.allSatisfy { !$0.isEmpty })
  }
}
