import AppKit
import Combine
import Defaults
import SwiftUI

/// Schedules the view model's delayed state transitions. Production uses the wall clock; tests
/// supply a virtual scheduler and advance it without waiting for an animation to elapse.
@MainActor
protocol NotchDelayScheduler: AnyObject {
  func schedule(
    after delay: Duration,
    action: @escaping @MainActor () -> Void
  ) -> any NotchScheduledOperation
}

@MainActor
protocol NotchScheduledOperation: AnyObject {
  func cancel()
}

@MainActor
private final class WallClockNotchDelayScheduler: NotchDelayScheduler {
  static let shared = WallClockNotchDelayScheduler()

  private init() {}

  func schedule(
    after delay: Duration,
    action: @escaping @MainActor () -> Void
  ) -> any NotchScheduledOperation {
    WallClockNotchScheduledOperation(after: delay, action: action)
  }
}

@MainActor
private final class WallClockNotchScheduledOperation: NotchScheduledOperation {
  private var task: Task<Void, Never>?

  init(after delay: Duration, action: @escaping @MainActor () -> Void) {
    task = Task { @MainActor in
      do {
        try await Task.sleep(for: delay)
      } catch {
        return
      }
      guard !Task.isCancelled else { return }
      action()
    }
  }

  func cancel() {
    task?.cancel()
    task = nil
  }
}

@MainActor
final class NotchViewModel: ObservableObject {
  @Published private(set) var state: NotchState = .closed
  /// The expanded switcher's explicit choice. A nil value lets the view choose its normal default.
  @Published private(set) var selectedActivityID: String?
  @Published private(set) var temporarilyPresentedActivityID: String?
  /// File-drop targeting belongs to this panel. Shelf contents are shared, but entering the Shelf
  /// on one display must not retarget an already-expanded island on another display.
  @Published private(set) var isShelfDropTargeted = false
  /// Screen-coordinate frame the panel should occupy right now. Growth is published before the
  /// island animates into it. Shrinkage waits for that animation to finish.
  @Published private(set) var panelFrame: CGRect
  /// The frame the window really occupies, read back after every AppKit frame transaction. This
  /// exposes any placement divergence and keeps the renderer's clipping alignment measurable.
  @Published private(set) var actualPanelFrame: CGRect
  /// Height tier the currently selected tab asked for. Reported by `ExpandedContainerView`; drives
  /// the drawn island, hover region and click-inside test.
  @Published private(set) var expandedHeight: CGFloat = Metrics.expandedSize.height
  /// Drawn island width for the live tab count.
  @Published private(set) var expandedWidth: CGFloat = Metrics.expandedSize.width
  @Published private(set) var compactTargetRevision: UInt = 0
  /// Home dismissal and snooze state belongs to the panel model, not the expanded view. The model
  /// survives tab changes and collapse/reopen cycles, while `IdleDashboardView` does not.
  @Published private(set) var homeAttentionDisposition = HomeAttentionDisposition()
  /// Live 0...1 pressure against the hover barrier. The view turns this into elastic stretch.
  @Published private(set) var barrierProgress: CGFloat = 0
  var preventAutoClose = false

  let geometry: NotchGeometry
  private let modeOverride: InteractionMode?
  private let barrierPushDistanceOverride: CGFloat?
  private let scheduler: any NotchDelayScheduler
  private var mode: InteractionMode { modeOverride ?? Defaults[.interactionMode] }
  private var barrierPushDistance: CGFloat {
    barrierPushDistanceOverride
      ?? CGFloat(
        min(
          max(Defaults[.barrierPushDistance], PushDistanceScale.minimum),
          PushDistanceScale.maximum))
  }

  private var wasInside = false
  private var lastMouseLocation: CGPoint = .zero
  private var compactLeadingWidth: CGFloat = 0
  private var compactTrailingWidth: CGFloat = 0
  private var barrierTravel: CGFloat = 0
  private var upwardDeviceDeltaSign: CGFloat?
  private var didPlayBarrierContactHaptic = false
  private var collapseTask: (any NotchScheduledOperation)?
  private var shrinkTask: (any NotchScheduledOperation)?
  private var collapseTaskGeneration: UInt = 0
  private var shrinkTaskGeneration: UInt = 0
  private var cancellables: Set<AnyCancellable> = []

  init(
    geometry: NotchGeometry, modeOverride: InteractionMode? = nil,
    barrierPushDistanceOverride: CGFloat? = nil,
    initialPresentation: PanelPresentationState = .initial,
    scheduler: (any NotchDelayScheduler)? = nil
  ) {
    self.geometry = geometry
    self.modeOverride = modeOverride
    self.barrierPushDistanceOverride = barrierPushDistanceOverride
    self.scheduler = scheduler ?? WallClockNotchDelayScheduler.shared
    let initialFrame = geometry.collapsedPanelFrame()
    self.panelFrame = initialFrame
    self.actualPanelFrame = initialFrame
    self.state = initialPresentation.notchState
    self.selectedActivityID = initialPresentation.selectedActivityID
    self.temporarilyPresentedActivityID = initialPresentation.temporarilyPresentedActivityID
    if state.isExpanded {
      expandedWidth = min(
        maximumExpandedWidth,
        max(Metrics.expandedSize.width, ceil(initialPresentation.expandedWidth)))
      expandedHeight = initialPresentation.expandedHeight
    }
    panelFrame = targetPanelFrame(for: state)
    // NSEvent monitors already deliver on the main thread, so no .receive(on:) hop is needed
    // (it would add a redundant async dispatch on every app-wide mouse move).
    EventMonitors.shared.mouseMovement
      .sink { [weak self] movement in
        self?.handleMouseMoved(
          movement.location, deviceDeltaY: movement.deviceDeltaY)
      }
      .store(in: &cancellables)
    EventMonitors.shared.mouseDown
      .sink { [weak self] p in self?.handleMouseDown(p) }
      .store(in: &cancellables)
    EventMonitors.shared.fileDragMovement
      .sink { [weak self] p in self?.handleFileDragMoved(p) }
      .store(in: &cancellables)
  }

  var presentationState: PanelPresentationState {
    PanelPresentationState(
      notchState: state, selectedActivityID: selectedActivityID,
      temporarilyPresentedActivityID: temporarilyPresentedActivityID,
      expandedWidth: expandedWidth, expandedHeight: expandedHeight)
  }

  func selectActivity(_ id: String?) {
    if temporarilyPresentedActivityID != id { temporarilyPresentedActivityID = nil }
    if selectedActivityID != id { selectedActivityID = id }
  }

  /// Selects an activity and opens the island if needed. Notification activation uses this rather
  /// than synthetic mouse events, so the completed timer is shown on the same display deterministically.
  func open(activityID: String, allowingDisabledActivity: Bool = false) {
    temporarilyPresentedActivityID = allowingDisabledActivity ? activityID : nil
    selectActivity(activityID)
    if !state.isExpanded { apply(.clickedNotch) }
  }

  func clearTemporaryPresentationIfUnavailable(availableActivityIDs: [String]) {
    guard let activityID = temporarilyPresentedActivityID,
      !availableActivityIDs.contains(activityID)
    else { return }
    temporarilyPresentedActivityID = nil
    if selectedActivityID == activityID { selectedActivityID = nil }
  }

  func isPresenting(activityID: String) -> Bool {
    guard state.isExpanded else { return false }
    if selectedActivityID == activityID {
      return temporarilyPresentedActivityID == activityID
        || ActivityEnablement.isEnabled(activityID)
    }
    return selectedActivityID == nil && ActivityCenter.shared.primaryActivity?.id == activityID
  }

  func visibleHomeAttentionItems(_ items: [HomeAttentionItem], now: Date) -> [HomeAttentionItem] {
    homeAttentionDisposition.visible(items, now: now)
  }

  func reconcileHomeAttention(with items: [HomeAttentionItem]) {
    homeAttentionDisposition.reconcile(with: items)
  }

  func dismissHomeAttention(_ item: HomeAttentionItem) {
    homeAttentionDisposition.dismiss(item)
  }

  func snoozeHomeAttention(_ item: HomeAttentionItem, until: Date) {
    homeAttentionDisposition.snooze(item, until: until)
  }

  func setShelfDropTargeted(_ targeted: Bool) {
    if isShelfDropTargeted != targeted { isShelfDropTargeted = targeted }
    if targeted { selectActivity("shelf") }
  }

  /// Resumes hover bookkeeping after ScreenManager restores an expanded presentation. Without
  /// this, an unpinned panel rebuilt while the pointer is already outside would never start its
  /// normal collapse timer because the new model has not observed an exit event.
  func resumePointerTracking(at location: CGPoint) {
    lastMouseLocation = location
    wasInside = region(hoverRegion, contains: location)
    guard !wasInside else { return }
    switch state {
    case .peek:
      apply(.hoverExited)
    case .expanded(false):
      scheduleCollapse()
    case .closed, .expanded(true):
      break
    }
  }

  /// Widest island needed for every catalogued activity, clamped to the current screen.
  var maximumExpandedWidth: CGFloat {
    let screenLimit = max(
      Metrics.expandedSize.width,
      geometry.screenFrame.width - (Metrics.earMargin + Metrics.expandedScreenMargin) * 2)
    return ActivityTabLayout.preferredContainerWidth(
      tabCount: ActivityCatalog.orderable.count + 1, notchWidth: geometry.notchSize.width,
      minimumWidth: Metrics.expandedSize.width, maximumWidth: screenLimit)
  }

  /// Stable screen frame for the SwiftUI renderer. The AppKit window clips this renderer to
  /// `panelFrame`, so the window-server footprint can adapt without changing NSHostingView's
  /// proposed size during a display-cycle constraint pass.
  var renderingFrame: CGRect {
    geometry.panelFrame(width: maximumExpandedWidth, height: Metrics.tallExpandedHeight)
  }

  /// The expanded island's rect at the current width and height tiers.
  var expandedRect: CGRect {
    geometry.expandedRect(width: expandedWidth, height: expandedHeight)
  }

  /// Bounding box of the visible expanded shape. `expandedRect` is the body size used for layout;
  /// the top corners flare outward by their radius and remain part of the interactive island.
  var expandedInteractionRect: CGRect {
    expandedRect.insetBy(dx: -Metrics.expandedRadii.top, dy: 0)
  }

  /// Expanded hosts retain small margins for their corner flare and shadow. A global movement
  /// monitor keeps those transparent pixels from swallowing input intended for the menu bar.
  var needsPointerPassthroughMonitoring: Bool {
    state.isExpanded
  }

  /// The region that counts as "hovering" for the current state.
  private var hoverRegion: CGRect {
    state.isExpanded ? expandedInteractionRect.union(geometry.hitRect) : geometry.hitRect
  }

  /// Only the rendered island inside the host should take mouse events. The host still carries
  /// room for corner flare and shadow, and those transparent margins must pass through.
  func shouldIgnorePanelMouseEvents(
    at location: CGPoint, allowingCompactFileDrag: Bool = false
  ) -> Bool {
    guard state.isExpanded || allowingCompactFileDrag else { return true }
    let interactiveRect = state.isExpanded ? expandedInteractionRect : targetPanelFrame(for: state)
    return !region(interactiveRect, contains: location)
  }

  /// `CGRect.contains` excludes its maximum edges. The pointer can legitimately clamp to the
  /// display's exact `maxY`, so nudge that coordinate one representable value back onto the screen
  /// before hit-testing. Without this, reaching the top resets the barrier before raw deltas can
  /// carry the push any farther.
  private func region(_ region: CGRect, contains location: CGPoint) -> Bool {
    var hitLocation = location
    if hitLocation.y >= geometry.screenFrame.maxY {
      hitLocation.y = geometry.screenFrame.maxY.nextDown
    }
    return region.contains(hitLocation)
  }

  func handleMouseMoved(_ location: CGPoint, deviceDeltaY: CGFloat? = nil) {
    let coordinateDeltaY = lastMouseLocation == .zero ? 0 : location.y - lastMouseLocation.y
    lastMouseLocation = location
    let inside = region(hoverRegion, contains: location)
    if inside, wasInside {
      updateBarrier(
        at: location, coordinateDeltaY: coordinateDeltaY, deviceDeltaY: deviceDeltaY)
      return
    }
    guard inside != wasInside else { return }
    wasInside = inside
    if inside {
      cancelScheduledCollapse()
      apply(.hoverEntered)
      beginBarrier(at: location)
    } else {
      resetBarrier()
      apply(.hoverExited)
      if case .expanded(false) = state { scheduleCollapse() }
    }
  }

  /// File drags use the normal collapsed notch hit area, but bypass the pressure barrier. AppKit's
  /// drop destination then follows the panel as it expands and handles the payload itself.
  func handleFileDragMoved(_ location: CGPoint) {
    lastMouseLocation = location
    let inside = region(hoverRegion, contains: location)
    if inside {
      wasInside = true
      cancelScheduledCollapse()
      setShelfDropTargeted(true)
      if !state.isExpanded { apply(.fileDragEntered) }
      return
    }
    setShelfDropTargeted(false)
    guard wasInside else { return }
    wasInside = false
    resetBarrier()
    apply(.hoverExited)
    if case .expanded(false) = state { scheduleCollapse() }
  }

  func handleMouseDown(_ location: CGPoint) {
    lastMouseLocation = location
    if region(geometry.hitRect, contains: location) {
      apply(.clickedNotch)
    } else if state.isExpanded, expandedInteractionRect.contains(location) {
      apply(.clickedInsideExpanded)
    } else if state.isExpanded {
      apply(.clickedOutside)
    }
  }

  /// Widths the compact slots actually rendered at, reported by the view. They set the collapsed
  /// island's width, so the panel has to follow them.
  func updateCompactWidths(leading: CGFloat, trailing: CGFloat) {
    guard leading != compactLeadingWidth || trailing != compactTrailingWidth else { return }
    compactLeadingWidth = leading
    compactTrailingWidth = trailing
    compactTargetRevision &+= 1
    updatePanelFrame(for: state)
  }

  /// Records where AppKit actually put the clipped host window for diagnostics, passthrough
  /// updates and renderer-alignment checks.
  func setActualPanelFrame(_ frame: CGRect) {
    guard frame != actualPanelFrame else { return }
    actualPanelFrame = frame
  }

  private func targetPanelFrame(for state: NotchState) -> CGRect {
    switch state {
    case .expanded:
      geometry.panelFrame(width: expandedWidth, height: expandedHeight)
    case .peek where mode == .hover:
      geometry.collapsedPanelFrame(
        compactLeading: compactLeadingWidth, compactTrailing: compactTrailingWidth,
        depth: Metrics.barrierPanelDepth)
    case .peek:
      geometry.collapsedPanelFrame(
        compactLeading: compactLeadingWidth, compactTrailing: compactTrailingWidth)
    case .closed:
      geometry.collapsedPanelFrame(
        compactLeading: compactLeadingWidth, compactTrailing: compactTrailingWidth)
    }
  }

  /// The selected tab's height tier, reported by `ExpandedContainerView`.
  func setExpandedHeight(_ height: CGFloat) {
    guard height != expandedHeight else { return }
    let oldHeight = expandedHeight
    if state.isExpanded, height > oldHeight {
      updatePanelFrame(
        toward: geometry.panelFrame(width: expandedWidth, height: height))
    }
    withAnimation(Motion.gated(Motion.opening)) { expandedHeight = height }
    if state.isExpanded, height < oldHeight {
      updatePanelFrame(toward: targetPanelFrame(for: state), restartingShrinkDelay: true)
    }
    reconcileHoverContainment()
  }

  /// Sets the width requested by the current tab count.
  func setExpandedWidth(_ width: CGFloat) {
    let clamped = min(maximumExpandedWidth, max(Metrics.expandedSize.width, ceil(width)))
    guard clamped != expandedWidth else { return }
    let oldWidth = expandedWidth
    if state.isExpanded, clamped > oldWidth {
      updatePanelFrame(
        toward: geometry.panelFrame(width: clamped, height: expandedHeight))
    }
    withAnimation(Motion.gated(Motion.opening)) { expandedWidth = clamped }
    if state.isExpanded, clamped < oldWidth {
      updatePanelFrame(toward: targetPanelFrame(for: state), restartingShrinkDelay: true)
    }
    reconcileHoverContainment()
  }

  /// A tab-count change can move the island edge past a stationary cursor without producing a
  /// mouse event. Treat that geometry change like the corresponding exit or re-entry.
  private func reconcileHoverContainment() {
    let inside = region(hoverRegion, contains: lastMouseLocation)
    guard inside != wasInside else { return }
    wasInside = inside
    if inside {
      cancelScheduledCollapse()
    } else if case .expanded(false) = state {
      scheduleCollapse()
    }
  }

  private func updatePanelFrame(for state: NotchState) {
    updatePanelFrame(toward: targetPanelFrame(for: state))
  }

  /// Grows before a matching content change can draw outside the window. Shrinks share one timer
  /// and re-read the current target when it fires, so rapid tier and state changes cannot leave a
  /// stale frame behind.
  private func updatePanelFrame(toward target: CGRect, restartingShrinkDelay: Bool = false) {
    let grown = panelFrame.union(target)
    if grown != panelFrame { panelFrame = grown }
    // Hover dithering and compact slot re-measurement do not restart a pending shrink, which stops
    // them from pushing its deadline back forever. A real content-tier shrink restarts the delay so
    // the outgoing animation is never clipped. Every timer re-reads the current target when it
    // fires.
    guard target != panelFrame else { return }
    if shrinkTask != nil {
      guard restartingShrinkDelay else { return }
      cancelScheduledShrink()
    }
    schedulePanelShrink()
  }

  /// Cancels a pending shrink without scheduling a replacement. Exposed for tests: nothing in the
  /// app cancels it today, and the point of the test is that the gating handle survives a cancel.
  func cancelPendingShrink() { cancelScheduledShrink() }

  func apply(_ event: NotchEvent) {
    let next = NotchStateMachine.transition(
      from: state, on: event, mode: mode, preventAutoClose: preventAutoClose)
    guard next != state else { return }
    let opening = order(next) > order(state)
    if next.isExpanded, !state.isExpanded {
      if event == .pushThresholdCrossed { Haptics.barrierSnap() }
      resetBarrier()
    }
    updatePanelFrame(for: next)  // publish the grown footprint before content animates into it
    withAnimation(Motion.gated(opening ? Motion.opening : Motion.closing)) {
      state = next
    }
    // Closing resets the size tiers and explicit selection, matching the old view-local selection
    // behavior. Leaving a tall tier behind would draw a 250pt island around 190pt content until
    // the new view corrected it. Set with no animation because none of these values draw closed.
    if !next.isExpanded, expandedHeight != Metrics.expandedSize.height {
      expandedHeight = Metrics.expandedSize.height
    }
    if !next.isExpanded, expandedWidth != Metrics.expandedSize.width {
      expandedWidth = Metrics.expandedSize.width
    }
    if !next.isExpanded { selectActivity(nil) }
    // hover-region may have changed shape; re-evaluate containment so exit fires correctly
    wasInside = region(hoverRegion, contains: lastMouseLocation)
  }

  private func order(_ s: NotchState) -> Int {
    switch s {
    case .closed: 0
    case .peek: 1
    case .expanded: 2
    }
  }

  private func schedulePanelShrink() {
    guard shrinkTask == nil else { return }
    shrinkTaskGeneration &+= 1
    let generation = shrinkTaskGeneration
    shrinkTask = scheduler.schedule(after: Motion.panelShrinkDelay) { [weak self] in
      guard let self, self.shrinkTaskGeneration == generation else { return }
      self.shrinkTask = nil
      let settled = self.targetPanelFrame(for: self.state)
      if settled != self.panelFrame { self.panelFrame = settled }
    }
  }

  private func cancelScheduledShrink() {
    shrinkTaskGeneration &+= 1
    shrinkTask?.cancel()
    shrinkTask = nil
  }

  private func cancelScheduledCollapse() {
    collapseTaskGeneration &+= 1
    collapseTask?.cancel()
    collapseTask = nil
  }

  private func beginBarrier(at location: CGPoint) {
    guard state == .peek, mode == .hover else { return }
    barrierTravel = 0
    upwardDeviceDeltaSign = nil
    barrierProgress = 0
    didPlayBarrierContactHaptic = false
  }

  private func updateBarrier(
    at location: CGPoint, coordinateDeltaY: CGFloat, deviceDeltaY: CGFloat?
  ) {
    guard state == .peek, mode == .hover else { return }

    var upwardTravel = coordinateDeltaY
    if let deviceDeltaY, abs(deviceDeltaY) > 0.01 {
      // Calibrate the device-delta sign while the cursor can still move. Once it reaches the top
      // edge, the screen coordinate clamps but device deltas continue, which creates the feeling
      // of pressing into a barrier instead of running out of pixels.
      if abs(coordinateDeltaY) > 0.01 {
        upwardDeviceDeltaSign = coordinateDeltaY * deviceDeltaY >= 0 ? 1 : -1
      }
      // Core Graphics mouse Y deltas use device coordinates, where an upward movement is negative.
      // If the barrier begins with the pointer already clamped, there is no coordinate movement to
      // calibrate against, so use that native sign directly instead of dropping the input.
      let sign = upwardDeviceDeltaSign ?? -1
      if abs(coordinateDeltaY) > 0.01 || location.y >= geometry.screenFrame.maxY - 1 {
        upwardTravel = deviceDeltaY * sign
      }
    }
    barrierTravel = min(max(barrierTravel + upwardTravel, 0), barrierPushDistance)
    let progress = barrierTravel / barrierPushDistance
    if progress != barrierProgress { barrierProgress = progress }

    // A fast flick may reach the threshold in one event. In that case the snap alone is clearer
    // than two simultaneous pulses; normal deliberate pressure gets exactly contact, then release.
    if progress >= 1 {
      apply(.pushThresholdCrossed)
      return
    }
    if !didPlayBarrierContactHaptic, progress >= Metrics.barrierContactProgress {
      didPlayBarrierContactHaptic = true
      Haptics.barrierContact()
    }
  }

  private func resetBarrier() {
    barrierTravel = 0
    upwardDeviceDeltaSign = nil
    barrierProgress = 0
    didPlayBarrierContactHaptic = false
  }

  private func scheduleCollapse() {
    cancelScheduledCollapse()
    collapseTaskGeneration &+= 1
    let generation = collapseTaskGeneration
    collapseTask = scheduler.schedule(after: .seconds(Defaults[.hoverCollapseTimeout])) {
      [weak self] in
      guard let self, self.collapseTaskGeneration == generation else { return }
      self.collapseTask = nil
      guard !self.wasInside else { return }
      self.apply(.collapseTimeoutElapsed)
    }
  }
}
