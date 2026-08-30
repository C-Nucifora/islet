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

  func testCommandFailurePublishesActionSpecificFeedback() async {
    let source = SourceID(
      bundleIdentifier: "com.example.Player", pid: 42, parentBundleIdentifier: "")
    let activity = NowPlayingActivity { _, source, _, _ in .rejected(target: source) }

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
    let activity = NowPlayingActivity { _, source, _, _ in await results.next(for: source) }

    await activity.perform(.next, for: source)
    await activity.perform(.next, for: source)

    XCTAssertEqual(activity.lastMediaCommandResult, .sent(target: source, sourceScoped: false))
    XCTAssertNil(activity.mediaControlNotice)
  }

  func testEarlierCommandCannotOverwriteFeedbackForALaterTap() async {
    let source = SourceID(
      bundleIdentifier: "com.example.Player", pid: 42, parentBundleIdentifier: "")
    let gate = CommandGate()
    let activity = NowPlayingActivity { command, source, _, _ in
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

  func testControlAvailabilityFailsClosedForUnknownSourceAndUnseekableMedia() {
    let source = SourceID(
      bundleIdentifier: "com.example.Player", pid: 42, parentBundleIdentifier: "")
    let activity = NowPlayingActivity()

    XCTAssertFalse(activity.canPerform(.togglePlayPause, for: source))
    XCTAssertFalse(activity.canPerform(.seek(to: 20), for: source))
  }
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
