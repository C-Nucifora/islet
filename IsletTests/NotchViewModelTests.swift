import Defaults
import XCTest

@testable import Islet

@MainActor
final class NotchViewModelTests: XCTestCase {
  func makeVM(
    mode: InteractionMode = .hover,
    barrierPushDistance: CGFloat? = Metrics.barrierPushDistance
  ) -> NotchViewModel {
    let g = NotchGeometry(
      screenFrame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
      safeAreaTop: 32, auxLeftWidth: 716, auxRightWidth: 716,
      menuBarHeight: 37)
    return NotchViewModel(
      geometry: g, modeOverride: mode, barrierPushDistanceOverride: barrierPushDistance)
  }

  func expandedPanel(_ vm: NotchViewModel) -> CGRect {
    vm.geometry.panelFrame(
      width: vm.maximumExpandedWidth, height: Metrics.tallExpandedHeight)
  }

  func testMouseIntoHitRectPeeks() {
    let vm = makeVM()
    vm.handleMouseMoved(CGPoint(x: 864, y: 1110))  // inside notch
    XCTAssertEqual(vm.state, .peek)
  }

  func testFileDragIntoCollapsedNotchExpandsFullyWithoutPush() {
    let vm = makeVM()
    XCTAssertEqual(vm.panelFrame, vm.geometry.collapsedPanelFrame())
    vm.handleFileDragMoved(CGPoint(x: 864, y: 1060))
    XCTAssertEqual(vm.state, .closed)
    XCTAssertEqual(vm.panelFrame, vm.geometry.collapsedPanelFrame())

    vm.handleFileDragMoved(CGPoint(x: 864, y: 1110))

    XCTAssertEqual(vm.state, .expanded(pinned: false))
    XCTAssertEqual(vm.panelFrame, expandedPanel(vm))
    XCTAssertEqual(vm.barrierProgress, 0)
  }

  func testFileDragExpandsWhenPointerWasAlreadyHoveringTheNotch() {
    let vm = makeVM()
    let notchPoint = CGPoint(x: 864, y: 1110)
    vm.handleMouseMoved(notchPoint)
    XCTAssertEqual(vm.state, .peek)

    vm.handleFileDragMoved(notchPoint)

    XCTAssertEqual(vm.state, .expanded(pinned: false))
    XCTAssertEqual(vm.barrierProgress, 0)
  }

  func testFileDragReenteringTheNotchExpandsAgainWithoutPush() {
    let vm = makeVM()
    let notchPoint = CGPoint(x: 864, y: 1110)
    vm.handleFileDragMoved(notchPoint)
    vm.handleFileDragMoved(CGPoint(x: 100, y: 500))
    vm.apply(.collapseTimeoutElapsed)
    XCTAssertEqual(vm.state, .closed)

    vm.handleFileDragMoved(notchPoint)

    XCTAssertEqual(vm.state, .expanded(pinned: false))
    XCTAssertEqual(vm.barrierProgress, 0)
  }

  func testHoverPeekPanelMakesRoomForTheFullBarrierStretch() {
    let vm = makeVM()
    vm.handleMouseMoved(CGPoint(x: 864, y: 1082))
    XCTAssertEqual(
      vm.panelFrame,
      vm.geometry.collapsedPanelFrame(depth: Metrics.barrierPanelDepth))
  }

  func testUpwardPushStretchesPeekBeforeOpening() {
    let vm = makeVM(barrierPushDistance: 288)
    vm.handleMouseMoved(CGPoint(x: 864, y: 1082))
    vm.handleMouseMoved(CGPoint(x: 864, y: 1116), deviceDeltaY: -34)
    vm.handleMouseMoved(CGPoint(x: 864, y: 1116), deviceDeltaY: -110)
    XCTAssertEqual(vm.state, .peek)
    XCTAssertEqual(vm.barrierProgress, 0.5, accuracy: 0.01)
  }

  func testUpwardPushSnapsOpenAtThreshold() {
    let vm = makeVM()
    vm.handleMouseMoved(CGPoint(x: 864, y: 1082))
    vm.handleMouseMoved(CGPoint(x: 864, y: 1116), deviceDeltaY: -34)
    vm.handleMouseMoved(CGPoint(x: 864, y: 1116), deviceDeltaY: -366)
    XCTAssertEqual(vm.state, .expanded(pinned: false))
    XCTAssertEqual(vm.barrierProgress, 0)
  }

  func testDeviceTravelKeepsBuildingPressureAtTheTopScreenEdge() {
    let vm = makeVM()
    vm.handleMouseMoved(CGPoint(x: 864, y: 1090))
    vm.handleMouseMoved(CGPoint(x: 864, y: 1116), deviceDeltaY: -27)
    XCTAssertEqual(vm.state, .peek)
    vm.handleMouseMoved(CGPoint(x: 864, y: 1116), deviceDeltaY: -373)
    XCTAssertEqual(vm.state, .expanded(pinned: false))
  }

  func testRawDeviceTravelWorksWhenBarrierBeginsAtExactTopEdge() {
    let vm = makeVM()
    vm.handleMouseMoved(CGPoint(x: 864, y: 1117))
    XCTAssertEqual(vm.state, .peek)
    vm.handleMouseMoved(CGPoint(x: 864, y: 1117), deviceDeltaY: -400)
    XCTAssertEqual(vm.state, .expanded(pinned: false))
  }

  func testConfiguredPushDistanceChangesTheSnapThreshold() {
    let vm = makeVM(barrierPushDistance: 160)
    vm.handleMouseMoved(CGPoint(x: 864, y: 1117))
    vm.handleMouseMoved(CGPoint(x: 864, y: 1117), deviceDeltaY: -159)
    XCTAssertEqual(vm.state, .peek)
    XCTAssertEqual(vm.barrierProgress, 159.0 / 160.0, accuracy: 0.001)
    vm.handleMouseMoved(CGPoint(x: 864, y: 1117), deviceDeltaY: -1)
    XCTAssertEqual(vm.state, .expanded(pinned: false))
  }

  func testDownwardMovementDoesNotBuildBarrierPressure() {
    let vm = makeVM()
    vm.handleMouseMoved(CGPoint(x: 864, y: 1090))
    vm.handleMouseMoved(CGPoint(x: 864, y: 1084))
    XCTAssertEqual(vm.state, .peek)
    XCTAssertEqual(vm.barrierProgress, 0)
  }

  func testClickModeIgnoresBarrierPressure() {
    let vm = makeVM(mode: .clickToPin)
    vm.handleMouseMoved(CGPoint(x: 864, y: 1082))
    vm.handleMouseMoved(CGPoint(x: 864, y: 1100))
    XCTAssertEqual(vm.state, .peek)
    XCTAssertEqual(vm.barrierProgress, 0)
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
    // Grown synchronously, and straight to the TALLEST tier: the panel never resizes while
    // expanded, because a setFrame during the tier cross-fade throws inside AppKit layout.
    XCTAssertEqual(vm.panelFrame, expandedPanel(vm))
  }

  func testPanelFrameStaysGrownUntilTheClosingAnimationEnds() {
    let vm = makeVM(mode: .clickToPin)
    vm.handleMouseDown(CGPoint(x: 864, y: 1110))
    vm.handleMouseDown(CGPoint(x: 100, y: 500))
    XCTAssertEqual(vm.state, .closed)
    // Still expanded-sized: shrinking here would clip the island mid-collapse.
    XCTAssertEqual(vm.panelFrame, expandedPanel(vm))
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

  func testExpandedWidthTracksTheTabCountWithoutMovingThePanel() {
    let vm = makeVM(mode: .clickToPin)
    vm.handleMouseDown(CGPoint(x: 864, y: 1110))
    let panel = expandedPanel(vm)
    XCTAssertEqual(vm.panelFrame, panel)

    vm.setExpandedWidth(700)
    XCTAssertEqual(vm.expandedWidth, 700)
    XCTAssertEqual(vm.expandedRect.width, 700)
    XCTAssertEqual(vm.panelFrame, panel)

    vm.setExpandedWidth(vm.maximumExpandedWidth + 100)
    XCTAssertEqual(vm.expandedWidth, vm.maximumExpandedWidth)
    XCTAssertEqual(vm.panelFrame, panel)
  }

  func testTransparentExpandedPanelMarginsIgnoreMouseEvents() {
    let vm = makeVM(mode: .clickToPin)
    vm.handleMouseDown(CGPoint(x: 864, y: 1110))

    XCTAssertFalse(vm.shouldIgnorePanelMouseEvents(at: CGPoint(x: 864, y: 1000)))
    XCTAssertTrue(vm.shouldIgnorePanelMouseEvents(at: CGPoint(x: 1_250, y: 1_000)))
    XCTAssertTrue(vm.shouldIgnorePanelMouseEvents(at: CGPoint(x: 864, y: 880)))
  }

  func testWidthShrinkPastStationaryCursorSchedulesCollapse() async throws {
    let savedTimeout = Defaults[.hoverCollapseTimeout]
    Defaults[.hoverCollapseTimeout] = 0.01
    defer { Defaults[.hoverCollapseTimeout] = savedTimeout }
    let vm = makeVM()
    vm.handleFileDragMoved(CGPoint(x: 864, y: 1110))
    vm.setExpandedWidth(700)
    vm.handleMouseMoved(CGPoint(x: 1_150, y: 1_000))
    XCTAssertEqual(vm.state, .expanded(pinned: false))

    vm.setExpandedWidth(Metrics.expandedSize.width)
    try await Task.sleep(for: .milliseconds(50))

    XCTAssertEqual(vm.state, .closed)
  }

  func testWidthGrowthAroundStationaryCursorCancelsPendingCollapse() async throws {
    let savedTimeout = Defaults[.hoverCollapseTimeout]
    Defaults[.hoverCollapseTimeout] = 0.03
    defer { Defaults[.hoverCollapseTimeout] = savedTimeout }
    let vm = makeVM()
    vm.handleFileDragMoved(CGPoint(x: 864, y: 1110))
    vm.handleMouseMoved(CGPoint(x: 1_150, y: 1_000))
    XCTAssertEqual(vm.state, .expanded(pinned: false))

    vm.setExpandedWidth(700)
    try await Task.sleep(for: .milliseconds(80))

    XCTAssertEqual(vm.state, .expanded(pinned: false))
  }

  /// The height tier drives the drawn island and the hit region ONLY. The panel holds the tallest
  /// tier for the whole expanded state: resizing the window while the hosting view animates the
  /// tier change throws an uncaught NSException out of AppKit's constraint pass — reproduced in
  /// TallTierHostingTests, where the identical transition against a fixed window survives.
  func testHeightTierNeverMovesThePanel() {
    let vm = makeVM(mode: .clickToPin)
    vm.handleMouseDown(CGPoint(x: 864, y: 1110))
    let expanded = expandedPanel(vm)
    XCTAssertEqual(vm.panelFrame, expanded)

    vm.setExpandedHeight(Metrics.tallExpandedHeight)
    XCTAssertEqual(vm.expandedHeight, Metrics.tallExpandedHeight)
    XCTAssertEqual(vm.expandedRect.height, Metrics.tallExpandedHeight)
    XCTAssertEqual(vm.panelFrame, expanded, "tier change must not republish the panel frame")

    vm.setExpandedHeight(Metrics.expandedSize.height)
    XCTAssertEqual(vm.expandedRect.height, Metrics.expandedSize.height)
    XCTAssertEqual(vm.panelFrame, expanded, "nor on the way back down")
  }

  func testTallExpandedRectSwallowsAClickTheBaseTierWouldTreatAsOutside() {
    let vm = makeVM(mode: .clickToPin)
    vm.handleMouseDown(CGPoint(x: 864, y: 1110))
    // No yield needed: the hit region follows `expandedHeight`, which is applied synchronously.
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
    // cancelled, so nothing shrank (the expanded panel is always the tallest tier)
    XCTAssertEqual(vm.panelFrame, expandedPanel(vm))

    // A later slot measurement must still be able to schedule a fresh shrink.
    vm.updateCompactWidths(leading: 10, trailing: 10)
    try await Task.sleep(for: Motion.panelShrinkDelay + .milliseconds(300))
    XCTAssertEqual(
      vm.panelFrame,
      vm.geometry.collapsedPanelFrame(compactLeading: 10, compactTrailing: 10))
  }

  /// The selection lives in ExpandedContainerView and dies with it on collapse, so the next open
  /// lands on the default tab. A surviving tall tier would draw a 250pt island around 190pt
  /// content until the new view corrected it.
  func testCollapsingResetsTheHeightTier() async {
    let vm = makeVM(mode: .clickToPin)
    vm.handleMouseDown(CGPoint(x: 864, y: 1110))
    vm.setExpandedHeight(Metrics.tallExpandedHeight)

    vm.handleMouseDown(CGPoint(x: 100, y: 500))  // collapse
    XCTAssertEqual(vm.expandedHeight, Metrics.expandedSize.height)

    // Reopening therefore draws the base tier, not the stale tall one.
    vm.handleMouseDown(CGPoint(x: 864, y: 1110))
    XCTAssertEqual(vm.expandedRect.height, Metrics.expandedSize.height)
  }

  func testCollapsingResetsTheWidthTier() {
    let vm = makeVM(mode: .clickToPin)
    vm.handleMouseDown(CGPoint(x: 864, y: 1110))
    vm.setExpandedWidth(700)

    vm.handleMouseDown(CGPoint(x: 100, y: 500))
    XCTAssertEqual(vm.expandedWidth, Metrics.expandedSize.width)
  }

  func testMouseMonitorTopBandCoversTallIslandButNotTheDesktop() {
    let frame = CGRect(x: 0, y: 0, width: 1728, height: 1117)
    XCTAssertTrue(
      EventMonitors.isInTopInteractionBand(
        CGPoint(x: 864, y: 900), screenFrames: [frame]))
    XCTAssertFalse(
      EventMonitors.isInTopInteractionBand(
        CGPoint(x: 864, y: 500), screenFrames: [frame]))
  }

  func testMouseMonitorTopBandHandlesOffsetDisplaysAndExactTopEdge() {
    let secondary = CGRect(x: -1440, y: 200, width: 1440, height: 900)
    XCTAssertTrue(
      EventMonitors.isInTopInteractionBand(
        CGPoint(x: -720, y: secondary.maxY), screenFrames: [secondary]))
    XCTAssertFalse(
      EventMonitors.isInTopInteractionBand(
        CGPoint(x: 100, y: secondary.maxY), screenFrames: [secondary]))
  }
}
