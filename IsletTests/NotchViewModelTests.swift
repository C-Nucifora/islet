import XCTest

@testable import Islet

@MainActor
final class NotchViewModelTests: XCTestCase {
  func makeVM(mode: InteractionMode = .hover) -> NotchViewModel {
    let g = NotchGeometry(
      screenFrame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
      safeAreaTop: 32, auxLeftWidth: 716, auxRightWidth: 716,
      menuBarHeight: 37)
    return NotchViewModel(geometry: g, modeOverride: mode)
  }

  func testMouseIntoHitRectPeeks() {
    let vm = makeVM()
    vm.handleMouseMoved(CGPoint(x: 864, y: 1110))  // inside notch
    XCTAssertEqual(vm.state, .peek)
  }

  func testMouseOutOfHitRectClosesFromPeek() {
    let vm = makeVM()
    vm.handleMouseMoved(CGPoint(x: 864, y: 1110))
    vm.handleMouseMoved(CGPoint(x: 100, y: 500))
    XCTAssertEqual(vm.state, .closed)
  }

  func testClickOnNotchPins() {
    let vm = makeVM(mode: .clickToPin)
    vm.handleMouseDown(CGPoint(x: 864, y: 1110))
    XCTAssertEqual(vm.state, .expanded(pinned: true))
  }

  func testClickOutsideExpandedCloses() {
    let vm = makeVM(mode: .clickToPin)
    vm.handleMouseDown(CGPoint(x: 864, y: 1110))
    vm.handleMouseDown(CGPoint(x: 100, y: 500))
    XCTAssertEqual(vm.state, .closed)
  }

  // MARK: - Panel frame
  //
  // The panel swallows every mouse event inside its frame, so any moment it is larger than the
  // island is menu bar the user can't click. These pin down grow-now/shrink-later.

  func testPanelFrameStartsHuggingTheNotch() {
    let vm = makeVM()
    XCTAssertEqual(vm.panelFrame, vm.geometry.collapsedPanelFrame())
    XCTAssertLessThan(
      vm.panelFrame.width, vm.geometry.panelFrame(height: Metrics.expandedSize.height).width)
  }

  func testPanelFrameGrowsBeforeTheIslandExpands() {
    let vm = makeVM(mode: .clickToPin)
    vm.handleMouseDown(CGPoint(x: 864, y: 1110))
    XCTAssertEqual(vm.state, .expanded(pinned: true))
    // grown synchronously, not deferred
    XCTAssertEqual(vm.panelFrame, vm.geometry.panelFrame(height: Metrics.expandedSize.height))
  }

  func testPanelFrameStaysGrownUntilTheClosingAnimationEnds() {
    let vm = makeVM(mode: .clickToPin)
    vm.handleMouseDown(CGPoint(x: 864, y: 1110))
    vm.handleMouseDown(CGPoint(x: 100, y: 500))
    XCTAssertEqual(vm.state, .closed)
    // Still expanded-sized: shrinking here would clip the island mid-collapse.
    XCTAssertEqual(vm.panelFrame, vm.geometry.panelFrame(height: Metrics.expandedSize.height))
  }

  func testPanelFrameShrinksAfterCollapsing() async throws {
    let vm = makeVM(mode: .clickToPin)
    vm.handleMouseDown(CGPoint(x: 864, y: 1110))
    vm.handleMouseDown(CGPoint(x: 100, y: 500))
    try await Task.sleep(for: Motion.panelShrinkDelay + .milliseconds(200))
    XCTAssertEqual(vm.panelFrame, vm.geometry.collapsedPanelFrame())
  }

  func testRepeatedTransitionsDoNotDeferTheShrink() async throws {
    let vm = makeVM(mode: .clickToPin)
    vm.handleMouseDown(CGPoint(x: 864, y: 1110))
    vm.handleMouseDown(CGPoint(x: 100, y: 500))
    // Dither across the hit boundary while the shrink is pending. Restarting the timer on every
    // transition used to strand the panel at expanded size for as long as the mouse kept moving.
    for _ in 0..<8 {
      vm.handleMouseMoved(CGPoint(x: 864, y: 1110))
      vm.handleMouseMoved(CGPoint(x: 100, y: 500))
      try await Task.sleep(for: .milliseconds(40))
    }
    try await Task.sleep(for: Motion.panelShrinkDelay + .milliseconds(200))
    XCTAssertEqual(vm.panelFrame, vm.geometry.collapsedPanelFrame())
  }

  func testCompactWidthsWidenThePanelImmediately() {
    let vm = makeVM()
    vm.updateCompactWidths(leading: 18, trailing: 76)
    XCTAssertEqual(
      vm.panelFrame, vm.geometry.collapsedPanelFrame(compactLeading: 18, compactTrailing: 76))
  }

  // MARK: - Per-tab height tiers

  func testExpandedHeightStartsAtTheBaseTier() {
    let vm = makeVM()
    XCTAssertEqual(vm.expandedHeight, Metrics.expandedSize.height)
    XCTAssertEqual(vm.expandedRect, vm.geometry.expandedRect(height: Metrics.expandedSize.height))
  }

  func testSetExpandedHeightGrowsThePanelImmediately() {
    let vm = makeVM(mode: .clickToPin)
    vm.handleMouseDown(CGPoint(x: 864, y: 1110))
    vm.setExpandedHeight(Metrics.tallExpandedHeight)
    XCTAssertEqual(vm.expandedHeight, Metrics.tallExpandedHeight)
    // Grown synchronously: a taller tab must never be drawn into a panel still sized for the
    // shorter one it replaced.
    XCTAssertEqual(vm.panelFrame, vm.geometry.panelFrame(height: Metrics.tallExpandedHeight))
    XCTAssertEqual(vm.expandedRect.height, Metrics.tallExpandedHeight)
  }

  func testSetExpandedHeightShrinksBackOnlyAfterTheDelay() async throws {
    let vm = makeVM(mode: .clickToPin)
    vm.handleMouseDown(CGPoint(x: 864, y: 1110))
    vm.setExpandedHeight(Metrics.tallExpandedHeight)
    vm.setExpandedHeight(Metrics.expandedSize.height)
    // Still tall: shrinking here would clip the outgoing tab mid-cross-fade.
    XCTAssertEqual(vm.panelFrame, vm.geometry.panelFrame(height: Metrics.tallExpandedHeight))
    try await Task.sleep(for: Motion.panelShrinkDelay + .milliseconds(200))
    // The deferred shrink re-reads state and height when it fires rather than capturing them, so
    // pin both down first: a failure here means the shrink resolved against the wrong inputs, not
    // that the shrink itself is broken.
    XCTAssertEqual(vm.state, .expanded(pinned: true), "the island should still be open")
    XCTAssertEqual(vm.expandedHeight, Metrics.expandedSize.height, "height should be back at base")
    XCTAssertEqual(vm.panelFrame, vm.geometry.panelFrame(height: Metrics.expandedSize.height))
  }

  func testTallExpandedRectSwallowsAClickTheBaseTierWouldTreatAsOutside() {
    let vm = makeVM(mode: .clickToPin)
    vm.handleMouseDown(CGPoint(x: 864, y: 1110))
    vm.setExpandedHeight(Metrics.tallExpandedHeight)
    // y = 900 is 217pt below the screen top: inside a 250pt island, below a 190pt one.
    vm.handleMouseDown(CGPoint(x: 864, y: 900))
    XCTAssertEqual(vm.state, .expanded(pinned: true))
  }

  func testBaseExpandedRectTreatsThatSamePointAsOutside() {
    let vm = makeVM(mode: .clickToPin)
    vm.handleMouseDown(CGPoint(x: 864, y: 1110))
    vm.handleMouseDown(CGPoint(x: 864, y: 900))
    XCTAssertEqual(vm.state, .closed)
  }

  func testHoverRegionWhileExpandedIsExpandedRect() {
    let vm = makeVM(mode: .clickToPin)
    vm.handleMouseDown(CGPoint(x: 864, y: 1110))
    // move inside expandedRect but outside notch: must NOT exit-hover/close
    vm.handleMouseMoved(CGPoint(x: 864, y: 1000))
    XCTAssertEqual(vm.state, .expanded(pinned: true))
  }

  // MARK: - Actual panel frame
  //
  // `panelFrame` is what we ask AppKit for; `actualPanelFrame` is what the window ended up with.
  // The island is drawn centred in the real window, so the drawing offset must use the second one.

  func testActualPanelFrameStartsEqualToTheRequestedFrame() {
    let vm = makeVM()
    XCTAssertEqual(vm.actualPanelFrame, vm.panelFrame)
    XCTAssertEqual(vm.actualPanelFrame, vm.geometry.collapsedPanelFrame())
  }

  func testActualPanelFrameTracksTheWindowNotTheRequest() {
    let vm = makeVM()
    let drifted = vm.panelFrame.offsetBy(dx: 37, dy: 0)
    vm.setActualPanelFrame(drifted)
    XCTAssertEqual(vm.actualPanelFrame, drifted)
    XCTAssertNotEqual(vm.panelFrame, drifted)  // the request is left alone

    // The whole point: with the real frame in hand the island still lands on the notch.
    let body = vm.geometry.collapsedIslandRect(
      inPanel: vm.actualPanelFrame, compactLeading: 0, compactTrailing: 0)
    XCTAssertEqual(
      body.minX, vm.geometry.notchRect.minX - Metrics.closedOversize, accuracy: 0.01)
  }

  /// Nothing in the app cancels the shrink today, but the handle that gates it must survive
  /// cancellation: a stranded non-nil `shrinkTask` fails the `shrinkTask == nil` guard forever, so
  /// the panel stays expanded-sized and the menu bar under it stays dead to clicks.
  func testACancelledShrinkDoesNotBlockLaterShrinks() async throws {
    let vm = makeVM(mode: .clickToPin)
    vm.handleMouseDown(CGPoint(x: 864, y: 1110))  // expand: panel grows immediately
    vm.handleMouseDown(CGPoint(x: 100, y: 500))  // close: a shrink is scheduled
    vm.cancelPendingShrink()
    try await Task.sleep(for: Motion.panelShrinkDelay + .milliseconds(200))
    // cancelled, so nothing shrank
    XCTAssertEqual(vm.panelFrame, vm.geometry.panelFrame(height: Metrics.expandedSize.height))

    // A later slot measurement must still be able to schedule a fresh shrink.
    vm.updateCompactWidths(leading: 10, trailing: 10)
    try await Task.sleep(for: Motion.panelShrinkDelay + .milliseconds(300))
    XCTAssertEqual(
      vm.panelFrame,
      vm.geometry.collapsedPanelFrame(compactLeading: 10, compactTrailing: 10))
  }
}
