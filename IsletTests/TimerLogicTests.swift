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
