import Darwin
import XCTest

@testable import Islet

final class MediaWatcherTests: XCTestCase {
  func testBackoffDoublesAndCaps() {
    XCTAssertEqual(MediaWatcher.backoffDelay(failureCount: 1), 1)
    XCTAssertEqual(MediaWatcher.backoffDelay(failureCount: 2), 2)
    XCTAssertEqual(MediaWatcher.backoffDelay(failureCount: 4), 8)
    XCTAssertEqual(MediaWatcher.backoffDelay(failureCount: 10), 60)
  }

  func testSnapshotStartupDeadlineBeforeOutput() {
    let tracker = MediaWatcher.SnapshotDeadlineTracker(
      startedAt: 10,
      timeouts: .init(startup: 2, idle: 3, total: 8))

    XCTAssertNil(tracker.expired(at: 11.999))
    XCTAssertEqual(tracker.expired(at: 12), .startup)
    XCTAssertEqual(tracker.nextDeadline(after: 10), 12)
  }

  func testSnapshotIdleDeadlineMovesWithOutput() {
    var tracker = MediaWatcher.SnapshotDeadlineTracker(
      startedAt: 10,
      timeouts: .init(startup: 2, idle: 3, total: 8))
    tracker.receivedOutput(at: 11)

    XCTAssertNil(tracker.expired(at: 13.999))
    XCTAssertEqual(tracker.expired(at: 14), .idle)
    XCTAssertEqual(tracker.nextDeadline(after: 11), 14)
  }

  func testSnapshotTotalDeadlineCannotBeExtendedByOutput() {
    var tracker = MediaWatcher.SnapshotDeadlineTracker(
      startedAt: 10,
      timeouts: .init(startup: 2, idle: 3, total: 8))
    tracker.receivedOutput(at: 17.5)

    XCTAssertNil(tracker.expired(at: 17.999))
    XCTAssertEqual(tracker.expired(at: 18), .total)
    XCTAssertEqual(tracker.nextDeadline(after: 17.5), 18)
  }

  func testInitialSnapshotRejectsMalformedOutput() {
    XCTAssertNil(MediaWatcher.parseInitialSnapshot(data: Data("not json".utf8)))
  }

  func testInitialSnapshotAcceptsIdlePayload() {
    XCTAssertEqual(MediaWatcher.parseInitialSnapshot(data: Data("{}".utf8)), .idle)
  }

  func testHangingSnapshotTimesOutReapsAndRetriesWithoutOverlap() throws {
    let helper = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .appendingPathComponent("Fixtures/hanging-media-helper.pl")
    XCTAssertTrue(FileManager.default.fileExists(atPath: helper.path))
    let log = FileManager.default.temporaryDirectory.appendingPathComponent(
      "media-watcher-\(UUID().uuidString).log")
    defer {
      try? FileManager.default.removeItem(at: log)
      try? FileManager.default.removeItem(atPath: log.path + ".stream.lock")
      try? FileManager.default.removeItem(atPath: log.path + ".get.lock")
    }

    let secondTimeout = expectation(description: "two snapshot attempts time out")
    secondTimeout.expectedFulfillmentCount = 2
    let watcher = MediaWatcher(
      snapshotTimeouts: .init(startup: 0.15, idle: 0.15, total: 0.4),
      initialSnapshotDelay: 0,
      commandProvider: { kind in
        MediaWatcher.HelperCommand(
          executableURL: URL(fileURLWithPath: "/usr/bin/perl"),
          arguments: [helper.path, kind.rawValue, log.path])
      },
      snapshotBackoff: { _ in 0.05 })
    watcher.onStatus = { status in
      if status.contains("snapshot startup timeout") { secondTimeout.fulfill() }
    }
    watcher.start()
    wait(for: [secondTimeout], timeout: 3)
    watcher.stop()

    let records = try String(contentsOf: log, encoding: .utf8)
      .split(separator: "\n").map(String.init)
    let snapshotStarts = records.filter { $0.hasPrefix("started get ") }
    XCTAssertGreaterThanOrEqual(snapshotStarts.count, 2)
    XCTAssertFalse(records.contains { $0.hasPrefix("overlap ") })

    for record in records where record.hasPrefix("started ") {
      let pid = try XCTUnwrap(Int32(record.split(separator: " ").last ?? ""))
      XCTAssertEqual(Darwin.kill(pid, 0), -1, "helper pid \(pid) is still present")
      XCTAssertEqual(errno, ESRCH, "helper pid \(pid) was not reaped")
    }
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
