import XCTest

@testable import Islet

final class SourceFilterTests: XCTestCase {
  func testDenylistedBundlesAreHidden() {
    for bundleID in [
      "systemsoundserverd", "com.apple.PowerChime", "com.apple.controlcenter",
    ] {
      XCTAssertNil(
        SourceFilter.rank(bundleID: bundleID, mode: .auto, priorityList: []),
        "\(bundleID) should be hidden")
      XCTAssertTrue(SourceFilter.isDenied(bundleID))
    }
  }

  func testConfiguredAppIdentityIsHidden() throws {
    let bundleIdentifier = try XCTUnwrap(Bundle.main.bundleIdentifier)
    XCTAssertTrue(SourceFilter.isDenied(bundleIdentifier))
    XCTAssertTrue(
      SourceFilter.isDenied("dev.review.override", ownBundleIdentifier: "dev.review.override"))
    XCTAssertFalse(
      SourceFilter.isDenied("dev.review.player", ownBundleIdentifier: "dev.review.override"))
  }

  func testEmptyBundleIdentifierIsHidden() {
    XCTAssertNil(SourceFilter.rank(bundleID: "", mode: .auto, priorityList: []))
  }

  func testAutoRanksEveryVisibleSourceEqually() {
    // .auto ignores the list entirely, so ordering falls through to the table's tiebreakers.
    let spotify = SourceFilter.rank(
      bundleID: "com.spotify.client", mode: .auto,
      priorityList: ["com.apple.Music", "com.spotify.client"])
    let music = SourceFilter.rank(
      bundleID: "com.apple.Music", mode: .auto,
      priorityList: ["com.apple.Music", "com.spotify.client"])
    XCTAssertNotNil(spotify)
    XCTAssertEqual(spotify, music)
  }

  func testPrioritizedOrdersByListPosition() {
    let list = ["com.spotify.client", "com.apple.Music"]
    XCTAssertEqual(
      SourceFilter.rank(bundleID: "com.spotify.client", mode: .prioritized, priorityList: list), 0)
    XCTAssertEqual(
      SourceFilter.rank(bundleID: "com.apple.Music", mode: .prioritized, priorityList: list), 1)
  }

  func testPrioritizedKeepsUnlistedSourcesAfterListedOnes() {
    let list = ["com.spotify.client", "com.apple.Music"]
    let unlisted = SourceFilter.rank(
      bundleID: "com.apple.Safari", mode: .prioritized, priorityList: list)
    XCTAssertEqual(unlisted, 2)
    XCTAssertGreaterThan(
      try XCTUnwrap(unlisted),
      try XCTUnwrap(
        SourceFilter.rank(bundleID: "com.apple.Music", mode: .prioritized, priorityList: list)))
  }

  func testPrioritizedNoLongerDropsUnlistedSources() {
    // The retired behaviour: an unlisted bundle used to be dropped outright, which made a second
    // player invisible rather than secondary.
    XCTAssertNotNil(
      SourceFilter.rank(
        bundleID: "com.apple.Safari", mode: .prioritized,
        priorityList: ["com.spotify.client"]))
  }
}
