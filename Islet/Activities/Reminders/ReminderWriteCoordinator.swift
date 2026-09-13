import EventKit
import Foundation

struct ReminderCoordinatorDraft: Equatable, Sendable {
  var reminderID: String?
  var title: String
  var notes: String?
  var urlText: String
  var listID: String?
  var startDate: ReminderDateValue?
  var dueDate: ReminderDateValue?
  var priority: Int
  var isCompleted: Bool
  var completionDate: Date?
  var alarms: [ReminderAlarmValue]
  var recurrenceRules: [ReminderRecurrenceValue]
  var baseline: ReminderEditableFields?
  var baselineRecord: ReminderWriteRecord?
  var sourceRevision: ReminderWriteRecord.Revision?
  var normalizationMismatches: [ReminderNormalizationMismatch]
  var pendingCommitReceipt: ReminderCommitReceipt?
  var retryBlockedReason: String?

  var canRetry: Bool {
    retryBlockedReason == nil && pendingCommitReceipt == nil
  }

  init(
    reminderID: String? = nil, title: String, notes: String? = nil,
    urlText: String = "", listID: String? = nil, startDate: ReminderDateValue? = nil,
    dueDate: ReminderDateValue? = nil, priority: Int = 0, isCompleted: Bool = false,
    completionDate: Date? = nil, baseline: ReminderEditableFields? = nil,
    baselineRecord: ReminderWriteRecord? = nil,
    sourceRevision: ReminderWriteRecord.Revision? = nil,
    normalizationMismatches: [ReminderNormalizationMismatch] = [],
    pendingCommitReceipt: ReminderCommitReceipt? = nil,
    retryBlockedReason: String? = nil,
    alarms: [ReminderAlarmValue] = [], recurrenceRules: [ReminderRecurrenceValue] = []
  ) {
    self.reminderID = reminderID
    self.title = title
    self.notes = notes
    self.urlText = urlText
    self.listID = listID
    self.startDate = startDate
    self.dueDate = dueDate
    self.priority = priority
    self.isCompleted = isCompleted
    self.completionDate = completionDate
    self.alarms = alarms
    self.recurrenceRules = recurrenceRules
    self.baseline = baseline
    self.baselineRecord = baselineRecord
    self.sourceRevision = sourceRevision
    self.normalizationMismatches = normalizationMismatches
    self.pendingCommitReceipt = pendingCommitReceipt
    self.retryBlockedReason = retryBlockedReason
  }
}

enum ReminderCoordinatorOutcome: Equatable, Sendable {
  case noChanges(ReminderWriteRecord)
  case saved(ReminderWriteRecord)
  case committedWithNormalization(
    actual: ReminderWriteRecord,
    mismatches: [ReminderNormalizationMismatch])
  case commitStatusUnknown(ReminderCommitReceipt)
}

struct ReminderCoordinatorWrite: Equatable, Sendable {
  let outcome: ReminderCoordinatorOutcome
  let draft: ReminderCoordinatorDraft
}

extension ReminderWriteError {
  static var invalidURL: Self {
    .eventKit("Enter a valid reminder URL.")
  }

  static var commitStatusUnknown: Self {
    .eventKit(
      "The previous reminder commit is still being confirmed. Reload reminders before trying again."
    )
  }

  static func deletionRejected(_ detail: String) -> Self {
    .eventKit(
      "The reminder could not be deleted. Check the reminder account, then try again. \(detail)"
    )
  }

  static var unsafeProviderValues: Self {
    .eventKit(
      "This reminder contains provider values that Islet cannot edit safely. Open it in Reminders to review or change it."
    )
  }

  static var normalizedQuickWrite: Self {
    .eventKit(
      "The reminder provider saved different values. Reload the reminder before trying again."
    )
  }

  static var committedDraftCannotCreate: Self {
    .eventKit(
      "This draft already belongs to a committed reminder. Save it instead of creating it again.")
  }
}

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
    fileprivate let completedFields: ReminderEditableFields
    fileprivate let completedRecord: ReminderWriteRecord
  }

  struct CompletionWrite: Equatable, Sendable {
    let write: ReminderCoordinatorWrite
    let undo: CompletionUndo?
  }

  private let store: any ReminderWriteStore
  private let undoDuration: TimeInterval
  private(set) var completionUndo: CompletionUndo?
  private(set) var pendingCommitReceipt: ReminderCommitReceipt?
  private(set) var pendingDraft: ReminderCoordinatorDraft?

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

  func writeDraft(for item: ReminderItem) -> Result<ReminderCoordinatorDraft, ReminderWriteError> {
    do {
      try checkPermission()
      guard let record = store.record(withID: item.id) else {
        throw ReminderWriteError.missingReminder
      }
      guard listIsWritable(record.listID) else { throw ReminderWriteError.missingList }
      return .success(try coordinatorDraft(from: record))
    } catch {
      return .failure(map(error))
    }
  }

  func createOutcome(
    _ draft: ReminderCoordinatorDraft
  ) -> Result<ReminderCoordinatorWrite, ReminderWriteError> {
    do {
      try checkNoPendingCommit()
      try checkPermission()
      if draft.retryBlockedReason != nil { throw ReminderWriteError.unsafeProviderValues }
      guard draft.reminderID == nil else {
        throw ReminderWriteError.committedDraftCannotCreate
      }
      let listID = try createListID(selectedID: draft.listID)
      let requested = try editableFields(from: draft, listID: listID)
      let outcome = try store.create(requested)
      return .success(
        coordinatorWrite(
          for: outcome, requested: submittedDraft(draft, fields: requested)))
    } catch {
      return .failure(map(error))
    }
  }

  func updateOutcome(
    _ draft: ReminderCoordinatorDraft
  ) -> Result<ReminderCoordinatorWrite, ReminderWriteError> {
    do {
      try checkNoPendingCommit()
      try checkPermission()
      if draft.retryBlockedReason != nil { throw ReminderWriteError.unsafeProviderValues }
      guard let reminderID = draft.reminderID else {
        throw ReminderWriteError.missingReminder
      }
      guard let sourceRevision = draft.sourceRevision, let baseline = draft.baseline else {
        throw ReminderWriteError.changedElsewhere
      }
      guard let listID = draft.listID, listIsWritable(listID) else {
        throw ReminderWriteError.missingList
      }

      let requested = try editableFields(from: draft, listID: listID)
      let patch = ReminderPatch(from: baseline, to: requested)
      if patch.isEmpty {
        guard let baselineRecord = draft.baselineRecord else {
          throw ReminderWriteError.changedElsewhere
        }
        var unchangedDraft = draft
        unchangedDraft.normalizationMismatches = []
        unchangedDraft.pendingCommitReceipt = nil
        return .success(
          ReminderCoordinatorWrite(
            outcome: .noChanges(baselineRecord), draft: unchangedDraft))
      }
      let outcome = try store.save(
        reminderID: reminderID, patch: patch, expectedRevision: sourceRevision)
      return .success(
        coordinatorWrite(
          for: outcome, requested: submittedDraft(draft, fields: requested)))
    } catch {
      return .failure(map(error))
    }
  }

  func delete(_ draft: ReminderCoordinatorDraft) -> Result<String, ReminderWriteError> {
    if pendingCommitReceipt != nil { return .failure(pendingCommitError) }
    guard let reminderID = draft.reminderID else {
      return .failure(.missingReminder)
    }
    guard let sourceRevision = draft.sourceRevision else {
      return .failure(.changedElsewhere)
    }
    return delete(reminderID: reminderID, sourceRevision: sourceRevision)
  }

  func delete(
    reminderID: String, sourceRevision: ReminderWriteRecord.Revision
  ) -> Result<String, ReminderWriteError> {
    do {
      try checkNoPendingCommit()
      try checkPermission()
      do {
        try store.delete(reminderID: reminderID, expectedRevision: sourceRevision)
      } catch let error as ReminderWriteError {
        if case .eventKit(let detail) = error {
          throw ReminderWriteError.deletionRejected(detail)
        }
        throw error
      } catch {
        throw ReminderWriteError.deletionRejected(error.localizedDescription)
      }
      return .success(reminderID)
    } catch {
      return .failure(map(error))
    }
  }

  @discardableResult
  func abandonPendingCommit() -> Bool {
    guard pendingCommitReceipt?.itemIdentifier == nil, pendingDraft?.reminderID == nil else {
      return false
    }
    pendingCommitReceipt = nil
    pendingDraft = nil
    return true
  }

  @discardableResult
  func abandonPendingCommitAfterRemindersHandoff() -> Bool {
    guard pendingCommitReceipt != nil || pendingDraft != nil else { return false }
    pendingCommitReceipt = nil
    pendingDraft = nil
    return true
  }

  func reconcilePendingCommit(
    with authoritativeRecord: ReminderWriteRecord?
  ) -> Result<ReminderCoordinatorDraft?, ReminderWriteError> {
    do {
      try checkPermission()
      guard let receipt = pendingCommitReceipt, let requested = pendingDraft else {
        return .success(nil)
      }
      guard let itemIdentifier = receipt.itemIdentifier ?? requested.reminderID,
        let actual = authoritativeRecord,
        actual.id == itemIdentifier
      else {
        return .success(nil)
      }
      let mismatches = try normalizationMismatches(
        requested: requested, actual: actual)
      let resolved = rebasedDraft(
        requested: requested, actual: actual, mismatches: mismatches)
      pendingCommitReceipt = nil
      pendingDraft = nil
      return .success(resolved)
    } catch {
      return .failure(map(error))
    }
  }

  func draft(for item: ReminderItem) -> Result<ReminderDraft, ReminderWriteError> {
    switch writeDraft(for: item) {
    case .success(let draft):
      let hasDueTime =
        draft.dueDate?.components.hour != nil || draft.dueDate?.components.minute != nil
        || draft.dueDate?.components.second != nil
      return .success(
        ReminderDraft(
          title: draft.title, listID: draft.listID,
          dueDate: RemindersLogic.dueDate(from: draft.dueDate?.components),
          hasDueTime: hasDueTime, priority: draft.priority,
          sourceRevision: draft.sourceRevision))
    case .failure(let error):
      return .failure(error)
    }
  }

  func create(_ draft: ReminderDraft) -> Result<ReminderItem, ReminderWriteError> {
    let dueDate: ReminderDateValue?
    do {
      dueDate = try draft.dueDate.map {
        try ReminderDateValue(
          validating: RemindersLogic.dueComponents(
            for: $0, hasTime: draft.hasDueTime))
      }
    } catch {
      return .failure(map(error))
    }
    let expanded = ReminderCoordinatorDraft(
      title: draft.title, listID: draft.listID, dueDate: dueDate,
      priority: draft.priority)
    switch createOutcome(expanded) {
    case .success(let write):
      guard let record = record(from: write.outcome) else {
        return .failure(.commitStatusUnknown)
      }
      return .success(record.item)
    case .failure(let error):
      return .failure(error)
    }
  }

  func update(_ item: ReminderItem, with draft: ReminderDraft) -> Result<
    ReminderItem, ReminderWriteError
  > {
    switch writeDraft(for: item) {
    case .success(var expanded):
      expanded.title = draft.title
      expanded.listID = draft.listID
      expanded.priority = draft.priority
      expanded.sourceRevision = draft.sourceRevision
      do {
        expanded.dueDate = try draft.dueDate.map {
          try ReminderDateValue(
            validating: RemindersLogic.dueComponents(
              for: $0, hasTime: draft.hasDueTime))
        }
      } catch {
        return .failure(map(error))
      }
      switch updateOutcome(expanded) {
      case .success(let write):
        guard let record = record(from: write.outcome) else {
          return .failure(.commitStatusUnknown)
        }
        return .success(record.item)
      case .failure(let error):
        return .failure(error)
      }
    case .failure(let error):
      return .failure(error)
    }
  }

  func move(_ item: ReminderItem, toListWithID listID: String) -> Result<
    ReminderItem, ReminderWriteError
  > {
    compatibilityQuickResult(moveOutcome(item, toListWithID: listID))
  }

  func moveOutcome(
    _ item: ReminderItem, toListWithID listID: String
  ) -> Result<ReminderCoordinatorWrite, ReminderWriteError> {
    do {
      try checkNoPendingCommit()
      try checkPermission()
      guard listIsWritable(listID) else { throw ReminderWriteError.missingList }
      guard let record = store.record(withID: item.id) else {
        throw ReminderWriteError.missingReminder
      }
      var draft = try coordinatorDraft(from: record)
      draft.listID = listID
      return updateOutcome(draft)
    } catch {
      return .failure(map(error))
    }
  }

  func reschedule(_ item: ReminderItem, to date: Date, hasTime: Bool) -> Result<
    ReminderItem, ReminderWriteError
  > {
    compatibilityQuickResult(rescheduleOutcome(item, to: date, hasTime: hasTime))
  }

  func rescheduleOutcome(
    _ item: ReminderItem, to date: Date, hasTime: Bool
  ) -> Result<ReminderCoordinatorWrite, ReminderWriteError> {
    do {
      try checkNoPendingCommit()
      try checkPermission()
      guard let record = store.record(withID: item.id) else {
        throw ReminderWriteError.missingReminder
      }
      var draft = try coordinatorDraft(from: record)
      if item.dueDate != date || item.hasDueTime != hasTime {
        draft.dueDate = try ReminderDateValue(
          validating: RemindersLogic.dueComponents(for: date, hasTime: hasTime))
      }
      return updateOutcome(draft)
    } catch {
      return .failure(map(error))
    }
  }

  func complete(_ item: ReminderItem, now: Date = Date()) -> Result<
    CompletionUndo, ReminderWriteError
  > {
    switch completeOutcome(item, now: now) {
    case .success(let completion):
      guard completion.write.draft.retryBlockedReason == nil else {
        return .failure(.unsafeProviderValues)
      }
      if let undo = completion.undo { return .success(undo) }
      switch completion.write.outcome {
      case .commitStatusUnknown:
        return .failure(.commitStatusUnknown)
      case .committedWithNormalization:
        return .failure(
          .eventKit(
            "The reminder provider saved a different completion value. Reload the reminder before trying again."
          ))
      case .noChanges, .saved:
        return .failure(.missingCompletionDate)
      }
    case .failure(let error):
      return .failure(error)
    }
  }

  func completeOutcome(_ item: ReminderItem, now: Date = Date()) -> Result<
    CompletionWrite, ReminderWriteError
  > {
    do {
      try checkNoPendingCommit()
      try checkPermission()
      guard let record = store.record(withID: item.id) else {
        throw ReminderWriteError.missingReminder
      }
      let revision = record.revision
      let baseline = try editableFields(from: record)
      var requested = baseline
      requested.completion = try ReminderCompletionValue(
        validating: true, completionDate: now)
      var requestedDraft = try coordinatorDraft(from: record)
      requestedDraft.isCompleted = true
      requestedDraft.completionDate = now
      let outcome = try store.save(
        reminderID: record.id, patch: ReminderPatch(from: baseline, to: requested),
        expectedRevision: revision)
      let write = coordinatorWrite(for: outcome, requested: requestedDraft)
      let undo: CompletionUndo?
      switch write.outcome {
      case .saved(let saved)
      where saved.isCompleted && saved.completionDate == now:
        if write.draft.canRetry, let completedFields = try? editableFields(from: saved) {
          undo = CompletionUndo(
            reminderID: saved.id, title: saved.title, completedRevision: saved.revision,
            expiresAt: now.addingTimeInterval(undoDuration),
            completedFields: completedFields, completedRecord: saved)
        } else {
          undo = nil
        }
      case .noChanges, .saved, .committedWithNormalization, .commitStatusUnknown:
        undo = nil
      }
      completionUndo = undo
      return .success(CompletionWrite(write: write, undo: undo))
    } catch {
      return .failure(map(error))
    }
  }

  func undoCompletion(now: Date = Date()) -> Result<ReminderItem, ReminderWriteError> {
    switch undoCompletionOutcome(now: now) {
    case .success(let write):
      guard write.draft.retryBlockedReason == nil else {
        return .failure(.unsafeProviderValues)
      }
      switch write.outcome {
      case .saved(let record):
        return .success(record.item)
      case .commitStatusUnknown:
        return .failure(.commitStatusUnknown)
      case .committedWithNormalization:
        return .failure(
          .eventKit(
            "The reminder provider saved a different completion value. Reload the reminder before trying again."
          ))
      case .noChanges:
        return .failure(.noUndoAvailable)
      }
    case .failure(let error):
      return .failure(error)
    }
  }

  func undoCompletionOutcome(
    now: Date = Date()
  ) -> Result<ReminderCoordinatorWrite, ReminderWriteError> {
    guard pendingCommitReceipt == nil else { return .failure(pendingCommitError) }
    guard let undo = completionUndo else { return .failure(.noUndoAvailable) }
    completionUndo = nil
    guard now < undo.expiresAt else { return .failure(.undoExpired) }
    do {
      try checkPermission()
      var requested = undo.completedFields
      requested.completion = try ReminderCompletionValue(
        validating: false, completionDate: nil)
      let outcome = try store.save(
        reminderID: undo.reminderID,
        patch: ReminderPatch(from: undo.completedFields, to: requested),
        expectedRevision: undo.completedRevision)
      var requestedDraft = try coordinatorDraft(from: undo.completedRecord)
      requestedDraft.isCompleted = false
      requestedDraft.completionDate = nil
      return .success(coordinatorWrite(for: outcome, requested: requestedDraft))
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
    .commitStatusUnknown
  }

  private func listIsWritable(_ id: String) -> Bool {
    store.reminderLists().contains { $0.id == id && $0.isWritable }
  }

  private func compatibilityQuickResult(
    _ result: Result<ReminderCoordinatorWrite, ReminderWriteError>
  ) -> Result<ReminderItem, ReminderWriteError> {
    switch result {
    case .success(let write):
      switch write.outcome {
      case .noChanges(let record), .saved(let record):
        return .success(record.item)
      case .committedWithNormalization:
        return .failure(.normalizedQuickWrite)
      case .commitStatusUnknown:
        return .failure(.commitStatusUnknown)
      }
    case .failure(let error):
      return .failure(error)
    }
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
        validating: record.isCompleted, completionDate: record.completionDate),
      alarms: record.alarmRevisions.compactMap(ReminderAdvancedCodec.alarmValue(from:)),
      recurrenceRules: record.recurrenceRevisions.compactMap(
        ReminderAdvancedCodec.recurrenceValue(from:)))
  }

  private func editableFields(
    from draft: ReminderCoordinatorDraft, listID: String
  ) throws -> ReminderEditableFields {
    let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else { throw ReminderWriteError.emptyTitle }

    let trimmedURL = draft.urlText.trimmingCharacters(in: .whitespacesAndNewlines)
    let url: URL?
    if trimmedURL.isEmpty {
      url = nil
    } else {
      guard let parsed = URL(string: trimmedURL), parsed.scheme?.isEmpty == false else {
        throw ReminderWriteError.invalidURL
      }
      url = parsed
    }

    return try ReminderEditableFields(
      validating: title, notes: draft.notes, url: url, listID: listID,
      startDate: draft.startDate, dueDate: draft.dueDate, priority: draft.priority,
      completion: ReminderCompletionValue(
        validating: draft.isCompleted, completionDate: draft.completionDate),
      alarms: draft.alarms, recurrenceRules: draft.recurrenceRules)
  }

  private func coordinatorDraft(
    from record: ReminderWriteRecord
  ) throws -> ReminderCoordinatorDraft {
    let fields = try editableFields(from: record)
    return ReminderCoordinatorDraft(
      reminderID: record.id, title: fields.title, notes: fields.notes,
      urlText: fields.url?.absoluteString ?? "", listID: fields.listID,
      startDate: fields.startDate, dueDate: fields.dueDate, priority: fields.priority,
      isCompleted: fields.completion.isCompleted,
      completionDate: fields.completion.completionDate, baseline: fields,
      baselineRecord: record, sourceRevision: record.revision,
      alarms: fields.alarms, recurrenceRules: fields.recurrenceRules)
  }

  private func submittedDraft(
    _ draft: ReminderCoordinatorDraft, fields: ReminderEditableFields
  ) -> ReminderCoordinatorDraft {
    var submitted = draft
    submitted.title = fields.title
    submitted.notes = fields.notes
    submitted.urlText = fields.url?.absoluteString ?? ""
    submitted.listID = fields.listID
    submitted.startDate = fields.startDate
    submitted.dueDate = fields.dueDate
    submitted.priority = fields.priority
    submitted.isCompleted = fields.completion.isCompleted
    submitted.completionDate = fields.completion.completionDate
    submitted.alarms = fields.alarms
    submitted.recurrenceRules = fields.recurrenceRules
    return submitted
  }

  private func createListID(selectedID: String?) throws -> String {
    let available = store.reminderLists()
    if let selectedID {
      guard available.contains(where: { $0.id == selectedID && $0.isWritable }) else {
        throw ReminderWriteError.missingList
      }
      return selectedID
    }
    if let systemDefaultID = store.defaultListID(),
      available.contains(where: { $0.id == systemDefaultID && $0.isWritable })
    {
      return systemDefaultID
    }
    guard let fallback = available.first(where: \.isWritable) else {
      throw ReminderWriteError.missingList
    }
    return fallback.id
  }

  private func coordinatorWrite(
    for outcome: ReminderWriteOutcome, requested: ReminderCoordinatorDraft
  ) -> ReminderCoordinatorWrite {
    switch outcome {
    case .saved(let actual):
      return ReminderCoordinatorWrite(
        outcome: .saved(actual),
        draft: knownCommitDraft(
          requested: requested, actual: actual, mismatches: [],
          preserveRequestedFields: false))
    case .committedWithNormalization(let actual, let mismatches):
      return ReminderCoordinatorWrite(
        outcome: .committedWithNormalization(actual: actual, mismatches: mismatches),
        draft: knownCommitDraft(
          requested: requested, actual: actual, mismatches: mismatches,
          preserveRequestedFields: true))
    case .commitStatusUnknown(let receipt):
      var pending = requested
      pending.pendingCommitReceipt = receipt
      pending.normalizationMismatches = []
      pendingCommitReceipt = receipt
      pendingDraft = pending
      return ReminderCoordinatorWrite(
        outcome: .commitStatusUnknown(receipt), draft: pending)
    }
  }

  private func rebasedDraft(
    requested: ReminderCoordinatorDraft, actual: ReminderWriteRecord,
    mismatches: [ReminderNormalizationMismatch]
  ) -> ReminderCoordinatorDraft {
    knownCommitDraft(
      requested: requested, actual: actual, mismatches: mismatches,
      preserveRequestedFields: true)
  }

  private func knownCommitDraft(
    requested: ReminderCoordinatorDraft, actual: ReminderWriteRecord,
    mismatches: [ReminderNormalizationMismatch], preserveRequestedFields: Bool
  ) -> ReminderCoordinatorDraft {
    guard let actualFields = try? editableFields(from: actual) else {
      var blocked = requested
      blocked.reminderID = actual.id
      blocked.baseline = nil
      blocked.baselineRecord = actual
      blocked.sourceRevision = actual.revision
      blocked.normalizationMismatches = mismatches
      blocked.pendingCommitReceipt = nil
      blocked.retryBlockedReason = ReminderWriteError.unsafeProviderValues.errorDescription
      return blocked
    }

    if !preserveRequestedFields {
      return ReminderCoordinatorDraft(
        reminderID: actual.id, title: actualFields.title, notes: actualFields.notes,
        urlText: actualFields.url?.absoluteString ?? "", listID: actualFields.listID,
        startDate: actualFields.startDate, dueDate: actualFields.dueDate,
        priority: actualFields.priority,
        isCompleted: actualFields.completion.isCompleted,
        completionDate: actualFields.completion.completionDate, baseline: actualFields,
        baselineRecord: actual, sourceRevision: actual.revision,
        alarms: actualFields.alarms, recurrenceRules: actualFields.recurrenceRules)
    }

    var rebased = requested
    // A retry owns only the fields changed in the original draft. Other fields may have
    // changed in another client after our save and must adopt the authoritative values.
    if let original = requested.baseline {
      if requested.title == original.title { rebased.title = actualFields.title }
      if requested.notes == original.notes { rebased.notes = actualFields.notes }
      if requested.urlText == (original.url?.absoluteString ?? "") {
        rebased.urlText = actualFields.url?.absoluteString ?? ""
      }
      if requested.listID == original.listID { rebased.listID = actualFields.listID }
      if requested.startDate == original.startDate { rebased.startDate = actualFields.startDate }
      if requested.dueDate == original.dueDate { rebased.dueDate = actualFields.dueDate }
      if requested.priority == original.priority { rebased.priority = actualFields.priority }
      if requested.isCompleted == original.completion.isCompleted,
        requested.completionDate == original.completion.completionDate
      {
        rebased.isCompleted = actualFields.completion.isCompleted
        rebased.completionDate = actualFields.completion.completionDate
      }
      if requested.alarms == original.alarms { rebased.alarms = actualFields.alarms }
      if requested.recurrenceRules == original.recurrenceRules {
        rebased.recurrenceRules = actualFields.recurrenceRules
      }
    }
    rebased.reminderID = actual.id
    rebased.baseline = actualFields
    rebased.baselineRecord = actual
    rebased.sourceRevision = actual.revision
    rebased.normalizationMismatches = mismatches
    rebased.pendingCommitReceipt = nil
    rebased.retryBlockedReason = nil
    return rebased
  }

  private func normalizationMismatches(
    requested draft: ReminderCoordinatorDraft, actual: ReminderWriteRecord
  ) throws -> [ReminderNormalizationMismatch] {
    guard let listID = draft.listID else { throw ReminderWriteError.missingList }
    let requested = try editableFields(from: draft, listID: listID)
    let actualStartDate = decodedDate(actual.startDateComponents)
    let actualDueDate = decodedDate(actual.dueDateComponents)
    let actualCompletion = decodedCompletion(actual)
    let baseline = draft.baseline
    var mismatches: [ReminderNormalizationMismatch] = []

    appendNormalizationMismatch(
      field: .title, wasRequested: baseline == nil || baseline?.title != requested.title,
      matches: actual.title == requested.title, to: &mismatches)
    appendNormalizationMismatch(
      field: .notes, wasRequested: baseline == nil || baseline?.notes != requested.notes,
      matches: actual.notes == requested.notes, to: &mismatches)
    appendNormalizationMismatch(
      field: .url, wasRequested: baseline == nil || baseline?.url != requested.url,
      matches: actual.url == requested.url, to: &mismatches)
    appendNormalizationMismatch(
      field: .list, wasRequested: baseline == nil || baseline?.listID != requested.listID,
      matches: actual.listID == requested.listID, to: &mismatches)
    appendNormalizationMismatch(
      field: .startDate,
      wasRequested: baseline == nil || baseline?.startDate != requested.startDate,
      matches: actualStartDate.isValid
        && ReminderDateValue.semanticallyEqual(
          actualStartDate.value?.components, requested.startDate?.components),
      to: &mismatches)
    appendNormalizationMismatch(
      field: .dueDate,
      wasRequested: baseline == nil || baseline?.dueDate != requested.dueDate,
      matches: actualDueDate.isValid
        && ReminderDateValue.semanticallyEqual(
          actualDueDate.value?.components, requested.dueDate?.components),
      to: &mismatches)
    appendNormalizationMismatch(
      field: .priority,
      wasRequested: baseline == nil || baseline?.priority != requested.priority,
      matches: actual.priority == requested.priority, to: &mismatches)
    appendNormalizationMismatch(
      field: .completion,
      wasRequested: baseline == nil || baseline?.completion != requested.completion,
      matches: actualCompletion.isValid && actualCompletion.value == requested.completion,
      to: &mismatches)
    appendNormalizationMismatch(
      field: .alarms,
      wasRequested: baseline == nil || baseline?.alarms != requested.alarms,
      matches: ReminderAdvancedCodec.sameValues(
        actual.alarmRevisions.compactMap(ReminderAdvancedCodec.alarmValue(from:)), requested.alarms),
      to: &mismatches)
    appendNormalizationMismatch(
      field: .recurrence,
      wasRequested: baseline == nil || baseline?.recurrenceRules != requested.recurrenceRules,
      matches: ReminderAdvancedCodec.sameValues(
        actual.recurrenceRevisions.compactMap(ReminderAdvancedCodec.recurrenceValue(from:)),
        requested.recurrenceRules),
      to: &mismatches)
    if let baseline, let original = draft.baselineRecord {
      appendNormalizationMismatch(
        field: .title,
        wasRequested: baseline.title == requested.title,
        matches: actual.title == original.title, to: &mismatches)
      appendNormalizationMismatch(
        field: .notes,
        wasRequested: baseline.notes == requested.notes,
        matches: actual.notes == original.notes, to: &mismatches)
      appendNormalizationMismatch(
        field: .url,
        wasRequested: baseline.url == requested.url,
        matches: actual.url == original.url, to: &mismatches)
      appendNormalizationMismatch(
        field: .list,
        wasRequested: baseline.listID == requested.listID,
        matches: actual.listID == original.listID, to: &mismatches)
      appendNormalizationMismatch(
        field: .startDate,
        wasRequested: baseline.startDate == requested.startDate,
        matches: ReminderDateValue.semanticallyEqual(
          actual.startDateComponents, original.startDateComponents),
        to: &mismatches)
      appendNormalizationMismatch(
        field: .dueDate,
        wasRequested: baseline.dueDate == requested.dueDate,
        matches: ReminderDateValue.semanticallyEqual(
          actual.dueDateComponents, original.dueDateComponents),
        to: &mismatches)
      appendNormalizationMismatch(
        field: .priority,
        wasRequested: baseline.priority == requested.priority,
        matches: actual.priority == original.priority, to: &mismatches)
      appendNormalizationMismatch(
        field: .completion,
        wasRequested: baseline.completion == requested.completion,
        matches: actual.isCompleted == original.isCompleted
          && actual.completionDate == original.completionDate,
        to: &mismatches)
      let originalAlarms = original.alarmRevisions.filter {
        baseline.alarms == requested.alarms || ReminderAdvancedCodec.alarmValue(from: $0) == nil
      }
      let actualAlarms = actual.alarmRevisions.filter {
        baseline.alarms == requested.alarms || ReminderAdvancedCodec.alarmValue(from: $0) == nil
      }
      if !mismatches.contains(where: { $0.field == .alarms }) {
        appendNormalizationMismatch(
          field: .alarms, wasRequested: true,
          matches: ReminderAdvancedCodec.sameValues(originalAlarms, actualAlarms), to: &mismatches)
      }
      let originalRules = original.recurrenceRevisions.filter {
        baseline.recurrenceRules == requested.recurrenceRules
          || ReminderAdvancedCodec.recurrenceValue(from: $0) == nil
      }
      let actualRules = actual.recurrenceRevisions.filter {
        baseline.recurrenceRules == requested.recurrenceRules
          || ReminderAdvancedCodec.recurrenceValue(from: $0) == nil
      }
      if !mismatches.contains(where: { $0.field == .recurrence }) {
        appendNormalizationMismatch(
          field: .recurrence, wasRequested: true,
          matches: ReminderAdvancedCodec.sameValues(originalRules, actualRules), to: &mismatches)
      }
      appendNormalizationMismatch(
        field: .nativeMetadata, wasRequested: true,
        matches: actual.location == original.location && actual.timeZone == original.timeZone,
        to: &mismatches)
    }
    return mismatches
  }

  private func decodedDate(
    _ components: DateComponents?
  ) -> (value: ReminderDateValue?, isValid: Bool) {
    guard let components else { return (nil, true) }
    do {
      return (try ReminderDateValue(validating: components), true)
    } catch {
      return (nil, false)
    }
  }

  private func decodedCompletion(
    _ record: ReminderWriteRecord
  ) -> (value: ReminderCompletionValue?, isValid: Bool) {
    do {
      return (
        try ReminderCompletionValue(
          validating: record.isCompleted, completionDate: record.completionDate),
        true
      )
    } catch {
      return (nil, false)
    }
  }

  private func appendNormalizationMismatch(
    field: ReminderField, wasRequested: Bool, matches: Bool,
    to mismatches: inout [ReminderNormalizationMismatch]
  ) {
    guard wasRequested, !matches else { return }
    mismatches.append(
      ReminderNormalizationMismatch(
        field: field,
        reason: "The reminder provider saved a different \(field.displayName) value."))
  }

  private func record(from outcome: ReminderCoordinatorOutcome) -> ReminderWriteRecord? {
    switch outcome {
    case .noChanges(let record), .saved(let record),
      .committedWithNormalization(let record, _):
      record
    case .commitStatusUnknown:
      nil
    }
  }

  private func map(_ error: Error) -> ReminderWriteError {
    if let error = error as? ReminderWriteError { return error }
    return .eventKit(error.localizedDescription)
  }
}
