import XCTest

@testable import Islet

final class RemindersLogicTests: XCTestCase {
  let now = Date(timeIntervalSince1970: 1_000_000)

  func item(
    _ id: String, due: TimeInterval? = nil, hasDueTime: Bool = true, priority: Int = 0
  ) -> ReminderItem {
    ReminderItem(
      id: id, title: id, dueDate: due.map { now.addingTimeInterval($0) },
      hasDueTime: hasDueTime, priority: priority, listColorHex: nil)
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

  func testDateOnlyReminderIsNotOverdueDuringItsDueDay() {
    let start = Calendar.current.startOfDay(for: now)
    let item = ReminderItem(
      id: "all-day", title: "all-day", dueDate: start, hasDueTime: false, priority: 0,
      listColorHex: nil)
    XCTAssertFalse(RemindersLogic.isOverdue(item, now: now))
  }

  func testDueDateUsesDeclaredTimeZone() throws {
    var components = DateComponents()
    components.calendar = Calendar(identifier: .gregorian)
    components.timeZone = try XCTUnwrap(TimeZone(identifier: "Australia/Brisbane"))
    components.year = 2026
    components.month = 8
    components.day = 28
    components.hour = 9
    components.minute = 30
    let resolved = try XCTUnwrap(RemindersLogic.dueDate(from: components))
    XCTAssertEqual(
      components.calendar?.dateComponents(in: components.timeZone!, from: resolved).hour, 9)
  }

  func testDateOnlyComponentsDoNotInventMidnightAsAnExplicitTime() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let components = RemindersLogic.dueComponents(for: now, hasTime: false, calendar: calendar)
    XCTAssertNotNil(components.year)
    XCTAssertNotNil(components.month)
    XCTAssertNotNil(components.day)
    XCTAssertNil(components.hour)
    XCTAssertNil(components.minute)
  }
}
