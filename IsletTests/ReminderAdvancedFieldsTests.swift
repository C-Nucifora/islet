import CoreLocation
import EventKit
import XCTest

@testable import Islet

@MainActor
final class ReminderAdvancedFieldsTests: XCTestCase {
  func testLargeFiniteRelativeOffsetCanBeDisplayedWithoutIntegerOverflow() {
    XCTAssertFalse(
      ReminderAlarmPresentation.title(.relative(Double.greatestFiniteMagnitude)).isEmpty)
    XCTAssertFalse(
      ReminderAlarmPresentation.title(.relative(-Double.greatestFiniteMagnitude)).isEmpty)
  }

  func testDateComparisonPreservesClockPresenceAndFloatingTimeZone() {
    var dateOnly = DateComponents(year: 2026, month: 9, day: 3)
    var timed = dateOnly
    timed.hour = 0
    timed.minute = 0
    XCTAssertFalse(ReminderDateValue.semanticallyEqual(dateOnly, timed))
    var withSeconds = timed
    withSeconds.second = 0
    withSeconds.isLeapMonth = false
    XCTAssertTrue(ReminderDateValue.semanticallyEqual(timed, withSeconds))
    withSeconds.timeZone = TimeZone(secondsFromGMT: 0)
    XCTAssertFalse(ReminderDateValue.semanticallyEqual(timed, withSeconds))
    dateOnly.day = 4
    XCTAssertFalse(ReminderDateValue.semanticallyEqual(dateOnly, timed))
  }

  func testAlarmRoundTripPreservesAbsoluteRelativeAndLocationValues() throws {
    let values: [ReminderAlarmValue] = [
      .absolute(Date(timeIntervalSince1970: 1_800_000_000)),
      .relative(-900),
      .location(
        title: "Workshop", latitude: -27.47, longitude: 153.03, radius: 120, onArrival: false),
    ]
    for value in values {
      let alarm = try ReminderAdvancedCodec.alarm(from: value)
      XCTAssertEqual(ReminderAdvancedCodec.alarmValue(from: alarm), value)
    }
  }

  func testAlarmEditPreservesOpaqueAlarmBetweenEditableSlots() throws {
    let store = EKEventStore()
    let reminder = EKReminder(eventStore: store)
    reminder.title = "Workshop"
    let opaque = EKAlarm(relativeOffset: -30)
    opaque.emailAddress = "alerts@example.com"
    reminder.alarms = [EKAlarm(relativeOffset: -60), opaque, EKAlarm(relativeOffset: -120)]
    let baseline = try ReminderEventKitCodec.editableFields(from: reminder)
    var edited = baseline
    edited.alarms = [.relative(-600)]
    try ReminderEventKitCodec.apply(
      ReminderPatch(from: baseline, to: edited), to: reminder, resolveList: { _ in nil })
    XCTAssertEqual(reminder.alarms?.count, 2)
    XCTAssertTrue(reminder.alarms?.contains { $0.relativeOffset == -600 } == true)
    XCTAssertTrue(reminder.alarms?.contains { $0 === opaque } == true)
  }

  func testRecurrenceRoundTripPreservesSelectorsAndCountEnd() throws {
    let rule = ReminderRecurrenceValue(
      frequency: .yearly, interval: 2,
      weekdays: [.init(day: 3, ordinal: 2)], monthDays: [3], months: [4],
      weeks: [5], yearDays: [6], positions: [-1], end: .count(3))
    let encoded = try ReminderAdvancedCodec.recurrence(from: rule)
    XCTAssertEqual(encoded.interval, 2)
    XCTAssertEqual(encoded.monthsOfTheYear, [4])
    XCTAssertEqual(encoded.recurrenceEnd?.occurrenceCount, 3)
    XCTAssertEqual(ReminderAdvancedCodec.recurrenceValue(from: encoded), rule)
  }

  func testInvalidSelectorsAndCoordinatesAreRejectedBeforeEventKit() {
    XCTAssertThrowsError(
      try ReminderAdvancedCodec.alarm(
        from:
          .location(title: "Invalid", latitude: 91, longitude: 0, radius: 100, onArrival: true)))
    XCTAssertThrowsError(try ReminderAdvancedCodec.alarm(from: .relative(.infinity)))
    XCTAssertThrowsError(
      try ReminderAdvancedCodec.recurrence(
        from:
          ReminderRecurrenceValue(frequency: .monthly, interval: 0)))
    XCTAssertThrowsError(
      try ReminderAdvancedCodec.recurrence(
        from:
          ReminderRecurrenceValue(frequency: .monthly, monthDays: [0])))
    XCTAssertThrowsError(
      try ReminderAdvancedCodec.recurrence(
        from:
          ReminderRecurrenceValue(frequency: .daily, positions: [1])))
  }

  func testRecurrencePatchRequiresDueDate() throws {
    let reminder = EKReminder(eventStore: EKEventStore())
    reminder.title = "Repeat"
    let baseline = try ReminderEventKitCodec.editableFields(from: reminder)
    var edited = baseline
    edited.recurrenceRules = [ReminderRecurrenceValue(frequency: .weekly)]
    XCTAssertThrowsError(
      try ReminderEventKitCodec.apply(
        ReminderPatch(from: baseline, to: edited), to: reminder, resolveList: { _ in nil }))
    XCTAssertTrue((reminder.recurrenceRules ?? []).isEmpty)
  }
}
