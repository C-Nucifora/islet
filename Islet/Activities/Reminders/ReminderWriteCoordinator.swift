import EventKit
import Foundation

struct ReminderListItem: Identifiable, Equatable, Sendable {
  let id: String
  let title: String
  let colorHex: String?
  let isDefault: Bool
  let isWritable: Bool
}

struct ReminderDraft: Equatable, Sendable {
  var title: String
  var listID: String?
  var dueDate: Date?
  var hasDueTime: Bool
  var priority: Int
  var sourceRevision: ReminderWriteRecord.Revision? = nil

  static let empty = ReminderDraft(
    title: "", listID: nil, dueDate: nil, hasDueTime: false, priority: 0)
}

struct ReminderWriteRecord: Equatable, Sendable {
  struct Revision: Equatable, Sendable {
    let lastModified: Date?
    let title: String
    let notes: String?
    let priority: Int
    let dueDateComponents: DateComponents?
    let listID: String
    let isCompleted: Bool
  }

  let id: String
  var title: String
  var notes: String?
  var priority: Int
  var dueDateComponents: DateComponents?
  var listID: String
  var listTitle: String
  var listColorHex: String?
  var isCompleted: Bool
  var lastModified: Date?

  var revision: Revision {
    Revision(
      lastModified: lastModified, title: title, notes: notes, priority: priority,
      dueDateComponents: dueDateComponents, listID: listID, isCompleted: isCompleted)
  }

  var item: ReminderItem {
    let hasDueTime =
      dueDateComponents?.hour != nil || dueDateComponents?.minute != nil
      || dueDateComponents?.second != nil
    return ReminderItem(
      id: id, title: title, dueDate: RemindersLogic.dueDate(from: dueDateComponents),
      hasDueTime: hasDueTime, priority: priority, listColorHex: listColorHex,
      listID: listID, listTitle: listTitle)
  }
}

enum ReminderWriteError: LocalizedError, Equatable {
  case permissionDenied
  case missingList
  case missingReminder
  case changedElsewhere
  case undoExpired
  case noUndoAvailable
  case emptyTitle
  case eventKit(String)

  var errorDescription: String? {
    switch self {
    case .permissionDenied:
      "Reminders access is no longer available."
    case .missingList:
      "That reminder list is no longer available."
    case .missingReminder:
      "That reminder is no longer available."
    case .changedElsewhere:
      "That reminder changed in another app, so it was not overwritten."
    case .undoExpired:
      "The undo period has expired."
    case .noUndoAvailable:
      "There is no completion to undo."
    case .emptyTitle:
      "Enter a reminder title."
    case .eventKit(let message):
      message
    }
  }
}

@MainActor
protocol ReminderWriteStore: AnyObject {
  var authorization: EventKitPermissionState { get }
  func reminderLists() -> [ReminderListItem]
  func defaultListID() -> String?
  func record(withID id: String) -> ReminderWriteRecord?
  func create(_ draft: ReminderDraft, inListWithID listID: String) throws -> ReminderWriteRecord
  func save(_ record: ReminderWriteRecord, expectedRevision: ReminderWriteRecord.Revision) throws
    -> ReminderWriteRecord
}

@MainActor
final class ReminderWriteCoordinator {
  struct CompletionUndo: Equatable, Sendable {
    let reminderID: String
    let title: String
    let completedRevision: ReminderWriteRecord.Revision
    let expiresAt: Date
  }

  private let store: any ReminderWriteStore
  private let undoDuration: TimeInterval
  private(set) var completionUndo: CompletionUndo?

  init(store: any ReminderWriteStore, undoDuration: TimeInterval = 8) {
    self.store = store
    self.undoDuration = undoDuration
  }

  func lists() -> [ReminderListItem] {
    guard store.authorization.canRead else { return [] }
    return store.reminderLists().filter(\.isWritable)
  }

  func defaultListID() -> String? {
    guard store.authorization.canRead, let id = store.defaultListID(), listIsWritable(id) else {
      return nil
    }
    return id
  }

  func draft(for item: ReminderItem) -> Result<ReminderDraft, ReminderWriteError> {
    do {
      try checkPermission()
      guard let record = store.record(withID: item.id) else {
        throw ReminderWriteError.missingReminder
      }
      guard listIsWritable(record.listID) else { throw ReminderWriteError.missingList }
      let hasDueTime =
        record.dueDateComponents?.hour != nil || record.dueDateComponents?.minute != nil
        || record.dueDateComponents?.second != nil
      return .success(
        ReminderDraft(
          title: record.title, listID: record.listID,
          dueDate: RemindersLogic.dueDate(from: record.dueDateComponents),
          hasDueTime: hasDueTime, priority: record.priority, sourceRevision: record.revision))
    } catch {
      return .failure(map(error))
    }
  }

  func create(_ draft: ReminderDraft) -> Result<ReminderItem, ReminderWriteError> {
    do {
      try checkPermission()
      let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !title.isEmpty else { throw ReminderWriteError.emptyTitle }
      guard let listID = draft.listID ?? defaultListID(), listIsWritable(listID) else {
        throw ReminderWriteError.missingList
      }
      var normalized = draft
      normalized.title = title
      if normalized.dueDate == nil { normalized.hasDueTime = false }
      return .success(try store.create(normalized, inListWithID: listID).item)
    } catch {
      return .failure(map(error))
    }
  }

  func update(_ item: ReminderItem, with draft: ReminderDraft) -> Result<
    ReminderItem, ReminderWriteError
  > {
    do {
      try checkPermission()
      let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !title.isEmpty else { throw ReminderWriteError.emptyTitle }
      guard let listID = draft.listID, listIsWritable(listID) else {
        throw ReminderWriteError.missingList
      }
      guard let sourceRevision = draft.sourceRevision else {
        throw ReminderWriteError.changedElsewhere
      }
      guard var record = store.record(withID: item.id) else {
        throw ReminderWriteError.missingReminder
      }
      guard record.revision == sourceRevision else {
        throw ReminderWriteError.changedElsewhere
      }
      record.title = title
      record.priority = draft.priority
      record.listID = listID
      record.dueDateComponents = draft.dueDate.map {
        RemindersLogic.dueComponents(for: $0, hasTime: draft.hasDueTime)
      }
      return .success(try store.save(record, expectedRevision: sourceRevision).item)
    } catch {
      return .failure(map(error))
    }
  }

  func move(_ item: ReminderItem, toListWithID listID: String) -> Result<
    ReminderItem, ReminderWriteError
  > {
    do {
      try checkPermission()
      guard listIsWritable(listID) else { throw ReminderWriteError.missingList }
      guard var record = store.record(withID: item.id) else {
        throw ReminderWriteError.missingReminder
      }
      let revision = record.revision
      record.listID = listID
      return .success(try store.save(record, expectedRevision: revision).item)
    } catch {
      return .failure(map(error))
    }
  }

  func reschedule(_ item: ReminderItem, to date: Date, hasTime: Bool) -> Result<
    ReminderItem, ReminderWriteError
  > {
    do {
      try checkPermission()
      guard var record = store.record(withID: item.id) else {
        throw ReminderWriteError.missingReminder
      }
      let revision = record.revision
      record.dueDateComponents = RemindersLogic.dueComponents(for: date, hasTime: hasTime)
      return .success(try store.save(record, expectedRevision: revision).item)
    } catch {
      return .failure(map(error))
    }
  }

  func complete(_ item: ReminderItem, now: Date = Date()) -> Result<
    CompletionUndo, ReminderWriteError
  > {
    do {
      try checkPermission()
      guard var record = store.record(withID: item.id) else {
        throw ReminderWriteError.missingReminder
      }
      let revision = record.revision
      record.isCompleted = true
      let saved = try store.save(record, expectedRevision: revision)
      let undo = CompletionUndo(
        reminderID: saved.id, title: saved.title, completedRevision: saved.revision,
        expiresAt: now.addingTimeInterval(undoDuration))
      completionUndo = undo
      return .success(undo)
    } catch {
      return .failure(map(error))
    }
  }

  func undoCompletion(now: Date = Date()) -> Result<ReminderItem, ReminderWriteError> {
    guard let undo = completionUndo else { return .failure(.noUndoAvailable) }
    completionUndo = nil
    guard now < undo.expiresAt else { return .failure(.undoExpired) }
    do {
      try checkPermission()
      guard var record = store.record(withID: undo.reminderID) else {
        throw ReminderWriteError.missingReminder
      }
      guard record.isCompleted, record.revision == undo.completedRevision else {
        throw ReminderWriteError.changedElsewhere
      }
      let revision = record.revision
      record.isCompleted = false
      return .success(try store.save(record, expectedRevision: revision).item)
    } catch {
      return .failure(map(error))
    }
  }

  func discardExpiredUndo(now: Date = Date()) {
    if let completionUndo, now >= completionUndo.expiresAt { self.completionUndo = nil }
  }

  private func checkPermission() throws {
    guard store.authorization.canRead else { throw ReminderWriteError.permissionDenied }
  }

  private func listIsWritable(_ id: String) -> Bool {
    store.reminderLists().contains { $0.id == id && $0.isWritable }
  }

  private func map(_ error: Error) -> ReminderWriteError {
    if let error = error as? ReminderWriteError { return error }
    return .eventKit(error.localizedDescription)
  }
}

@MainActor
final class EventKitReminderWriteStore: ReminderWriteStore {
  private let store: EKEventStore

  init(store: EKEventStore) {
    self.store = store
  }

  var authorization: EventKitPermissionState {
    EventKitPermissionState(EKEventStore.authorizationStatus(for: .reminder))
  }

  func reminderLists() -> [ReminderListItem] {
    let defaultID = store.defaultCalendarForNewReminders()?.calendarIdentifier
    return store.calendars(for: .reminder)
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
    store.defaultCalendarForNewReminders()?.calendarIdentifier
  }

  func record(withID id: String) -> ReminderWriteRecord? {
    guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else { return nil }
    return record(from: reminder)
  }

  func create(_ draft: ReminderDraft, inListWithID listID: String) throws -> ReminderWriteRecord {
    guard let list = reminderList(withID: listID) else { throw ReminderWriteError.missingList }
    let reminder = EKReminder(eventStore: store)
    reminder.title = draft.title
    reminder.calendar = list
    reminder.priority = draft.priority
    reminder.dueDateComponents = draft.dueDate.map {
      RemindersLogic.dueComponents(for: $0, hasTime: draft.hasDueTime)
    }
    try store.save(reminder, commit: true)
    return record(withID: reminder.calendarItemIdentifier) ?? record(from: reminder)
  }

  func save(_ record: ReminderWriteRecord, expectedRevision: ReminderWriteRecord.Revision) throws
    -> ReminderWriteRecord
  {
    guard let reminder = store.calendarItem(withIdentifier: record.id) as? EKReminder else {
      throw ReminderWriteError.missingReminder
    }
    guard self.record(from: reminder).revision == expectedRevision else {
      throw ReminderWriteError.changedElsewhere
    }
    guard let list = reminderList(withID: record.listID) else {
      throw ReminderWriteError.missingList
    }
    reminder.title = record.title
    reminder.notes = record.notes
    reminder.priority = record.priority
    reminder.dueDateComponents = record.dueDateComponents
    reminder.calendar = list
    reminder.isCompleted = record.isCompleted
    try store.save(reminder, commit: true)
    return self.record(withID: reminder.calendarItemIdentifier) ?? self.record(from: reminder)
  }

  private func reminderList(withID id: String) -> EKCalendar? {
    store.calendars(for: .reminder).first {
      $0.calendarIdentifier == id && $0.allowsContentModifications
    }
  }

  private func record(from reminder: EKReminder) -> ReminderWriteRecord {
    ReminderWriteRecord(
      id: reminder.calendarItemIdentifier, title: reminder.title ?? "Untitled",
      notes: reminder.notes, priority: reminder.priority,
      dueDateComponents: reminder.dueDateComponents,
      listID: reminder.calendar.calendarIdentifier, listTitle: reminder.calendar.title,
      listColorHex: ColorHex.string(from: reminder.calendar.cgColor),
      isCompleted: reminder.isCompleted, lastModified: reminder.lastModifiedDate)
  }
}
