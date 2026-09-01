import CoreLocation
import EventKit
import Foundation
import XCTest

@testable import Islet

final class ReminderEventKitCodecTests: XCTestCase {
  func testRecordPreservesNotesURLStartDuePriorityAndCompletion() throws {
    let fixture = makeReminder(title: "Submit expenses")
    let start = components(year: 2026, month: 9, day: 2, hour: 9, minute: 15)
    let due = components(year: 2026, month: 9, day: 3)
    let completedAt = Date(timeIntervalSince1970: 1_788_400_000)
    fixture.reminder.notes = "Attach every receipt"
    fixture.reminder.url = try XCTUnwrap(URL(string: "https://example.com/expenses"))
    fixture.reminder.startDateComponents = start
    fixture.reminder.dueDateComponents = due
    fixture.reminder.priority = 5
    fixture.reminder.completionDate = completedAt

    let record = ReminderEventKitCodec.record(from: fixture.reminder)

    XCTAssertEqual(record.title, "Submit expenses")
    XCTAssertEqual(record.notes, "Attach every receipt")
    XCTAssertEqual(record.url, URL(string: "https://example.com/expenses"))
    XCTAssertEqual(record.startDateComponents, start)
    XCTAssertEqual(record.dueDateComponents, due)
    XCTAssertEqual(record.priority, 5)
    XCTAssertTrue(record.isCompleted)
    XCTAssertEqual(record.completionDate, completedAt)
    XCTAssertEqual(record.listID, fixture.calendar.calendarIdentifier)
  }

  func testDateOnlyAndFloatingComponentsRoundTripExactly() throws {
    let fixture = makeReminder()
    let start = components(year: 2026, month: 11, day: 1)
    let due = components(year: 2026, month: 11, day: 2, hour: 8, minute: 45)
    fixture.reminder.startDateComponents = start
    fixture.reminder.dueDateComponents = due
    let baseline = try ReminderEventKitCodec.editableFields(from: fixture.reminder)
    var edited = baseline
    edited.startDate = try ReminderDateValue(validating: due)
    edited.dueDate = try ReminderDateValue(validating: start)

    try ReminderEventKitCodec.apply(
      ReminderPatch(from: baseline, to: edited), to: fixture.reminder,
      resolveList: { _ in nil })
    let roundTrip = try ReminderEventKitCodec.editableFields(from: fixture.reminder)

    XCTAssertEqual(roundTrip.startDate?.components, due)
    XCTAssertEqual(roundTrip.dueDate?.components, start)
    XCTAssertNil(roundTrip.startDate?.components.timeZone)
    XCTAssertNil(roundTrip.dueDate?.components.timeZone)
    XCTAssertNil(roundTrip.dueDate?.components.hour)
    XCTAssertNil(roundTrip.dueDate?.components.minute)
  }

  func testRevisionChangesForEveryEditableCoreField() throws {
    let fixture = makeReminder()
    configureEveryCoreField(on: fixture.reminder)
    let baseline = ReminderEventKitCodec.revision(from: fixture.reminder)

    fixture.reminder.title = "Changed title"
    XCTAssertNotEqual(ReminderEventKitCodec.revision(from: fixture.reminder), baseline)
    fixture.reminder.title = "Submit report"

    fixture.reminder.notes = "Changed notes"
    XCTAssertNotEqual(ReminderEventKitCodec.revision(from: fixture.reminder), baseline)
    fixture.reminder.notes = "Attach the draft"

    fixture.reminder.url = URL(string: "https://example.com/changed")
    XCTAssertNotEqual(ReminderEventKitCodec.revision(from: fixture.reminder), baseline)
    fixture.reminder.url = URL(string: "https://example.com/report")

    fixture.reminder.startDateComponents = components(year: 2026, month: 10, day: 1)
    XCTAssertNotEqual(ReminderEventKitCodec.revision(from: fixture.reminder), baseline)
    fixture.reminder.startDateComponents = components(year: 2026, month: 9, day: 2)

    fixture.reminder.dueDateComponents = components(year: 2026, month: 10, day: 2)
    XCTAssertNotEqual(ReminderEventKitCodec.revision(from: fixture.reminder), baseline)
    fixture.reminder.dueDateComponents = components(
      year: 2026, month: 9, day: 3, hour: 16, minute: 30)

    fixture.reminder.priority = 9
    XCTAssertNotEqual(ReminderEventKitCodec.revision(from: fixture.reminder), baseline)
    fixture.reminder.priority = 5

    fixture.reminder.completionDate = Date(timeIntervalSince1970: 1_800_000_000)
    XCTAssertNotEqual(ReminderEventKitCodec.revision(from: fixture.reminder), baseline)
    fixture.reminder.completionDate = Date(timeIntervalSince1970: 1_788_300_000)

    let changedList = EKCalendar(for: .reminder, eventStore: fixture.store)
    changedList.title = "Changed list"
    fixture.reminder.calendar = changedList
    XCTAssertNotEqual(ReminderEventKitCodec.revision(from: fixture.reminder), baseline)
  }

  func testRevisionIncludesInheritedLocationAndTimeZone() throws {
    let fixture = makeReminder()
    fixture.reminder.location = "Building 4"
    fixture.reminder.timeZone = try XCTUnwrap(TimeZone(identifier: "Australia/Brisbane"))

    let original = ReminderEventKitCodec.revision(from: fixture.reminder)
    fixture.reminder.location = "Building 5"
    let changedLocation = ReminderEventKitCodec.revision(from: fixture.reminder)
    fixture.reminder.location = "Building 4"
    fixture.reminder.timeZone = try XCTUnwrap(TimeZone(identifier: "Pacific/Auckland"))
    let changedTimeZone = ReminderEventKitCodec.revision(from: fixture.reminder)

    XCTAssertEqual(original.location, "Building 4")
    XCTAssertEqual(original.timeZone, TimeZone(identifier: "Australia/Brisbane"))
    XCTAssertNotEqual(changedLocation, original)
    XCTAssertNotEqual(changedTimeZone, original)
  }

  func testRevisionIncludesEveryReadableAlarmProperty() throws {
    let fixture = makeReminder()
    let absoluteDate = Date(timeIntervalSince1970: 1_799_000_000)
    let absolute = EKAlarm(absoluteDate: absoluteDate)
    let location = EKStructuredLocation(title: "Warehouse door")
    location.geoLocation = CLLocation(latitude: -27.4698, longitude: 153.0251)
    location.radius = 125
    absolute.structuredLocation = location
    absolute.proximity = .enter
    absolute.soundName = "Glass"

    let relative = EKAlarm(relativeOffset: -900)
    relative.emailAddress = "alerts@example.com"
    fixture.reminder.alarms = [absolute, relative]

    let revision = ReminderEventKitCodec.revision(from: fixture.reminder)

    XCTAssertEqual(
      revision.alarms,
      [
        ReminderAlarmRevision(
          typeRawValue: EKAlarmType.audio.rawValue, absoluteDate: absoluteDate,
          relativeOffset: 0, locationTitle: "Warehouse door", latitude: -27.4698,
          longitude: 153.0251, radius: 125,
          proximityRawValue: EKAlarmProximity.enter.rawValue, emailAddress: nil,
          soundName: "Glass", url: nil),
        ReminderAlarmRevision(
          typeRawValue: EKAlarmType.email.rawValue, absoluteDate: nil,
          relativeOffset: -900, locationTitle: nil, latitude: nil, longitude: nil,
          radius: nil, proximityRawValue: EKAlarmProximity.none.rawValue,
          emailAddress: "alerts@example.com", soundName: nil, url: nil),
      ])
  }

  func testRevisionIncludesEveryReadableRecurrenceProperty() throws {
    let fixture = makeReminder()
    let countEnd = EKRecurrenceEnd(occurrenceCount: 3)
    let advanced = EKRecurrenceRule(
      recurrenceWith: .yearly, interval: 2,
      daysOfTheWeek: [EKRecurrenceDayOfWeek(.tuesday, weekNumber: 2)],
      daysOfTheMonth: [3], monthsOfTheYear: [4], weeksOfTheYear: [5],
      daysOfTheYear: [6], setPositions: [-1], end: countEnd)
    let endDate = Date(timeIntervalSince1970: 1_830_000_000)
    let simple = EKRecurrenceRule(
      recurrenceWith: .daily, interval: 4, end: EKRecurrenceEnd(end: endDate))
    fixture.reminder.recurrenceRules = [advanced, simple]

    let revision = ReminderEventKitCodec.revision(from: fixture.reminder)

    XCTAssertEqual(
      revision.recurrenceRules,
      [
        ReminderRecurrenceRevision(
          calendarIdentifier: .gregorian,
          frequencyRawValue: EKRecurrenceFrequency.yearly.rawValue, interval: 2,
          firstDayOfTheWeek: 2,
          daysOfTheWeek: [
            ReminderWeekdayRevision(
              dayOfTheWeekRawValue: EKWeekday.tuesday.rawValue, weekNumber: 2)
          ],
          daysOfTheMonth: [3], monthsOfTheYear: [4], weeksOfTheYear: [5],
          daysOfTheYear: [6], setPositions: [-1], endDate: nil, occurrenceCount: 3),
        ReminderRecurrenceRevision(
          calendarIdentifier: .gregorian,
          frequencyRawValue: EKRecurrenceFrequency.daily.rawValue, interval: 4,
          firstDayOfTheWeek: 0, daysOfTheWeek: [], daysOfTheMonth: [],
          monthsOfTheYear: [], weeksOfTheYear: [], daysOfTheYear: [], setPositions: [],
          endDate: endDate, occurrenceCount: nil),
      ])
  }

  func testApplyLeavesUnchangedFieldsAndOpaqueMetadataUntouched() throws {
    let fixture = makeReminder()
    configureEveryCoreField(on: fixture.reminder)
    let alarm = EKAlarm(relativeOffset: -300)
    let recurrence = EKRecurrenceRule(recurrenceWith: .weekly, interval: 2, end: nil)
    fixture.reminder.alarms = [alarm]
    fixture.reminder.recurrenceRules = [recurrence]
    let originalURL = fixture.reminder.url
    let originalStart = fixture.reminder.startDateComponents
    let originalDue = fixture.reminder.dueDateComponents
    let baseline = try ReminderEventKitCodec.editableFields(from: fixture.reminder)
    var edited = baseline
    edited.notes = "Only the notes changed"

    try ReminderEventKitCodec.apply(
      ReminderPatch(from: baseline, to: edited), to: fixture.reminder,
      resolveList: { _ in
        XCTFail("An unchanged list must not be resolved")
        return nil
      })

    XCTAssertEqual(fixture.reminder.notes, "Only the notes changed")
    XCTAssertEqual(fixture.reminder.url, originalURL)
    XCTAssertEqual(fixture.reminder.startDateComponents, originalStart)
    XCTAssertEqual(fixture.reminder.dueDateComponents, originalDue)
    XCTAssertTrue(try XCTUnwrap(fixture.reminder.alarms?.first) === alarm)
    XCTAssertTrue(try XCTUnwrap(fixture.reminder.recurrenceRules?.first) === recurrence)
  }

  func testApplyClearsOnlyExplicitlyClearedFields() throws {
    let fixture = makeReminder()
    configureEveryCoreField(on: fixture.reminder)
    let baseline = try ReminderEventKitCodec.editableFields(from: fixture.reminder)
    let originalTitle = fixture.reminder.title
    let originalPriority = fixture.reminder.priority
    let originalCompletion = fixture.reminder.completionDate
    var edited = baseline
    edited.notes = nil
    edited.url = nil
    edited.startDate = nil
    edited.dueDate = nil

    try ReminderEventKitCodec.apply(
      ReminderPatch(from: baseline, to: edited), to: fixture.reminder,
      resolveList: { _ in nil })

    XCTAssertNil(fixture.reminder.notes)
    XCTAssertNil(fixture.reminder.url)
    XCTAssertNil(fixture.reminder.startDateComponents)
    XCTAssertNil(fixture.reminder.dueDateComponents)
    XCTAssertEqual(fixture.reminder.title, originalTitle)
    XCTAssertEqual(fixture.reminder.priority, originalPriority)
    XCTAssertEqual(fixture.reminder.completionDate, originalCompletion)
    XCTAssertEqual(
      fixture.reminder.calendar.calendarIdentifier, fixture.calendar.calendarIdentifier)
  }

  func testApplyRequiresAnExactWritableList() throws {
    let fixture = makeReminder()
    let baseline = try ReminderEventKitCodec.editableFields(from: fixture.reminder)
    let requested = EKCalendar(for: .reminder, eventStore: fixture.store)
    requested.title = "Requested"
    var edited = baseline
    edited.listID = requested.calendarIdentifier
    let patch = ReminderPatch(from: baseline, to: edited)

    XCTAssertThrowsError(
      try ReminderEventKitCodec.apply(
        patch, to: fixture.reminder, resolveList: { _ in fixture.calendar })
    ) { error in
      XCTAssertEqual(error as? ReminderWriteError, .missingList)
    }

    try ReminderEventKitCodec.apply(
      patch, to: fixture.reminder,
      resolveList: { id in
        id == requested.calendarIdentifier ? requested : nil
      })
    XCTAssertTrue(fixture.reminder.calendar === requested)
  }

  private func configureEveryCoreField(on reminder: EKReminder) {
    reminder.title = "Submit report"
    reminder.notes = "Attach the draft"
    reminder.url = URL(string: "https://example.com/report")
    reminder.startDateComponents = components(year: 2026, month: 9, day: 2)
    reminder.dueDateComponents = components(year: 2026, month: 9, day: 3, hour: 16, minute: 30)
    reminder.priority = 5
    reminder.completionDate = Date(timeIntervalSince1970: 1_788_300_000)
  }

  private func makeReminder(title: String = "Submit report") -> (
    store: EKEventStore, calendar: EKCalendar, reminder: EKReminder
  ) {
    let store = EKEventStore()
    let calendar = EKCalendar(for: .reminder, eventStore: store)
    calendar.title = "List \(UUID().uuidString)"
    let reminder = EKReminder(eventStore: store)
    reminder.calendar = calendar
    reminder.title = title
    return (store, calendar, reminder)
  }

  private func components(
    year: Int, month: Int, day: Int, hour: Int? = nil, minute: Int? = nil
  ) -> DateComponents {
    var value = DateComponents()
    value.calendar = Calendar(identifier: .gregorian)
    value.era = 1
    value.year = year
    value.month = month
    value.day = day
    value.hour = hour
    value.minute = minute
    return value
  }
}
