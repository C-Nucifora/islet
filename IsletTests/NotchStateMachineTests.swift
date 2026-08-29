import XCTest

@testable import Islet

final class NotchStateMachineTests: XCTestCase {
  func t(_ s: NotchState, _ e: NotchEvent, _ m: InteractionMode, prevent: Bool = false)
    -> NotchState
  {
    NotchStateMachine.transition(from: s, on: e, mode: m, preventAutoClose: prevent)
  }

  // Both modes
  func testHoverEnterPeeks() {
    XCTAssertEqual(t(.closed, .hoverEntered, .hover), .peek)
    XCTAssertEqual(t(.closed, .hoverEntered, .clickToPin), .peek)
  }

  func testPeekExitCloses() { XCTAssertEqual(t(.peek, .hoverExited, .hover), .closed) }

  func testFileDragHoverExpandsImmediatelyWithoutPushInEitherMode() {
    XCTAssertEqual(t(.closed, .fileDragEntered, .hover), .expanded(pinned: false))
    XCTAssertEqual(t(.peek, .fileDragEntered, .hover), .expanded(pinned: false))
    XCTAssertEqual(t(.closed, .fileDragEntered, .clickToPin), .expanded(pinned: false))
    XCTAssertEqual(t(.peek, .fileDragEntered, .clickToPin), .expanded(pinned: false))
  }

  func testFileDragHoverDoesNotToggleAnExpandedNotchClosed() {
    XCTAssertEqual(
      t(.expanded(pinned: false), .fileDragEntered, .hover), .expanded(pinned: false))
    XCTAssertEqual(
      t(.expanded(pinned: true), .fileDragEntered, .hover), .expanded(pinned: true))
  }

  func testClickNotchPinsFromClosedOrPeek() {
    XCTAssertEqual(t(.peek, .clickedNotch, .clickToPin), .expanded(pinned: true))
    XCTAssertEqual(t(.closed, .clickedNotch, .hover), .expanded(pinned: true))
  }

  func testClickNotchWhileExpandedCloses() {
    XCTAssertEqual(t(.expanded(pinned: true), .clickedNotch, .clickToPin), .closed)
  }

  func testClickOutsideCloses() {
    XCTAssertEqual(t(.expanded(pinned: true), .clickedOutside, .hover), .closed)
    XCTAssertEqual(t(.expanded(pinned: false), .clickedOutside, .hover), .closed)
  }

  func testClickOutsideRespectsPreventAutoClose() {
    XCTAssertEqual(
      t(.expanded(pinned: true), .clickedOutside, .hover, prevent: true),
      .expanded(pinned: true))
  }

  // Hover mode
  func testPushExpandsUnpinnedInHoverMode() {
    XCTAssertEqual(t(.peek, .pushThresholdCrossed, .hover), .expanded(pinned: false))
  }

  func testPushDoesNothingInClickMode() {
    XCTAssertEqual(t(.peek, .pushThresholdCrossed, .clickToPin), .peek)
  }

  func testCollapseTimeoutClosesUnpinnedOnly() {
    XCTAssertEqual(t(.expanded(pinned: false), .collapseTimeoutElapsed, .hover), .closed)
    XCTAssertEqual(
      t(.expanded(pinned: true), .collapseTimeoutElapsed, .hover),
      .expanded(pinned: true))
  }

  func testCollapseTimeoutRespectsPreventAutoClose() {
    XCTAssertEqual(
      t(.expanded(pinned: false), .collapseTimeoutElapsed, .hover, prevent: true),
      .expanded(pinned: false))
  }

  func testClickInsideUpgradesToPinned() {
    XCTAssertEqual(
      t(.expanded(pinned: false), .clickedInsideExpanded, .hover),
      .expanded(pinned: true))
  }
}
