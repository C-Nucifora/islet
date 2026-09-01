import XCTest

@testable import Islet

final class ReminderDashboardPresentationTests: XCTestCase {
  func testEmptyLoadedDashboardStillOffersCreation() {
    let presentation = ReminderDashboardPresentation.make(
      loadState: .loaded,
      reminderCount: 0,
      hasMoreReminders: false,
      hasCompletionUndo: false)

    XCTAssertEqual(presentation.actions, [.create])
    XCTAssertEqual(
      presentation.content,
      .empty(message: "All clear", showsMore: false))
  }

  func testCompletingTheLastVisibleReminderKeepsUndoAvailable() {
    let presentation = ReminderDashboardPresentation.make(
      loadState: .loaded,
      reminderCount: 0,
      hasMoreReminders: false,
      hasCompletionUndo: true)

    XCTAssertEqual(presentation.actions, [.create, .undo])
    XCTAssertEqual(
      presentation.content,
      .empty(message: "All clear", showsMore: false))
  }

  func testEmptyDashboardWithMoreItemsUsesDueSoonMessageAndHandoff() {
    let presentation = ReminderDashboardPresentation.make(
      loadState: .loaded,
      reminderCount: 0,
      hasMoreReminders: true,
      hasCompletionUndo: false)

    XCTAssertEqual(presentation.actions, [.create])
    XCTAssertEqual(
      presentation.content,
      .empty(message: "No reminders due soon", showsMore: true))
  }

  func testPopulatedDashboardUsesItemsContent() {
    let presentation = ReminderDashboardPresentation.make(
      loadState: .loaded,
      reminderCount: 1,
      hasMoreReminders: false,
      hasCompletionUndo: false)

    XCTAssertEqual(presentation.actions, [.create])
    XCTAssertEqual(presentation.content, .items)
  }

  func testLoadingAndFailureKeepCreationAvailable() {
    let loading = ReminderDashboardPresentation.make(
      loadState: .loading,
      reminderCount: 0,
      hasMoreReminders: false,
      hasCompletionUndo: false)
    let failed = ReminderDashboardPresentation.make(
      loadState: .failed("Could not load reminders"),
      reminderCount: 0,
      hasMoreReminders: false,
      hasCompletionUndo: false)

    XCTAssertEqual(loading.actions, [.create])
    XCTAssertEqual(loading.content, .loading)
    XCTAssertEqual(failed.actions, [.create])
    XCTAssertEqual(failed.content, .failed("Could not load reminders"))
  }
}
