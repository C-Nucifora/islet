import Combine
import Defaults
import XCTest

@testable import Islet

@MainActor
private final class VirtualNotchDelayScheduler: NotchDelayScheduler {
  private struct PendingOperation {
    let id: UInt
    let deadline: Duration
    let order: UInt
    let action: @MainActor () -> Void
  }

  private final class ScheduledOperation: NotchScheduledOperation {
    private weak var scheduler: VirtualNotchDelayScheduler?
    private let id: UInt

    init(scheduler: VirtualNotchDelayScheduler, id: UInt) {
      self.scheduler = scheduler
      self.id = id
    }

    func cancel() { scheduler?.cancel(id) }
  }

  private var now: Duration = .zero
  private var nextID: UInt = 0
  private var pending: [PendingOperation] = []

  func schedule(
    after delay: Duration,
    action: @escaping @MainActor () -> Void
  ) -> any NotchScheduledOperation {
    precondition(delay >= .zero)
    nextID &+= 1
    let id = nextID
    pending.append(PendingOperation(id: id, deadline: now + delay, order: id, action: action))
    return ScheduledOperation(scheduler: self, id: id)
  }

  func advance(by duration: Duration) {
    precondition(duration >= .zero)
    now += duration
    while let index = nextDueOperationIndex() {
      let operation = pending.remove(at: index)
      operation.action()
    }
  }

  func advance(to time: Duration) {
    precondition(time >= now)
    advance(by: time - now)
  }

  private func cancel(_ id: UInt) {
    pending.removeAll { $0.id == id }
  }

  private func nextDueOperationIndex() -> Int? {
    pending.indices.filter { pending[$0].deadline <= now }.min {
      pending[$0].order < pending[$1].order
    }
  }
}

final class DisplayStateReconcilerTests: XCTestCase {
  private let builtin = DisplayHardwareIdentity.builtin
  private let external = DisplayHardwareIdentity.external(vendor: 10, model: 20, serial: 30)

  private func display(_ id: String, identity: DisplayHardwareIdentity? = nil) -> ManagedDisplay {
    ManagedDisplay(id: id, hardwareIdentity: identity)
  }

  private func presentation(
    _ state: NotchState, selection: String? = nil
  ) -> PanelPresentationState {
    PanelPresentationState(notchState: state, selectedActivityID: selection)
  }

  private func state(
    _ display: ManagedDisplay, _ presentation: PanelPresentationState
  ) -> ManagedDisplayState {
    ManagedDisplayState(display: display, presentation: presentation)
  }

  func testConnectPreservesExistingDisplayAndInitializesNewDisplay() {
    let first = display("first", identity: builtin)
    let second = display("second", identity: external)
    let openTimer = presentation(.expanded(pinned: true), selection: "timer")

    let result = DisplayStateReconciler.reconcile(
      previous: [state(first, openTimer)], current: [first, second],
      preferredDisplayID: first.id)

    XCTAssertEqual(result[first.id], openTimer)
    XCTAssertEqual(result[second.id], .initial)
  }

  func testDisconnectMovesOpenPresentationToPreferredSurvivingDisplay() {
    let first = display("first", identity: builtin)
    let second = display("second", identity: external)
    let openShelf = presentation(.expanded(pinned: false), selection: "shelf")

    let result = DisplayStateReconciler.reconcile(
      previous: [state(first, .initial), state(second, openShelf)], current: [first],
      preferredDisplayID: first.id)

    XCTAssertEqual(result[first.id], openShelf)
  }

  func testRearrangeUsesDisplayIdentifiersInsteadOfTargetOrder() {
    let first = display("first", identity: builtin)
    let second = display("second", identity: external)
    let firstPresentation = presentation(.expanded(pinned: true), selection: "system")
    let secondPresentation = presentation(.peek)

    let result = DisplayStateReconciler.reconcile(
      previous: [state(first, firstPresentation), state(second, secondPresentation)],
      current: [second, first], preferredDisplayID: second.id)

    XCTAssertEqual(result[first.id], firstPresentation)
    XCTAssertEqual(result[second.id], secondPresentation)
  }

  func testWakeMapsChangedIdentifierThroughUniqueHardwareIdentity() {
    let beforeWake = display("before-wake", identity: external)
    let afterWake = display("after-wake", identity: external)
    let openBattery = presentation(.expanded(pinned: true), selection: "battery")

    let result = DisplayStateReconciler.reconcile(
      previous: [state(beforeWake, openBattery)], current: [afterWake],
      preferredDisplayID: afterWake.id)

    XCTAssertEqual(result[afterWake.id], openBattery)
  }

  func testAmbiguousHardwareIdentityDoesNotCrossMapClosedState() {
    let oldFirst = display("old-first", identity: external)
    let oldSecond = display("old-second", identity: external)
    let newFirst = display("new-first", identity: external)
    let newSecond = display("new-second", identity: external)

    let result = DisplayStateReconciler.reconcile(
      previous: [
        state(oldFirst, presentation(.closed, selection: "timer")),
        state(oldSecond, presentation(.closed, selection: "battery")),
      ], current: [newFirst, newSecond], preferredDisplayID: newFirst.id)

    XCTAssertEqual(result[newFirst.id], .initial)
    XCTAssertEqual(result[newSecond.id], .initial)
  }

  func testVanishedPresentationDoesNotReplaceOpenSurvivingDisplay() {
    let first = display("first", identity: builtin)
    let second = display("second", identity: external)
    let firstPresentation = presentation(.expanded(pinned: true), selection: "system")
    let secondPresentation = presentation(.expanded(pinned: false), selection: "shelf")

    let result = DisplayStateReconciler.reconcile(
      previous: [state(first, firstPresentation), state(second, secondPresentation)],
      current: [first], preferredDisplayID: first.id)

    XCTAssertEqual(result[first.id], firstPresentation)
  }
}

@MainActor
final class MultiDisplayPresentationTests: XCTestCase {
  func testExpansionAndShelfDropAffectOnlyTheTargetDisplayViewModel() {
    let leftGeometry = NotchGeometry(
      screenFrame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
      safeAreaTop: 32, auxLeftWidth: 716, auxRightWidth: 708, menuBarHeight: 37)
    let rightGeometry = NotchGeometry(
      screenFrame: CGRect(x: 1728, y: 0, width: 2560, height: 1440),
      safeAreaTop: 0, auxLeftWidth: 0, auxRightWidth: 0, menuBarHeight: 24)
    let left = NotchViewModel(geometry: leftGeometry, modeOverride: .clickToPin)
    let right = NotchViewModel(geometry: rightGeometry, modeOverride: .clickToPin)
    right.apply(.clickedNotch)
    right.selectActivity("system")

    left.handleFileDragMoved(
      CGPoint(x: leftGeometry.notchRect.midX, y: leftGeometry.notchRect.midY))

    XCTAssertTrue(left.state.isExpanded)
    XCTAssertEqual(left.selectedActivityID, "shelf")
    XCTAssertTrue(right.state.isExpanded)
    XCTAssertEqual(right.selectedActivityID, "system")
  }
}

@MainActor
final class NotchViewModelTests: XCTestCase {
  func makeVM(
    mode: InteractionMode = .hover,
    barrierPushDistance: CGFloat? = Metrics.barrierPushDistance,
    scheduler: (any NotchDelayScheduler)? = nil
  ) -> NotchViewModel {
    let g = NotchGeometry(
      screenFrame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
      safeAreaTop: 32, auxLeftWidth: 716, auxRightWidth: 716,
      menuBarHeight: 37)
    return NotchViewModel(
      geometry: g, modeOverride: mode, barrierPushDistanceOverride: barrierPushDistance,
      scheduler: scheduler)
  }

  func expandedPanel(
    _ vm: NotchViewModel, width: CGFloat = Metrics.expandedSize.width,
    height: CGFloat = Metrics.expandedSize.height
  ) -> CGRect {
    vm.geometry.panelFrame(width: width, height: height)
  }

  func testInitialPresentationRestoresExpansionSelectionAndSize() {
    let source = makeVM(mode: .clickToPin)
    source.handleMouseDown(CGPoint(x: 864, y: 1110))
    source.selectActivity("system")
    source.setExpandedWidth(700)
    source.setExpandedHeight(Metrics.tallExpandedHeight)

    let restored = NotchViewModel(
      geometry: source.geometry, modeOverride: .clickToPin,
      initialPresentation: source.presentationState)

    XCTAssertEqual(restored.state, .expanded(pinned: true))
    XCTAssertEqual(restored.selectedActivityID, "system")
    XCTAssertEqual(restored.expandedWidth, source.expandedWidth)
    XCTAssertEqual(restored.expandedHeight, Metrics.tallExpandedHeight)
    XCTAssertEqual(
      restored.panelFrame,
      expandedPanel(
        restored, width: source.expandedWidth, height: Metrics.tallExpandedHeight))
  }

  func testInitialPresentationRestoresTemporaryActivityException() {
    let saved = Defaults[.disabledActivities]
    defer { Defaults[.disabledActivities] = saved }
    Defaults[.disabledActivities] = ["timer"]
    let source = makeVM(mode: .clickToPin)
    source.open(activityID: "timer", allowingDisabledActivity: true)

    let restored = NotchViewModel(
      geometry: source.geometry, modeOverride: .clickToPin,
      initialPresentation: source.presentationState)

    XCTAssertEqual(restored.selectedActivityID, "timer")
    XCTAssertEqual(restored.temporarilyPresentedActivityID, "timer")
    XCTAssertTrue(restored.isPresenting(activityID: "timer"))
  }

  func testOrdinaryCloseStillClearsSelection() {
    let vm = makeVM(mode: .clickToPin)
    vm.handleMouseDown(CGPoint(x: 864, y: 1110))
    vm.selectActivity("system")

    vm.handleMouseDown(CGPoint(x: 100, y: 500))

    XCTAssertEqual(vm.state, .closed)
    XCTAssertNil(vm.selectedActivityID)
  }

  func testProgrammaticOpenShowsTheRequestedActivity() {
    let vm = makeVM(mode: .clickToPin)

    vm.open(activityID: "timer")

    XCTAssertEqual(vm.state, .expanded(pinned: true))
    XCTAssertEqual(vm.selectedActivityID, "timer")
    XCTAssertTrue(vm.isPresenting(activityID: "timer"))
    XCTAssertEqual(vm.keyboardFocusRequestRevision, 0)
  }

  func testPointerAndFileDragExpansionDoNotRequestKeyboardFocus() {
    let pointerVM = makeVM(mode: .clickToPin)
    pointerVM.handleMouseDown(CGPoint(x: 864, y: 1110))
    XCTAssertTrue(pointerVM.state.isExpanded)
    XCTAssertEqual(pointerVM.keyboardFocusRequestRevision, 0)

    let dragVM = makeVM()
    dragVM.handleFileDragMoved(CGPoint(x: 864, y: 1110))
    XCTAssertTrue(dragVM.state.isExpanded)
    XCTAssertEqual(dragVM.keyboardFocusRequestRevision, 0)
  }

  func testFocusedInteractionOpensTheRequestedActivityAndRequestsFocus() {
    let vm = makeVM(mode: .clickToPin)

    vm.openForFocusedInteraction(activityID: "system")

    XCTAssertEqual(vm.state, .expanded(pinned: true))
    XCTAssertEqual(vm.selectedActivityID, "system")
    XCTAssertEqual(vm.keyboardFocusRequestRevision, 1)
  }

  func testProgrammaticOpenCanTemporarilyPresentADisabledActivity() {
    let vm = makeVM(mode: .clickToPin)

    vm.open(activityID: "timer", allowingDisabledActivity: true)

    XCTAssertEqual(vm.temporarilyPresentedActivityID, "timer")
    XCTAssertEqual(vm.selectedActivityID, "timer")
  }

  func testDisabledSelectionIsPresentedOnlyThroughTemporaryException() {
    let saved = Defaults[.disabledActivities]
    defer { Defaults[.disabledActivities] = saved }
    Defaults[.disabledActivities] = ["timer"]
    let vm = makeVM(mode: .clickToPin)

    vm.open(activityID: "timer")
    XCTAssertFalse(vm.isPresenting(activityID: "timer"))

    vm.open(activityID: "timer", allowingDisabledActivity: true)
    XCTAssertTrue(vm.isPresenting(activityID: "timer"))
  }

  func testTemporaryActivityPresentationClearsWhenItsContentDisappears() {
    let vm = makeVM(mode: .clickToPin)
    vm.open(activityID: "timer", allowingDisabledActivity: true)

    vm.clearTemporaryPresentationIfUnavailable(availableActivityIDs: [])

    XCTAssertNil(vm.temporarilyPresentedActivityID)
    XCTAssertNil(vm.selectedActivityID)
  }

  func testRestoredPeekUsesPeekGeometryAndClosesWhenPointerIsOutside() {
    let vm = NotchViewModel(
      geometry: makeVM().geometry, modeOverride: .hover,
      initialPresentation: PanelPresentationState(notchState: .peek))

    XCTAssertEqual(vm.state, .peek)
    XCTAssertGreaterThan(vm.panelFrame.height, vm.geometry.collapsedPanelFrame().height)

    vm.resumePointerTracking(at: CGPoint(x: 100, y: 500))

    XCTAssertEqual(vm.state, .closed)
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
    // The default tab uses the base tier. The panel does not reserve wider or taller content.
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

  func testPanelFrameShrinksAfterCollapsing() {
    let scheduler = VirtualNotchDelayScheduler()
    let vm = makeVM(mode: .clickToPin, scheduler: scheduler)
    vm.handleMouseDown(CGPoint(x: 864, y: 1110))
    vm.handleMouseDown(CGPoint(x: 100, y: 500))
    scheduler.advance(to: Motion.panelShrinkDelay)
    XCTAssertEqual(vm.panelFrame, vm.geometry.collapsedPanelFrame())
  }

  func testRepeatedTransitionsDoNotDeferTheShrink() {
    let scheduler = VirtualNotchDelayScheduler()
    let vm = makeVM(mode: .clickToPin, scheduler: scheduler)
    vm.handleMouseDown(CGPoint(x: 864, y: 1110))
    vm.handleMouseDown(CGPoint(x: 100, y: 500))
    // Dither across the hit boundary while the shrink is pending. Restarting the timer on every
    // transition used to strand the panel at expanded size for as long as the mouse kept moving.
    for _ in 0..<8 {
      vm.handleMouseMoved(CGPoint(x: 864, y: 1110))
      vm.handleMouseMoved(CGPoint(x: 100, y: 500))
      scheduler.advance(by: .milliseconds(40))
    }
    XCTAssertEqual(vm.panelFrame, expandedPanel(vm))
    scheduler.advance(to: Motion.panelShrinkDelay)
    XCTAssertEqual(vm.panelFrame, vm.geometry.collapsedPanelFrame())
  }

  func testCompactWidthsWidenThePanelImmediately() {
    let vm = makeVM()
    vm.updateCompactWidths(leading: 18, trailing: 76)
    XCTAssertEqual(
      vm.panelFrame, vm.geometry.collapsedPanelFrame(compactLeading: 18, compactTrailing: 76))
  }

  func testCompactTargetChangePublishesBeforeDelayedShrink() {
    let vm = makeVM(mode: .clickToPin)
    vm.updateCompactWidths(leading: 80, trailing: 80)
    vm.setActualPanelFrame(vm.panelFrame)
    var revisions: [UInt] = []
    let cancellable = vm.$compactTargetRevision.dropFirst()
      .sink { revisions.append($0) }

    vm.updateCompactWidths(leading: 10, trailing: 10)

    XCTAssertEqual(revisions, [2])
    XCTAssertFalse(vm.needsPointerPassthroughMonitoring)
    withExtendedLifetime(cancellable) {}
  }

  // MARK: - Per-tab height tiers

  func testExpandedHeightStartsAtTheBaseTier() {
    let vm = makeVM()
    XCTAssertEqual(vm.expandedHeight, Metrics.expandedSize.height)
    XCTAssertEqual(vm.expandedRect, vm.geometry.expandedRect(height: Metrics.expandedSize.height))
  }

  func testExpandedWidthGrowsThePanelWithTheTabCount() async throws {
    let vm = makeVM(mode: .clickToPin)
    vm.handleMouseDown(CGPoint(x: 864, y: 1110))
    XCTAssertEqual(vm.panelFrame, expandedPanel(vm))

    vm.setExpandedWidth(700)
    XCTAssertEqual(vm.expandedWidth, 700)
    XCTAssertEqual(vm.expandedRect.width, 700)
    XCTAssertEqual(vm.panelFrame, expandedPanel(vm, width: 700))

    vm.setExpandedWidth(vm.maximumExpandedWidth + 100)
    XCTAssertEqual(vm.expandedWidth, vm.maximumExpandedWidth)
    XCTAssertEqual(vm.panelFrame, expandedPanel(vm, width: vm.maximumExpandedWidth))

    vm.setExpandedWidth(Metrics.expandedSize.width)
    XCTAssertEqual(
      vm.panelFrame, expandedPanel(vm, width: vm.maximumExpandedWidth),
      "the host must not clip the width animation")
    try await Task.sleep(for: Motion.panelShrinkDelay + .milliseconds(100))
    XCTAssertEqual(vm.panelFrame, expandedPanel(vm))
  }

  func testTransparentExpandedPanelMarginsIgnoreMouseEvents() {
    let vm = makeVM(mode: .clickToPin)
    vm.handleMouseDown(CGPoint(x: 864, y: 1110))

    XCTAssertFalse(vm.shouldIgnorePanelMouseEvents(at: CGPoint(x: 864, y: 1000)))
    XCTAssertTrue(vm.shouldIgnorePanelMouseEvents(at: CGPoint(x: 1_250, y: 1_000)))
    XCTAssertTrue(vm.shouldIgnorePanelMouseEvents(at: CGPoint(x: 864, y: 880)))
  }

  func testVisibleExpandedCornerFlareRemainsInteractive() {
    let vm = makeVM(mode: .clickToPin)
    vm.handleMouseDown(CGPoint(x: 864, y: 1110))
    let body = vm.expandedRect
    let flare = vm.expandedInteractionRect
    let visibleFlarePoint = CGPoint(x: body.minX - 8, y: body.maxY - 4)
    let transparentMarginPoint = CGPoint(x: flare.minX - 8, y: body.maxY - 4)

    XCTAssertFalse(body.contains(visibleFlarePoint))
    XCTAssertTrue(flare.contains(visibleFlarePoint))
    XCTAssertFalse(vm.shouldIgnorePanelMouseEvents(at: visibleFlarePoint))
    XCTAssertTrue(vm.shouldIgnorePanelMouseEvents(at: transparentMarginPoint))
  }

  func testWholeClosingPanelBecomesTransparentAsClosingStarts() {
    let vm = makeVM(mode: .clickToPin)
    vm.handleMouseDown(CGPoint(x: 864, y: 1110))
    vm.handleMouseDown(CGPoint(x: 100, y: 500))

    XCTAssertEqual(vm.state, .closed)
    XCTAssertEqual(vm.panelFrame, expandedPanel(vm))
    XCTAssertTrue(vm.shouldIgnorePanelMouseEvents(at: CGPoint(x: 864, y: 1110)))
    XCTAssertTrue(vm.shouldIgnorePanelMouseEvents(at: CGPoint(x: 1_250, y: 1_000)))
  }

  func testWidthShrinkPastStationaryCursorSchedulesCollapse() {
    let savedTimeout = Defaults[.hoverCollapseTimeout]
    Defaults[.hoverCollapseTimeout] = 0.01
    defer { Defaults[.hoverCollapseTimeout] = savedTimeout }
    let scheduler = VirtualNotchDelayScheduler()
    let vm = makeVM(scheduler: scheduler)
    vm.handleFileDragMoved(CGPoint(x: 864, y: 1110))
    vm.setExpandedWidth(700)
    vm.handleMouseMoved(CGPoint(x: 1_150, y: 1_000))
    XCTAssertEqual(vm.state, .expanded(pinned: false))

    vm.setExpandedWidth(Metrics.expandedSize.width)
    scheduler.advance(by: .milliseconds(10))

    XCTAssertEqual(vm.state, .closed)
  }

  func testWidthGrowthAroundStationaryCursorCancelsPendingCollapse() {
    let savedTimeout = Defaults[.hoverCollapseTimeout]
    Defaults[.hoverCollapseTimeout] = 0.03
    defer { Defaults[.hoverCollapseTimeout] = savedTimeout }
    let scheduler = VirtualNotchDelayScheduler()
    let vm = makeVM(scheduler: scheduler)
    vm.handleFileDragMoved(CGPoint(x: 864, y: 1110))
    vm.handleMouseMoved(CGPoint(x: 1_150, y: 1_000))
    XCTAssertEqual(vm.state, .expanded(pinned: false))

    vm.setExpandedWidth(700)
    scheduler.advance(by: .milliseconds(30))

    XCTAssertEqual(vm.state, .expanded(pinned: false))
  }

  func testHeightTierGrowsImmediatelyAndShrinksAfterItsAnimation() async throws {
    let vm = makeVM(mode: .clickToPin)
    vm.handleMouseDown(CGPoint(x: 864, y: 1110))
    XCTAssertEqual(vm.panelFrame, expandedPanel(vm))

    vm.setExpandedHeight(Metrics.tallExpandedHeight)
    XCTAssertEqual(vm.expandedHeight, Metrics.tallExpandedHeight)
    XCTAssertEqual(vm.expandedRect.height, Metrics.tallExpandedHeight)
    XCTAssertEqual(
      vm.panelFrame, expandedPanel(vm, height: Metrics.tallExpandedHeight),
      "growth must precede the content animation")

    vm.setExpandedHeight(Metrics.expandedSize.height)
    XCTAssertEqual(vm.expandedRect.height, Metrics.expandedSize.height)
    XCTAssertEqual(
      vm.panelFrame, expandedPanel(vm, height: Metrics.tallExpandedHeight),
      "the outgoing tall content must not be clipped")
    try await Task.sleep(for: Motion.panelShrinkDelay + .milliseconds(100))
    XCTAssertEqual(vm.panelFrame, expandedPanel(vm))
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
  // The fixed renderer has its own screen frame and is clipped to the actual window.

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

    // The renderer stays anchored to the notch even if the clipped window is temporarily moved.
    let body = vm.geometry.collapsedIslandRect(
      inPanel: vm.renderingFrame, compactLeading: 0, compactTrailing: 0)
    XCTAssertEqual(
      body.minX, vm.geometry.notchRect.minX - Metrics.closedOversize, accuracy: 0.01)
  }

  /// Nothing in the app cancels the shrink today, but the handle that gates it must survive
  /// cancellation: a stranded non-nil `shrinkTask` fails the `shrinkTask == nil` guard forever, so
  /// the panel stays expanded-sized and the menu bar under it stays dead to clicks.
  func testACancelledShrinkDoesNotBlockLaterShrinks() {
    let scheduler = VirtualNotchDelayScheduler()
    let vm = makeVM(mode: .clickToPin, scheduler: scheduler)
    vm.handleMouseDown(CGPoint(x: 864, y: 1110))  // expand: panel grows immediately
    vm.handleMouseDown(CGPoint(x: 100, y: 500))  // close: a shrink is scheduled
    vm.cancelPendingShrink()
    scheduler.advance(by: Motion.panelShrinkDelay)
    // Cancelled, so the base expanded frame remains in place.
    XCTAssertEqual(vm.panelFrame, expandedPanel(vm))

    // A later slot measurement must still be able to schedule a fresh shrink.
    vm.updateCompactWidths(leading: 10, trailing: 10)
    scheduler.advance(by: Motion.panelShrinkDelay)
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

  func testHomeDispositionSurvivesTabAndCollapseRoundTrips() {
    let vm = makeVM(mode: .clickToPin)
    let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
    let item = HomeAttentionItem(
      id: "reminder:current", stableID: "reminder", source: .reminders,
      title: "Send notes", detail: nil, symbol: "checklist", accentHex: nil,
      state: "Due", priority: .urgent, rankingReason: "It is due now", dueAt: now,
      expiresAt: nil, progress: nil, primaryAction: nil, allowsDismiss: true,
      allowsSnooze: true)

    vm.reconcileHomeAttention(with: [item])
    vm.snoozeHomeAttention(item, until: now + 3_600)
    vm.handleMouseDown(CGPoint(x: 864, y: 1110))
    vm.selectActivity("calendar")
    vm.selectActivity(nil)
    vm.reconcileHomeAttention(with: [item])
    XCTAssertTrue(vm.visibleHomeAttentionItems([item], now: now).isEmpty)

    vm.handleMouseDown(CGPoint(x: 100, y: 500))
    vm.handleMouseDown(CGPoint(x: 864, y: 1110))
    vm.reconcileHomeAttention(with: [item])
    XCTAssertTrue(vm.visibleHomeAttentionItems([item], now: now + 3_599).isEmpty)
    XCTAssertEqual(vm.visibleHomeAttentionItems([item], now: now + 3_600), [item])

    vm.dismissHomeAttention(item)
    vm.selectActivity("timer")
    vm.selectActivity(nil)
    vm.handleMouseDown(CGPoint(x: 100, y: 500))
    vm.handleMouseDown(CGPoint(x: 864, y: 1110))
    vm.reconcileHomeAttention(with: [item])
    XCTAssertTrue(vm.visibleHomeAttentionItems([item], now: now + 7_200).isEmpty)
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

  func testPointerPassthroughForwardsOnlyTheTopBandAndItsFirstExit() {
    let frame = CGRect(x: 0, y: 0, width: 1728, height: 1117)
    let desktop = CGPoint(x: 864, y: 500)
    XCTAssertFalse(
      EventMonitors.shouldForwardTopBandMovement(
        desktop, screenFrames: [frame], wasInTopInteractionBand: false))
    XCTAssertTrue(
      EventMonitors.shouldForwardTopBandMovement(
        desktop, screenFrames: [frame], wasInTopInteractionBand: true))
  }

  func testMovementMonitorRunsOnlyForHoverOrExpandedPassthrough() {
    XCTAssertFalse(
      EventMonitors.shouldRunMovementMonitor(
        hoverEnabled: false, pointerPassthroughDemandCount: 0))
    XCTAssertTrue(
      EventMonitors.shouldRunMovementMonitor(
        hoverEnabled: true, pointerPassthroughDemandCount: 0))
    XCTAssertTrue(
      EventMonitors.shouldRunMovementMonitor(
        hoverEnabled: false, pointerPassthroughDemandCount: 1))
  }

  func testPointerPassthroughMonitoringRunsOnlyWhileExpanded() {
    let vm = makeVM(mode: .clickToPin)
    vm.setActualPanelFrame(vm.panelFrame)
    XCTAssertFalse(vm.needsPointerPassthroughMonitoring)

    vm.handleMouseDown(CGPoint(x: 864, y: 1110))
    XCTAssertTrue(vm.needsPointerPassthroughMonitoring)

    vm.handleMouseDown(CGPoint(x: 100, y: 500))
    XCTAssertFalse(vm.needsPointerPassthroughMonitoring)
  }

  func testCollapsedPanelIsTransparentExceptForARelevantFileDrag() {
    let vm = makeVM(mode: .clickToPin)
    vm.setActualPanelFrame(vm.panelFrame)
    let notch = CGPoint(x: vm.geometry.notchRect.midX, y: vm.geometry.screenFrame.maxY - 1)

    XCTAssertTrue(vm.shouldIgnorePanelMouseEvents(at: notch))
    XCTAssertFalse(
      vm.shouldIgnorePanelMouseEvents(at: notch, allowingCompactFileDrag: true))
  }

  func testDisabledShelfDoesNotForwardMonitorDrivenFileDrags() {
    let frame = CGRect(x: 0, y: 0, width: 1728, height: 1117)
    let notch = CGPoint(x: 864, y: 1110)
    XCTAssertFalse(
      EventMonitors.shouldForwardFileDrag(
        notch, screenFrames: [frame], shelfAvailable: false,
        wasInTopInteractionBand: false))
    XCTAssertTrue(
      EventMonitors.shouldForwardFileDrag(
        notch, screenFrames: [frame], shelfAvailable: true,
        wasInTopInteractionBand: false))
  }
}
