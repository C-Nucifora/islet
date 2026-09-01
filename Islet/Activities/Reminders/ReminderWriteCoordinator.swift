import EventKit
import Foundation

struct ReminderListItem: Identifiable, Equatable, Sendable {
  let id: String
  let title: String
  let colorHex: String?
  let isDefault: Bool
  let isWritable: Bool
}

extension ReminderWriteRecord {
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

@MainActor
protocol ReminderWriteStore: AnyObject {
  var authorization: EventKitPermissionState { get }
  func reminderLists() -> [ReminderListItem]
  func defaultListID() -> String?
  func record(withID id: String) -> ReminderWriteRecord?
  func create(_ fields: ReminderEditableFields) throws -> ReminderWriteOutcome
  func save(
    reminderID: String, patch: ReminderPatch,
    expectedRevision: ReminderWriteRecord.Revision
  ) throws -> ReminderWriteOutcome
  func delete(
    reminderID: String, expectedRevision: ReminderWriteRecord.Revision
  ) throws
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
  private(set) var pendingCommitReceipt: ReminderCommitReceipt?

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
    guard pendingCommitReceipt == nil else {
      return .failure(pendingCommitError)
    }
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
      let dueDate = try normalized.dueDate.map {
        try ReminderDateValue(
          validating: RemindersLogic.dueComponents(
            for: $0, hasTime: normalized.hasDueTime))
      }
      let fields = try ReminderEditableFields(
        validating: normalized.title, notes: nil, url: nil, listID: listID,
        startDate: nil, dueDate: dueDate, priority: normalized.priority,
        completion: ReminderCompletionValue(
          validating: false, completionDate: nil))
      return .success(try committedRecord(from: store.create(fields)).item)
    } catch {
      return .failure(map(error))
    }
  }

  func update(_ item: ReminderItem, with draft: ReminderDraft) -> Result<
    ReminderItem, ReminderWriteError
  > {
    do {
      try checkNoPendingCommit()
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
      return .success(try save(record, expectedRevision: sourceRevision).item)
    } catch {
      return .failure(map(error))
    }
  }

  func move(_ item: ReminderItem, toListWithID listID: String) -> Result<
    ReminderItem, ReminderWriteError
  > {
    do {
      try checkNoPendingCommit()
      try checkPermission()
      guard listIsWritable(listID) else { throw ReminderWriteError.missingList }
      guard var record = store.record(withID: item.id) else {
        throw ReminderWriteError.missingReminder
      }
      let revision = record.revision
      record.listID = listID
      return .success(try save(record, expectedRevision: revision).item)
    } catch {
      return .failure(map(error))
    }
  }

  func reschedule(_ item: ReminderItem, to date: Date, hasTime: Bool) -> Result<
    ReminderItem, ReminderWriteError
  > {
    do {
      try checkNoPendingCommit()
      try checkPermission()
      guard var record = store.record(withID: item.id) else {
        throw ReminderWriteError.missingReminder
      }
      let revision = record.revision
      record.dueDateComponents = RemindersLogic.dueComponents(for: date, hasTime: hasTime)
      return .success(try save(record, expectedRevision: revision).item)
    } catch {
      return .failure(map(error))
    }
  }

  func complete(_ item: ReminderItem, now: Date = Date()) -> Result<
    CompletionUndo, ReminderWriteError
  > {
    do {
      try checkNoPendingCommit()
      try checkPermission()
      guard var record = store.record(withID: item.id) else {
        throw ReminderWriteError.missingReminder
      }
      let revision = record.revision
      record.isCompleted = true
      record.completionDate = now
      let saved = try save(record, expectedRevision: revision)
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
    guard pendingCommitReceipt == nil else { return .failure(pendingCommitError) }
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
      record.completionDate = nil
      return .success(try save(record, expectedRevision: revision).item)
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

  private func checkNoPendingCommit() throws {
    guard pendingCommitReceipt == nil else { throw pendingCommitError }
  }

  private var pendingCommitError: ReminderWriteError {
    .eventKit(
      "The previous reminder commit is still being confirmed. Reload reminders before trying again."
    )
  }

  private func listIsWritable(_ id: String) -> Bool {
    store.reminderLists().contains { $0.id == id && $0.isWritable }
  }

  private func save(
    _ edited: ReminderWriteRecord, expectedRevision: ReminderWriteRecord.Revision
  ) throws -> ReminderWriteRecord {
    guard let current = store.record(withID: edited.id) else {
      throw ReminderWriteError.missingReminder
    }
    let baseline = try editableFields(from: current)
    let requested = try editableFields(from: edited)
    return try committedRecord(
      from: store.save(
        reminderID: edited.id,
        patch: ReminderPatch(from: baseline, to: requested),
        expectedRevision: expectedRevision))
  }

  private func editableFields(from record: ReminderWriteRecord) throws
    -> ReminderEditableFields
  {
    try ReminderEditableFields(
      validating: record.title, notes: record.notes, url: record.url,
      listID: record.listID,
      startDate: try record.startDateComponents.map(ReminderDateValue.init(validating:)),
      dueDate: try record.dueDateComponents.map(ReminderDateValue.init(validating:)),
      priority: record.priority,
      completion: ReminderCompletionValue(
        validating: record.isCompleted, completionDate: record.completionDate))
  }

  private func committedRecord(from outcome: ReminderWriteOutcome) throws
    -> ReminderWriteRecord
  {
    switch outcome {
    case .saved(let record):
      record
    case .committedWithNormalization(let actual, _):
      actual
    case .commitStatusUnknown(let receipt):
      pendingCommitReceipt = receipt
      throw ReminderWriteError.eventKit(
        "The reminder commit could not be confirmed. Reload reminders before trying again.")
    }
  }

  private func map(_ error: Error) -> ReminderWriteError {
    if let error = error as? ReminderWriteError { return error }
    return .eventKit(error.localizedDescription)
  }
}
