import XCTest

@testable import Islet

final class MediaSourceTableTests: XCTestCase {
  let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)

  func key(_ bundle: String, _ pid: Int32, parent: String = "") -> SourceID {
    SourceID(bundleIdentifier: bundle, pid: pid, parentBundleIdentifier: parent)
  }

  func state(_ title: String, playing: Bool) -> PlaybackState {
    var s = PlaybackState()
    s.title = title
    s.isPlaying = playing
    return s
  }

  func testUpsertInsertsAndReportsNew() {
    var table = MediaSourceTable()
    let spotify = key("com.spotify.client", 1)
    XCTAssertTrue(table.upsert(spotify, state("A", playing: true), now: t0))
    XCTAssertEqual(table.states.count, 1)
    XCTAssertEqual(table.states[spotify]?.title, "A")
    XCTAssertFalse(table.isEmpty)
  }

  func testUpsertOfAKnownKeyIsAnUpdateNotAnInsert() {
    var table = MediaSourceTable()
    let spotify = key("com.spotify.client", 1)
    table.upsert(spotify, state("A", playing: true), now: t0)
    XCTAssertFalse(table.upsert(spotify, state("B", playing: true), now: t0.addingTimeInterval(5)))
    XCTAssertEqual(table.states.count, 1)
    XCTAssertEqual(table.states[spotify]?.title, "B")
  }

  func testTwoSourcesCoexist() {
    var table = MediaSourceTable()
    table.upsert(key("com.spotify.client", 1), state("A", playing: true), now: t0)
    table.upsert(key("com.apple.Music", 2), state("B", playing: true), now: t0)
    XCTAssertEqual(table.states.count, 2)
  }

  func testRemoveDropsOneSourceOnly() {
    var table = MediaSourceTable()
    let spotify = key("com.spotify.client", 1)
    let music = key("com.apple.Music", 2)
    table.upsert(spotify, state("A", playing: true), now: t0)
    table.upsert(music, state("B", playing: true), now: t0)
    XCTAssertTrue(table.remove(spotify))
    XCTAssertEqual(Array(table.states.keys), [music])
    XCTAssertFalse(table.remove(spotify))  // already gone
  }

  func testRemoveAllClears() {
    var table = MediaSourceTable()
    table.upsert(key("com.spotify.client", 1), state("A", playing: false), now: t0)
    table.upsert(key("com.apple.Music", 2), state("B", playing: false), now: t0)
    table.removeAll()
    XCTAssertTrue(table.isEmpty)
    XCTAssertNil(table.nextDeadline)
  }

  func testPausingSetsADeadlineAndPlayingClearsIt() {
    var table = MediaSourceTable(idleTimeout: 60)
    let spotify = key("com.spotify.client", 1)
    table.upsert(spotify, state("A", playing: true), now: t0)
    XCTAssertNil(table.nextDeadline)
    table.upsert(spotify, state("A", playing: false), now: t0)
    XCTAssertEqual(table.nextDeadline, t0.addingTimeInterval(60))
    table.upsert(spotify, state("A", playing: true), now: t0.addingTimeInterval(5))
    XCTAssertNil(table.nextDeadline)
  }

  func testAContinuingPauseDoesNotPushTheDeadlineBack() {
    var table = MediaSourceTable(idleTimeout: 60)
    let spotify = key("com.spotify.client", 1)
    table.upsert(spotify, state("A", playing: false), now: t0)
    table.upsert(spotify, state("A", playing: false), now: t0.addingTimeInterval(30))
    XCTAssertEqual(table.nextDeadline, t0.addingTimeInterval(60))
  }

  func testExpireIsANoOpBeforeTheDeadline() {
    var table = MediaSourceTable(idleTimeout: 60)
    table.upsert(key("com.spotify.client", 1), state("A", playing: false), now: t0)
    XCTAssertEqual(table.expire(now: t0.addingTimeInterval(59)), [])
    XCTAssertEqual(table.states.count, 1)
  }

  func testExpireEvictsOnlyPastDeadlineSources() {
    var table = MediaSourceTable(idleTimeout: 60)
    let early = key("com.spotify.client", 1)
    let late = key("com.apple.Music", 2)
    table.upsert(early, state("A", playing: false), now: t0)
    table.upsert(late, state("B", playing: false), now: t0.addingTimeInterval(30))
    XCTAssertEqual(table.expire(now: t0.addingTimeInterval(61)), [early])
    XCTAssertEqual(Array(table.states.keys), [late])
    XCTAssertEqual(table.expire(now: t0.addingTimeInterval(91)), [late])
    XCTAssertTrue(table.isEmpty)
  }

  func testResumingPlaybackCancelsExpiry() {
    var table = MediaSourceTable(idleTimeout: 60)
    let spotify = key("com.spotify.client", 1)
    table.upsert(spotify, state("A", playing: false), now: t0)
    table.upsert(spotify, state("A", playing: true), now: t0.addingTimeInterval(10))
    XCTAssertEqual(table.expire(now: t0.addingTimeInterval(600)), [])
    XCTAssertEqual(table.states.count, 1)
  }

  func testNextDeadlineIsTheEarliest() {
    var table = MediaSourceTable(idleTimeout: 60)
    table.upsert(
      key("com.apple.Music", 2), state("B", playing: false), now: t0.addingTimeInterval(30))
    table.upsert(key("com.spotify.client", 1), state("A", playing: false), now: t0)
    XCTAssertEqual(table.nextDeadline, t0.addingTimeInterval(60))
  }

  func testPrimaryPrefersPlayingOverPaused() {
    var table = MediaSourceTable()
    let paused = key("com.apple.Music", 2)
    let playing = key("com.spotify.client", 1)
    table.upsert(paused, state("B", playing: false), now: t0)
    table.upsert(playing, state("A", playing: true), now: t0)
    XCTAssertEqual(table.primaryKey(mode: .auto, priorityList: []), playing)
  }

  func testPrioritizedModeFollowsThePriorityList() {
    var table = MediaSourceTable()
    let music = key("com.apple.Music", 2)
    let spotify = key("com.spotify.client", 1)
    table.upsert(spotify, state("A", playing: true), now: t0)
    table.upsert(music, state("B", playing: true), now: t0)
    XCTAssertEqual(
      table.primaryKey(
        mode: .prioritized, priorityList: ["com.apple.Music", "com.spotify.client"]),
      music)
    XCTAssertEqual(
      table.primaryKey(
        mode: .prioritized, priorityList: ["com.spotify.client", "com.apple.Music"]),
      spotify)
  }

  func testOrderedRanksByDisplayIdentityNotTheHelperBundle() {
    var table = MediaSourceTable()
    let safari = key("com.apple.WebKit.GPU", 6712, parent: "com.apple.Safari")
    let spotify = key("com.spotify.client", 1)
    table.upsert(safari, state("A", playing: true), now: t0)
    table.upsert(spotify, state("B", playing: true), now: t0)
    XCTAssertEqual(
      table.ordered(mode: .prioritized, priorityList: ["com.apple.Safari"]),
      [safari, spotify])
  }

  func testDeniedSourcesAreNeverOrderedOrPrimary() {
    var table = MediaSourceTable()
    let denied = key("com.apple.controlcenter", 726)
    let spotify = key("com.spotify.client", 1)
    table.upsert(denied, state("Ping", playing: true), now: t0)
    table.upsert(spotify, state("A", playing: true), now: t0)
    XCTAssertEqual(table.ordered(mode: .auto, priorityList: []), [spotify])
    XCTAssertEqual(table.primaryKey(mode: .auto, priorityList: []), spotify)
  }
}
