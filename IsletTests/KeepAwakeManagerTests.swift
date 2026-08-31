import Combine
import Defaults
import Foundation
import XCTest

@testable import Islet

@MainActor
final class KeepAwakeManagerTests: XCTestCase {
  func testPreferenceChangeFromUtilityTaskPublishesOnMainAndUpdatesDisplayAssertion() async {
    let savedAllowDisplaySleep = Defaults[.allowDisplaySleep]
    let changedAllowDisplaySleep = !savedAllowDisplaySleep
    defer { Defaults[.allowDisplaySleep] = savedAllowDisplaySleep }

    let fixture = Fixture(
      allowDisplaySleep: savedAllowDisplaySleep, observePreferenceChanges: true)
    XCTAssertTrue(fixture.manager.start(duration: .indefinitely))
    let published = expectation(description: "KeepAwakeManager publishes the preference change")
    let cancellable = fixture.manager.$allowDisplaySleep.dropFirst().sink { value in
      XCTAssertTrue(Thread.isMainThread)
      XCTAssertEqual(value, changedAllowDisplaySleep)
      published.fulfill()
    }

    await Task.detached(priority: .utility) {
      Defaults[.allowDisplaySleep] = changedAllowDisplaySleep
    }.value
    await fulfillment(of: [published], timeout: 2)

    XCTAssertEqual(fixture.manager.effectivelyAllowsDisplaySleep, changedAllowDisplaySleep)
    if changedAllowDisplaySleep {
      XCTAssertEqual(fixture.provider.releasedIDs, [2])
    } else {
      XCTAssertEqual(fixture.provider.createdKinds, [.systemSleep, .displaySleep])
    }
    cancellable.cancel()
    fixture.manager.stop(reason: .manual)
  }

  func testIndefiniteSessionCreatesSystemAssertionAndReleasesItExactlyOnce() {
    let fixture = Fixture(allowDisplaySleep: true)

    XCTAssertTrue(fixture.manager.start(duration: .indefinitely))
    XCTAssertTrue(fixture.manager.isActive)
    XCTAssertEqual(fixture.provider.createdKinds, [.systemSleep])
    XCTAssertNil(fixture.manager.remainingTime)

    fixture.manager.stop(reason: .manual)
    fixture.manager.stop(reason: .manual)

    XCTAssertFalse(fixture.manager.isActive)
    XCTAssertEqual(fixture.manager.lastEndReason, .manual)
    XCTAssertEqual(fixture.provider.releasedIDs, [1])
  }

  func testDisplayPreferenceOnlyChangesTheDisplayAssertionDuringSession() {
    let fixture = Fixture(allowDisplaySleep: false)
    XCTAssertTrue(fixture.manager.start(duration: .indefinitely))
    XCTAssertEqual(fixture.provider.createdKinds, [.systemSleep, .displaySleep])

    fixture.manager.setAllowDisplaySleep(true)
    XCTAssertEqual(fixture.provider.releasedIDs, [2])

    fixture.manager.setAllowDisplaySleep(false)
    XCTAssertEqual(
      fixture.provider.createdKinds, [.systemSleep, .displaySleep, .displaySleep])
    XCTAssertEqual(fixture.provider.releasedIDs, [2])

    fixture.manager.stop(reason: .manual)
    XCTAssertEqual(fixture.provider.releasedIDs, [2, 3, 1])
  }

  func testPartialCreationFailureRollsBackSystemAssertion() {
    let fixture = Fixture(allowDisplaySleep: false)
    fixture.provider.failCreationFor = .displaySleep

    XCTAssertFalse(fixture.manager.start(duration: .indefinitely))
    XCTAssertFalse(fixture.manager.isActive)
    XCTAssertEqual(fixture.provider.createdKinds, [.systemSleep, .displaySleep])
    XCTAssertEqual(fixture.provider.releasedIDs, [1])
    XCTAssertNotNil(fixture.manager.lastError)
  }

  func testSystemCreationFailureDoesNotCreateOrReleaseDisplayAssertion() {
    let fixture = Fixture(allowDisplaySleep: false)
    fixture.provider.failCreationFor = .systemSleep

    XCTAssertFalse(fixture.manager.start(duration: .indefinitely))
    XCTAssertEqual(fixture.provider.createdKinds, [.systemSleep])
    XCTAssertTrue(fixture.provider.releasedIDs.isEmpty)
  }

  func testFailedReleaseStaysOwnedUntilLaterStopSucceeds() {
    let fixture = Fixture(allowDisplaySleep: true)
    XCTAssertTrue(fixture.manager.start(duration: .indefinitely))
    fixture.provider.releaseFailuresRemaining[1] = 1

    fixture.manager.stop(reason: .manual)
    XCTAssertEqual(fixture.provider.releasedIDs, [1])
    XCTAssertTrue(fixture.manager.hasUnreleasedAssertions)

    fixture.manager.stop(reason: .quit)
    fixture.manager.stop(reason: .quit)

    XCTAssertEqual(fixture.provider.releasedIDs, [1, 1])
    XCTAssertEqual(fixture.provider.successfulReleases, [1])
    XCTAssertFalse(fixture.manager.hasUnreleasedAssertions)
    XCTAssertEqual(fixture.manager.lastEndReason, .quit)
    XCTAssertNil(fixture.manager.lastError)
  }

  func testPartialCreationRollbackReleaseFailureRemainsRetryable() {
    let fixture = Fixture(allowDisplaySleep: false)
    fixture.provider.failCreationFor = .displaySleep
    fixture.provider.releaseFailuresRemaining[1] = 1

    XCTAssertFalse(fixture.manager.start(duration: .indefinitely))
    XCTAssertTrue(fixture.manager.hasUnreleasedAssertions)
    XCTAssertEqual(fixture.provider.releasedIDs, [1])

    fixture.manager.retryUnreleasedAssertions()
    fixture.manager.retryUnreleasedAssertions()
    XCTAssertFalse(fixture.manager.hasUnreleasedAssertions)
    XCTAssertEqual(fixture.provider.releasedIDs, [1, 1])
    XCTAssertEqual(fixture.provider.successfulReleases, [1])
  }

  func testTimedSessionExpiresFromMonotonicDeadline() {
    let fixture = Fixture(allowDisplaySleep: true)
    XCTAssertTrue(fixture.manager.start(duration: .timed(10)))
    XCTAssertEqual(fixture.manager.remainingTime, 10)
    XCTAssertEqual(fixture.manager.endsAt, Date(timeIntervalSince1970: 1_010))

    fixture.clock.advance(monotonic: 10, wall: 10)
    fixture.scheduler.fireLatest()

    XCTAssertFalse(fixture.manager.isActive)
    XCTAssertEqual(fixture.manager.lastEndReason, .timer)
    XCTAssertEqual(fixture.provider.releasedIDs, [1])
  }

  func testReplacingTimerKeepsAssertionsAndStaleCallbackCannotEndNewSession() {
    let fixture = Fixture(allowDisplaySleep: false)
    XCTAssertTrue(fixture.manager.start(duration: .timed(10)))
    let staleTask = fixture.scheduler.latestTask

    fixture.clock.advance(monotonic: 2, wall: 2)
    XCTAssertTrue(fixture.manager.start(duration: .timed(30)))
    XCTAssertEqual(fixture.provider.createdKinds, [.systemSleep, .displaySleep])

    fixture.clock.advance(monotonic: 9, wall: 9)
    staleTask?.fireIgnoringCancellation()
    XCTAssertTrue(fixture.manager.isActive)

    fixture.clock.advance(monotonic: 21, wall: 21)
    fixture.scheduler.fireLatest()
    XCTAssertFalse(fixture.manager.isActive)
    XCTAssertEqual(fixture.manager.lastEndReason, .timer)
  }

  func testClockChangeRebuildsWallDeadlineWithoutChangingElapsedTime() {
    let fixture = Fixture(allowDisplaySleep: true)
    XCTAssertTrue(fixture.manager.start(duration: .timed(60)))

    fixture.clock.advance(monotonic: 10, wall: 3_610)
    fixture.manager.systemTimeDidChange()

    XCTAssertTrue(fixture.manager.isActive)
    XCTAssertEqual(fixture.manager.remainingTime, 50)
    XCTAssertEqual(fixture.manager.endsAt, Date(timeIntervalSince1970: 4_660))

    fixture.clock.advance(monotonic: 50, wall: 50)
    fixture.manager.systemTimeDidChange()
    XCTAssertFalse(fixture.manager.isActive)
    XCTAssertEqual(fixture.manager.lastEndReason, .timer)
  }

  func testLowBatteryStopsOnlyWhileUnpluggedAndThresholdIsEnabled() {
    let fixture = Fixture(allowDisplaySleep: true)
    XCTAssertTrue(fixture.manager.start(duration: .indefinitely))

    fixture.manager.handleBattery(
      BatteryState(percent: 10, isCharging: false, onAC: true), lowBatteryThreshold: 20)
    XCTAssertTrue(fixture.manager.isActive)
    fixture.manager.handleBattery(
      BatteryState(percent: 10, isCharging: false, onAC: false), lowBatteryThreshold: 0)
    XCTAssertTrue(fixture.manager.isActive)
    fixture.manager.handleBattery(
      BatteryState(percent: 20, isCharging: false, onAC: false), lowBatteryThreshold: 20)

    XCTAssertFalse(fixture.manager.isActive)
    XCTAssertEqual(fixture.manager.lastEndReason, .battery)
    XCTAssertEqual(fixture.provider.releasedIDs, [1])
  }

  func testAlreadyLowBatteryPreventsSessionFromCreatingAssertions() {
    let fixture = Fixture(allowDisplaySleep: false, lowBatteryThreshold: 20)
    fixture.batteryStateProvider.state = BatteryState(
      percent: 19, isCharging: false, onAC: false)

    XCTAssertFalse(fixture.manager.start(duration: .indefinitely))

    XCTAssertFalse(fixture.manager.isActive)
    XCTAssertEqual(fixture.manager.lastEndReason, .battery)
    XCTAssertTrue(fixture.provider.createdKinds.isEmpty)
    XCTAssertNotNil(fixture.manager.lastError)
  }

  func testRaisingThresholdStopsActiveSessionUsingLatestBatteryState() {
    let fixture = Fixture(allowDisplaySleep: true, lowBatteryThreshold: 10)
    fixture.manager.handleBattery(
      BatteryState(percent: 20, isCharging: false, onAC: false), lowBatteryThreshold: 10)
    XCTAssertTrue(fixture.manager.start(duration: .indefinitely))

    fixture.manager.setLowBatteryThreshold(30)

    XCTAssertFalse(fixture.manager.isActive)
    XCTAssertEqual(fixture.manager.lastEndReason, .battery)
    XCTAssertEqual(fixture.provider.releasedIDs, [1])
  }

  func testClearingBatteryStateAllowsStartAfterMonitoringStops() {
    let fixture = Fixture(allowDisplaySleep: true, lowBatteryThreshold: 20)
    fixture.manager.handleBattery(
      BatteryState(percent: 10, isCharging: false, onAC: false), lowBatteryThreshold: 20)
    fixture.manager.clearBatteryState()

    XCTAssertTrue(fixture.manager.start(duration: .indefinitely))
    XCTAssertEqual(fixture.provider.createdKinds, [.systemSleep])
  }

  func testDisplayCreationFailureDuringLivePreferenceChangeKeepsSystemSession() {
    let fixture = Fixture(allowDisplaySleep: true)
    XCTAssertTrue(fixture.manager.start(duration: .indefinitely))
    fixture.provider.failCreationFor = .displaySleep

    fixture.manager.setAllowDisplaySleep(false)

    XCTAssertTrue(fixture.manager.isActive)
    XCTAssertEqual(fixture.provider.createdKinds, [.systemSleep, .displaySleep])
    XCTAssertTrue(fixture.provider.releasedIDs.isEmpty)
    XCTAssertNotNil(fixture.manager.lastError)

    fixture.provider.failCreationFor = nil
    fixture.manager.retryUnreleasedAssertions()
    XCTAssertFalse(fixture.manager.effectivelyAllowsDisplaySleep)
    XCTAssertNil(fixture.manager.lastError)

    fixture.manager.stop(reason: .manual)
    XCTAssertEqual(fixture.provider.releasedIDs, [2, 1])
  }

  func testFailedLiveDisplayReleaseRetainsEffectiveStateAndRetriesOnNextTransition() {
    let fixture = Fixture(allowDisplaySleep: false)
    XCTAssertTrue(fixture.manager.start(duration: .indefinitely))
    fixture.provider.releaseFailuresRemaining[2] = 1

    fixture.manager.setAllowDisplaySleep(true)
    XCTAssertTrue(fixture.manager.allowDisplaySleep)
    XCTAssertFalse(fixture.manager.effectivelyAllowsDisplaySleep)
    XCTAssertEqual(fixture.provider.releasedIDs, [2])
    XCTAssertNotNil(fixture.manager.lastError)

    fixture.manager.retryUnreleasedAssertions()
    XCTAssertTrue(fixture.manager.effectivelyAllowsDisplaySleep)
    XCTAssertEqual(fixture.provider.releasedIDs, [2, 2])
    XCTAssertEqual(fixture.provider.successfulReleases, [2])

    fixture.manager.stop(reason: .manual)
    XCTAssertEqual(fixture.provider.releasedIDs, [2, 2, 1])
    XCTAssertEqual(fixture.provider.successfulReleases, [2, 1])
  }

  func testNewSessionReleasesOldFailedAssertionBeforeCreatingReplacement() {
    let fixture = Fixture(allowDisplaySleep: true)
    XCTAssertTrue(fixture.manager.start(duration: .indefinitely))
    fixture.provider.releaseFailuresRemaining[1] = 1
    fixture.manager.stop(reason: .manual)
    XCTAssertTrue(fixture.manager.hasUnreleasedAssertions)

    XCTAssertTrue(fixture.manager.start(duration: .indefinitely))
    XCTAssertEqual(fixture.provider.releasedIDs, [1, 1])
    XCTAssertEqual(fixture.provider.createdKinds, [.systemSleep, .systemSleep])
    XCTAssertTrue(fixture.manager.effectivelyAllowsDisplaySleep)
  }

  func testNullAssertionIDFailsWithoutAttemptingToReleaseIt() {
    let fixture = Fixture(allowDisplaySleep: true)
    fixture.provider.nullCreationFor = .systemSleep

    XCTAssertFalse(fixture.manager.start(duration: .indefinitely))
    XCTAssertFalse(fixture.manager.isActive)
    XCTAssertFalse(fixture.manager.hasUnreleasedAssertions)
    XCTAssertTrue(fixture.provider.releasedIDs.isEmpty)
    XCTAssertNotNil(fixture.manager.lastError)
  }

  func testInvalidTimedDurationDoesNotCreateOrReplaceAssertions() {
    let fixture = Fixture(allowDisplaySleep: true)

    XCTAssertFalse(fixture.manager.start(duration: .timed(.nan)))
    XCTAssertFalse(fixture.manager.start(duration: .timed(0)))
    XCTAssertFalse(fixture.manager.start(duration: .timed(-1)))
    XCTAssertTrue(fixture.provider.createdKinds.isEmpty)

    XCTAssertTrue(fixture.manager.start(duration: .timed(60)))
    XCTAssertFalse(fixture.manager.start(duration: .timed(.infinity)))
    XCTAssertTrue(fixture.manager.isActive)
    XCTAssertEqual(fixture.manager.remainingTime, 60)
    XCTAssertEqual(fixture.provider.createdKinds, [.systemSleep])
  }
}

@MainActor
private struct Fixture {
  let provider = TestAssertionProvider()
  let clock = TestKeepAwakeClock()
  let scheduler = TestKeepAwakeScheduler()
  let batteryStateProvider = TestBatteryStateProvider()
  let manager: KeepAwakeManager

  init(
    allowDisplaySleep: Bool, lowBatteryThreshold: Int = 20,
    observePreferenceChanges: Bool = false
  ) {
    manager = KeepAwakeManager(
      assertionProvider: provider, clock: clock, scheduler: scheduler,
      allowDisplaySleep: allowDisplaySleep, lowBatteryThreshold: lowBatteryThreshold,
      batteryStateProvider: { [batteryStateProvider] in batteryStateProvider.state },
      observePreferenceChanges: observePreferenceChanges)
  }
}

private final class TestBatteryStateProvider {
  var state: BatteryState?
}

private enum TestKeepAwakeError: Error {
  case expectedFailure
}

private final class TestAssertionProvider: KeepAwakeAssertionProviding {
  var createdKinds: [KeepAwakeAssertionKind] = []
  var releasedIDs: [UInt32] = []
  var successfulReleases: [UInt32] = []
  var failCreationFor: KeepAwakeAssertionKind?
  var nullCreationFor: KeepAwakeAssertionKind?
  var releaseFailuresRemaining: [UInt32: Int] = [:]
  private var nextID: UInt32 = 1

  func create(_ kind: KeepAwakeAssertionKind, reason: String) throws -> UInt32 {
    createdKinds.append(kind)
    guard failCreationFor != kind else { throw TestKeepAwakeError.expectedFailure }
    if nullCreationFor == kind { return 0 }
    defer { nextID += 1 }
    return nextID
  }

  func release(_ assertionID: UInt32) throws {
    releasedIDs.append(assertionID)
    let failures = releaseFailuresRemaining[assertionID, default: 0]
    if failures > 0 {
      releaseFailuresRemaining[assertionID] = failures - 1
      throw TestKeepAwakeError.expectedFailure
    }
    successfulReleases.append(assertionID)
  }
}

private final class TestKeepAwakeClock: KeepAwakeClock {
  var wallNow = Date(timeIntervalSince1970: 1_000)
  var monotonicNow: TimeInterval = 100

  func advance(monotonic: TimeInterval, wall: TimeInterval) {
    monotonicNow += monotonic
    wallNow = wallNow.addingTimeInterval(wall)
  }
}

@MainActor
private final class TestKeepAwakeScheduler: KeepAwakeScheduling {
  private(set) var tasks: [TestKeepAwakeTask] = []
  var latestTask: TestKeepAwakeTask? { tasks.last }

  func schedule(after delay: TimeInterval, action: @escaping @MainActor () -> Void)
    -> KeepAwakeScheduledTask
  {
    let task = TestKeepAwakeTask(delay: delay, action: action)
    tasks.append(task)
    return task
  }

  func fireLatest() {
    latestTask?.fire()
  }
}

@MainActor
private final class TestKeepAwakeTask: KeepAwakeScheduledTask {
  let delay: TimeInterval
  private let action: @MainActor () -> Void
  private var isCancelled = false

  init(delay: TimeInterval, action: @escaping @MainActor () -> Void) {
    self.delay = delay
    self.action = action
  }

  func cancel() {
    isCancelled = true
  }

  func fire() {
    guard !isCancelled else { return }
    action()
  }

  func fireIgnoringCancellation() {
    action()
  }
}
