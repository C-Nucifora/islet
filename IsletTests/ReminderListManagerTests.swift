import AppKit
import XCTest

@testable import Islet

final class ReminderListManagerTests: XCTestCase {
  func testListEditRejectsExternalRenameAndMissingList() {
    let baseline = list(title: "Work")
    let edit = ReminderListEdit(
      baseline: baseline, sourceID: "source", title: "Tasks", color: .blue)
    XCTAssertThrowsError(try edit.validate(current: list(title: "Renamed elsewhere"))) { error in
      XCTAssertEqual(error as? ReminderWriteError, .changedElsewhere)
    }
    XCTAssertThrowsError(try edit.validate(current: nil)) { error in
      XCTAssertEqual(error as? ReminderWriteError, .missingList)
    }
  }

  func testImmutableListAndEmptyTitleAreRejected() {
    let baseline = list(title: "Work", immutable: true)
    XCTAssertThrowsError(
      try ReminderListEdit(baseline: baseline, sourceID: "source", title: "Tasks", color: .blue)
        .validate(current: baseline))
    XCTAssertThrowsError(
      try ReminderListEdit(baseline: nil, sourceID: "source", title: "  ", color: .blue).validate(
        current: nil))
  }

  func testListEditAllowsNameAndColorChangesWithoutChangingAccount() throws {
    let baseline = list(title: "Work")
    try ReminderListEdit(baseline: baseline, sourceID: "source", title: "Tasks", color: .red)
      .validate(current: baseline)
    XCTAssertThrowsError(
      try ReminderListEdit(baseline: baseline, sourceID: "another", title: "Tasks", color: .red)
        .validate(current: baseline))
  }

  private func list(title: String, immutable: Bool = false) -> ReminderManagedList {
    ReminderManagedList(
      id: "list", sourceID: "source", sourceTitle: "Account", title: title, colorHex: "#0000FF",
      isImmutable: immutable)
  }
}
