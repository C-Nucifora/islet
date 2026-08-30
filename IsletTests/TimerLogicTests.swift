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

  func testElapsedDeadlineRestoresAsCompletedAndClearsStoredSession() throws {
    let now = Date(timeIntervalSinceReferenceDate: 30_000)
    let session = TimerSessionSnapshot(
      savedAt: now.addingTimeInterval(-120),
      label: "Tea",
      duration: 60,
      deadline: now.addingTimeInterval(-60),
      isPaused: false,
      pausedRemaining: nil)
    let box = TimerPersistenceBox(sessionData: try XCTUnwrap(TimerPersistence.encode(session)))

    XCTAssertEqual(
      TimerPersistence.restoreSession(from: box.store, now: now),
      .completed(session))
    XCTAssertNil(box.sessionData)
  }

  func testCompletedTimerRemainsActiveUntilDismissed() async throws {
    let activity = try completedActivity()

    try await Task.sleep(for: .milliseconds(6_100))

    XCTAssertTrue(activity.finished)
    XCTAssertTrue(activity.isActive)
    XCTAssertFalse(activity.isRunning)

    activity.cancel()

    XCTAssertFalse(activity.finished)
    XCTAssertFalse(activity.isActive)
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
  func prepareForTimerStart(onUnavailable: @escaping @MainActor () -> Void) {}

  func notifyTimerFinished(
    completionID: UUID, snapshot: TimerCompletionSnapshot, title: String, body: String,
    onUnavailable: @escaping @MainActor () -> Void
  ) {}
}
