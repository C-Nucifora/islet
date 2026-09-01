import EventKit
import Foundation
import XCTest

@testable import Islet

@MainActor
final class EventKitReminderWriteStoreTests: XCTestCase {
  func testCreateUsesExactSelectedWritableList() throws {
    let backing = Backing()
    let inbox = backing.addWritableCalendar(title: "Inbox")
    let selected = backing.addWritableCalendar(title: "Selected")
    let store = EventKitReminderWriteStore(backing: backing)

    let outcome = try store.create(fields(listID: selected.calendarIdentifier))

    guard case .saved(let record) = outcome else {
      return XCTFail("Expected an exact save, got \(outcome)")
    }
    XCTAssertTrue(try XCTUnwrap(backing.createdReminder).calendar === selected)
    XCTAssertEqual(record.listID, selected.calendarIdentifier)
    XCTAssertEqual(
      backing.writableCalendarLookups,
      [selected.calendarIdentifier])
    XCTAssertNotEqual(record.listID, inbox.calendarIdentifier)
    XCTAssertEqual(backing.postCommitLookupCount, 1)
    XCTAssertEqual(backing.postCommitRefreshCount, 1)
  }

  func testCreateMissingSelectedListNeverFallsBack() throws {
    let backing = Backing()
    _ = backing.addWritableCalendar(title: "Default")
    let store = EventKitReminderWriteStore(backing: backing)

    XCTAssertThrowsError(try store.create(fields(listID: "missing"))) { error in
      XCTAssertEqual(error as? ReminderWriteError, .missingList)
    }
    XCTAssertEqual(backing.writableCalendarLookups, ["missing"])
    XCTAssertEqual(backing.makeReminderCount, 0)
    XCTAssertEqual(backing.stageSaveCount, 0)
  }

  func testSaveRejectsARevisionChangedAfterEditorOpen() throws {
    let backing = Backing()
    let calendar = backing.addWritableCalendar(title: "Inbox")
    let reminder = backing.addReminder(title: "Original", calendar: calendar)
    reminder.notes = "Original notes"
    let expectedRevision = ReminderEventKitCodec.revision(from: reminder)
    let patch = try notesPatch(for: reminder, notes: "Requested notes")
    backing.onRefresh = { refreshed, refreshCount in
      if refreshCount == 1 { refreshed.title = "External title" }
    }
    let store = EventKitReminderWriteStore(backing: backing)

    XCTAssertThrowsError(
      try store.save(
        reminderID: reminder.calendarItemIdentifier, patch: patch,
        expectedRevision: expectedRevision)
    ) { error in
      XCTAssertEqual(error as? ReminderWriteError, .changedElsewhere)
    }
    XCTAssertEqual(reminder.notes, "Original notes")
    XCTAssertEqual(backing.stageSaveCount, 0)
    XCTAssertEqual(backing.resetCount, 0)
  }

  func testSaveTreatsFailedRefreshAsMissingBeforeAnyOtherWriteCheck() throws {
    let backing = Backing()
    let calendar = backing.addWritableCalendar(title: "Inbox")
    let reminder = backing.addReminder(title: "Original", calendar: calendar)
    let expectedRevision = ReminderEventKitCodec.revision(from: reminder)
    let patch = try notesPatch(for: reminder, notes: "Requested notes")
    backing.refreshResult = false
    let store = EventKitReminderWriteStore(backing: backing)

    XCTAssertThrowsError(
      try store.save(
        reminderID: reminder.calendarItemIdentifier, patch: patch,
        expectedRevision: expectedRevision)
    ) { error in
      XCTAssertEqual(error as? ReminderWriteError, .missingReminder)
    }
    XCTAssertEqual(backing.refreshCount, 1)
    XCTAssertEqual(backing.writableCalendarLookups, [])
    XCTAssertEqual(backing.stageSaveCount, 0)
    XCTAssertEqual(backing.commitCount, 0)
  }

  func testSaveAppliesOnlyChangedFields() throws {
    let backing = Backing()
    let calendar = backing.addWritableCalendar(title: "Inbox")
    let reminder = backing.addReminder(title: "Original", calendar: calendar)
    let alarm = EKAlarm(relativeOffset: -300)
    let recurrence = EKRecurrenceRule(recurrenceWith: .weekly, interval: 2, end: nil)
    let originalURL = try XCTUnwrap(URL(string: "https://example.com/original"))
    let originalStart = components(year: 2026, month: 9, day: 2)
    let originalDue = components(year: 2026, month: 9, day: 3, hour: 16, minute: 30)
    reminder.notes = "Original notes"
    reminder.url = originalURL
    reminder.startDateComponents = originalStart
    reminder.dueDateComponents = originalDue
    reminder.alarms = [alarm]
    reminder.recurrenceRules = [recurrence]
    let expectedRevision = ReminderEventKitCodec.revision(from: reminder)
    let patch = try notesPatch(for: reminder, notes: "Requested notes")
    let store = EventKitReminderWriteStore(backing: backing)

    let outcome = try store.save(
      reminderID: reminder.calendarItemIdentifier, patch: patch,
      expectedRevision: expectedRevision)

    guard case .saved = outcome else { return XCTFail("Expected an exact save") }
    XCTAssertEqual(reminder.notes, "Requested notes")
    XCTAssertEqual(reminder.url, originalURL)
    XCTAssertEqual(reminder.startDateComponents, originalStart)
    XCTAssertEqual(reminder.dueDateComponents, originalDue)
    XCTAssertTrue(try XCTUnwrap(reminder.alarms?.first) === alarm)
    XCTAssertTrue(try XCTUnwrap(reminder.recurrenceRules?.first) === recurrence)
    XCTAssertEqual(backing.postCommitLookupCount, 1)
    XCTAssertEqual(backing.postCommitRefreshCount, 1)
  }

  func testSaveRejectsAListThatBecameReadOnly() throws {
    let backing = Backing()
    let originalList = backing.addWritableCalendar(title: "Inbox")
    let unavailableList = backing.makeCalendar(title: "Read only")
    let reminder = backing.addReminder(title: "Original", calendar: originalList)
    let expectedRevision = ReminderEventKitCodec.revision(from: reminder)
    let original = ReminderEventKitCodec.record(from: reminder)
    let baseline = try ReminderEventKitCodec.editableFields(from: reminder)
    var edited = baseline
    edited.title = "Must not be staged"
    edited.listID = unavailableList.calendarIdentifier
    let store = EventKitReminderWriteStore(backing: backing)

    XCTAssertThrowsError(
      try store.save(
        reminderID: reminder.calendarItemIdentifier,
        patch: ReminderPatch(from: baseline, to: edited),
        expectedRevision: expectedRevision)
    ) { error in
      XCTAssertEqual(error as? ReminderWriteError, .missingList)
    }
    XCTAssertEqual(ReminderEventKitCodec.record(from: reminder), original)
    XCTAssertTrue(reminder.calendar === originalList)
    XCTAssertEqual(
      backing.writableCalendarLookups,
      [unavailableList.calendarIdentifier])
    XCTAssertEqual(backing.stageSaveCount, 0)
  }

  func testStagedMismatchResetsBeforeCommit() throws {
    let backing = Backing()
    let calendar = backing.addWritableCalendar(title: "Inbox")
    let reminder = backing.addReminder(title: "Original", calendar: calendar)
    let expectedRevision = ReminderEventKitCodec.revision(from: reminder)
    let patch = try notesPatch(for: reminder, notes: "Requested notes")
    backing.onStageSave = { staged in staged.notes = "Provider staged notes" }
    let store = EventKitReminderWriteStore(backing: backing)

    XCTAssertThrowsError(
      try store.save(
        reminderID: reminder.calendarItemIdentifier, patch: patch,
        expectedRevision: expectedRevision)
    ) { error in
      XCTAssertEqual(
        error as? ReminderWriteError,
        .eventKit("The reminder provider could not stage the requested values."))
    }
    XCTAssertEqual(backing.resetCount, 1)
    XCTAssertEqual(backing.commitCount, 0)
    XCTAssertEqual(backing.postCommitLookupCount, 0)
  }

  func testDeleteChecksRevisionBeforeRemoving() throws {
    let backing = Backing()
    let calendar = backing.addWritableCalendar(title: "Inbox")
    let reminder = backing.addReminder(title: "Delete me", calendar: calendar)
    let expectedRevision = ReminderEventKitCodec.revision(from: reminder)
    let store = EventKitReminderWriteStore(backing: backing)

    try store.delete(
      reminderID: reminder.calendarItemIdentifier, expectedRevision: expectedRevision)

    XCTAssertEqual(backing.removedReminders.count, 1)
    XCTAssertTrue(backing.removedReminders[0] === reminder)
    XCTAssertEqual(backing.refreshCount, 1)
  }

  func testDeleteTreatsFailedRefreshAsMissing() throws {
    let backing = Backing()
    let calendar = backing.addWritableCalendar(title: "Inbox")
    let reminder = backing.addReminder(title: "Keep me", calendar: calendar)
    let expectedRevision = ReminderEventKitCodec.revision(from: reminder)
    backing.refreshResult = false
    let store = EventKitReminderWriteStore(backing: backing)

    XCTAssertThrowsError(
      try store.delete(
        reminderID: reminder.calendarItemIdentifier, expectedRevision: expectedRevision)
    ) { error in
      XCTAssertEqual(error as? ReminderWriteError, .missingReminder)
    }
    XCTAssertEqual(backing.refreshCount, 1)
    XCTAssertTrue(backing.removedReminders.isEmpty)
  }

  func testDeletePropagatesRemoveFailure() throws {
    let backing = Backing()
    let calendar = backing.addWritableCalendar(title: "Inbox")
    let reminder = backing.addReminder(title: "Keep me", calendar: calendar)
    let expectedRevision = ReminderEventKitCodec.revision(from: reminder)
    backing.removeError = .removeRejected
    let store = EventKitReminderWriteStore(backing: backing)

    XCTAssertThrowsError(
      try store.delete(
        reminderID: reminder.calendarItemIdentifier, expectedRevision: expectedRevision)
    ) { error in
      XCTAssertEqual(error as? BackingError, .removeRejected)
    }
    XCTAssertEqual(backing.removeAttemptCount, 1)
    XCTAssertTrue(backing.removedReminders.isEmpty)
  }

  func testDeleteDoesNotRemoveAfterExternalChange() throws {
    let backing = Backing()
    let calendar = backing.addWritableCalendar(title: "Inbox")
    let reminder = backing.addReminder(title: "Keep me", calendar: calendar)
    let expectedRevision = ReminderEventKitCodec.revision(from: reminder)
    backing.onRefresh = { refreshed, refreshCount in
      if refreshCount == 1 { refreshed.notes = "Changed elsewhere" }
    }
    let store = EventKitReminderWriteStore(backing: backing)

    XCTAssertThrowsError(
      try store.delete(
        reminderID: reminder.calendarItemIdentifier, expectedRevision: expectedRevision)
    ) { error in
      XCTAssertEqual(error as? ReminderWriteError, .changedElsewhere)
    }
    XCTAssertTrue(backing.removedReminders.isEmpty)
    XCTAssertEqual(backing.resetCount, 0)
  }

  func testNormalizedCreateReturnsTheCommittedIdentifier() throws {
    let backing = Backing()
    let calendar = backing.addWritableCalendar(title: "Inbox")
    backing.onCommit = { reminder in reminder.title = "Provider title" }
    let store = EventKitReminderWriteStore(backing: backing)

    let outcome = try store.create(
      fields(title: "Requested title", listID: calendar.calendarIdentifier))

    guard case .committedWithNormalization(let actual, let mismatches) = outcome else {
      return XCTFail("Expected provider normalization, got \(outcome)")
    }
    let staged = try XCTUnwrap(backing.createdReminder)
    let committed = try XCTUnwrap(backing.authoritativeReminder)
    XCTAssertFalse(committed === staged)
    XCTAssertEqual(staged.title, "Requested title")
    XCTAssertEqual(actual.id, committed.calendarItemIdentifier)
    XCTAssertEqual(actual.title, "Provider title")
    XCTAssertEqual(mismatches.map(\.field), [.title])
    XCTAssertEqual(backing.postCommitLookupCount, 1)
    XCTAssertEqual(backing.postCommitRefreshCount, 1)
  }

  func testNormalizedUpdateReportsEveryChangedFieldMismatch() throws {
    let backing = Backing()
    let originalList = backing.addWritableCalendar(title: "Inbox")
    let requestedList = backing.addWritableCalendar(title: "Work")
    let reminder = backing.addReminder(title: "Original", calendar: originalList)
    reminder.notes = "Original notes"
    reminder.url = URL(string: "https://example.com/original")
    reminder.startDateComponents = components(year: 2026, month: 9, day: 1)
    reminder.dueDateComponents = components(year: 2026, month: 9, day: 2)
    reminder.priority = 1
    reminder.isCompleted = false
    let baseline = try ReminderEventKitCodec.editableFields(from: reminder)
    let expectedRevision = ReminderEventKitCodec.revision(from: reminder)
    var edited = baseline
    edited.title = "Requested"
    edited.notes = "Requested notes"
    edited.url = URL(string: "https://example.com/requested")
    edited.listID = requestedList.calendarIdentifier
    edited.startDate = try ReminderDateValue(
      validating: components(year: 2026, month: 10, day: 1))
    edited.dueDate = try ReminderDateValue(
      validating: components(year: 2026, month: 10, day: 2, hour: 9, minute: 15))
    edited.priority = 9
    edited.completion = try ReminderCompletionValue(
      validating: true, completionDate: Date(timeIntervalSince1970: 1_799_000_000))
    backing.onCommit = { committed in
      committed.title = baseline.title
      committed.notes = baseline.notes
      committed.url = baseline.url
      committed.calendar = originalList
      committed.startDateComponents = baseline.startDate?.components
      committed.dueDateComponents = baseline.dueDate?.components
      committed.priority = baseline.priority
      committed.isCompleted = baseline.completion.isCompleted
      committed.completionDate = baseline.completion.completionDate
    }
    let store = EventKitReminderWriteStore(backing: backing)

    let outcome = try store.save(
      reminderID: reminder.calendarItemIdentifier,
      patch: ReminderPatch(from: baseline, to: edited),
      expectedRevision: expectedRevision)

    guard case .committedWithNormalization(_, let mismatches) = outcome else {
      return XCTFail("Expected provider normalization, got \(outcome)")
    }
    XCTAssertEqual(
      mismatches.map(\.field),
      [.title, .notes, .url, .list, .startDate, .dueDate, .priority, .completion])
    XCTAssertEqual(reminder.title, edited.title)
    XCTAssertEqual(reminder.notes, edited.notes)
    XCTAssertTrue(try XCTUnwrap(backing.authoritativeReminder) !== reminder)
    XCTAssertEqual(backing.postCommitLookupCount, 1)
    XCTAssertEqual(backing.postCommitRefreshCount, 1)
  }

  func testNormalizedPartialPatchReportsOnlyTheChangedField() throws {
    let backing = Backing()
    let calendar = backing.addWritableCalendar(title: "Inbox")
    let reminder = backing.addReminder(title: "Original", calendar: calendar)
    reminder.notes = "Original notes"
    let expectedRevision = ReminderEventKitCodec.revision(from: reminder)
    let patch = try notesPatch(for: reminder, notes: "Requested notes")
    backing.onCommit = { committed in
      committed.title = "Provider changed an unpatched title"
      committed.notes = "Provider normalized notes"
    }
    let store = EventKitReminderWriteStore(backing: backing)

    let outcome = try store.save(
      reminderID: reminder.calendarItemIdentifier, patch: patch,
      expectedRevision: expectedRevision)

    guard case .committedWithNormalization(let actual, let mismatches) = outcome else {
      return XCTFail("Expected provider normalization, got \(outcome)")
    }
    XCTAssertEqual(actual.title, "Provider changed an unpatched title")
    XCTAssertEqual(actual.notes, "Provider normalized notes")
    XCTAssertEqual(reminder.title, "Original")
    XCTAssertEqual(reminder.notes, "Requested notes")
    XCTAssertEqual(
      mismatches,
      [
        ReminderNormalizationMismatch(
          field: .notes,
          reason: "The reminder provider saved a different notes value.")
      ])
  }

  func testNilProviderTitleDoesNotEqualARequestedUntitledString() throws {
    let backing = Backing()
    let calendar = backing.addWritableCalendar(title: "Inbox")
    backing.onCommit = { committed in committed.title = nil }
    let store = EventKitReminderWriteStore(backing: backing)

    let outcome = try store.create(
      fields(title: "Untitled", listID: calendar.calendarIdentifier))

    guard case .committedWithNormalization(_, let mismatches) = outcome else {
      return XCTFail("Expected a raw title mismatch, got \(outcome)")
    }
    XCTAssertEqual(mismatches.map(\.field), [.title])
  }

  func testUnreadablePostCommitCreateReturnsUnknownStatusWithoutRetrying() throws {
    let backing = Backing()
    let calendar = backing.addWritableCalendar(title: "Inbox")
    backing.exposesCreatedReminderAfterCommit = false
    let store = EventKitReminderWriteStore(backing: backing)

    let outcome = try store.create(fields(listID: calendar.calendarIdentifier))

    guard case .commitStatusUnknown(let receipt) = outcome else {
      return XCTFail("Expected unknown commit status, got \(outcome)")
    }
    let staged = try XCTUnwrap(backing.createdReminder)
    XCTAssertEqual(receipt.itemIdentifier, normalized(staged.calendarItemIdentifier))
    XCTAssertEqual(receipt.externalIdentifier, normalized(staged.calendarItemExternalIdentifier))
    XCTAssertEqual(backing.makeReminderCount, 1)
    XCTAssertEqual(backing.commitCount, 1)
    XCTAssertEqual(backing.resetCount, 0)
    XCTAssertEqual(backing.postCommitLookupCount, 1)
  }

  func testThrownCommitResetsPendingBatchAndReturnsUnknownStatus() throws {
    let backing = Backing()
    let calendar = backing.addWritableCalendar(title: "Inbox")
    backing.commitError = .commitRejected
    let store = EventKitReminderWriteStore(backing: backing)

    let outcome = try store.create(fields(listID: calendar.calendarIdentifier))

    guard case .commitStatusUnknown(let receipt) = outcome else {
      return XCTFail("Expected unknown commit status, got \(outcome)")
    }
    let staged = try XCTUnwrap(backing.createdReminder)
    XCTAssertEqual(receipt.itemIdentifier, normalized(staged.calendarItemIdentifier))
    XCTAssertEqual(receipt.externalIdentifier, normalized(staged.calendarItemExternalIdentifier))
    XCTAssertEqual(backing.resetCount, 1)
    XCTAssertEqual(backing.postCommitLookupCount, 0)
  }

  func testUnknownCreateReceiptBlocksASecondCoordinatorCreate() throws {
    let backing = Backing()
    let calendar = backing.addWritableCalendar(title: "Inbox")
    backing.exposesCreatedReminderAfterCommit = false
    let coordinator = ReminderWriteCoordinator(
      store: EventKitReminderWriteStore(backing: backing))
    let draft = ReminderDraft(
      title: "Requested", listID: calendar.calendarIdentifier, dueDate: nil,
      hasDueTime: false, priority: 0)

    _ = coordinator.create(draft)
    let staged = try XCTUnwrap(backing.createdReminder)
    XCTAssertEqual(
      coordinator.pendingCommitReceipt,
      ReminderCommitReceipt(
        itemIdentifier: normalized(staged.calendarItemIdentifier),
        externalIdentifier: normalized(staged.calendarItemExternalIdentifier)))

    _ = coordinator.create(draft)

    XCTAssertEqual(backing.makeReminderCount, 1)
    XCTAssertEqual(backing.commitCount, 1)
  }

  func testUnknownUpdateReceiptBlocksAnotherCoordinatorMutation() throws {
    let backing = Backing()
    let inbox = backing.addWritableCalendar(title: "Inbox")
    let work = backing.addWritableCalendar(title: "Work")
    let reminder = backing.addReminder(title: "Original", calendar: inbox)
    let coordinator = ReminderWriteCoordinator(
      store: EventKitReminderWriteStore(backing: backing))
    backing.exposesPostCommitReminder = false

    _ = coordinator.move(reminderItem(from: reminder), toListWithID: work.calendarIdentifier)
    let receipt = try XCTUnwrap(coordinator.pendingCommitReceipt)
    let stageCount = backing.stageSaveCount
    let commitCount = backing.commitCount

    _ = coordinator.reschedule(
      reminderItem(from: reminder), to: Date(timeIntervalSince1970: 1_799_000_000),
      hasTime: true)

    XCTAssertEqual(coordinator.pendingCommitReceipt, receipt)
    XCTAssertEqual(backing.stageSaveCount, stageCount)
    XCTAssertEqual(backing.commitCount, commitCount)
  }

  private func fields(
    title: String = "Requested", listID: String
  ) throws -> ReminderEditableFields {
    try ReminderEditableFields(
      validating: title, notes: "Notes", url: URL(string: "https://example.com/reminder"),
      listID: listID, startDate: nil,
      dueDate: ReminderDateValue(validating: components(year: 2026, month: 9, day: 3)),
      priority: 5,
      completion: ReminderCompletionValue(validating: false, completionDate: nil))
  }

  private func notesPatch(for reminder: EKReminder, notes: String?) throws -> ReminderPatch {
    let baseline = try ReminderEventKitCodec.editableFields(from: reminder)
    var edited = baseline
    edited.notes = notes
    return ReminderPatch(from: baseline, to: edited)
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

  private func normalized(_ identifier: String?) -> String? {
    guard let identifier, !identifier.isEmpty else { return nil }
    return identifier
  }

  private func reminderItem(from reminder: EKReminder) -> ReminderItem {
    ReminderEventKitCodec.record(from: reminder).item
  }
}

@MainActor
private final class Backing: ReminderEventKitStoreBacking {
  let eventStore = EKEventStore()
  var authorization: EventKitPermissionState = .fullAccess
  var onRefresh: ((EKReminder, Int) -> Void)?
  var onStageSave: ((EKReminder) -> Void)?
  var onCommit: ((EKReminder) -> Void)?
  var exposesCreatedReminderAfterCommit = true
  var exposesPostCommitReminder = true
  var refreshResult = true
  var commitError: BackingError?
  var removeError: BackingError?
  private(set) var createdReminder: EKReminder?
  private(set) var authoritativeReminder: EKReminder?
  private(set) var makeReminderCount = 0
  private(set) var stageSaveCount = 0
  private(set) var commitCount = 0
  private(set) var resetCount = 0
  private(set) var postCommitLookupCount = 0
  private(set) var postCommitRefreshCount = 0
  private(set) var removeAttemptCount = 0
  private(set) var writableCalendarLookups: [String] = []
  private(set) var removedReminders: [EKReminder] = []
  private(set) var refreshCount = 0
  private var calendars: [EKCalendar] = []
  private var writableCalendars: [String: EKCalendar] = [:]
  private var reminders: [String: EKReminder] = [:]
  private var stagedReminder: EKReminder?

  func reminderCalendars() -> [EKCalendar] { calendars }
  func defaultReminderCalendar() -> EKCalendar? { calendars.first }

  func writableReminderCalendar(withID id: String) -> EKCalendar? {
    writableCalendarLookups.append(id)
    return writableCalendars[id]
  }

  func reminder(withID id: String) -> EKReminder? {
    if commitCount > 0 { postCommitLookupCount += 1 }
    if commitCount > 0, !exposesPostCommitReminder { return nil }
    return reminders[id]
  }

  func makeReminder() -> EKReminder {
    makeReminderCount += 1
    let reminder = EKReminder(eventStore: eventStore)
    createdReminder = reminder
    return reminder
  }

  func refresh(_ reminder: EKReminder) -> Bool {
    refreshCount += 1
    if commitCount > 0 { postCommitRefreshCount += 1 }
    onRefresh?(reminder, refreshCount)
    return refreshResult
  }

  func stageSave(_ reminder: EKReminder) throws {
    stageSaveCount += 1
    stagedReminder = reminder
    onStageSave?(reminder)
  }

  func commit() throws {
    commitCount += 1
    if let commitError { throw commitError }
    guard let stagedReminder else { return }
    if stagedReminder === createdReminder, !exposesCreatedReminderAfterCommit { return }
    let authoritative = copy(stagedReminder)
    onCommit?(authoritative)
    authoritativeReminder = authoritative
    reminders[stagedReminder.calendarItemIdentifier] = authoritative
  }

  func reset() {
    resetCount += 1
    stagedReminder = nil
  }

  func remove(_ reminder: EKReminder) throws {
    removeAttemptCount += 1
    if let removeError { throw removeError }
    removedReminders.append(reminder)
    reminders.removeValue(forKey: reminder.calendarItemIdentifier)
  }

  func makeCalendar(title: String) -> EKCalendar {
    let calendar = EKCalendar(for: .reminder, eventStore: eventStore)
    calendar.title = title
    calendars.append(calendar)
    return calendar
  }

  func addWritableCalendar(title: String) -> EKCalendar {
    let calendar = makeCalendar(title: title)
    writableCalendars[calendar.calendarIdentifier] = calendar
    return calendar
  }

  func addReminder(title: String, calendar: EKCalendar) -> EKReminder {
    let reminder = EKReminder(eventStore: eventStore)
    reminder.title = title
    reminder.calendar = calendar
    reminders[reminder.calendarItemIdentifier] = reminder
    return reminder
  }

  private func copy(_ reminder: EKReminder) -> EKReminder {
    let copied = EKReminder(eventStore: eventStore)
    copied.title = reminder.title
    copied.notes = reminder.notes
    copied.url = reminder.url
    copied.calendar = reminder.calendar
    copied.startDateComponents = reminder.startDateComponents
    copied.dueDateComponents = reminder.dueDateComponents
    copied.priority = reminder.priority
    copied.isCompleted = reminder.isCompleted
    copied.completionDate = reminder.completionDate
    copied.location = reminder.location
    copied.timeZone = reminder.timeZone
    copied.alarms = reminder.alarms
    copied.recurrenceRules = reminder.recurrenceRules
    return copied
  }
}

private enum BackingError: Error, Equatable {
  case commitRejected
  case removeRejected
}
