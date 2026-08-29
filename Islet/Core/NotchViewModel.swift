import AppKit
import Combine
import Defaults
import SwiftUI

@MainActor
final class NotchViewModel: ObservableObject {
  @Published private(set) var state: NotchState = .closed
  /// Screen-coordinate footprint the visible island should occupy right now. The AppKit panel is
  /// permanently reserved at `reservedPanelFrame`; keeping this logical footprint separate lets
  /// pointer passthrough and alignment follow only the pixels the island actually draws.
  @Published private(set) var panelFrame: CGRect
  /// The frame the reserved window really occupies, read back from AppKit after placement or
  /// reassertion. Anything positioning drawn content on screen uses this because the compact
  /// island is aligned within that larger transparent host.
  @Published private(set) var actualPanelFrame: CGRect
  /// Height tier the currently selected tab asked for. Reported by `ExpandedContainerView`; drives
  /// the drawn island, hover region and click-inside test.
  @Published private(set) var expandedHeight: CGFloat = Metrics.expandedSize.height
  /// Drawn island width for the live tab count. The expanded panel reserves the maximum supported
  /// width up front, so changing this value animates only SwiftUI content and never resizes AppKit.
  @Published private(set) var expandedWidth: CGFloat = Metrics.expandedSize.width
  @Published private(set) var compactTargetRevision: UInt = 0
  /// Live 0...1 pressure against the hover barrier. The view turns this into elastic stretch.
  @Published private(set) var barrierProgress: CGFloat = 0
  var preventAutoClose = false

  let geometry: NotchGeometry
  private let modeOverride: InteractionMode?
  private let barrierPushDistanceOverride: CGFloat?
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
  private var collapseTask: Task<Void, Never>?
  private var shrinkTask: Task<Void, Never>?
  private var cancellables: Set<AnyCancellable> = []

  init(
    geometry: NotchGeometry, modeOverride: InteractionMode? = nil,
    barrierPushDistanceOverride: CGFloat? = nil
  ) {
    self.geometry = geometry
    self.modeOverride = modeOverride
    self.barrierPushDistanceOverride = barrierPushDistanceOverride
    let initialFrame = geometry.collapsedPanelFrame()
    self.panelFrame = initialFrame
    self.actualPanelFrame = initialFrame
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

  /// Widest island needed for every catalogued activity, clamped to the current screen.
  var maximumExpandedWidth: CGFloat {
    let screenLimit = max(
      Metrics.expandedSize.width,
      geometry.screenFrame.width - (Metrics.earMargin + Metrics.expandedScreenMargin) * 2)
    return ActivityTabLayout.preferredContainerWidth(
      tabCount: ActivityCatalog.orderable.count + 1, notchWidth: geometry.notchSize.width,
      minimumWidth: Metrics.expandedSize.width, maximumWidth: screenLimit)
  }

  /// The one AppKit frame used for this panel's whole lifetime. SwiftUI animates the island inside
  /// it; AppKit never resizes an NSHostingView while that view is updating constraints.
  var reservedPanelFrame: CGRect {
    geometry.panelFrame(width: maximumExpandedWidth, height: Metrics.tallExpandedHeight)
  }

  /// The expanded island's rect at the current width and height tiers.
  var expandedRect: CGRect {
    geometry.expandedRect(width: expandedWidth, height: expandedHeight)
  }

  /// The reserved window has transparent margins that must pass pointer events through. Keep the
  /// global movement monitor while expanded or whenever its frame exceeds the visible footprint.
  var needsPointerPassthroughMonitoring: Bool {
    state.isExpanded || actualPanelFrame != targetPanelFrame(for: state)
  }

  /// The region that counts as "hovering" for the current state.
  private var hoverRegion: CGRect {
    state.isExpanded ? expandedRect.union(geometry.hitRect) : geometry.hitRect
  }

  /// The AppKit window is deliberately fixed at its maximum size. Only the rendered island inside
  /// it should take mouse events; transparent margins behave like the menu bar or app beneath them.
  func shouldIgnorePanelMouseEvents(at location: CGPoint) -> Bool {
    let interactiveRect = state.isExpanded ? expandedRect : targetPanelFrame(for: state)
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
      collapseTask?.cancel()
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
      collapseTask?.cancel()
      if !state.isExpanded { apply(.fileDragEntered) }
      return
    }
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
    } else if state.isExpanded, expandedRect.contains(location) {
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

  /// Records where AppKit actually put the reserved host window. Drawing offsets use it to keep
  /// the visible island aligned with the hardware notch.
  func setActualPanelFrame(_ frame: CGRect) {
    guard frame != actualPanelFrame else { return }
    actualPanelFrame = frame
  }

  private func targetPanelFrame(for state: NotchState) -> CGRect {
    // This is the visible footprint, not the reserved AppKit window. The expanded footprint uses
    // the tallest and widest supported island; compact footprints follow their measured slots.
    switch state {
    case .expanded:
      geometry.panelFrame(width: maximumExpandedWidth, height: Metrics.tallExpandedHeight)
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

  /// The selected tab's height tier, reported by `ExpandedContainerView`. Only the drawn island
  /// and the hit region follow it — deliberately NOT the panel, which stays at the tallest tier
  /// for the whole expanded state. See `targetPanelFrame` for the crash this avoids.
  func setExpandedHeight(_ height: CGFloat) {
    guard height != expandedHeight else { return }
    withAnimation(Motion.gated(Motion.opening)) { expandedHeight = height }
    reconcileHoverContainment()
  }

  /// Sets the width requested by the current tab count. The panel already reserves
  /// `maximumExpandedWidth`, so this changes only the drawn island and its hit region.
  func setExpandedWidth(_ width: CGFloat) {
    let clamped = min(maximumExpandedWidth, max(Metrics.expandedSize.width, ceil(width)))
    guard clamped != expandedWidth else { return }
    withAnimation(Motion.gated(Motion.opening)) { expandedWidth = clamped }
    reconcileHoverContainment()
  }

  /// A tab-count change can move the island edge past a stationary cursor without producing a
  /// mouse event. Treat that geometry change like the corresponding exit or re-entry.
  private func reconcileHoverContainment() {
    let inside = region(hoverRegion, contains: lastMouseLocation)
    guard inside != wasInside else { return }
    wasInside = inside
    if inside {
      collapseTask?.cancel()
    } else if case .expanded(false) = state {
      scheduleCollapse()
    }
  }

  /// Grows the logical visible footprint immediately, then lets it settle after the closing
  /// animation. The AppKit host itself remains at `reservedPanelFrame` throughout.
  private func updatePanelFrame(for state: NotchState) {
    let target = targetPanelFrame(for: state)
    let grown = panelFrame.union(target)
    if grown != panelFrame { panelFrame = grown }
    // A pending shrink is deliberately left running rather than restarted: hover dithering on the
    // notch boundary, or a compact slot re-measuring, would otherwise push its deadline back
    // forever and strand the panel at expanded size. It re-reads the target when it fires, so a
    // single timer always settles on the current frame.
    guard target != panelFrame, shrinkTask == nil else { return }
    shrinkTask = Self.debounce(
      for: Motion.panelShrinkDelay,
      cleanup: { [weak self] in self?.shrinkTask = nil },
      body: { [weak self] in
        guard let self else { return }
        let settled = self.targetPanelFrame(for: self.state)
        if settled != self.panelFrame { self.panelFrame = settled }
      })
  }

  /// Cancels a pending shrink without scheduling a replacement. Exposed for tests: nothing in the
  /// app cancels it today, and the point of the test is that the gating handle survives a cancel.
  func cancelPendingShrink() { shrinkTask?.cancel() }

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
    // Closing resets the size tiers. The selection state lives in ExpandedContainerView and dies
    // with it, so the next open lands on the default tab — leaving a tall tier behind would draw a
    // 250pt island around 190pt content until the new view corrected it. Set with no animation:
    // nothing reads expandedHeight while the island is closed, so the change is invisible.
    if !next.isExpanded, expandedHeight != Metrics.expandedSize.height {
      expandedHeight = Metrics.expandedSize.height
    }
    if !next.isExpanded, expandedWidth != Metrics.expandedSize.width {
      expandedWidth = Metrics.expandedSize.width
    }
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

  /// Runs `body` after `delay`, cancelling any timer passed as `cancelling`. Omitting it schedules
  /// without disturbing what's already in flight.
  ///
  /// `cleanup` runs on EVERY path, cancellation included. A handle that gates future scheduling —
  /// `shrinkTask`, whose non-nil-ness blocks the next shrink — has to be released even when the
  /// timer never fires, or the first cancel blocks that path for the rest of the process. Nilling
  /// the handle here is safe against clobbering a newer one: no replacement can be scheduled while
  /// the old handle is still non-nil.
  private static func debounce(
    cancelling existing: Task<Void, Never>? = nil, for delay: Duration,
    cleanup: (@MainActor () -> Void)? = nil,
    body: @escaping @MainActor () -> Void
  ) -> Task<Void, Never> {
    existing?.cancel()
    return Task { @MainActor in
      try? await Task.sleep(for: delay)
      cleanup?()
      guard !Task.isCancelled else { return }
      body()
    }
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
    collapseTask = Self.debounce(
      cancelling: collapseTask, for: .seconds(Defaults[.hoverCollapseTimeout]),
      body: { [weak self] in
        guard let self, !self.wasInside else { return }
        self.apply(.collapseTimeoutElapsed)
      })
  }
}
