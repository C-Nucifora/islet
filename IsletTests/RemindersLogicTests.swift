import XCTest

@testable import Islet

final class RemindersLogicTests: XCTestCase {
  let now = Date(timeIntervalSince1970: 1_000_000)

  func item(_ id: String, due: TimeInterval? = nil, priority: Int = 0) -> ReminderItem {
    ReminderItem(
      id: id, title: id, dueDate: due.map { now.addingTimeInterval($0) },
      priority: priority, listColorHex: nil)
  }

  func testDatedBeforeUndated() {
    let items = [item("undated"), item("soon", due: 600)]
    XCTAssertEqual(RemindersLogic.display(items).map(\.id), ["soon", "undated"])
  }

  func testSoonestDueFirst() {
    let items = [item("later", due: 7200), item("overdue", due: -3600), item("soon", due: 600)]
    XCTAssertEqual(RemindersLogic.display(items).map(\.id), ["overdue", "soon", "later"])
  }

  func testUndatedSortedByPriority() {
    let items = [item("low", priority: 9), item("none", priority: 0), item("high", priority: 1)]
    XCTAssertEqual(RemindersLogic.display(items).map(\.id), ["high", "low", "none"])
  }

  func testLimitCaps() {
    let items = (0..<12).map { item("r\($0)", due: TimeInterval($0) * 60) }
    XCTAssertEqual(RemindersLogic.display(items, limit: 5).count, 5)
  }

  func testOverdueDetection() {
    XCTAssertTrue(RemindersLogic.isOverdue(item("x", due: -60), now: now))
    XCTAssertFalse(RemindersLogic.isOverdue(item("y", due: 60), now: now))
    XCTAssertFalse(RemindersLogic.isOverdue(item("z"), now: now))
  }
}
