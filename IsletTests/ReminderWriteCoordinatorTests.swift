import XCTest

@testable import Islet

@MainActor
final class ReminderWriteCoordinatorTests: XCTestCase {
  private final class Store: ReminderWriteStore {
    var authorization: EventKitPermissionState = .fullAccess
    var lists = [
      ReminderListItem(
        id: "inbox", title: "Inbox", colorHex: "#FF0000", isDefault: true,
        isWritable: true),
      ReminderListItem(
        id: "work", title: "Work", colorHex: "#00FF00", isDefault: false,
        isWritable: true),
    ]
    var records: [String: ReminderWriteRecord] = [:]
    var nextID = 1
    var revision = 1
    var createCount = 0
    var saveCount = 0
    var deleteCount = 0
    var lastCreatedFields: ReminderEditableFields?
    var lastSavedID: String?
    var lastPatch: ReminderPatch?
    var lastExpectedRevision: ReminderWriteRecord.Revision?
    var lastDeletedID: String?
    var createOutcome: ReminderWriteOutcome?
    var saveOutcome: ReminderWriteOutcome?
    var deleteError: Error?
    var defaultListOverride: String?
    var recordLookupIDs: [String] = []

    func reminderLists() -> [ReminderListItem] { lists }
    func defaultListID() -> String? {
      defaultListOverride ?? lists.first(where: \.isDefault)?.id
    }
    func record(withID id: String) -> ReminderWriteRecord? {
      recordLookupIDs.append(id)
      return records[id]
    }

    func create(_ fields: ReminderEditableFields) throws -> ReminderWriteOutcome {
      createCount += 1
      lastCreatedFields = fields
      if let createOutcome { return createOutcome }
      guard let list = lists.first(where: { $0.id == fields.listID && $0.isWritable }) else {
        throw ReminderWriteError.missingList
      }
      let id = "new-\(nextID)"
      nextID += 1
      let record = ReminderWriteRecord(
        id: id, title: fields.title, notes: fields.notes, priority: fields.priority,
        dueDateComponents: fields.dueDate?.components,
        listID: list.id, listTitle: list.title, listColorHex: list.colorHex,
        isCompleted: fields.completion.isCompleted,
        lastModified: Date(timeIntervalSince1970: TimeInterval(revision)), url: fields.url,
        startDateComponents: fields.startDate?.components,
        completionDate: fields.completion.completionDate)
      revision += 1
      records[id] = record
      return .saved(record)
    }

    func save(
      reminderID: String, patch: ReminderPatch,
      expectedRevision: ReminderWriteRecord.Revision
    ) throws -> ReminderWriteOutcome {
      saveCount += 1
      lastSavedID = reminderID
      lastPatch = patch
      lastExpectedRevision = expectedRevision
      guard let current = records[reminderID] else { throw ReminderWriteError.missingReminder }
      guard current.revision == expectedRevision else { throw ReminderWriteError.changedElsewhere }
      if let saveOutcome {
        if let actual = saveOutcome.record { records[actual.id] = actual }
        return saveOutcome
      }

      let requestedListID: String
      switch patch.listID {
      case .unchanged:
        requestedListID = current.listID
      case .value(let listID):
        requestedListID = listID
      }
      guard let list = lists.first(where: { $0.id == requestedListID && $0.isWritable }) else {
        throw ReminderWriteError.missingList
      }

      var saved = current
      if case .value(let title) = patch.title { saved.title = title }
      if case .value(let notes) = patch.notes { saved.notes = notes }
      if case .value(let url) = patch.url { saved.url = url }
      if case .value(let listID) = patch.listID { saved.listID = listID }
      if case .value(let startDate) = patch.startDate {
        saved.startDateComponents = startDate?.components
      }
      if case .value(let dueDate) = patch.dueDate {
        saved.dueDateComponents = dueDate?.components
      }
      if case .value(let priority) = patch.priority { saved.priority = priority }
      if case .value(let completion) = patch.completion {
        saved.isCompleted = completion.isCompleted
        saved.completionDate = completion.completionDate
      }
      saved.listTitle = list.title
      saved.listColorHex = list.colorHex
      saved.lastModified = Date(timeIntervalSince1970: TimeInterval(revision))
      revision += 1
      records[saved.id] = saved
      return .saved(saved)
    }

    func delete(
      reminderID: String, expectedRevision: ReminderWriteRecord.Revision
    ) throws {
      deleteCount += 1
      lastDeletedID = reminderID
      lastExpectedRevision = expectedRevision
      if let deleteError { throw deleteError }
      guard let current = records[reminderID] else { throw ReminderWriteError.missingReminder }
      guard current.revision == expectedRevision else { throw ReminderWriteError.changedElsewhere }
      records.removeValue(forKey: reminderID)
    }

    func addExisting() -> ReminderItem {
      var due = DateComponents()
      due.calendar = testCalendar
      due.timeZone = testCalendar.timeZone
      due.year = 2026
      due.month = 9
      due.day = 4
      let record = ReminderWriteRecord(
        id: "existing", title: "File report", notes: "Attach receipts", priority: 1,
        dueDateComponents: due, listID: "inbox", listTitle: "Inbox", listColorHex: "#FF0000",
        isCompleted: false, lastModified: Date(timeIntervalSince1970: 1))
      records[record.id] = record
      return record.item
    }

    func changeExternally(_ id: String) {
      records[id]?.notes = "Changed elsewhere"
      records[id]?.lastModified = Date(timeIntervalSince1970: 9_999)
    }

    func record(
      id: String, title: String, notes: String?, url: URL?, listID: String,
      lastModified: TimeInterval, priority: Int = 1
    ) -> ReminderWriteRecord {
      let list = lists.first(where: { $0.id == listID })!
      return ReminderWriteRecord(
        id: id, title: title, notes: notes, priority: priority,
        dueDateComponents: nil, listID: listID, listTitle: list.title,
        listColorHex: list.colorHex, isCompleted: false,
        lastModified: Date(timeIntervalSince1970: lastModified), url: url)
    }

    private var testCalendar: Calendar {
      var calendar = Calendar(identifier: .gregorian)
      calendar.timeZone = TimeZone(secondsFromGMT: 0)!
      return calendar
    }
  }

  func testCreationPreservesDateOnlyDueValue() throws {
    let store = Store()
    let coordinator = ReminderWriteCoordinator(store: store)
    let due = Date(timeIntervalSince1970: 1_788_480_000)

    let result = coordinator.create(
      ReminderDraft(
        title: "Pay invoice", listID: "inbox", dueDate: due, hasDueTime: false, priority: 5))
    let item = try result.get()
    let saved = try XCTUnwrap(store.records[item.id])

    XCTAssertEqual(item.title, "Pay invoice")
    XCTAssertFalse(item.hasDueTime)
    XCTAssertNil(saved.dueDateComponents?.hour)
    XCTAssertNil(saved.dueDateComponents?.minute)
    XCTAssertEqual(saved.priority, 5)
  }

  func testDeletedSelectedListRejectsCreationWithoutFallback() {
    let store = Store()
    let coordinator = ReminderWriteCoordinator(store: store)
    store.lists.removeAll { $0.id == "work" }

    let result = coordinator.create(
      ReminderDraft(
        title: "Plan launch", listID: "work", dueDate: nil, hasDueTime: false, priority: 0))

    XCTAssertEqual(result.failure, .missingList)
    XCTAssertTrue(store.records.isEmpty)
  }

  func testEditorDraftRejectsSubmitAfterExternalMutation() throws {
    let store = Store()
    let item = store.addExisting()
    let coordinator = ReminderWriteCoordinator(store: store)
    var draft = try coordinator.draft(for: item).get()
    draft.title = "Updated report"
    store.changeExternally(item.id)

    let result = coordinator.update(item, with: draft)

    XCTAssertEqual(result.failure, .changedElsewhere)
    let current = try XCTUnwrap(store.records[item.id])
    XCTAssertEqual(current.title, "File report")
    XCTAssertEqual(current.notes, "Changed elsewhere")
  }

  func testEditorDraftUpdatesItsCapturedRevisionAndPreservesUneditedNotes() throws {
    let store = Store()
    let item = store.addExisting()
    let coordinator = ReminderWriteCoordinator(store: store)
    var draft = try coordinator.draft(for: item).get()
    draft.title = "Updated report"

    let updated = try coordinator.update(item, with: draft).get()

    XCTAssertEqual(updated.title, "Updated report")
    XCTAssertEqual(try XCTUnwrap(store.records[item.id]).notes, "Attach receipts")
  }

  func testReadOnlyListsAreHiddenAndRejectedAsWriteTargets() throws {
    let store = Store()
    store.lists.append(
      ReminderListItem(
        id: "shared", title: "Shared", colorHex: nil, isDefault: false,
        isWritable: false))
    let item = store.addExisting()
    let coordinator = ReminderWriteCoordinator(store: store)

    XCTAssertEqual(coordinator.lists().map(\.id), ["inbox", "work"])
    XCTAssertEqual(
      coordinator.create(
        ReminderDraft(
          title: "Cannot add", listID: "shared", dueDate: nil, hasDueTime: false,
          priority: 0)
      ).failure,
      .missingList)
    XCTAssertEqual(coordinator.move(item, toListWithID: "shared").failure, .missingList)

    var draft = try coordinator.draft(for: item).get()
    draft.listID = "shared"
    XCTAssertEqual(coordinator.update(item, with: draft).failure, .missingList)
  }

  func testCustomSnoozeWritesChosenDateAndTime() throws {
    let store = Store()
    let item = store.addExisting()
    let coordinator = ReminderWriteCoordinator(store: store)
    let customDate = Date(timeIntervalSince1970: 1_788_523_800)

    let updated = try coordinator.reschedule(item, to: customDate, hasTime: true).get()
    let saved = try XCTUnwrap(store.records[item.id])

    XCTAssertEqual(updated.dueDate, customDate)
    XCTAssertNotNil(saved.dueDateComponents?.hour)
    XCTAssertNotNil(saved.dueDateComponents?.minute)
  }

  func testMoveKeepsContentPriorityAndDate() throws {
    let store = Store()
    let item = store.addExisting()
    let original = try XCTUnwrap(store.records[item.id])
    let coordinator = ReminderWriteCoordinator(store: store)

    _ = try coordinator.move(item, toListWithID: "work").get()
    let moved = try XCTUnwrap(store.records[item.id])

    XCTAssertEqual(moved.listID, "work")
    XCTAssertEqual(moved.title, original.title)
    XCTAssertEqual(moved.notes, original.notes)
    XCTAssertEqual(moved.priority, original.priority)
    XCTAssertEqual(moved.dueDateComponents, original.dueDateComponents)
  }

  func testUndoExpiresAndDoesNotRewriteReminder() throws {
    let store = Store()
    let item = store.addExisting()
    let coordinator = ReminderWriteCoordinator(store: store, undoDuration: 8)
    let now = Date(timeIntervalSince1970: 100)
    _ = try coordinator.complete(item, now: now).get()

    let result = coordinator.undoCompletion(now: now.addingTimeInterval(8))

    XCTAssertEqual(result.failure, .undoExpired)
    XCTAssertTrue(try XCTUnwrap(store.records[item.id]).isCompleted)
  }

  func testUndoRestoresSameReminderOnce() throws {
    let store = Store()
    let item = store.addExisting()
    let coordinator = ReminderWriteCoordinator(store: store)
    let now = Date(timeIntervalSince1970: 100)
    _ = try coordinator.complete(item, now: now).get()

    let restored = try coordinator.undoCompletion(now: now.addingTimeInterval(1)).get()

    XCTAssertEqual(restored.id, item.id)
    XCTAssertFalse(try XCTUnwrap(store.records[item.id]).isCompleted)
    XCTAssertEqual(
      coordinator.undoCompletion(now: now.addingTimeInterval(2)).failure, .noUndoAvailable)
  }

  func testUndoFailsSafelyAfterExternalChange() throws {
    let store = Store()
    let item = store.addExisting()
    let coordinator = ReminderWriteCoordinator(store: store)
    let now = Date(timeIntervalSince1970: 100)
    _ = try coordinator.complete(item, now: now).get()
    store.changeExternally(item.id)

    let result = coordinator.undoCompletion(now: now.addingTimeInterval(1))

    XCTAssertEqual(result.failure, .changedElsewhere)
    XCTAssertTrue(try XCTUnwrap(store.records[item.id]).isCompleted)
    XCTAssertEqual(try XCTUnwrap(store.records[item.id]).notes, "Changed elsewhere")
    XCTAssertEqual(store.recordLookupIDs, [item.id])
  }

  func testPermissionLossRetainsOriginalRecord() throws {
    let store = Store()
    let item = store.addExisting()
    let before = store.records
    let coordinator = ReminderWriteCoordinator(store: store)
    store.authorization = .denied

    let result = coordinator.move(item, toListWithID: "work")

    XCTAssertEqual(result.failure, .permissionDenied)
    XCTAssertEqual(store.records, before)
  }

  func testCreateRoundTripsNotesURLStartDueAndCompletion() throws {
    let store = Store()
    let coordinator = ReminderWriteCoordinator(store: store)
    let start = try dateValue(day: 2, hour: 9)
    let due = try dateValue(day: 3, hour: 17)
    let completedAt = Date(timeIntervalSince1970: 1_788_400_000)
    let draft = ReminderCoordinatorDraft(
      title: "Ship release", notes: "Confirm checks",
      urlText: "https://example.com/release", listID: "work", startDate: start,
      dueDate: due, priority: 9, isCompleted: true, completionDate: completedAt)

    let write = try coordinator.createOutcome(draft).get()
    let fields = try XCTUnwrap(store.lastCreatedFields)

    XCTAssertEqual(write.outcome.record?.id, "new-1")
    XCTAssertEqual(fields.title, "Ship release")
    XCTAssertEqual(fields.notes, "Confirm checks")
    XCTAssertEqual(fields.url, URL(string: "https://example.com/release"))
    XCTAssertEqual(fields.startDate, start)
    XCTAssertEqual(fields.dueDate, due)
    XCTAssertEqual(fields.priority, 9)
    XCTAssertEqual(fields.completion.isCompleted, true)
    XCTAssertEqual(fields.completion.completionDate, completedAt)
  }

  func testUpdateBuildsAnExplicitClearForNotesAndURL() throws {
    let store = Store()
    let item = store.addExisting()
    store.records[item.id]?.url = URL(string: "https://example.com/original")
    let coordinator = ReminderWriteCoordinator(store: store)
    var draft = try coordinator.writeDraft(for: item).get()
    draft.notes = nil
    draft.urlText = ""

    _ = try coordinator.updateOutcome(draft).get()

    XCTAssertEqual(store.lastPatch?.notes, .value(nil))
    XCTAssertEqual(store.lastPatch?.url, .value(nil))
    XCTAssertEqual(store.recordLookupIDs, [item.id])
  }

  func testTitleOnlyUpdateKeepsCanonicalDateComponentsUnchanged() throws {
    let store = Store()
    let item = store.addExisting()
    var floatingStart = DateComponents()
    floatingStart.calendar = Calendar(identifier: .gregorian)
    floatingStart.year = 2026
    floatingStart.month = 11
    floatingStart.day = 1
    var explicitDue = DateComponents()
    explicitDue.calendar = Calendar(identifier: .gregorian)
    explicitDue.timeZone = TimeZone(identifier: "America/Los_Angeles")
    explicitDue.year = 2026
    explicitDue.month = 11
    explicitDue.day = 1
    explicitDue.hour = 9
    explicitDue.minute = 45
    store.records[item.id]?.startDateComponents = floatingStart
    store.records[item.id]?.dueDateComponents = explicitDue
    let coordinator = ReminderWriteCoordinator(store: store)
    var draft = try coordinator.writeDraft(for: item).get()
    draft.title = "Title only"

    _ = try coordinator.updateOutcome(draft).get()

    XCTAssertEqual(store.lastPatch?.startDate, .unchanged)
    XCTAssertEqual(store.lastPatch?.dueDate, .unchanged)
    XCTAssertNil(draft.startDate?.components.timeZone)
    XCTAssertEqual(
      draft.dueDate?.components.timeZone, TimeZone(identifier: "America/Los_Angeles"))
  }

  func testUpdateDoesNotPatchUnchangedFields() throws {
    let store = Store()
    let item = store.addExisting()
    let coordinator = ReminderWriteCoordinator(store: store)
    let draft = try coordinator.writeDraft(for: item).get()

    let write = try coordinator.updateOutcome(draft).get()

    XCTAssertEqual(store.saveCount, 0)
    XCTAssertEqual(write.outcome.record?.id, item.id)
    XCTAssertNil(coordinator.pendingCommitReceipt)
  }

  func testNoOpHasExplicitOutcomeAndCompatibilityReturnsCapturedItem() throws {
    let store = Store()
    let record = store.record(
      id: "plain", title: "No changes", notes: nil, url: nil,
      listID: "inbox", lastModified: 20)
    store.records[record.id] = record
    let coordinator = ReminderWriteCoordinator(store: store)
    let item = record.item
    let expanded = try coordinator.writeDraft(for: item).get()

    let write = try coordinator.updateOutcome(expanded).get()

    XCTAssertEqual(write.outcome, .noChanges(record))
    XCTAssertEqual(store.saveCount, 0)
    XCTAssertNil(coordinator.pendingCommitReceipt)

    let compatibility = try coordinator.draft(for: item).get()
    XCTAssertEqual(try coordinator.update(item, with: compatibility).get(), item)
    XCTAssertEqual(store.saveCount, 0)
  }

  func testOnlyNativePublicPriorityCategoriesAreAccepted() throws {
    for priority in [0, 1, 5, 9] {
      let store = Store()
      let coordinator = ReminderWriteCoordinator(store: store)
      _ = try coordinator.createOutcome(
        ReminderCoordinatorDraft(
          title: "Priority \(priority)", listID: "inbox", priority: priority)
      ).get()
      XCTAssertEqual(store.lastCreatedFields?.priority, priority)
    }

    let store = Store()
    let coordinator = ReminderWriteCoordinator(store: store)
    XCTAssertEqual(
      coordinator.createOutcome(
        ReminderCoordinatorDraft(title: "Invalid", listID: "inbox", priority: 2)
      ).failure,
      .invalidPriority)
  }

  func testUpdateRejectsEveryExternalCoreFieldMutation() throws {
    let mutations: [(inout ReminderWriteRecord) -> Void] = [
      { $0.title = "External title" },
      { $0.notes = "External notes" },
      { $0.url = URL(string: "https://example.com/external") },
      { $0.listID = "work" },
      { $0.startDateComponents = self.components(day: 1, hour: 8) },
      { $0.dueDateComponents = self.components(day: 8, hour: 12) },
      { $0.priority = 9 },
      {
        $0.isCompleted = true
        $0.completionDate = Date(timeIntervalSince1970: 500)
      },
      { $0.location = "External location" },
      { $0.timeZone = TimeZone(identifier: "Pacific/Auckland") },
      {
        $0.alarmRevisions = [
          ReminderAlarmRevision(
            typeRawValue: 0, absoluteDate: Date(timeIntervalSince1970: 800),
            relativeOffset: 0, locationTitle: nil, latitude: nil, longitude: nil,
            radius: nil, proximityRawValue: nil, emailAddress: nil, soundName: nil,
            url: nil)
        ]
      },
      {
        $0.recurrenceRevisions = [
          ReminderRecurrenceRevision(
            calendarIdentifierRawValue: "gregorian", calendarIdentifier: .gregorian,
            frequencyRawValue: 0, interval: 1, firstDayOfTheWeek: 1,
            daysOfTheWeek: [], daysOfTheMonth: [], monthsOfTheYear: [],
            weeksOfTheYear: [], daysOfTheYear: [], setPositions: [], endDate: nil,
            occurrenceCount: nil)
        ]
      },
      { $0.lastModified = Date(timeIntervalSince1970: 9_999) },
    ]

    for mutate in mutations {
      let store = Store()
      let item = store.addExisting()
      let coordinator = ReminderWriteCoordinator(store: store)
      var draft = try coordinator.writeDraft(for: item).get()
      draft.title = "Requested title"
      mutate(&store.records[item.id]!)

      XCTAssertEqual(coordinator.updateOutcome(draft).failure, .changedElsewhere)
      XCTAssertEqual(store.saveCount, 1)
      XCTAssertEqual(store.recordLookupIDs, [item.id])
    }
  }

  func testCompletionWritesCompletionDateAndUndoClearsIt() throws {
    let store = Store()
    let item = store.addExisting()
    let coordinator = ReminderWriteCoordinator(store: store)
    let now = Date(timeIntervalSince1970: 700)
    let originalRevision = try XCTUnwrap(store.records[item.id]).revision

    let undo = try coordinator.complete(item, now: now).get()

    XCTAssertEqual(
      store.lastPatch?.completion,
      .value(try ReminderCompletionValue(validating: true, completionDate: now)))
    XCTAssertEqual(store.lastExpectedRevision, originalRevision)
    XCTAssertEqual(store.recordLookupIDs, [item.id])

    _ = try coordinator.undoCompletion(now: now.addingTimeInterval(1)).get()

    XCTAssertEqual(
      store.lastPatch?.completion,
      .value(try ReminderCompletionValue(validating: false, completionDate: nil)))
    XCTAssertEqual(store.lastExpectedRevision, undo.completedRevision)
    XCTAssertEqual(store.recordLookupIDs, [item.id])
  }

  func testNormalizedAndUnknownCompletionDoNotCreateUndo() throws {
    let normalizedStore = Store()
    let normalizedItem = normalizedStore.addExisting()
    let normalizedCoordinator = ReminderWriteCoordinator(store: normalizedStore)
    let normalizedActual = try XCTUnwrap(normalizedStore.records[normalizedItem.id])
    normalizedStore.saveOutcome = .committedWithNormalization(
      actual: normalizedActual,
      mismatches: [
        ReminderNormalizationMismatch(field: .completion, reason: "Completion rejected")
      ])

    let normalized = try normalizedCoordinator.completeOutcome(
      normalizedItem, now: Date(timeIntervalSince1970: 900)
    ).get()

    XCTAssertNil(normalized.undo)
    XCTAssertNil(normalizedCoordinator.completionUndo)
    guard case .committedWithNormalization = normalized.write.outcome else {
      return XCTFail("Expected normalized completion")
    }

    let unknownStore = Store()
    let unknownItem = unknownStore.addExisting()
    let unknownCoordinator = ReminderWriteCoordinator(store: unknownStore)
    let receipt = ReminderCommitReceipt(
      itemIdentifier: unknownItem.id, externalIdentifier: "completion-external")
    unknownStore.saveOutcome = .commitStatusUnknown(receipt)

    let unknown = try unknownCoordinator.completeOutcome(
      unknownItem, now: Date(timeIntervalSince1970: 901)
    ).get()

    XCTAssertNil(unknown.undo)
    XCTAssertEqual(unknownCoordinator.pendingCommitReceipt, receipt)
    XCTAssertEqual(unknown.write.draft.pendingCommitReceipt, receipt)
    XCTAssertNil(unknownCoordinator.completionUndo)
  }

  func testNormalizedAndUnknownUndoDoNotReturnOrdinarySuccess() throws {
    let normalizedStore = Store()
    let normalizedItem = normalizedStore.addExisting()
    let normalizedCoordinator = ReminderWriteCoordinator(store: normalizedStore)
    let now = Date(timeIntervalSince1970: 950)
    _ = try normalizedCoordinator.complete(normalizedItem, now: now).get()
    let stillCompleted = try XCTUnwrap(normalizedStore.records[normalizedItem.id])
    normalizedStore.saveOutcome = .committedWithNormalization(
      actual: stillCompleted,
      mismatches: [
        ReminderNormalizationMismatch(field: .completion, reason: "Undo rejected")
      ])

    let normalized = try normalizedCoordinator.undoCompletionOutcome(
      now: now.addingTimeInterval(1)
    ).get()

    guard case .committedWithNormalization = normalized.outcome else {
      return XCTFail("Expected normalized undo")
    }
    XCTAssertNil(normalizedCoordinator.completionUndo)

    let unknownStore = Store()
    let unknownItem = unknownStore.addExisting()
    let unknownCoordinator = ReminderWriteCoordinator(store: unknownStore)
    _ = try unknownCoordinator.complete(unknownItem, now: now).get()
    let receipt = ReminderCommitReceipt(
      itemIdentifier: unknownItem.id, externalIdentifier: "undo-external")
    unknownStore.saveOutcome = .commitStatusUnknown(receipt)

    let unknown = try unknownCoordinator.undoCompletionOutcome(
      now: now.addingTimeInterval(1)
    ).get()

    XCTAssertEqual(unknown.outcome, .commitStatusUnknown(receipt))
    XCTAssertEqual(unknownCoordinator.pendingCommitReceipt, receipt)
    XCTAssertEqual(unknown.draft.pendingCommitReceipt, receipt)
  }

  func testDeleteRemovesTheExactUnchangedReminder() throws {
    let store = Store()
    let item = store.addExisting()
    let coordinator = ReminderWriteCoordinator(store: store)
    let draft = try coordinator.writeDraft(for: item).get()
    let expectedRevision = try XCTUnwrap(draft.sourceRevision)

    let deletedID = try coordinator.delete(draft).get()

    XCTAssertEqual(deletedID, item.id)
    XCTAssertEqual(store.lastDeletedID, item.id)
    XCTAssertEqual(store.lastExpectedRevision, expectedRevision)
    XCTAssertNil(store.records[item.id])
    XCTAssertEqual(store.recordLookupIDs, [item.id])
  }

  func testDeleteRejectsAnExternallyChangedReminder() throws {
    let store = Store()
    let item = store.addExisting()
    let coordinator = ReminderWriteCoordinator(store: store)
    let draft = try coordinator.writeDraft(for: item).get()
    store.changeExternally(item.id)

    let result = coordinator.delete(draft)

    XCTAssertEqual(result.failure, .changedElsewhere)
    XCTAssertNotNil(store.records[item.id])
    XCTAssertEqual(store.recordLookupIDs, [item.id])
  }

  func testMissingSelectedListNeverFallsBack() {
    let store = Store()
    let coordinator = ReminderWriteCoordinator(store: store)
    let draft = ReminderCoordinatorDraft(title: "No fallback", listID: "missing")

    XCTAssertEqual(coordinator.createOutcome(draft).failure, .missingList)
    XCTAssertEqual(store.createCount, 0)

    var readOnlyDraft = draft
    readOnlyDraft.listID = "work"
    store.lists[1] = ReminderListItem(
      id: "work", title: "Work", colorHex: "#00FF00", isDefault: false,
      isWritable: false)
    XCTAssertEqual(coordinator.createOutcome(readOnlyDraft).failure, .missingList)
    XCTAssertEqual(store.createCount, 0)
  }

  func testMissingOrReadOnlySystemDefaultUsesFirstWritableList() throws {
    for unavailableDefaultID in ["missing", "blocked"] {
      let store = Store()
      store.lists = [
        ReminderListItem(
          id: "blocked", title: "Blocked", colorHex: nil, isDefault: true,
          isWritable: false),
        ReminderListItem(
          id: "z-list", title: "Z list", colorHex: nil, isDefault: false,
          isWritable: true),
        ReminderListItem(
          id: "a-list", title: "A list", colorHex: nil, isDefault: false,
          isWritable: true),
      ]
      store.defaultListOverride = unavailableDefaultID
      let coordinator = ReminderWriteCoordinator(store: store)

      _ = try coordinator.createOutcome(ReminderCoordinatorDraft(title: "Fallback")).get()

      XCTAssertEqual(store.lastCreatedFields?.listID, "z-list")
    }
  }

  func testNilSelectionUsesWritableSystemDefault() throws {
    let store = Store()
    store.lists = [store.lists[1], store.lists[0]]
    store.defaultListOverride = "inbox"
    let coordinator = ReminderWriteCoordinator(store: store)

    _ = try coordinator.createOutcome(
      ReminderCoordinatorDraft(title: "Use default")
    ).get()

    XCTAssertEqual(store.lastCreatedFields?.listID, "inbox")
  }

  func testNormalizedCreateRebasesOntoCommittedIdentifierAndRevision() throws {
    let store = Store()
    let actual = store.record(
      id: "committed", title: "Provider title", notes: nil, url: nil,
      listID: "inbox", lastModified: 80)
    store.records[actual.id] = actual
    store.createOutcome = .committedWithNormalization(
      actual: actual,
      mismatches: [ReminderNormalizationMismatch(field: .title, reason: "Normalized")])
    let coordinator = ReminderWriteCoordinator(store: store)
    let requested = ReminderCoordinatorDraft(
      title: "Requested title", notes: "Requested notes", listID: "inbox")

    var normalized = try coordinator.createOutcome(requested).get().draft

    XCTAssertEqual(normalized.reminderID, actual.id)
    XCTAssertEqual(normalized.title, "Requested title")
    XCTAssertEqual(normalized.notes, "Requested notes")
    XCTAssertEqual(normalized.baseline?.title, "Provider title")
    XCTAssertEqual(normalized.sourceRevision, actual.revision)
    XCTAssertEqual(normalized.normalizationMismatches.map(\.field), [.title])

    normalized.notes = "Second attempt"
    _ = try coordinator.updateOutcome(normalized).get()
    XCTAssertEqual(store.lastSavedID, actual.id)
    XCTAssertEqual(store.lastExpectedRevision, actual.revision)
    XCTAssertEqual(store.createCount, 1)
  }

  func testNormalizedUpdateKeepsRequestedFieldsAndRebasesBaseline() throws {
    let store = Store()
    let item = store.addExisting()
    let coordinator = ReminderWriteCoordinator(store: store)
    var draft = try coordinator.writeDraft(for: item).get()
    draft.title = "Requested title"
    draft.notes = "Requested notes"
    let actual = store.record(
      id: item.id, title: "Provider title", notes: "Provider notes", url: nil,
      listID: "inbox", lastModified: 90)
    store.saveOutcome = .committedWithNormalization(
      actual: actual,
      mismatches: [
        ReminderNormalizationMismatch(field: .title, reason: "Title normalized"),
        ReminderNormalizationMismatch(field: .notes, reason: "Notes normalized"),
      ])

    var normalized = try coordinator.updateOutcome(draft).get().draft

    XCTAssertEqual(normalized.title, "Requested title")
    XCTAssertEqual(normalized.notes, "Requested notes")
    XCTAssertEqual(normalized.baseline?.title, "Provider title")
    XCTAssertEqual(normalized.baseline?.notes, "Provider notes")
    XCTAssertEqual(normalized.sourceRevision, actual.revision)
    XCTAssertEqual(normalized.normalizationMismatches.map(\.field), [.title, .notes])

    store.saveOutcome = nil
    normalized.notes = "Second requested notes"
    _ = try coordinator.updateOutcome(normalized).get()
    XCTAssertEqual(store.lastSavedID, actual.id)
    XCTAssertEqual(store.lastExpectedRevision, actual.revision)
  }

  func testUnknownCreateCommitRemainsPendingAndCannotRetryCreate() throws {
    let store = Store()
    let receipt = ReminderCommitReceipt(
      itemIdentifier: "maybe-created", externalIdentifier: "external")
    store.createOutcome = .commitStatusUnknown(receipt)
    let coordinator = ReminderWriteCoordinator(store: store)
    let draft = ReminderCoordinatorDraft(title: "Unknown", listID: "inbox")

    let pending = try coordinator.createOutcome(draft).get()

    XCTAssertEqual(pending.outcome, .commitStatusUnknown(receipt))
    XCTAssertEqual(pending.draft.pendingCommitReceipt, receipt)
    XCTAssertEqual(coordinator.pendingCommitReceipt, receipt)
    XCTAssertEqual(coordinator.createOutcome(draft).failure, .commitStatusUnknown)
    XCTAssertEqual(coordinator.delete(pending.draft).failure, .commitStatusUnknown)
    XCTAssertEqual(store.createCount, 1)
    XCTAssertFalse(coordinator.abandonPendingCommit())

    let actual = store.record(
      id: "maybe-created", title: "Provider title", notes: nil, url: nil,
      listID: "inbox", lastModified: 120, priority: 0)
    store.records[actual.id] = actual
    let reconciled = try XCTUnwrap(
      try coordinator.reconcilePendingCommit(with: actual).get())
    XCTAssertEqual(reconciled.reminderID, actual.id)
    XCTAssertEqual(reconciled.title, "Unknown")
    XCTAssertEqual(reconciled.baseline?.title, "Provider title")
    XCTAssertEqual(reconciled.sourceRevision, actual.revision)
    XCTAssertEqual(reconciled.normalizationMismatches.map(\.field), [.title])
    XCTAssertNil(coordinator.pendingCommitReceipt)
    store.createOutcome = nil
    _ = try coordinator.createOutcome(draft).get()
    XCTAssertEqual(store.createCount, 2)
  }

  func testPendingReconciliationPollsOnlyExactIdentifierAndCanAbandonNilIdentifier() throws {
    let store = Store()
    let coordinator = ReminderWriteCoordinator(store: store)
    let requested = ReminderCoordinatorDraft(
      title: "Same title", notes: "Requested", listID: "inbox")
    store.createOutcome = .commitStatusUnknown(
      ReminderCommitReceipt(itemIdentifier: "exact-id", externalIdentifier: "shared-external"))
    _ = try coordinator.createOutcome(requested).get()
    store.records["different-id"] = store.record(
      id: "different-id", title: "Same title", notes: "Requested", url: nil,
      listID: "inbox", lastModified: 130)

    XCTAssertNil(try coordinator.reconcilePendingCommit(with: nil).get())
    XCTAssertNil(
      try coordinator.reconcilePendingCommit(
        with: try XCTUnwrap(store.records["different-id"])
      ).get())
    XCTAssertTrue(store.recordLookupIDs.isEmpty)
    XCTAssertEqual(coordinator.pendingCommitReceipt?.itemIdentifier, "exact-id")
    XCTAssertFalse(coordinator.abandonPendingCommit())

    let nilIDStore = Store()
    let nilIDCoordinator = ReminderWriteCoordinator(store: nilIDStore)
    nilIDStore.createOutcome = .commitStatusUnknown(
      ReminderCommitReceipt(itemIdentifier: nil, externalIdentifier: "external-only"))
    _ = try nilIDCoordinator.createOutcome(requested).get()

    XCTAssertNil(try nilIDCoordinator.reconcilePendingCommit(with: nil).get())
    XCTAssertTrue(nilIDStore.recordLookupIDs.isEmpty)
    XCTAssertTrue(nilIDCoordinator.abandonPendingCommit())
    XCTAssertNil(nilIDCoordinator.pendingCommitReceipt)

    let updateStore = Store()
    let updateItem = updateStore.addExisting()
    let updateCoordinator = ReminderWriteCoordinator(store: updateStore)
    var updateDraft = try updateCoordinator.writeDraft(for: updateItem).get()
    updateDraft.title = "Requested update"
    updateStore.saveOutcome = .commitStatusUnknown(
      ReminderCommitReceipt(itemIdentifier: nil, externalIdentifier: nil))
    _ = try updateCoordinator.updateOutcome(updateDraft).get()

    XCTAssertFalse(updateCoordinator.abandonPendingCommit())
    XCTAssertNil(
      try updateCoordinator.reconcilePendingCommit(
        with: try XCTUnwrap(updateStore.records[updateItem.id])
      ).get())
    var committed = try XCTUnwrap(updateStore.records[updateItem.id])
    committed.title = "Requested update"
    committed.lastModified = Date(timeIntervalSince1970: 140)
    updateStore.records[updateItem.id] = committed
    XCTAssertNotNil(try updateCoordinator.reconcilePendingCommit(with: committed).get())
    XCTAssertEqual(updateStore.recordLookupIDs, [updateItem.id])
  }

  func testInvalidCoreValuesAndRejectedDeletionHaveActionableErrors() throws {
    let store = Store()
    let coordinator = ReminderWriteCoordinator(store: store)
    XCTAssertEqual(
      coordinator.createOutcome(
        ReminderCoordinatorDraft(title: "Bad URL", urlText: "not a URL", listID: "inbox")
      ).failure,
      .invalidURL)
    XCTAssertEqual(
      coordinator.createOutcome(
        ReminderCoordinatorDraft(
          title: "No completion date", listID: "inbox", isCompleted: true)
      ).failure,
      .missingCompletionDate)

    let item = store.addExisting()
    let draft = try coordinator.writeDraft(for: item).get()
    store.deleteError = NSError(
      domain: "EventKit", code: 17,
      userInfo: [NSLocalizedDescriptionKey: "Account rejected removal"])

    XCTAssertEqual(
      coordinator.delete(draft).failure,
      .deletionRejected("Account rejected removal"))
  }

  func testSameRevisionAuthoritativeRecordResolvesPendingAndReportsNormalization() throws {
    let store = Store()
    let item = store.addExisting()
    let coordinator = ReminderWriteCoordinator(store: store)
    var requested = try coordinator.writeDraft(for: item).get()
    requested.title = "Requested title"
    store.saveOutcome = .commitStatusUnknown(
      ReminderCommitReceipt(itemIdentifier: item.id, externalIdentifier: nil))
    _ = try coordinator.updateOutcome(requested).get()
    let unchangedActual = try XCTUnwrap(store.records[item.id])

    let resolved = try XCTUnwrap(
      try coordinator.reconcilePendingCommit(with: unchangedActual).get())

    XCTAssertEqual(resolved.reminderID, item.id)
    XCTAssertEqual(resolved.sourceRevision, unchangedActual.revision)
    XCTAssertEqual(resolved.title, "Requested title")
    XCTAssertEqual(resolved.baseline?.title, "File report")
    XCTAssertEqual(resolved.normalizationMismatches.map(\.field), [.title])
    XCTAssertNil(coordinator.pendingCommitReceipt)
  }

  func testKnownNormalizedCreateWithUnsupportedActualValuesIsNonRetryable() throws {
    let invalidActuals: [(ReminderWriteRecord, ReminderField)] = [
      (
        Store().record(
          id: "priority-actual", title: "Requested", notes: nil, url: nil,
          listID: "inbox", lastModified: 201, priority: 2),
        .priority
      ),
      (
        {
          let store = Store()
          var record = store.record(
            id: "date-actual", title: "Requested", notes: nil, url: nil,
            listID: "inbox", lastModified: 202, priority: 0)
          var invalid = DateComponents()
          invalid.calendar = Calendar(identifier: .gregorian)
          invalid.year = 2026
          invalid.month = 2
          invalid.day = 31
          record.dueDateComponents = invalid
          return record
        }(),
        .dueDate
      ),
      (
        {
          let store = Store()
          var record = store.record(
            id: "completion-actual", title: "Requested", notes: nil, url: nil,
            listID: "inbox", lastModified: 203, priority: 0)
          record.isCompleted = true
          record.completionDate = nil
          return record
        }(),
        .completion
      ),
    ]

    for (actual, field) in invalidActuals {
      let store = Store()
      store.createOutcome = .committedWithNormalization(
        actual: actual,
        mismatches: [
          ReminderNormalizationMismatch(field: field, reason: "Provider value")
        ])
      let coordinator = ReminderWriteCoordinator(store: store)
      let requested = ReminderCoordinatorDraft(
        title: "Requested", listID: "inbox", priority: 0)

      let write = try coordinator.createOutcome(requested).get()

      XCTAssertEqual(write.draft.reminderID, actual.id)
      XCTAssertEqual(write.draft.sourceRevision, actual.revision)
      XCTAssertNil(write.draft.baseline)
      XCTAssertNotNil(write.draft.retryBlockedReason)
      XCTAssertFalse(write.draft.canRetry)
      XCTAssertEqual(write.draft.normalizationMismatches.map(\.field), [field])
      XCTAssertNil(write.draft.pendingCommitReceipt)
      XCTAssertNil(coordinator.pendingCommitReceipt)
      XCTAssertEqual(coordinator.updateOutcome(write.draft).failure, .unsafeProviderValues)
      XCTAssertEqual(coordinator.createOutcome(write.draft).failure, .unsafeProviderValues)
      XCTAssertEqual(store.createCount, 1)
      XCTAssertEqual(store.saveCount, 0)
    }
  }

  func testKnownSavedUnsupportedActualPreservesKnownOutcomeAndIdentifier() throws {
    let store = Store()
    let actual = store.record(
      id: "saved-invalid", title: "Requested", notes: nil, url: nil,
      listID: "inbox", lastModified: 210, priority: 2)
    store.createOutcome = .saved(actual)
    let coordinator = ReminderWriteCoordinator(store: store)

    let write = try coordinator.createOutcome(
      ReminderCoordinatorDraft(title: "Requested", listID: "inbox")
    ).get()

    XCTAssertEqual(write.outcome, .saved(actual))
    XCTAssertEqual(write.draft.reminderID, actual.id)
    XCTAssertEqual(write.draft.sourceRevision, actual.revision)
    XCTAssertFalse(write.draft.canRetry)
    XCTAssertNotNil(write.draft.retryBlockedReason)
    XCTAssertNil(coordinator.pendingCommitReceipt)
    XCTAssertEqual(store.createCount, 1)
  }

  func testCompatibilityCompletionAndUndoBlockAfterKnownUnsafeActual() throws {
    let completionStore = Store()
    let completionItem = completionStore.addExisting()
    let completionCoordinator = ReminderWriteCoordinator(store: completionStore)
    let now = Date(timeIntervalSince1970: 240)
    var unsafeCompleted = try XCTUnwrap(completionStore.records[completionItem.id])
    unsafeCompleted.priority = 2
    unsafeCompleted.isCompleted = true
    unsafeCompleted.completionDate = now
    unsafeCompleted.lastModified = Date(timeIntervalSince1970: 241)
    completionStore.saveOutcome = .saved(unsafeCompleted)

    XCTAssertEqual(
      completionCoordinator.complete(completionItem, now: now).failure,
      .unsafeProviderValues)
    XCTAssertNil(completionCoordinator.pendingCommitReceipt)

    let undoStore = Store()
    let undoItem = undoStore.addExisting()
    let undoCoordinator = ReminderWriteCoordinator(store: undoStore)
    _ = try undoCoordinator.complete(undoItem, now: now).get()
    var unsafeUndone = try XCTUnwrap(undoStore.records[undoItem.id])
    unsafeUndone.priority = 2
    unsafeUndone.isCompleted = false
    unsafeUndone.completionDate = nil
    unsafeUndone.lastModified = Date(timeIntervalSince1970: 242)
    undoStore.saveOutcome = .saved(unsafeUndone)

    XCTAssertEqual(
      undoCoordinator.undoCompletion(now: now.addingTimeInterval(1)).failure,
      .unsafeProviderValues)
    XCTAssertNil(undoCoordinator.pendingCommitReceipt)
  }

  func testConfirmedRemindersHandoffCanClearKnownIdentifierPendingState() throws {
    let store = Store()
    let receipt = ReminderCommitReceipt(
      itemIdentifier: "never-appears", externalIdentifier: "external")
    store.createOutcome = .commitStatusUnknown(receipt)
    let coordinator = ReminderWriteCoordinator(store: store)
    let draft = ReminderCoordinatorDraft(title: "Unknown", listID: "inbox")
    _ = try coordinator.createOutcome(draft).get()

    XCTAssertFalse(coordinator.abandonPendingCommit())
    XCTAssertTrue(coordinator.abandonPendingCommitAfterRemindersHandoff())
    XCTAssertNil(coordinator.pendingCommitReceipt)
    XCTAssertNil(coordinator.pendingDraft)

    store.createOutcome = nil
    _ = try coordinator.createOutcome(draft).get()
    XCTAssertEqual(store.createCount, 2)
  }

  func testNormalizedMoveAndReschedulePreserveOutcomeDraftAndMismatches() throws {
    let moveStore = Store()
    let moveItem = moveStore.addExisting()
    var movedActual = try XCTUnwrap(moveStore.records[moveItem.id])
    movedActual.lastModified = Date(timeIntervalSince1970: 220)
    moveStore.saveOutcome = .committedWithNormalization(
      actual: movedActual,
      mismatches: [ReminderNormalizationMismatch(field: .list, reason: "Move rejected")])
    let moveCoordinator = ReminderWriteCoordinator(store: moveStore)

    let move = try moveCoordinator.moveOutcome(moveItem, toListWithID: "work").get()

    XCTAssertEqual(move.draft.listID, "work")
    XCTAssertEqual(move.draft.baseline?.listID, "inbox")
    XCTAssertEqual(move.draft.normalizationMismatches.map(\.field), [.list])

    let compatibilityMoveStore = Store()
    let compatibilityMoveItem = compatibilityMoveStore.addExisting()
    var compatibilityMovedActual = try XCTUnwrap(
      compatibilityMoveStore.records[compatibilityMoveItem.id])
    compatibilityMovedActual.lastModified = Date(timeIntervalSince1970: 221)
    compatibilityMoveStore.saveOutcome = .committedWithNormalization(
      actual: compatibilityMovedActual,
      mismatches: [ReminderNormalizationMismatch(field: .list, reason: "Move rejected")])
    let compatibilityMoveCoordinator = ReminderWriteCoordinator(
      store: compatibilityMoveStore)
    XCTAssertEqual(
      compatibilityMoveCoordinator.move(
        compatibilityMoveItem, toListWithID: "work"
      ).failure,
      .normalizedQuickWrite)

    let rescheduleStore = Store()
    let rescheduleItem = rescheduleStore.addExisting()
    let requestedDate = Date(timeIntervalSince1970: 1_788_523_800)
    var rescheduledActual = try XCTUnwrap(rescheduleStore.records[rescheduleItem.id])
    rescheduledActual.lastModified = Date(timeIntervalSince1970: 222)
    rescheduleStore.saveOutcome = .committedWithNormalization(
      actual: rescheduledActual,
      mismatches: [
        ReminderNormalizationMismatch(field: .dueDate, reason: "Date rejected")
      ])
    let rescheduleCoordinator = ReminderWriteCoordinator(store: rescheduleStore)

    let reschedule = try rescheduleCoordinator.rescheduleOutcome(
      rescheduleItem, to: requestedDate, hasTime: true
    ).get()
    let requestedDateValue = try ReminderDateValue(
      validating: RemindersLogic.dueComponents(for: requestedDate, hasTime: true))
    let actualDateValue = try rescheduledActual.dueDateComponents.map(
      ReminderDateValue.init(validating:))

    XCTAssertEqual(reschedule.draft.dueDate, requestedDateValue)
    XCTAssertEqual(reschedule.draft.baseline?.dueDate, actualDateValue)
    XCTAssertEqual(reschedule.draft.normalizationMismatches.map(\.field), [.dueDate])

    let compatibilityRescheduleStore = Store()
    let compatibilityRescheduleItem = compatibilityRescheduleStore.addExisting()
    var compatibilityRescheduledActual = try XCTUnwrap(
      compatibilityRescheduleStore.records[compatibilityRescheduleItem.id])
    compatibilityRescheduledActual.lastModified = Date(timeIntervalSince1970: 223)
    compatibilityRescheduleStore.saveOutcome = .committedWithNormalization(
      actual: compatibilityRescheduledActual,
      mismatches: [
        ReminderNormalizationMismatch(field: .dueDate, reason: "Date rejected")
      ])
    let compatibilityRescheduleCoordinator = ReminderWriteCoordinator(
      store: compatibilityRescheduleStore)
    XCTAssertEqual(
      compatibilityRescheduleCoordinator.reschedule(
        compatibilityRescheduleItem, to: requestedDate, hasTime: true
      ).failure,
      .normalizedQuickWrite)
  }

  func testNoOpMoveAndRescheduleDoNotCallStoreSave() throws {
    let moveStore = Store()
    let moveItem = moveStore.addExisting()
    let moveCoordinator = ReminderWriteCoordinator(store: moveStore)

    let move = try moveCoordinator.moveOutcome(moveItem, toListWithID: "inbox").get()

    guard case .noChanges = move.outcome else { return XCTFail("Expected no changes") }
    XCTAssertEqual(moveStore.saveCount, 0)
    XCTAssertNil(moveCoordinator.pendingCommitReceipt)
    XCTAssertEqual(
      try moveCoordinator.move(moveItem, toListWithID: "inbox").get(), moveItem)
    XCTAssertEqual(moveStore.saveCount, 0)

    let rescheduleStore = Store()
    let rescheduleItem = rescheduleStore.addExisting()
    let date = try XCTUnwrap(rescheduleItem.dueDate)
    let rescheduleCoordinator = ReminderWriteCoordinator(store: rescheduleStore)
    let canonicalDueDate = try rescheduleCoordinator.writeDraft(for: rescheduleItem).get().dueDate

    let reschedule = try rescheduleCoordinator.rescheduleOutcome(
      rescheduleItem, to: date, hasTime: rescheduleItem.hasDueTime
    ).get()

    guard case .noChanges = reschedule.outcome else {
      return XCTFail("Expected no changes")
    }
    XCTAssertEqual(reschedule.draft.dueDate, canonicalDueDate)
    XCTAssertEqual(rescheduleStore.saveCount, 0)
    XCTAssertNil(rescheduleCoordinator.pendingCommitReceipt)
    XCTAssertEqual(
      try rescheduleCoordinator.reschedule(
        rescheduleItem, to: date, hasTime: rescheduleItem.hasDueTime
      ).get(),
      rescheduleItem)
    XCTAssertEqual(rescheduleStore.saveCount, 0)
  }

  func testNoOpRescheduleUsesSuppliedPresentationAcrossDefaultTimeZoneChange() throws {
    let originalTimeZone = NSTimeZone.default
    defer { NSTimeZone.default = originalTimeZone }
    NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: "Pacific/Honolulu"))

    let store = Store()
    _ = store.addExisting()
    var record = try XCTUnwrap(store.records["existing"])
    var floatingDueDate = DateComponents()
    floatingDueDate.year = 2026
    floatingDueDate.month = 9
    floatingDueDate.day = 4
    floatingDueDate.hour = 9
    floatingDueDate.minute = 30
    record.dueDateComponents = floatingDueDate
    store.records[record.id] = record
    let displayedItem = record.item
    let displayedDate = try XCTUnwrap(displayedItem.dueDate)

    NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: "Pacific/Kiritimati"))
    let coordinator = ReminderWriteCoordinator(store: store)
    let canonicalDueDate = try XCTUnwrap(coordinator.writeDraft(for: displayedItem).get().dueDate)

    let write = try coordinator.rescheduleOutcome(
      displayedItem, to: displayedDate, hasTime: displayedItem.hasDueTime
    ).get()

    guard case .noChanges = write.outcome else {
      return XCTFail("Expected no changes")
    }
    XCTAssertEqual(write.draft.dueDate, canonicalDueDate)
    XCTAssertEqual(write.draft.dueDate?.components.timeZone, nil)
    XCTAssertEqual(write.draft.dueDate?.components.day, 4)
    XCTAssertEqual(write.draft.dueDate?.components.hour, 9)
    XCTAssertEqual(store.saveCount, 0)
  }

  private func dateValue(day: Int, hour: Int? = nil) throws -> ReminderDateValue {
    try ReminderDateValue(validating: components(day: day, hour: hour))
  }

  private func components(day: Int, hour: Int? = nil) -> DateComponents {
    var value = DateComponents()
    value.calendar = Calendar(identifier: .gregorian)
    value.timeZone = TimeZone(secondsFromGMT: 0)
    value.year = 2026
    value.month = 9
    value.day = day
    value.hour = hour
    value.minute = hour == nil ? nil : 30
    return value
  }
}

extension ReminderCoordinatorOutcome {
  fileprivate var record: ReminderWriteRecord? {
    switch self {
    case .noChanges(let record), .saved(let record),
      .committedWithNormalization(let record, _):
      record
    case .commitStatusUnknown:
      nil
    }
  }
}

extension ReminderWriteOutcome {
  fileprivate var record: ReminderWriteRecord? {
    switch self {
    case .saved(let record), .committedWithNormalization(let record, _):
      record
    case .commitStatusUnknown:
      nil
    }
  }
}

extension Result where Failure == ReminderWriteError {
  fileprivate var failure: ReminderWriteError? {
    guard case .failure(let error) = self else { return nil }
    return error
  }
}
