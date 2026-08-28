import AppKit
import Combine
import Defaults
import SwiftUI

@MainActor
final class NotchViewModel: ObservableObject {
  @Published private(set) var state: NotchState = .closed
  /// Screen-coordinate frame the panel should occupy right now. Tracked so the collapsed island
  /// doesn't reserve — and swallow the clicks of — the whole expanded footprint. This is a
  /// REQUEST: AppKit is handed it, and what the window ends up with is `actualPanelFrame`.
  @Published private(set) var panelFrame: CGRect
  /// The frame the window really occupies, read back from AppKit after every `setFrame` by
  /// `ScreenManager`. Anything that positions drawn content on screen must use this: the island is
  /// drawn centred in the real window, so any divergence from `panelFrame` maps 1:1 onto a
  /// horizontal shift of the island.
  @Published private(set) var actualPanelFrame: CGRect
  /// Height tier the currently selected tab asked for. Reported by `ExpandedContainerView`; drives
  /// the drawn island, the hover region, the click-inside test and the panel frame.
  @Published private(set) var expandedHeight: CGFloat = Metrics.expandedSize.height
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
  private var barrierHapticStage = 0
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
  }

  /// The expanded island's rect at the current height tier.
  var expandedRect: CGRect { geometry.expandedRect(height: expandedHeight) }

  /// The region that counts as "hovering" for the current state.
  private var hoverRegion: CGRect {
    state.isExpanded ? expandedRect.union(geometry.hitRect) : geometry.hitRect
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
    updatePanelFrame(for: state)
  }

  /// Records where AppKit actually put the window. Only drawing offsets read it — `panelFrame`
  /// remains the single source of truth for what Islet asks for, so a rejected request is visible
  /// as a divergence rather than being quietly adopted as the new intent.
  func setActualPanelFrame(_ frame: CGRect) {
    guard frame != actualPanelFrame else { return }
    actualPanelFrame = frame
  }

  private func targetPanelFrame(for state: NotchState) -> CGRect {
    // The expanded panel is sized for the TALLEST tier, always — it does not follow
    // `expandedHeight`. Resizing the window while the hosting view animates a tier change throws
    // an uncaught NSException out of AppKit's constraint pass and aborts the app; reproduced
    // deterministically in TallTierHostingTests, where the identical transition against a fixed
    // window survives. The drawn island is what changes height — the shape mask clips it and
    // `testTallPanelFrameContainsTheBaseOneAndItsIsland` pins the containment. Cost: while a
    // base-tier tab is open, the panel swallows a ~60pt strip below the island, which the
    // expanded island's full-frame black backdrop was already doing.
    switch state {
    case .expanded:
      geometry.panelFrame(height: Metrics.tallExpandedHeight)
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
  }

  /// Grows the panel immediately so nothing is ever clipped mid-animation, but defers shrinking
  /// until the closing animation has played out.
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
      cleanup: { [weak self] in self?.shrinkTask = nil }
    ) { [weak self] in
      guard let self else { return }
      let settled = self.targetPanelFrame(for: self.state)
      if settled != self.panelFrame { self.panelFrame = settled }
    }
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
      if event == .pushThresholdCrossed {
        Haptics.barrierSnap()
      } else {
        Haptics.perform(.levelChange)
      }
      resetBarrier()
    }
    updatePanelFrame(for: next)  // widen the window before the content animates into it
    withAnimation(Motion.gated(opening ? Motion.opening : Motion.closing)) {
      state = next
    }
    // Closing resets the height tier. The selection state lives in ExpandedContainerView and dies
    // with it, so the next open lands on the default tab — leaving a tall tier behind would draw a
    // 250pt island around 190pt content until the new view corrected it. Set with no animation:
    // nothing reads expandedHeight while the island is closed, so the change is invisible.
    if !next.isExpanded, expandedHeight != Metrics.expandedSize.height {
      expandedHeight = Metrics.expandedSize.height
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
    _ body: @escaping @MainActor () -> Void
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
    barrierHapticStage = 0
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
      if abs(coordinateDeltaY) > 0.01 || location.y >= geometry.screenFrame.maxY - 1
      {
        upwardTravel = deviceDeltaY * sign
      }
    }
    barrierTravel = min(max(barrierTravel + upwardTravel, 0), barrierPushDistance)
    let progress = barrierTravel / barrierPushDistance
    if progress != barrierProgress { barrierProgress = progress }

    // A fast flick may cross both marks in one event. In that case the snap alone is clearer than
    // two simultaneous pulses; normal deliberate pressure still gets contact, then release.
    if progress >= 1 {
      apply(.pushThresholdCrossed)
      return
    }
    if barrierHapticStage < 2, progress >= Metrics.barrierStrainProgress {
      barrierHapticStage = 2
      Haptics.barrierResistance(strong: true)
    } else if barrierHapticStage < 1, progress >= Metrics.barrierContactProgress {
      barrierHapticStage = 1
      Haptics.barrierResistance(strong: false)
    }
  }

  private func resetBarrier() {
    barrierTravel = 0
    upwardDeviceDeltaSign = nil
    barrierProgress = 0
    barrierHapticStage = 0
  }

  private func scheduleCollapse() {
    collapseTask = Self.debounce(
      cancelling: collapseTask, for: .seconds(Defaults[.hoverCollapseTimeout])
    ) { [weak self] in
      guard let self, !self.wasInside else { return }
      self.apply(.collapseTimeoutElapsed)
    }
  }
}
