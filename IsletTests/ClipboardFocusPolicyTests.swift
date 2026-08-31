import XCTest

@testable import Islet

final class ClipboardFocusPolicyTests: XCTestCase {
  private let first = ClipboardItem(kind: .text("first"), date: .distantPast)
  private let middle = ClipboardItem(kind: .text("middle"), date: .distantPast)
  private let last = ClipboardItem(kind: .text("last"), date: .distantPast)

  func testRemovingFirstFocusesTheNextItem() {
    let items = [first, middle, last]

    XCTAssertEqual(
      ClipboardFocusPolicy.replacementItemID(afterRemoving: first.id, from: items), middle.id)
  }

  func testRemovingMiddleFocusesTheNextItem() {
    let items = [first, middle, last]

    XCTAssertEqual(
      ClipboardFocusPolicy.replacementItemID(afterRemoving: middle.id, from: items), last.id)
  }

  func testRemovingLastFocusesThePreviousItem() {
    let items = [first, middle, last]

    XCTAssertEqual(
      ClipboardFocusPolicy.replacementItemID(afterRemoving: last.id, from: items), middle.id)
  }
}
