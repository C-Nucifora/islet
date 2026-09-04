import XCTest

@testable import Islet

final class ReminderCommandPresentationTests: XCTestCase {
  func testSelectedReminderRoutesEveryWriteAction() {
    let item = ReminderItem(
      id: "report", title: "File report", dueDate: Date(timeIntervalSince1970: 1_000),
      priority: 0, listColorHex: nil, listID: "inbox", listTitle: "Inbox")
    let presentation = ReminderCommandPresentation(
      reminders: [item], selectedReminderID: item.id, writableListIDs: ["inbox", "work"],
      hasCompletionUndo: true)

    XCTAssertEqual(presentation.route(for: .create), .create)
    XCTAssertEqual(presentation.route(for: .complete), .complete(item))
    XCTAssertEqual(presentation.route(for: .undo), .undo)
    XCTAssertEqual(presentation.route(for: .edit), .edit(item))
    XCTAssertEqual(
      presentation.route(for: .snooze(.oneHour)),
      .snooze(item, preset: .oneHour))
    XCTAssertEqual(presentation.route(for: .customSnooze), .customSnooze(item))
    XCTAssertEqual(presentation.route(for: .move(toListID: "work")), .move(item, toListID: "work"))
  }

  func testRouteRejectsAnUnselectedReminderAndReadOnlyMoveTarget() {
    let presentation = ReminderCommandPresentation(
      reminders: [], selectedReminderID: nil, writableListIDs: ["inbox"],
      hasCompletionUndo: false)

    XCTAssertNil(presentation.route(for: .complete))
    XCTAssertNil(presentation.route(for: .edit))
    XCTAssertNil(presentation.route(for: .snooze(.tomorrowMorning)))
    XCTAssertNil(presentation.route(for: .customSnooze))
    XCTAssertNil(presentation.route(for: .move(toListID: "read-only")))
    XCTAssertNil(presentation.route(for: .undo))
  }

  func testNoWritableListsRejectEveryWriteRoute() {
    let item = ReminderItem(
      id: "shared", title: "Shared reminder", dueDate: nil, priority: 0, listColorHex: nil,
      listID: "read-only", listTitle: "Shared")
    let presentation = ReminderCommandPresentation(
      reminders: [item], selectedReminderID: item.id, writableListIDs: [],
      hasCompletionUndo: true)

    XCTAssertNil(presentation.route(for: .create))
    XCTAssertNil(presentation.route(for: .complete))
    XCTAssertNil(presentation.route(for: .undo))
    XCTAssertNil(presentation.route(for: .edit))
    XCTAssertNil(presentation.route(for: .snooze(.oneHour)))
    XCTAssertNil(presentation.route(for: .customSnooze))
    XCTAssertNil(presentation.route(for: .move(toListID: "read-only")))
  }

  func testReadOnlySelectionRejectsMutationsWhileCreateRemainsAvailable() {
    let item = ReminderItem(
      id: "shared", title: "Shared reminder", dueDate: nil, priority: 0, listColorHex: nil,
      listID: "read-only", listTitle: "Shared")
    let presentation = ReminderCommandPresentation(
      reminders: [item], selectedReminderID: item.id, writableListIDs: ["inbox"],
      hasCompletionUndo: false)

    XCTAssertEqual(presentation.route(for: .create), .create)
    XCTAssertNil(presentation.route(for: .complete))
    XCTAssertNil(presentation.route(for: .edit))
    XCTAssertNil(presentation.route(for: .snooze(.tomorrowMorning)))
    XCTAssertNil(presentation.route(for: .customSnooze))
    XCTAssertNil(presentation.route(for: .move(toListID: "inbox")))
  }
}
