import XCTest

@testable import Islet

final class ReminderDashboardReconciliationTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_000_000)

  private func item(_ id: String, daysFromNow: Int) -> ReminderItem {
    ReminderItem(
      id: id, title: id, dueDate: now.addingTimeInterval(TimeInterval(daysFromNow) * 86_400),
      priority: 0, listColorHex: nil)
  }

  func testFarFutureCreateStaysOutOfDashboardAndMarksMore() {
    let reconciliation = ReminderDashboardReconciliation.make(
      visibleReminders: [], hasMoreReminders: false,
      mutation: .insert(item("future", daysFromNow: 31)), now: now)

    XCTAssertEqual(reconciliation.reminders, [])
    XCTAssertTrue(reconciliation.hasMoreReminders)
    XCTAssertFalse(reconciliation.requiresReload)
  }

  func testEditPastHorizonRemovesVisibleReminderAndReloadsHiddenItems() {
    let original = item("report", daysFromNow: 1)
    let edited = item("report", daysFromNow: 31)

    let reconciliation = ReminderDashboardReconciliation.make(
      visibleReminders: [original], hasMoreReminders: true,
      mutation: .replace(originalID: original.id, with: edited), now: now)

    XCTAssertEqual(reconciliation.reminders, [])
    XCTAssertTrue(reconciliation.hasMoreReminders)
    XCTAssertTrue(reconciliation.requiresReload)
  }

  func testNewEarlierReminderDisplacesLatestItemAtDisplayLimit() {
    let visible = (1...8).map { item("r\($0)", daysFromNow: $0) }

    let reconciliation = ReminderDashboardReconciliation.make(
      visibleReminders: visible, hasMoreReminders: false,
      mutation: .insert(item("new", daysFromNow: 0)), now: now)

    XCTAssertEqual(
      reconciliation.reminders.map(\.id), ["new", "r1", "r2", "r3", "r4", "r5", "r6", "r7"])
    XCTAssertTrue(reconciliation.hasMoreReminders)
    XCTAssertFalse(reconciliation.requiresReload)
  }

  func testPriorHasMoreReloadsAfterReplacementEvenWhenVisibleCountStaysConstant() {
    let original = item("report", daysFromNow: 1)
    let renamed = ReminderItem(
      id: original.id, title: "Renamed report", dueDate: original.dueDate,
      priority: original.priority, listColorHex: original.listColorHex)

    let reconciliation = ReminderDashboardReconciliation.make(
      visibleReminders: [original], hasMoreReminders: true,
      mutation: .replace(originalID: original.id, with: renamed), now: now)

    XCTAssertEqual(reconciliation.reminders, [renamed])
    XCTAssertTrue(reconciliation.hasMoreReminders)
    XCTAssertTrue(reconciliation.requiresReload)
  }

  func testRankLoweringReplacementReloadsHiddenCandidateAtDisplayLimit() {
    let visible = (1...8).map { item("r\($0)", daysFromNow: $0) }
    let lowered = item("r1", daysFromNow: 10)

    let reconciliation = ReminderDashboardReconciliation.make(
      visibleReminders: visible, hasMoreReminders: true,
      mutation: .replace(originalID: "r1", with: lowered), now: now)

    XCTAssertEqual(
      reconciliation.reminders.map(\.id), ["r2", "r3", "r4", "r5", "r6", "r7", "r8", "r1"])
    XCTAssertTrue(reconciliation.hasMoreReminders)
    XCTAssertTrue(reconciliation.requiresReload)
  }
}
