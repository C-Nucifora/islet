import AppKit
import XCTest

@testable import Islet

@MainActor
private final class ClipboardPollingSchedulerProbe: ClipboardPollingScheduling {
  @MainActor
  final class ScheduledTask: ClipboardPollingTask {
    let delay: TimeInterval
    private let action: @MainActor () -> Void
    private(set) var isCancelled = false

    init(delay: TimeInterval, action: @escaping @MainActor () -> Void) {
      self.delay = delay
      self.action = action
    }

    func cancel() { isCancelled = true }
    func fire() { action() }
  }

  private(set) var tasks: [ScheduledTask] = []

  func schedule(
    after delay: TimeInterval, action: @escaping @MainActor () -> Void
  ) -> any ClipboardPollingTask {
    let task = ScheduledTask(delay: delay, action: action)
    tasks.append(task)
    return task
  }
}

@MainActor
private final class ClipboardPollingPrivacyStore: ClipboardPrivacyStoring {
  var onChange: (() -> Void)?
  private var configuration = ClipboardPrivacyConfiguration()

  func load() -> ClipboardPrivacyConfiguration { configuration }
  func save(_ configuration: ClipboardPrivacyConfiguration) {
    self.configuration = configuration
  }
}

@MainActor
private final class ClipboardPollingContextMonitor: ClipboardContextMonitoring {
  var context = ClipboardCaptureContext(
    application: ClipboardApplicationIdentity(
      bundleIdentifier: "com.example.clipboard-polling-tests", name: "Clipboard Polling Tests"))
  var onChange: ((ClipboardCaptureContext) -> Void)?

  func start() {}
  func stop() {}
  func refreshApplication() -> Bool { false }
}

@MainActor
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

  func testSupersededPollCallbackCannotReplaceTheCurrentSchedule() throws {
    let pasteboard = NSPasteboard(
      name: NSPasteboard.Name("islet-tests-poll-generation-\(UUID().uuidString)"))
    let scheduler = ClipboardPollingSchedulerProbe()
    let model = makeModel(pasteboard: pasteboard, scheduler: scheduler)
    model.start()
    XCTAssertEqual(scheduler.tasks.count, 1)

    model.setPaused(true)
    model.setPaused(false)
    XCTAssertEqual(scheduler.tasks.count, 2)
    XCTAssertTrue(scheduler.tasks[0].isCancelled)
    XCTAssertFalse(scheduler.tasks[1].isCancelled)
    pasteboard.clearContents()
    XCTAssertTrue(pasteboard.setString("new copy", forType: .string))

    scheduler.tasks[0].fire()
    XCTAssertTrue(model.items.isEmpty)
    XCTAssertEqual(scheduler.tasks.count, 2)
    XCTAssertFalse(scheduler.tasks[1].isCancelled)

    scheduler.tasks[1].fire()
    XCTAssertEqual(model.items.map(\.kind), [.text("new copy")])
    XCTAssertEqual(scheduler.tasks.count, 3)
    model.stop()
  }

  func testForegroundCheckCancelsTheExistingSchedule() {
    let pasteboard = NSPasteboard(
      name: NSPasteboard.Name("islet-tests-poll-foreground-\(UUID().uuidString)"))
    let scheduler = ClipboardPollingSchedulerProbe()
    let model = makeModel(pasteboard: pasteboard, scheduler: scheduler)
    model.start()
    XCTAssertEqual(scheduler.tasks.count, 1)

    NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)

    XCTAssertEqual(scheduler.tasks.count, 2)
    XCTAssertTrue(scheduler.tasks[0].isCancelled)
    XCTAssertFalse(scheduler.tasks[1].isCancelled)
    model.stop()
  }

  func testClearDiscardsAPasteboardChangeThatPredatesIt() {
    let pasteboard = NSPasteboard(
      name: NSPasteboard.Name("islet-tests-poll-clear-\(UUID().uuidString)"))
    let scheduler = ClipboardPollingSchedulerProbe()
    let model = makeModel(pasteboard: pasteboard, scheduler: scheduler)
    model.start()
    pasteboard.clearContents()
    XCTAssertTrue(pasteboard.setString("copied before clear", forType: .string))

    model.clear()

    guard scheduler.tasks.count == 2 else {
      XCTFail("Clear must replace the pending poll")
      model.stop()
      return
    }
    XCTAssertTrue(scheduler.tasks[0].isCancelled)
    scheduler.tasks[0].fire()
    XCTAssertTrue(model.items.isEmpty)
    XCTAssertEqual(scheduler.tasks.count, 2)

    scheduler.tasks[1].fire()
    XCTAssertTrue(model.items.isEmpty)
    XCTAssertEqual(scheduler.tasks.count, 3)
    model.stop()
  }

  func testTimedPauseSchedulesItsOwnExpiryAndResumesWithoutManualPolling() {
    let pasteboard = NSPasteboard(
      name: NSPasteboard.Name("islet-tests-poll-timed-pause-\(UUID().uuidString)"))
    let scheduler = ClipboardPollingSchedulerProbe()
    let store = ClipboardPollingPrivacyStore()
    let context = ClipboardPollingContextMonitor()
    var now = start
    let policy = ClipboardPollingPolicy(now: { now })
    let model = ClipboardModel(
      pasteboard: pasteboard, privacyStore: store, contextMonitor: context, now: { now },
      pollingPolicy: policy, pollingScheduler: scheduler)
    model.start()

    model.pause(for: 5 * 60)

    XCTAssertTrue(model.isPaused)
    XCTAssertEqual(scheduler.tasks.count, 2)
    XCTAssertTrue(scheduler.tasks[0].isCancelled)
    XCTAssertEqual(scheduler.tasks[1].delay, 5 * 60)

    now.addTimeInterval(5 * 60)
    scheduler.tasks[1].fire()

    XCTAssertFalse(model.isPaused)
    XCTAssertNil(store.load().pausedUntil)
    XCTAssertEqual(scheduler.tasks.count, 3)
    model.stop()
  }

  private func makeModel(
    pasteboard: NSPasteboard, scheduler: ClipboardPollingSchedulerProbe
  ) -> ClipboardModel {
    ClipboardModel(
      pasteboard: pasteboard,
      privacyStore: ClipboardPollingPrivacyStore(),
      contextMonitor: ClipboardPollingContextMonitor(),
      pollingScheduler: scheduler)
  }
}
