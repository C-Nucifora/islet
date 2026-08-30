import XCTest

@testable import Islet

final class MediaWatcherTests: XCTestCase {
  func testBackoffDoublesAndCaps() {
    XCTAssertEqual(MediaWatcher.backoffDelay(failureCount: 1), 1)
    XCTAssertEqual(MediaWatcher.backoffDelay(failureCount: 2), 2)
    XCTAssertEqual(MediaWatcher.backoffDelay(failureCount: 4), 8)
    XCTAssertEqual(MediaWatcher.backoffDelay(failureCount: 10), 60)
  }

  func testInitialSnapshotIsRejectedAfterIdleStreamRecord() {
    XCTAssertFalse(
      MediaWatcher.shouldAcceptInitialSnapshot(
        streamHasEmittedRecord: true, currentSource: nil))
  }

  func testInitialSnapshotIsAcceptedBeforeAnyStreamRecord() {
    XCTAssertTrue(
      MediaWatcher.shouldAcceptInitialSnapshot(
        streamHasEmittedRecord: false, currentSource: nil))
  }

  func testInitialSnapshotIsRejectedWhenStreamHasCurrentSource() {
    XCTAssertFalse(
      MediaWatcher.shouldAcceptInitialSnapshot(
        streamHasEmittedRecord: false, currentSource: key("com.spotify.client", 1)))
  }

  func key(_ bundle: String, _ pid: Int32) -> SourceID {
    SourceID(bundleIdentifier: bundle, pid: pid, parentBundleIdentifier: "")
  }

  /// Build the state ONCE per test and reuse it. `PlaybackState.elapsedAt` defaults to `Date()`,
  /// so two separate constructions are never equal.
  func state(_ title: String) -> PlaybackState {
    var s = PlaybackState()
    s.title = title
    s.isPlaying = true
    return s
  }

  func testIgnoredExpandsToNothing() {
    XCTAssertEqual(MediaWatcher.expand(.ignored, current: nil), [])
    XCTAssertEqual(
      MediaWatcher.expand(.ignored, current: key("com.spotify.client", 1)), [])
  }

  func testFirstSourceJustPublishes() {
    let spotify = key("com.spotify.client", 1)
    let playing = state("A")
    XCTAssertEqual(
      MediaWatcher.expand(.nowPlaying(spotify, playing), current: nil),
      [.nowPlaying(spotify, playing)])
  }

  func testSameSourceDoesNotEvict() {
    let spotify = key("com.spotify.client", 1)
    let playing = state("B")
    XCTAssertEqual(
      MediaWatcher.expand(.nowPlaying(spotify, playing), current: spotify),
      [.nowPlaying(spotify, playing)])
  }

  func testSourceChangeEvictsThePreviousSourceFirst() {
    // The vendored adapter calls resetAll() on a process change, so the previous source is not
    // backgrounded — it is gone.
    let spotify = key("com.spotify.client", 1)
    let music = key("com.apple.Music", 2)
    let playing = state("B")
    XCTAssertEqual(
      MediaWatcher.expand(.nowPlaying(music, playing), current: spotify),
      [.sourceGone(spotify), .nowPlaying(music, playing)])
  }

  func testIdlePassesThrough() {
    XCTAssertEqual(MediaWatcher.expand(.idle, current: key("com.spotify.client", 1)), [.idle])
    XCTAssertEqual(MediaWatcher.expand(.idle, current: nil), [.idle])
  }

  func testSourceGonePassesThrough() {
    let spotify = key("com.spotify.client", 1)
    XCTAssertEqual(
      MediaWatcher.expand(.sourceGone(spotify), current: spotify), [.sourceGone(spotify)])
  }
}
