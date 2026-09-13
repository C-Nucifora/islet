import Foundation
import XCTest

@testable import Islet

final class ReminderWriteModelsTests: XCTestCase {
  func testDateOnlyValuePreservesMissingClockAndFloatingZone() throws {
    let components = dateComponents(year: 2026, month: 3, day: 8)

    let value = try ReminderDateValue(validating: components)

    XCTAssertEqual(value.components, components)
    XCTAssertNil(value.components.hour)
    XCTAssertNil(value.components.minute)
    XCTAssertNil(value.components.second)
    XCTAssertNil(value.components.timeZone)
  }

  func testTimedValueRequiresHourAndMinuteTogether() throws {
    var hourOnly = dateComponents(year: 2026, month: 11, day: 1)
    hourOnly.hour = 1
    XCTAssertThrowsError(try ReminderDateValue(validating: hourOnly))

    var minuteOnly = dateComponents(year: 2026, month: 11, day: 1)
    minuteOnly.minute = 30
    XCTAssertThrowsError(try ReminderDateValue(validating: minuteOnly))

    var secondWithoutClock = dateComponents(year: 2026, month: 11, day: 1)
    secondWithoutClock.second = 15
    XCTAssertThrowsError(try ReminderDateValue(validating: secondWithoutClock))

    var timed = dateComponents(year: 2026, month: 11, day: 1)
    timed.hour = 1
    timed.minute = 30
    timed.second = 15
    XCTAssertEqual(try ReminderDateValue(validating: timed).components, timed)
  }

  func testExplicitZoneSurvivesRoundTrip() throws {
    let zone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
    var components = dateComponents(year: 2026, month: 11, day: 1)
    components.timeZone = zone
    components.hour = 1
    components.minute = 30

    let value = try ReminderDateValue(validating: components)
    let date = try value.date(in: gregorianCalendar(timeZone: zone))

    XCTAssertEqual(value.components, components)
    XCTAssertEqual(
      date,
      gregorianCalendar(timeZone: zone).date(from: components))
  }

  func testInvalidGregorianDateIsRejected() throws {
    var springForwardGap = dateComponents(year: 2026, month: 3, day: 8)
    springForwardGap.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
    springForwardGap.hour = 2
    springForwardGap.minute = 30
    XCTAssertThrowsError(try ReminderDateValue(validating: springForwardGap))

    XCTAssertThrowsError(
      try ReminderDateValue(validating: dateComponents(year: 2026, month: 2, day: 29)))
  }

  func testPatchDistinguishesUnchangedFromExplicitClear() throws {
    let baseline = try editableFields()
    var cleared = baseline
    cleared.notes = nil
    cleared.url = nil

    let unchangedPatch = ReminderPatch(from: baseline, to: baseline)
    let clearPatch = ReminderPatch(from: baseline, to: cleared)

    XCTAssertEqual(unchangedPatch.notes, .unchanged)
    XCTAssertEqual(unchangedPatch.url, .unchanged)
    XCTAssertEqual(clearPatch.notes, .value(nil))
    XCTAssertEqual(clearPatch.url, .value(nil))
    XCTAssertFalse(clearPatch.isEmpty)
  }

  func testPatchContainsOnlyFieldsChangedFromBaseline() throws {
    let baseline = try editableFields()
    let updatedStart = try ReminderDateValue(
      validating: dateComponents(year: 2026, month: 11, day: 1))
    let completedAt = Date(timeIntervalSince1970: 1_793_512_800)
    var edited = baseline
    edited.title = "Send updated report"
    edited.startDate = updatedStart
    edited.priority = 1
    edited.completion = try ReminderCompletionValue(validating: true, completionDate: completedAt)

    let patch = ReminderPatch(from: baseline, to: edited)

    XCTAssertEqual(patch.title, .value("Send updated report"))
    XCTAssertEqual(patch.notes, .unchanged)
    XCTAssertEqual(patch.url, .unchanged)
    XCTAssertEqual(patch.listID, .unchanged)
    XCTAssertEqual(patch.startDate, .value(updatedStart))
    XCTAssertEqual(patch.dueDate, .unchanged)
    XCTAssertEqual(patch.priority, .value(1))
    XCTAssertEqual(
      patch.completion,
      .value(try ReminderCompletionValue(validating: true, completionDate: completedAt)))
    XCTAssertFalse(patch.isEmpty)
  }

  func testCompletedValueRequiresACompletionDate() throws {
    XCTAssertThrowsError(try ReminderCompletionValue(validating: true, completionDate: nil))

    let incomplete = try ReminderCompletionValue(
      validating: false, completionDate: Date(timeIntervalSince1970: 1))
    XCTAssertFalse(incomplete.isCompleted)
    XCTAssertNil(incomplete.completionDate)
  }

  func testEditableFieldsRejectUnsupportedPriority() throws {
    XCTAssertThrowsError(try editableFields(priority: 10))
  }

  private func editableFields(priority: Int = 5) throws -> ReminderEditableFields {
    try ReminderEditableFields(
      validating: "Send report", notes: "Attach the draft",
      url: URL(string: "https://example.com/report"),
      listID: "work", startDate: nil,
      dueDate: ReminderDateValue(validating: dateComponents(year: 2026, month: 3, day: 8)),
      priority: priority,
      completion: ReminderCompletionValue(validating: false, completionDate: nil))
  }

  private func dateComponents(year: Int, month: Int, day: Int) -> DateComponents {
    var components = DateComponents()
    components.calendar = gregorianCalendar(timeZone: TimeZone(secondsFromGMT: 0)!)
    components.era = 1
    components.year = year
    components.month = month
    components.day = day
    return components
  }

  private func gregorianCalendar(timeZone: TimeZone) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    return calendar
  }
}
