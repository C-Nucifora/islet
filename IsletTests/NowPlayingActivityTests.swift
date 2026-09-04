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

  func testMatchingCoreAudioChangesDoNotPromotePausedAdapterStateOrMoveDeadline() throws {
    let activity = NowPlayingActivity()
    let browser = SourceID(
      bundleIdentifier: "company.thebrowser.Browser", pid: 100, parentBundleIdentifier: "")
    let browserAudio = SourceID(
      bundleIdentifier: "company.thebrowser.Browser.helper", pid: 101,
      parentBundleIdentifier: "company.thebrowser.Browser")
    var paused = PlaybackState()
    paused.title = "Video"
    paused.isPlaying = false
    activity.receive(.nowPlaying(browser, paused), now: Date())
    let deadline = try XCTUnwrap(activity.table.nextDeadline)

    activity.audioSourcesChanged([browserAudio])

    XCTAssertFalse(activity.sources[browser]?.isPlaying ?? true)
    XCTAssertEqual(activity.table.nextDeadline, deadline)

    activity.audioSourcesChanged([])

    XCTAssertFalse(activity.sources[browser]?.isPlaying ?? true)
    XCTAssertEqual(activity.table.nextDeadline, deadline)
  }

  func testCommandFailurePublishesActionSpecificFeedback() async {
    let source = SourceID(
      bundleIdentifier: "com.example.Player", pid: 42, parentBundleIdentifier: "")
    let activity = NowPlayingActivity { _, source, _ in .rejected(target: source) }

    await activity.perform(.next, for: source)

    XCTAssertEqual(activity.lastMediaCommandResult, .rejected(target: source))
    XCTAssertEqual(
      activity.mediaControlNotice, "Can't go to the next track: the player rejected it")
  }

  func testCommandSuccessClearsPreviousFailureFeedback() async {
    let source = SourceID(
      bundleIdentifier: "com.example.Player", pid: 42, parentBundleIdentifier: "")
    let results = CommandResults([
      .rejected(target: source), .sent(target: source, sourceScoped: false),
    ])
    let activity = NowPlayingActivity { _, source, _ in await results.next(for: source) }

    await activity.perform(.next, for: source)
    await activity.perform(.next, for: source)

    XCTAssertEqual(activity.lastMediaCommandResult, .sent(target: source, sourceScoped: false))
    XCTAssertNil(activity.mediaControlNotice)
  }

  func testEarlierCommandCannotOverwriteFeedbackForALaterTap() async {
    let source = SourceID(
      bundleIdentifier: "com.example.Player", pid: 42, parentBundleIdentifier: "")
    let gate = CommandGate()
    let activity = NowPlayingActivity { command, source, _ in
      if command == .next { await gate.wait() }
      return .rejected(target: source)
    }

    let first = Task { await activity.perform(.next, for: source) }
    await gate.waitUntilWaiting()
    await activity.perform(.previous, for: source)
    await gate.release()
    await first.value

    XCTAssertEqual(activity.lastMediaCommandResult, .rejected(target: source))
    XCTAssertEqual(
      activity.mediaControlNotice, "Can't go to the previous track: the player rejected it")
  }

  func testOnlyTheAcceptedLatestFailureIsAnnounced() async {
    let source = SourceID(
      bundleIdentifier: "com.example.Player", pid: 42, parentBundleIdentifier: "")
    let gate = CommandGate()
    let announcements = AnnouncementRecorder()
    let activity = NowPlayingActivity(
      commandPerformer: { command, source, _ in
        if command == .next { await gate.wait() }
        return .rejected(target: source)
      },
      announce: { announcements.messages.append($0) })

    let first = Task { await activity.perform(.next, for: source) }
    await gate.waitUntilWaiting()
    await activity.perform(.previous, for: source)
    await gate.release()
    await first.value

    XCTAssertEqual(
      announcements.messages,
      ["Media control error: Can't go to the previous track: the player rejected it"])
  }

  func testUnconfirmedSeekPublishesAndAnnouncesStatus() async {
    let source = SourceID(
      bundleIdentifier: "com.example.Player", pid: 42, parentBundleIdentifier: "")
    let announcements = AnnouncementRecorder()
    let activity = NowPlayingActivity(
      commandPerformer: { _, source, _ in .unconfirmed(target: source) },
      announce: { announcements.messages.append($0) })

    await activity.perform(.seek(to: 42), for: source)

    XCTAssertEqual(activity.lastMediaCommandResult, .unconfirmed(target: source))
    XCTAssertEqual(
      activity.mediaControlNotice,
      "Couldn't confirm seek: the player didn't report a result")
    XCTAssertEqual(
      announcements.messages,
      ["Media control error: Couldn't confirm seek: the player didn't report a result"])
  }

  func testControlAvailabilityFailsClosedForUnknownSourceAndUnseekableMedia() {
    let source = SourceID(
      bundleIdentifier: "com.example.Player", pid: 42, parentBundleIdentifier: "")
    let activity = NowPlayingActivity()

    XCTAssertFalse(activity.canPerform(.togglePlayPause, for: source))
    XCTAssertFalse(activity.canPerform(.seek(to: 20), for: source))
  }

  func testZeroAndNonFiniteDurationsAreNotSeekable() {
    var state = PlaybackState()
    XCTAssertEqual(state.seekability, .unavailable)

    state.duration = .nan
    XCTAssertEqual(state.seekability, .unavailable)

    state.duration = .infinity
    XCTAssertEqual(state.seekability, .unavailable)
  }

  func testLiveMediaIsNeverSeekableEvenWithRollingDuration() {
    var state = PlaybackState()
    state.duration = 60
    state.isLive = true
    XCTAssertEqual(state.seekability, .live)
  }

  func testExplicitlyNonSeekableMediaHidesTheScrubber() {
    var state = PlaybackState()
    state.duration = 60
    state.supportsSeeking = false
    XCTAssertEqual(state.seekability, .unavailable)
  }

  func testFiniteOnDemandMediaIsSeekable() {
    var state = PlaybackState()
    state.duration = 60
    state.supportsSeeking = true
    XCTAssertEqual(state.seekability, .seekable)
  }

  func testExternalBackwardSeekIsAcceptedWhenNoLocalSeekIsPending() {
    let source = SourceID(
      bundleIdentifier: "com.example.player", pid: 1, parentBundleIdentifier: "")
    let start = Date(timeIntervalSinceReferenceDate: 10)
    var first = PlaybackState()
    first.duration = 120
    first.elapsed = 30
    first.elapsedAt = start
    first.isPlaying = true
    first.supportsSeeking = true

    var externalSeek = first
    externalSeek.elapsed = 10
    externalSeek.elapsedAt = start.addingTimeInterval(5)

    var table = MediaSourceTable()
    table.upsert(source, first, now: start)
    table.upsert(source, externalSeek, now: start.addingTimeInterval(5))
    XCTAssertEqual(table.states[source]?.currentElapsed(at: start.addingTimeInterval(5)), 10)
  }

  func testLocalSeekUpdatesPositionOptimistically() {
    let source = SourceID(
      bundleIdentifier: "com.example.player", pid: 1, parentBundleIdentifier: "")
    let start = Date(timeIntervalSinceReferenceDate: 10)
    var playing = PlaybackState()
    playing.duration = 120
    playing.elapsed = 30
    playing.elapsedAt = start
    playing.isPlaying = true
    playing.supportsSeeking = true

    var table = MediaSourceTable()
    table.upsert(source, playing, now: start)
    XCTAssertEqual(table.seek(source, to: 5, now: start.addingTimeInterval(1)), 5)
    XCTAssertEqual(table.states[source]?.currentElapsed(at: start.addingTimeInterval(1)), 5)
  }

  func testExternalSeekDuringALocalSeekWinsImmediately() {
    let source = SourceID(
      bundleIdentifier: "com.example.player", pid: 1, parentBundleIdentifier: "")
    let start = Date(timeIntervalSinceReferenceDate: 10)
    var playing = PlaybackState()
    playing.duration = 120
    playing.elapsed = 30
    playing.elapsedAt = start
    playing.isPlaying = true
    playing.supportsSeeking = true

    var table = MediaSourceTable()
    table.upsert(source, playing, now: start)
    XCTAssertEqual(table.seek(source, to: 5, now: start.addingTimeInterval(1)), 5)

    var externalSeek = playing
    externalSeek.elapsed = 80
    externalSeek.elapsedAt = start.addingTimeInterval(2)
    table.upsert(source, externalSeek, now: start.addingTimeInterval(2))
    XCTAssertEqual(table.states[source]?.currentElapsed(at: start.addingTimeInterval(2)), 80)
  }

  func testAdapterUpdateAfterLocalSeekAppliesPositionAndPause() {
    let source = SourceID(
      bundleIdentifier: "com.example.player", pid: 1, parentBundleIdentifier: "")
    let start = Date(timeIntervalSinceReferenceDate: 10)
    var playing = PlaybackState()
    playing.title = "Episode"
    playing.duration = 120
    playing.elapsed = 30
    playing.elapsedAt = start
    playing.isPlaying = true
    playing.supportsSeeking = true

    var table = MediaSourceTable()
    table.upsert(source, playing, now: start)
    XCTAssertEqual(table.seek(source, to: 80, now: start.addingTimeInterval(1)), 80)

    var adapterPause = playing
    adapterPause.elapsed = 31
    adapterPause.elapsedAt = start.addingTimeInterval(2)
    adapterPause.isPlaying = false
    table.upsert(source, adapterPause, now: start.addingTimeInterval(2))

    XCTAssertEqual(table.states[source]?.elapsed, 31)
    XCTAssertEqual(table.states[source]?.isPlaying, false)
  }

  func testTrackChangeStartsAtReportedPositionAfterLocalSeek() {
    let source = SourceID(
      bundleIdentifier: "com.example.player", pid: 1, parentBundleIdentifier: "")
    let start = Date(timeIntervalSinceReferenceDate: 10)
    var first = PlaybackState()
    first.title = "First"
    first.duration = 120
    first.elapsed = 30
    first.supportsSeeking = true

    var table = MediaSourceTable()
    table.upsert(source, first, now: start)
    XCTAssertEqual(table.seek(source, to: 80, now: start), 80)

    var second = first
    second.title = "Second"
    second.elapsed = 0
    table.upsert(source, second, now: start.addingTimeInterval(1))
    XCTAssertEqual(table.states[source]?.title, "Second")
    XCTAssertEqual(table.states[source]?.elapsed, 0)
  }

  func testScrubCompletionForAReplacedPrimaryIsIgnored() {
    let old = SourceID(bundleIdentifier: "com.example.old", pid: 1, parentBundleIdentifier: "")
    let new = SourceID(bundleIdentifier: "com.example.new", pid: 2, parentBundleIdentifier: "")
    var session = PlaybackScrubSession()
    session.begin(for: old)
    XCTAssertNil(session.finish(value: 25, currentSource: new))
    XCTAssertFalse(session.isActive)
  }
}

@MainActor
private final class AnnouncementRecorder {
  var messages: [String] = []
}

private actor CommandResults {
  private var results: [MediaCommandResult]

  init(_ results: [MediaCommandResult]) {
    self.results = results
  }

  func next(for source: SourceID) -> MediaCommandResult {
    results.isEmpty ? .sourceNotControllable(source) : results.removeFirst()
  }
}

private actor CommandGate {
  private var continuation: CheckedContinuation<Void, Never>?
  private var readyContinuation: CheckedContinuation<Void, Never>?

  func wait() async {
    readyContinuation?.resume()
    readyContinuation = nil
    await withCheckedContinuation { continuation = $0 }
  }

  func waitUntilWaiting() async {
    guard continuation == nil else { return }
    await withCheckedContinuation { readyContinuation = $0 }
  }

  func release() {
    continuation?.resume()
    continuation = nil
  }
}
