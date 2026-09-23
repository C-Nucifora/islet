import EventKit
import Foundation

@MainActor
struct ReminderEventKitStoreRoles {
  let queryStore: EKEventStore
  let writeStore: EKEventStore
  let authoritativeReadbackStore: EKEventStore

  init(
    queryStore: EKEventStore = EKEventStore(),
    writeStore: EKEventStore = EKEventStore(),
    authoritativeReadbackStore: EKEventStore = EKEventStore()
  ) {
    self.queryStore = queryStore
    self.writeStore = writeStore
    self.authoritativeReadbackStore = authoritativeReadbackStore
    precondition(areDistinct, "Reminder EventKit store roles must use distinct instances")
  }

  var areDistinct: Bool {
    queryStore !== writeStore && queryStore !== authoritativeReadbackStore
      && writeStore !== authoritativeReadbackStore
  }
}

@MainActor
protocol ReminderEventKitStoreBacking: AnyObject {
  var authorization: EventKitPermissionState { get }
  func reminderCalendars() -> [EKCalendar]
  func defaultReminderCalendar() -> EKCalendar?
  func writableReminderCalendar(withID id: String) -> EKCalendar?
  func reminder(withID id: String) -> EKReminder?
  func authoritativeReminder(withID id: String) -> EKReminder?
  func makeReminder() -> EKReminder
  func refresh(_ reminder: EKReminder) -> Bool
  func stageSave(_ reminder: EKReminder) throws
  func commit() throws
  func reset()
  func remove(_ reminder: EKReminder) throws
}

@MainActor
private final class LiveReminderEventKitStoreBacking: ReminderEventKitStoreBacking {
  private let writeStore: EKEventStore
  private let authoritativeReadbackStore: EKEventStore

  init(store: EKEventStore, authoritativeReadbackStore: EKEventStore) {
    precondition(
      store !== authoritativeReadbackStore,
      "Reminder write and authoritative-readback stores must be distinct")
    writeStore = store
    self.authoritativeReadbackStore = authoritativeReadbackStore
  }

  var authorization: EventKitPermissionState {
    EventKitPermissionState(EKEventStore.authorizationStatus(for: .reminder))
  }

  func reminderCalendars() -> [EKCalendar] {
    writeStore.calendars(for: .reminder)
  }

  func defaultReminderCalendar() -> EKCalendar? {
    writeStore.defaultCalendarForNewReminders()
  }

  func writableReminderCalendar(withID id: String) -> EKCalendar? {
    writeStore.calendars(for: .reminder).first {
      $0.calendarIdentifier == id && $0.allowsContentModifications
    }
  }

  func reminder(withID id: String) -> EKReminder? {
    writeStore.calendarItem(withIdentifier: id) as? EKReminder
  }

  func authoritativeReminder(withID id: String) -> EKReminder? {
    authoritativeReadbackStore.calendarItem(withIdentifier: id) as? EKReminder
  }

  func makeReminder() -> EKReminder {
    EKReminder(eventStore: writeStore)
  }

  func refresh(_ reminder: EKReminder) -> Bool {
    reminder.refresh()
  }

  func stageSave(_ reminder: EKReminder) throws {
    try writeStore.save(reminder, commit: false)
  }

  func commit() throws {
    try writeStore.commit()
  }

  func reset() {
    writeStore.reset()
  }

  func remove(_ reminder: EKReminder) throws {
    try writeStore.remove(reminder, commit: true)
  }
}

@MainActor
final class EventKitReminderWriteStore: ReminderWriteStore {
  // Main-actor isolation serializes Islet's EventKit access. Another process can still write
  // between refresh, comparison, staging, and commit, so the post-commit read remains authoritative.
  private let backing: any ReminderEventKitStoreBacking

  init(
    store: EKEventStore,
    authoritativeReadbackStore: EKEventStore = EKEventStore()
  ) {
    backing = LiveReminderEventKitStoreBacking(
      store: store, authoritativeReadbackStore: authoritativeReadbackStore)
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
    let expectedRecord = ReminderEventKitCodec.record(from: reminder)
    let expectedAlarms = (reminder.alarms ?? []).map(ReminderEventKitCodec.alarmRevision(from:))
    let expectedRules = (reminder.recurrenceRules ?? []).map(
      ReminderEventKitCodec.recurrenceRevision(from:))
    do {
      try backing.stageSave(reminder)
    } catch {
      backing.reset()
      if requestedPatch.alarms != .unchanged || requestedPatch.recurrenceRules != .unchanged {
        throw ReminderWriteError.eventKit(
          String(
            localized:
              "This account could not save the requested alerts or repeat rules. Check the account's support in Reminders, then try again. \(error.localizedDescription)"
          ))
      }
      throw error
    }

    let stagedMismatches = Self.mismatches(
      for: requestedPatch, in: reminder, expectedAlarms: expectedAlarms,
      expectedRules: expectedRules, expectedRecord: expectedRecord,
      allowEquivalentDateInstants: true)
    guard stagedMismatches.isEmpty else {
      backing.reset()
      throw ReminderWriteError.eventKit(
        "This account could not save the requested values. "
          + stagedMismatches.map(\.reason).joined(separator: " "))
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
      let committed = backing.authoritativeReminder(withID: itemIdentifier),
      committed !== reminder,
      backing.refresh(committed)
    else {
      return .commitStatusUnknown(receipt)
    }

    let actual = ReminderEventKitCodec.record(from: committed)
    let committedMismatches = Self.mismatches(
      for: requestedPatch, in: committed, expectedAlarms: expectedAlarms,
      expectedRules: expectedRules, expectedRecord: expectedRecord)
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
    patch.alarms = .value(fields.alarms)
    patch.recurrenceRules = .value(fields.recurrenceRules)
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
    for patch: ReminderPatch, in reminder: EKReminder,
    expectedAlarms: [ReminderAlarmRevision], expectedRules: [ReminderRecurrenceRevision],
    expectedRecord: ReminderWriteRecord, allowEquivalentDateInstants: Bool = false
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
    if case .value(let requested) = patch.startDate,
      !datesMatch(
        requested?.components, reminder.startDateComponents,
        allowEquivalentInstants: allowEquivalentDateInstants)
    {
      mismatches.append(mismatch(for: .startDate))
    }
    if case .value(let requested) = patch.dueDate,
      !datesMatch(
        requested?.components, reminder.dueDateComponents,
        allowEquivalentInstants: allowEquivalentDateInstants)
    {
      mismatches.append(mismatch(for: .dueDate))
    }
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

    if !ReminderAdvancedCodec.sameValues(
      expectedAlarms,
      (reminder.alarms ?? []).map(ReminderEventKitCodec.alarmRevision(from:)))
    {
      mismatches.append(mismatch(for: .alarms))
    }
    if !ReminderAdvancedCodec.sameValues(
      expectedRules,
      (reminder.recurrenceRules ?? []).map(ReminderEventKitCodec.recurrenceRevision(from:)))
    {
      mismatches.append(mismatch(for: .recurrence))
    }
    func preserved(_ unchanged: Bool, _ matches: Bool, field: ReminderField) {
      if unchanged && !matches && !mismatches.contains(where: { $0.field == field }) {
        mismatches.append(
          ReminderNormalizationMismatch(
            field: field,
            reason:
              "The account changed \(field.displayName) even though it was not edited. Review the saved reminder before retrying."
          ))
      }
    }
    preserved(patch.title == .unchanged, reminder.title == expectedRecord.title, field: .title)
    preserved(patch.notes == .unchanged, reminder.notes == expectedRecord.notes, field: .notes)
    preserved(patch.url == .unchanged, reminder.url == expectedRecord.url, field: .url)
    preserved(
      patch.listID == .unchanged, reminder.calendar?.calendarIdentifier == expectedRecord.listID,
      field: .list)
    preserved(
      patch.startDate == .unchanged,
      ReminderDateValue.semanticallyEqual(
        reminder.startDateComponents, expectedRecord.startDateComponents), field: .startDate)
    preserved(
      patch.dueDate == .unchanged,
      ReminderDateValue.semanticallyEqual(
        reminder.dueDateComponents, expectedRecord.dueDateComponents), field: .dueDate)
    preserved(
      patch.priority == .unchanged, reminder.priority == expectedRecord.priority, field: .priority)
    preserved(
      patch.completion == .unchanged,
      reminder.isCompleted == expectedRecord.isCompleted
        && reminder.completionDate == expectedRecord.completionDate,
      field: .completion)
    preserved(
      true,
      reminder.location == expectedRecord.location && reminder.timeZone == expectedRecord.timeZone,
      field: .nativeMetadata)
    return mismatches
  }

  private static func datesMatch(
    _ requested: DateComponents?, _ actual: DateComponents?, allowEquivalentInstants: Bool
  ) -> Bool {
    if ReminderDateValue.semanticallyEqual(requested, actual) { return true }
    guard allowEquivalentInstants, let requested, let actual,
      requested.timeZone != nil,
      requested.hour != nil, requested.minute != nil,
      actual.hour != nil, actual.minute != nil
    else {
      return false
    }

    return resolvedDate(from: requested) == resolvedDate(from: actual)
  }

  private static func resolvedDate(from components: DateComponents) -> Date? {
    var calendar = components.calendar ?? Calendar(identifier: .gregorian)
    if let timeZone = components.timeZone { calendar.timeZone = timeZone }
    return calendar.date(from: components)
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
      field: field,
      reason: String(
        localized: "The reminder provider saved a different \(field.displayName) value."))
  }
}
