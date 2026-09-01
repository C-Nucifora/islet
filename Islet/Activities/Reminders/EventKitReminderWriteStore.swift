import EventKit
import Foundation

@MainActor
protocol ReminderEventKitStoreBacking: AnyObject {
  var authorization: EventKitPermissionState { get }
  func reminderCalendars() -> [EKCalendar]
  func defaultReminderCalendar() -> EKCalendar?
  func writableReminderCalendar(withID id: String) -> EKCalendar?
  func reminder(withID id: String) -> EKReminder?
  func makeReminder() -> EKReminder
  func refresh(_ reminder: EKReminder) -> Bool
  func stageSave(_ reminder: EKReminder) throws
  func commit() throws
  func reset()
  func remove(_ reminder: EKReminder) throws
}

@MainActor
private final class LiveReminderEventKitStoreBacking: ReminderEventKitStoreBacking {
  private let store: EKEventStore

  init(store: EKEventStore) {
    self.store = store
  }

  var authorization: EventKitPermissionState {
    EventKitPermissionState(EKEventStore.authorizationStatus(for: .reminder))
  }

  func reminderCalendars() -> [EKCalendar] {
    store.calendars(for: .reminder)
  }

  func defaultReminderCalendar() -> EKCalendar? {
    store.defaultCalendarForNewReminders()
  }

  func writableReminderCalendar(withID id: String) -> EKCalendar? {
    store.calendars(for: .reminder).first {
      $0.calendarIdentifier == id && $0.allowsContentModifications
    }
  }

  func reminder(withID id: String) -> EKReminder? {
    store.calendarItem(withIdentifier: id) as? EKReminder
  }

  func makeReminder() -> EKReminder {
    EKReminder(eventStore: store)
  }

  func refresh(_ reminder: EKReminder) -> Bool {
    reminder.refresh()
  }

  func stageSave(_ reminder: EKReminder) throws {
    try store.save(reminder, commit: false)
  }

  func commit() throws {
    try store.commit()
  }

  func reset() {
    store.reset()
  }

  func remove(_ reminder: EKReminder) throws {
    try store.remove(reminder, commit: true)
  }
}

@MainActor
final class EventKitReminderWriteStore: ReminderWriteStore {
  // Main-actor isolation serializes Islet's EventKit access. Another process can still write
  // between refresh, comparison, staging, and commit, so the post-commit read remains authoritative.
  private let backing: any ReminderEventKitStoreBacking

  init(store: EKEventStore) {
    backing = LiveReminderEventKitStoreBacking(store: store)
  }

  init(backing: any ReminderEventKitStoreBacking) {
    self.backing = backing
  }

  var authorization: EventKitPermissionState {
    backing.authorization
  }

  func reminderLists() -> [ReminderListItem] {
    let defaultID = backing.defaultReminderCalendar()?.calendarIdentifier
    return backing.reminderCalendars()
      .map {
        ReminderListItem(
          id: $0.calendarIdentifier, title: $0.title,
          colorHex: ColorHex.string(from: $0.cgColor),
          isDefault: $0.calendarIdentifier == defaultID,
          isWritable: $0.allowsContentModifications)
      }
      .sorted {
        if $0.isDefault != $1.isDefault { return $0.isDefault }
        return $0.title.localizedStandardCompare($1.title) == .orderedAscending
      }
  }

  func defaultListID() -> String? {
    backing.defaultReminderCalendar()?.calendarIdentifier
  }

  func record(withID id: String) -> ReminderWriteRecord? {
    backing.reminder(withID: id).map(ReminderEventKitCodec.record(from:))
  }

  func create(_ fields: ReminderEditableFields) throws -> ReminderWriteOutcome {
    guard let list = backing.writableReminderCalendar(withID: fields.listID),
      list.calendarIdentifier == fields.listID,
      list.allowsContentModifications
    else {
      throw ReminderWriteError.missingList
    }

    let reminder = backing.makeReminder()
    let patch = Self.replacementPatch(for: fields)
    try ReminderEventKitCodec.apply(
      patch, to: reminder,
      resolveList: { id in id == fields.listID ? list : nil })
    return try stageCommitAndRead(reminder, requestedPatch: patch)
  }

  func save(
    reminderID: String, patch: ReminderPatch,
    expectedRevision: ReminderWriteRecord.Revision
  ) throws -> ReminderWriteOutcome {
    guard let reminder = backing.reminder(withID: reminderID) else {
      throw ReminderWriteError.missingReminder
    }
    guard backing.refresh(reminder) else {
      throw ReminderWriteError.missingReminder
    }
    guard ReminderEventKitCodec.revision(from: reminder) == expectedRevision else {
      throw ReminderWriteError.changedElsewhere
    }

    let resolvedList: EKCalendar?
    switch patch.listID {
    case .unchanged:
      resolvedList = nil
    case .value(let listID):
      guard let list = backing.writableReminderCalendar(withID: listID),
        list.calendarIdentifier == listID,
        list.allowsContentModifications
      else {
        throw ReminderWriteError.missingList
      }
      resolvedList = list
    }

    try ReminderEventKitCodec.apply(
      patch, to: reminder,
      resolveList: { id in
        guard let resolvedList, resolvedList.calendarIdentifier == id else { return nil }
        return resolvedList
      })
    return try stageCommitAndRead(reminder, requestedPatch: patch)
  }

  func delete(
    reminderID: String, expectedRevision: ReminderWriteRecord.Revision
  ) throws {
    guard let reminder = backing.reminder(withID: reminderID) else {
      throw ReminderWriteError.missingReminder
    }
    guard backing.refresh(reminder) else {
      throw ReminderWriteError.missingReminder
    }
    guard ReminderEventKitCodec.revision(from: reminder) == expectedRevision else {
      throw ReminderWriteError.changedElsewhere
    }
    try backing.remove(reminder)
  }

  private func stageCommitAndRead(
    _ reminder: EKReminder, requestedPatch: ReminderPatch
  ) throws -> ReminderWriteOutcome {
    do {
      try backing.stageSave(reminder)
    } catch {
      backing.reset()
      throw error
    }

    let stagedMismatches = Self.mismatches(for: requestedPatch, in: reminder)
    guard stagedMismatches.isEmpty else {
      backing.reset()
      throw ReminderWriteError.eventKit(
        "The reminder provider could not stage the requested values.")
    }

    let stagedReceipt = Self.receipt(for: reminder)
    do {
      try backing.commit()
    } catch {
      backing.reset()
      return .commitStatusUnknown(stagedReceipt)
    }

    let receipt = Self.receipt(for: reminder)
    guard let itemIdentifier = receipt.itemIdentifier,
      let committed = backing.reminder(withID: itemIdentifier),
      backing.refresh(committed)
    else {
      return .commitStatusUnknown(receipt)
    }

    let actual = ReminderEventKitCodec.record(from: committed)
    let committedMismatches = Self.mismatches(for: requestedPatch, in: committed)
    if committedMismatches.isEmpty {
      return .saved(actual)
    }
    return .committedWithNormalization(
      actual: actual, mismatches: committedMismatches)
  }

  private static func replacementPatch(for fields: ReminderEditableFields) -> ReminderPatch {
    var patch = ReminderPatch(from: fields, to: fields)
    patch.title = .value(fields.title)
    patch.notes = .value(fields.notes)
    patch.url = .value(fields.url)
    patch.listID = .value(fields.listID)
    patch.startDate = .value(fields.startDate)
    patch.dueDate = .value(fields.dueDate)
    patch.priority = .value(fields.priority)
    patch.completion = .value(fields.completion)
    return patch
  }

  private static func receipt(for reminder: EKReminder) -> ReminderCommitReceipt {
    ReminderCommitReceipt(
      itemIdentifier: normalized(reminder.calendarItemIdentifier),
      externalIdentifier: normalized(reminder.calendarItemExternalIdentifier))
  }

  private static func normalized(_ identifier: String?) -> String? {
    guard let identifier, !identifier.isEmpty else { return nil }
    return identifier
  }

  private static func mismatches(
    for patch: ReminderPatch, in reminder: EKReminder
  ) -> [ReminderNormalizationMismatch] {
    var mismatches: [ReminderNormalizationMismatch] = []

    appendMismatch(
      patch.title, actual: reminder.title, field: .title,
      requestedValue: { Optional($0) }, to: &mismatches)
    appendMismatch(patch.notes, actual: reminder.notes, field: .notes, to: &mismatches)
    appendMismatch(patch.url, actual: reminder.url, field: .url, to: &mismatches)
    appendMismatch(
      patch.listID, actual: reminder.calendar?.calendarIdentifier ?? "", field: .list,
      to: &mismatches)
    appendMismatch(
      patch.startDate, actual: reminder.startDateComponents, field: .startDate,
      requestedValue: { $0?.components }, to: &mismatches)
    appendMismatch(
      patch.dueDate, actual: reminder.dueDateComponents, field: .dueDate,
      requestedValue: { $0?.components }, to: &mismatches)
    appendMismatch(
      patch.priority, actual: reminder.priority, field: .priority, to: &mismatches)

    switch patch.completion {
    case .unchanged:
      break
    case .value(let requested):
      if reminder.isCompleted != requested.isCompleted
        || reminder.completionDate != requested.completionDate
      {
        mismatches.append(mismatch(for: .completion))
      }
    }

    return mismatches
  }

  private static func appendMismatch<Value: Equatable & Sendable>(
    _ change: ReminderFieldChange<Value>, actual: Value, field: ReminderField,
    to mismatches: inout [ReminderNormalizationMismatch]
  ) {
    guard case .value(let requested) = change, requested != actual else { return }
    mismatches.append(mismatch(for: field))
  }

  private static func appendMismatch<Value: Equatable & Sendable, Actual: Equatable>(
    _ change: ReminderFieldChange<Value>, actual: Actual, field: ReminderField,
    requestedValue: (Value) -> Actual,
    to mismatches: inout [ReminderNormalizationMismatch]
  ) {
    guard case .value(let requested) = change, requestedValue(requested) != actual else { return }
    mismatches.append(mismatch(for: field))
  }

  private static func mismatch(for field: ReminderField) -> ReminderNormalizationMismatch {
    ReminderNormalizationMismatch(
      field: field, reason: "The reminder provider saved a different \(field.rawValue) value.")
  }
}
