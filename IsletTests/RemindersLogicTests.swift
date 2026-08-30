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

  func testDashboardBoundsLargeStoreAndKeepsEarliestItems() {
    let items = (0..<10_000).reversed().map {
      item("r\($0)", due: TimeInterval($0) * 60)
    }
    let selection = RemindersLogic.dashboardSelection(items, now: now)

    XCTAssertEqual(selection.items.map(\.id), (0..<8).map { "r\($0)" })
    XCTAssertTrue(selection.hasMore)
  }

  func testDashboardIncludesOverdueNearTermAndImportantUndatedItems() {
    let items = [
      item("far-future", due: 31 * 86_400),
      item("undated-low", priority: 9),
      item("near-term", due: 29 * 86_400),
      item("undated-high", priority: 1),
      item("overdue", due: -86_400),
      item("undated-none"),
    ]
    let policy = RemindersLogic.DashboardPolicy(
      horizonDays: 30, displayLimit: 4, reservedUndatedItems: 2)
    let selection = RemindersLogic.dashboardSelection(items, now: now, policy: policy)

    XCTAssertEqual(
      selection.items.map(\.id), ["overdue", "near-term", "undated-high", "undated-low"])
    XCTAssertTrue(selection.hasMore)
  }

  func testDashboardUsesUndatedItemsWhenThereAreNotEnoughDatedItems() {
    let items = [
      item("dated", due: 60), item("undated-none"), item("undated-low", priority: 9),
      item("undated-high", priority: 1),
    ]
    let policy = RemindersLogic.DashboardPolicy(
      horizonDays: 30, displayLimit: 3, reservedUndatedItems: 1)

    XCTAssertEqual(
      RemindersLogic.dashboardSelection(items, now: now, policy: policy).items.map(\.id),
      ["dated", "undated-high", "undated-low"])
  }

  func testDashboardReportsNoMoreWhenEveryItemFits() {
    let selection = RemindersLogic.dashboardSelection(
      [item("overdue", due: -60), item("undated", priority: 1)], now: now)

    XCTAssertFalse(selection.hasMore)
  }

  func testDashboardLeavesFarFutureItemsForMorePath() {
    let selection = RemindersLogic.dashboardSelection(
      [item("later", due: 31 * 86_400)], now: now)

    XCTAssertTrue(selection.items.isEmpty)
    XCTAssertTrue(selection.hasMore)
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

  func testOneHourSnoozeUsesCalendarArithmetic() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Australia/Brisbane"))
    let result = try XCTUnwrap(
      RemindersLogic.snoozeDate(.oneHour, from: now, calendar: calendar))
    XCTAssertEqual(calendar.dateComponents([.minute], from: now, to: result).minute, 60)
  }

  func testTomorrowMorningSnoozeIsNineAMOnNextCalendarDay() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Australia/Brisbane"))
    let result = try XCTUnwrap(
      RemindersLogic.snoozeDate(.tomorrowMorning, from: now, calendar: calendar))
    XCTAssertEqual(
      calendar.startOfDay(for: result),
      calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)))
    let components = calendar.dateComponents([.hour, .minute, .second], from: result)
    XCTAssertEqual(components.hour, 9)
    XCTAssertEqual(components.minute, 0)
    XCTAssertEqual(components.second, 0)
  }
}
