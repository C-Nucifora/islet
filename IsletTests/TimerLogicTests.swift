import XCTest

@testable import Islet

@MainActor
final class TimerLogicTests: XCTestCase {
  func testRejectsInvalidDurations() {
    XCTAssertNil(TimerLogic.validatedDuration(0))
    XCTAssertNil(TimerLogic.validatedDuration(-1))
    XCTAssertNil(TimerLogic.validatedDuration(.infinity))
    XCTAssertNil(TimerLogic.validatedDuration(.nan))
  }

  func testDurationIsCappedAtOneWeek() {
    XCTAssertEqual(
      TimerLogic.validatedDuration(TimerLogic.maximumDuration + 60),
      TimerLogic.maximumDuration)
  }

  func testTimerEditorAcceptsWholeMinutesAndLeavesTheLabelOptional() {
    XCTAssertEqual(TimerEditorValidation.validate(minutes: "25"), .valid(1_500))
    XCTAssertEqual(TimerEditorValidation.validate(minutes: " 5 "), .valid(300))
  }

  func testTimerEditorRejectsEmptyAndNonNumericDurations() {
    XCTAssertEqual(TimerEditorValidation.validate(minutes: ""), .missingDuration)
    XCTAssertEqual(TimerEditorValidation.validate(minutes: "five"), .invalidDuration)
    XCTAssertEqual(TimerEditorValidation.validate(minutes: "2.5"), .invalidDuration)
  }

  func testTimerEditorRejectsZeroAndNegativeDurationsBeforeStart() {
    XCTAssertEqual(TimerEditorValidation.validate(minutes: "0"), .nonPositiveDuration)
    XCTAssertEqual(TimerEditorValidation.validate(minutes: "-1"), .nonPositiveDuration)
  }

  func testTimerEditorRejectsDurationsOverOneWeekBeforeStart() {
    XCTAssertEqual(
      TimerEditorValidation.validate(minutes: "\(TimerEditorValidation.maximumMinutes + 1)"),
      .overMaximumDuration)
    XCTAssertEqual(
      TimerEditorValidation.validate(minutes: "\(TimerEditorValidation.maximumMinutes)"),
      .valid(TimerLogic.maximumDuration))
  }

  func testCustomTimerStartTrimsAnOptionalLabel() {
    let box = TimerPersistenceBox()
    let activity = TimerActivity(
      persistenceStore: box.store, completionNotifier: TimerNotifierStub())

    activity.start(300, label: "  Tea  ")
    XCTAssertEqual(activity.label, "Tea")

    activity.start(300, label: " \n")
    XCTAssertNil(activity.label)
    activity.cancel()
  }

  func testAdjustCannotFinishTimerAccidentally() {
    XCTAssertEqual(TimerLogic.adjustedRemaining(30, by: -60), 1)
  }

  func testAdjustCannotExceedMaximum() {
    XCTAssertEqual(
      TimerLogic.adjustedRemaining(TimerLogic.maximumDuration, by: 60),
      TimerLogic.maximumDuration)
  }

  func testTimerFormattingFailsClosedForInvalidValues() {
    XCTAssertEqual(TimerFormat.mmss(-5), "0:00")
    XCTAssertEqual(TimerFormat.mmss(.nan), "0:00")
    XCTAssertEqual(TimerFormat.accessible(3661), "1 hour, 1 minute, 1 second")
    XCTAssertEqual(TimerFormat.accessible(0), "0 seconds")
  }

  func testActiveAndCompletedPresentationsKeepTheSelectedTimerTheme() {
    XCTAssertEqual(TimerPresentation.tintRole(finished: false), .timer)
    XCTAssertEqual(TimerPresentation.tintRole(finished: true), .timer)
  }

  func testRestoresActiveTimerFromAbsoluteDeadline() throws {
    let now = Date(timeIntervalSinceReferenceDate: 10_000)
    let session = TimerSessionSnapshot(
      savedAt: now.addingTimeInterval(-30),
      label: "Focus",
      duration: 300,
      deadline: now.addingTimeInterval(270),
      isPaused: false,
      pausedRemaining: nil)

    XCTAssertEqual(
      TimerPersistence.restoration(from: try XCTUnwrap(TimerPersistence.encode(session)), now: now),
      .running(session))
  }

  func testRestoresPausedTimerWithoutApplyingTimeAway() throws {
    let now = Date(timeIntervalSinceReferenceDate: 20_000)
    let session = TimerSessionSnapshot(
      savedAt: now.addingTimeInterval(-3_600),
      label: "Break",
      duration: 600,
      deadline: nil,
      isPaused: true,
      pausedRemaining: 412)

    XCTAssertEqual(
      TimerPersistence.restoration(from: try XCTUnwrap(TimerPersistence.encode(session)), now: now),
      .paused(session))
  }

  func testElapsedDeadlineRestoresAsCompletedAndRetainsStoredSession() throws {
    let now = Date(timeIntervalSinceReferenceDate: 30_000)
    let session = TimerSessionSnapshot(
      savedAt: now.addingTimeInterval(-120),
      label: "Tea",
      duration: 60,
      deadline: now.addingTimeInterval(-60),
      isPaused: false,
      pausedRemaining: nil)
    let encoded = try XCTUnwrap(TimerPersistence.encode(session))
    let box = TimerPersistenceBox(sessionData: encoded)

    XCTAssertEqual(
      TimerPersistence.restoreSession(from: box.store, now: now),
      .completed(session))
    XCTAssertEqual(box.sessionData, encoded)
  }

  func testCompletedTimerRemainsActiveWhenClockAdvancesUntilDismissed() throws {
    let now = Date(timeIntervalSinceReferenceDate: 30_000)
    let session = TimerSessionSnapshot(
      savedAt: now.addingTimeInterval(-120),
      label: "Tea",
      duration: 60,
      deadline: now.addingTimeInterval(-60),
      isPaused: false,
      pausedRemaining: nil)
    let preset = TimerPresetSnapshot(duration: 60, label: "Tea")
    let persistence = TimerPersistenceBox(
      sessionData: try XCTUnwrap(TimerPersistence.encode(session)),
      presetData: try XCTUnwrap(TimerPersistence.encode(preset)))
    let clock = MutableTimerClock(now: now)
    let completionGate = ControlledTimerCompletionGate()
    let activity = TimerActivity(
      persistenceStore: persistence.store, now: now, completionNotifier: TimerNotifierStub(),
      clock: { clock.now }, completionScheduler: completionGate)

    clock.now = now.addingTimeInterval(7)
    completionGate.makeDueCompletionsReady(at: clock.now)
    completionGate.runReadyCompletions()

    XCTAssertTrue(activity.finished)
    XCTAssertTrue(activity.isActive)
    XCTAssertFalse(activity.isRunning)

    activity.cancel()

    XCTAssertFalse(activity.finished)
    XCTAssertFalse(activity.isActive)
  }

  func testReadyCompletionIsCancelledBeforeElapsedPausePathCanFireTwice() {
    let start = Date(timeIntervalSinceReferenceDate: 60_000)
    let clock = MutableTimerClock(now: start)
    let completionGate = ControlledTimerCompletionGate()
    let notifier = TimerNotifierStub()
    let persistence = TimerPersistenceBox()
    let activity = TimerActivity(
      persistenceStore: persistence.store, now: start, completionNotifier: notifier,
      clock: { clock.now }, completionScheduler: completionGate)
    activity.start(1, label: "Tea")

    clock.now = start.addingTimeInterval(1)
    completionGate.makeDueCompletionsReady(at: clock.now)
    XCTAssertEqual(completionGate.readyCount, 1)

    activity.togglePause()
    completionGate.runReadyCompletions()

    XCTAssertTrue(activity.finished)
    XCTAssertEqual(notifier.finishedCompletionIDs.count, 1)
    activity.cancel()
  }

  func testNaturalCompletionPersistsStableIdentityAndTimestampAcrossRelaunch() throws {
    let start = Date(timeIntervalSinceReferenceDate: 70_000)
    let completedAt = start.addingTimeInterval(60)
    let clock = MutableTimerClock(now: start)
    let completionGate = ControlledTimerCompletionGate()
    let notifier = TimerNotifierStub()
    let persistence = TimerPersistenceBox()
    var activity: TimerActivity? = TimerActivity(
      persistenceStore: persistence.store, now: start, completionNotifier: notifier,
      clock: { clock.now }, completionScheduler: completionGate)
    activity?.start(60, label: "Tea")

    clock.now = completedAt
    completionGate.makeDueCompletionsReady(at: completedAt)
    completionGate.runReadyCompletions()

    XCTAssertTrue(activity?.finished == true)
    XCTAssertEqual(notifier.finishedCompletionIDs.count, 1)
    XCTAssertEqual(notifier.finishedSnapshots.first?.completedAt, completedAt)
    let completionID = try XCTUnwrap(notifier.finishedCompletionIDs.first)
    let persisted = try XCTUnwrap(
      JSONDecoder().decode(
        TimerSessionSnapshot.self, from: try XCTUnwrap(persistence.sessionData)))
    XCTAssertEqual(
      persisted.completionIdentifier,
      TimerCompletionNotificationCoordinator.identifier(for: completionID))
    XCTAssertEqual(persisted.completedAt, completedAt)

    activity = nil
    clock.now = completedAt.addingTimeInterval(60)
    let restored = TimerActivity(
      persistenceStore: persistence.store, now: clock.now, completionNotifier: notifier,
      clock: { clock.now }, completionScheduler: ControlledTimerCompletionGate())

    XCTAssertTrue(restored.finished)
    XCTAssertEqual(restored.label, "Tea")
    XCTAssertEqual(notifier.finishedCompletionIDs.count, 1)
    let restoredSnapshot = try XCTUnwrap(
      JSONDecoder().decode(
        TimerSessionSnapshot.self, from: try XCTUnwrap(persistence.sessionData)))
    XCTAssertEqual(restoredSnapshot.completionIdentifier, persisted.completionIdentifier)
    XCTAssertEqual(restoredSnapshot.completedAt, persisted.completedAt)

    restored.cancel()
    XCTAssertNil(persistence.sessionData)
  }

  func testRestartReplacesCompletedTimerWithARunningTimer() throws {
    let activity = try completedActivity()

    activity.restartLastTimer()

    XCTAssertFalse(activity.finished)
    XCTAssertTrue(activity.isActive)
    XCTAssertTrue(activity.isRunning)
    XCTAssertEqual(activity.total, 60)
    XCTAssertEqual(activity.label, "Tea")
    activity.cancel()
  }

  func testCorruptSessionIsRejectedAndCleared() {
    let box = TimerPersistenceBox(sessionData: Data("not json".utf8))

    XCTAssertEqual(
      TimerPersistence.restoreSession(
        from: box.store, now: Date(timeIntervalSinceReferenceDate: 40_000)),
      .discard)
    XCTAssertNil(box.sessionData)
  }

  func testStaleSessionIsRejectedAndCleared() throws {
    let now = Date(timeIntervalSinceReferenceDate: 50_000_000)
    let savedAt = now.addingTimeInterval(-(TimerPersistence.maximumRecordAge + 1))
    let session = TimerSessionSnapshot(
      savedAt: savedAt,
      label: "Old timer",
      duration: TimerLogic.maximumDuration,
      deadline: savedAt.addingTimeInterval(TimerLogic.maximumDuration),
      isPaused: false,
      pausedRemaining: nil)
    let box = TimerPersistenceBox(sessionData: try XCTUnwrap(TimerPersistence.encode(session)))

    XCTAssertEqual(TimerPersistence.restoreSession(from: box.store, now: now), .discard)
    XCTAssertNil(box.sessionData)
  }

  func testPersistedCompletedStateDoesNotExpireBeforeAcknowledgement() throws {
    let now = Date(timeIntervalSinceReferenceDate: 80_000_000)
    let completedAt = now.addingTimeInterval(-(TimerPersistence.maximumRecordAge * 2))
    let session = TimerSessionSnapshot(
      savedAt: completedAt,
      label: "Long-finished timer",
      duration: 60,
      deadline: completedAt,
      isPaused: false,
      pausedRemaining: nil,
      completionIdentifier: "timer-completion-99999999-9999-9999-9999-999999999999",
      completedAt: completedAt)
    let encoded = try XCTUnwrap(TimerPersistence.encode(session))
    let box = TimerPersistenceBox(sessionData: encoded)

    XCTAssertEqual(TimerPersistence.restoreSession(from: box.store, now: now), .completed(session))
    XCTAssertEqual(box.sessionData, encoded)
  }

  func testPersistedCompletedStateStillRejectsFutureTimestamp() throws {
    let now = Date(timeIntervalSinceReferenceDate: 80_000_000)
    let completedAt = now.addingTimeInterval(TimerPersistence.maximumFutureClockSkew + 1)
    let session = TimerSessionSnapshot(
      savedAt: now,
      label: "Future completion",
      duration: 60,
      deadline: completedAt,
      isPaused: false,
      pausedRemaining: nil,
      completionIdentifier: "timer-completion-AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
      completedAt: completedAt)
    let box = TimerPersistenceBox(
      sessionData: try XCTUnwrap(TimerPersistence.encode(session)))

    XCTAssertEqual(TimerPersistence.restoreSession(from: box.store, now: now), .discard)
    XCTAssertNil(box.sessionData)
  }

  func testLastPresetRestoresSeparatelyFromCurrentSession() throws {
    let preset = TimerPresetSnapshot(duration: 1_500, label: "Focus")
    let encodedPreset = try XCTUnwrap(TimerPersistence.encode(preset))
    let box = TimerPersistenceBox(presetData: encodedPreset)

    XCTAssertEqual(TimerPersistence.restorePreset(from: box.store), preset)
    XCTAssertEqual(box.presetData, encodedPreset)
  }

  private func completedActivity() throws -> TimerActivity {
    let now = Date(timeIntervalSinceReferenceDate: 30_000)
    let session = TimerSessionSnapshot(
      savedAt: now.addingTimeInterval(-120),
      label: "Tea",
      duration: 60,
      deadline: now.addingTimeInterval(-60),
      isPaused: false,
      pausedRemaining: nil)
    let preset = TimerPresetSnapshot(duration: 60, label: "Tea")
    let box = TimerPersistenceBox(
      sessionData: try XCTUnwrap(TimerPersistence.encode(session)),
      presetData: try XCTUnwrap(TimerPersistence.encode(preset)))

    return TimerActivity(
      persistenceStore: box.store, now: now, completionNotifier: TimerNotifierStub())
  }
}

@MainActor
private final class TimerPersistenceBox {
  var sessionData: Data?
  var presetData: Data?

  init(sessionData: Data? = nil, presetData: Data? = nil) {
    self.sessionData = sessionData
    self.presetData = presetData
  }

  var store: TimerPersistenceStore {
    TimerPersistenceStore(
      readSessionData: { [weak self] in self?.sessionData },
      writeSessionData: { [weak self] in self?.sessionData = $0 },
      readPresetData: { [weak self] in self?.presetData },
      writePresetData: { [weak self] in self?.presetData = $0 })
  }
}

@MainActor
private final class TimerNotifierStub: TimerCompletionNotifying {
  private(set) var finishedCompletionIDs: [UUID] = []
  private(set) var finishedSnapshots: [TimerCompletionSnapshot] = []

  func prepareForTimerStart(onUnavailable: @escaping @MainActor () -> Void) {}

  func notifyTimerFinished(
    completionID: UUID, snapshot: TimerCompletionSnapshot, title: String, body: String,
    onUnavailable: @escaping @MainActor () -> Void
  ) {
    finishedCompletionIDs.append(completionID)
    finishedSnapshots.append(snapshot)
  }
}

@MainActor
private final class MutableTimerClock {
  var now: Date

  init(now: Date) {
    self.now = now
  }
}

@MainActor
private final class ControlledTimerCompletionGate: TimerCompletionScheduling {
  private struct Completion {
    let id: UInt
    let deadline: Date
    let action: @MainActor () -> Void
  }

  private final class Handle: TimerScheduledCompletion {
    private weak var gate: ControlledTimerCompletionGate?
    private let id: UInt

    init(gate: ControlledTimerCompletionGate, id: UInt) {
      self.gate = gate
      self.id = id
    }

    func cancel() {
      gate?.cancel(id: id)
    }
  }

  private var nextID: UInt = 0
  private var waiting: [Completion] = []
  private var ready: [Completion] = []

  var readyCount: Int { ready.count }

  func schedule(
    at deadline: Date, action: @escaping @MainActor () -> Void
  ) -> any TimerScheduledCompletion {
    nextID &+= 1
    let id = nextID
    waiting.append(Completion(id: id, deadline: deadline, action: action))
    return Handle(gate: self, id: id)
  }

  func makeDueCompletionsReady(at now: Date) {
    let due = waiting.filter { $0.deadline <= now }
    waiting.removeAll { $0.deadline <= now }
    ready.append(contentsOf: due)
  }

  func runReadyCompletions() {
    let completions = ready
    ready.removeAll()
    for completion in completions { completion.action() }
  }

  private func cancel(id: UInt) {
    waiting.removeAll { $0.id == id }
    ready.removeAll { $0.id == id }
  }
}
