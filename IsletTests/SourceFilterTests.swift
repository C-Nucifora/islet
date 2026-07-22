import XCTest

@testable import Islet

final class SourceFilterTests: XCTestCase {
  func testAutoAcceptsEverything() {
    XCTAssertTrue(
      SourceFilter.shouldAccept(
        bundleID: "com.spotify.client",
        currentBundleID: nil, mode: .auto, priorityList: []))
  }

  func testPrioritizedRejectsUnlisted() {
    XCTAssertFalse(
      SourceFilter.shouldAccept(
        bundleID: "com.apple.Safari",
        currentBundleID: nil, mode: .prioritized,
        priorityList: ["com.spotify.client"]))
  }

  func testHigherPriorityTakesOver() {
    XCTAssertTrue(
      SourceFilter.shouldAccept(
        bundleID: "com.spotify.client",
        currentBundleID: "com.apple.Music", mode: .prioritized,
        priorityList: ["com.spotify.client", "com.apple.Music"]))
  }

  func testLowerPriorityDoesNotPreemptCurrent() {
    XCTAssertFalse(
      SourceFilter.shouldAccept(
        bundleID: "com.apple.Music",
        currentBundleID: "com.spotify.client", mode: .prioritized,
        priorityList: ["com.spotify.client", "com.apple.Music"]))
  }

  func testSameSourceAlwaysAllowedWhenListed() {
    XCTAssertTrue(
      SourceFilter.shouldAccept(
        bundleID: "com.apple.Music",
        currentBundleID: "com.apple.Music", mode: .prioritized,
        priorityList: ["com.spotify.client", "com.apple.Music"]))
  }
}
