import XCTest

@testable import Islet

final class ClipboardPollingPolicyTests: XCTestCase {
  private let start = Date(timeIntervalSinceReferenceDate: 1_000)

  private func policy(at date: Date) -> ClipboardPollingPolicy {
    ClipboardPollingPolicy(now: { date })
  }

  private func activeState(
    lastActivity: Date? = nil, lowPowerMode: Bool = false
  ) -> ClipboardPollingPolicy.State {
    .init(
      isEnabled: true,
      isPaused: false,
      isAppActive: true,
      isLowPowerMode: lowPowerMode,
      lastActivity: lastActivity)
  }

  func testRapidChangesKeepThePromptCadence() {
    var state = activeState(lastActivity: start)
    let firstChange = policy(at: start.addingTimeInterval(4.9))
    state = firstChange.stateRecordingActivity(from: state)
    let secondChange = policy(at: start.addingTimeInterval(9.8))
    state = secondChange.stateRecordingActivity(from: state)

    XCTAssertEqual(secondChange.nextDelay(for: state), 0.25)
  }

  func testIdlePollingBacksOffInBoundedSteps() {
    let state = activeState(lastActivity: start)

    XCTAssertEqual(policy(at: start.addingTimeInterval(4.9)).nextDelay(for: state), 0.25)
    XCTAssertEqual(policy(at: start.addingTimeInterval(5)).nextDelay(for: state), 1)
    XCTAssertEqual(policy(at: start.addingTimeInterval(30)).nextDelay(for: state), 3)
    XCTAssertEqual(policy(at: start.addingTimeInterval(120)).nextDelay(for: state), 10)
    XCTAssertEqual(policy(at: start.addingTimeInterval(600)).nextDelay(for: state), 30)
  }

  func testDetectedActivityResetsAnIdleSchedule() {
    var state = activeState(lastActivity: start)
    let idlePolicy = policy(at: start.addingTimeInterval(600))
    XCTAssertEqual(idlePolicy.nextDelay(for: state), 30)

    let activityPolicy = policy(at: start.addingTimeInterval(601))
    state = activityPolicy.stateRecordingActivity(from: state)
    XCTAssertEqual(activityPolicy.nextDelay(for: state), 0.25)
  }

  func testLowPowerModeDoublesCadenceWithASixtySecondCeiling() {
    let recent = activeState(lastActivity: start, lowPowerMode: true)
    let idle = activeState(lastActivity: start, lowPowerMode: true)

    XCTAssertEqual(policy(at: start).nextDelay(for: recent), 0.5)
    XCTAssertEqual(policy(at: start.addingTimeInterval(600)).nextDelay(for: idle), 60)
  }

  func testBackgroundAppSlowsPollingAndForegroundCanResumePromptly() {
    var state = activeState(lastActivity: start)
    state.isAppActive = false
    XCTAssertEqual(policy(at: start).nextDelay(for: state), 0.5)
    XCTAssertEqual(policy(at: start.addingTimeInterval(600)).nextDelay(for: state), 60)

    state.isAppActive = true
    let foreground = policy(at: start.addingTimeInterval(601))
    state = foreground.stateRecordingActivity(from: state)
    XCTAssertEqual(foreground.nextDelay(for: state), 0.25)
  }

  func testPauseAndDisableCancelTheSchedule() {
    var paused = activeState(lastActivity: start)
    paused.isPaused = true
    XCTAssertNil(policy(at: start).nextDelay(for: paused))

    var disabled = activeState(lastActivity: start)
    disabled.isEnabled = false
    XCTAssertNil(policy(at: start).nextDelay(for: disabled))
  }

  func testStopAndRestartStartsWithThePromptCadence() {
    var state = activeState(lastActivity: start)
    state.isEnabled = false
    XCTAssertNil(policy(at: start.addingTimeInterval(600)).nextDelay(for: state))

    state.isEnabled = true
    let restart = policy(at: start.addingTimeInterval(600))
    state = restart.stateRecordingActivity(from: state)
    XCTAssertEqual(restart.nextDelay(for: state), 0.25)
  }
}
