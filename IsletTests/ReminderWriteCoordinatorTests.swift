import XCTest

@testable import Islet

@MainActor
final class ReminderWriteCoordinatorTests: XCTestCase {
  private final class Store: ReminderWriteStore {
    var authorization: EventKitPermissionState = .fullAccess
    var lists = [
      ReminderListItem(id: "inbox", title: "Inbox", colorHex: "#FF0000", isDefault: true),
      ReminderListItem(id: "work", title: "Work", colorHex: "#00FF00", isDefault: false),
    ]
    var records: [String: ReminderWriteRecord] = [:]
    var nextID = 1
    var revision = 1

    func reminderLists() -> [ReminderListItem] { lists }
    func defaultListID() -> String? { lists.first(where: \.isDefault)?.id }
    func record(withID id: String) -> ReminderWriteRecord? { records[id] }

    func create(_ draft: ReminderDraft, inListWithID listID: String) throws
      -> ReminderWriteRecord
    {
      guard let list = lists.first(where: { $0.id == listID }) else {
        throw ReminderWriteError.missingList
      }
      let id = "new-\(nextID)"
      nextID += 1
      let record = ReminderWriteRecord(
        id: id, title: draft.title, notes: nil, priority: draft.priority,
        dueDateComponents: draft.dueDate.map {
          RemindersLogic.dueComponents(for: $0, hasTime: draft.hasDueTime, calendar: testCalendar)
        },
        listID: list.id, listTitle: list.title, listColorHex: list.colorHex,
        isCompleted: false, lastModified: Date(timeIntervalSince1970: TimeInterval(revision)))
      revision += 1
      records[id] = record
      return record
    }

    func save(
      _ record: ReminderWriteRecord, expectedRevision: ReminderWriteRecord.Revision
    ) throws -> ReminderWriteRecord {
      guard let current = records[record.id] else { throw ReminderWriteError.missingReminder }
      guard current.revision == expectedRevision else { throw ReminderWriteError.changedElsewhere }
      guard let list = lists.first(where: { $0.id == record.listID }) else {
        throw ReminderWriteError.missingList
      }
      var saved = record
      saved.listTitle = list.title
      saved.listColorHex = list.colorHex
      saved.lastModified = Date(timeIntervalSince1970: TimeInterval(revision))
      revision += 1
      records[saved.id] = saved
      return saved
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
}

extension Result where Failure == ReminderWriteError {
  fileprivate var failure: ReminderWriteError? {
    guard case .failure(let error) = self else { return nil }
    return error
  }
}
