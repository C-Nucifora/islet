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
  var preventAutoClose = false

  let geometry: NotchGeometry
  private let modeOverride: InteractionMode?
  private var mode: InteractionMode { modeOverride ?? Defaults[.interactionMode] }

  private var wasInside = false
  private var lastMouseLocation: CGPoint = .zero
  private var compactLeadingWidth: CGFloat = 0
  private var compactTrailingWidth: CGFloat = 0
  private var dwellTask: Task<Void, Never>?
  private var collapseTask: Task<Void, Never>?
  private var shrinkTask: Task<Void, Never>?
  private var cancellables: Set<AnyCancellable> = []

  init(geometry: NotchGeometry, modeOverride: InteractionMode? = nil) {
    self.geometry = geometry
    self.modeOverride = modeOverride
    let initialFrame = geometry.collapsedPanelFrame()
    self.panelFrame = initialFrame
    self.actualPanelFrame = initialFrame
    // NSEvent monitors already deliver on the main thread, so no .receive(on:) hop is needed
    // (it would add a redundant async dispatch on every app-wide mouse move).
    EventMonitors.shared.mouseLocation
      .sink { [weak self] p in self?.handleMouseMoved(p) }
      .store(in: &cancellables)
    EventMonitors.shared.mouseDown
      .sink { [weak self] p in self?.handleMouseDown(p) }
      .store(in: &cancellables)
  }

  /// The region that counts as "hovering" for the current state.
  private var hoverRegion: CGRect {
    state.isExpanded ? geometry.expandedRect.union(geometry.hitRect) : geometry.hitRect
  }

  func handleMouseMoved(_ location: CGPoint) {
    lastMouseLocation = location
    let inside = hoverRegion.contains(location)
    guard inside != wasInside else { return }
    wasInside = inside
    if inside {
      collapseTask?.cancel()
      apply(.hoverEntered)
      if state == .peek, mode == .hover { scheduleDwell() }
    } else {
      dwellTask?.cancel()
      apply(.hoverExited)
      if case .expanded(false) = state { scheduleCollapse() }
    }
  }

  func handleMouseDown(_ location: CGPoint) {
    lastMouseLocation = location
    if geometry.hitRect.contains(location) {
      apply(.clickedNotch)
    } else if state.isExpanded, geometry.expandedRect.contains(location) {
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
    state.isExpanded
      ? geometry.panelFrame
      : geometry.collapsedPanelFrame(
        compactLeading: compactLeadingWidth, compactTrailing: compactTrailingWidth)
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
      for: Metrics.panelShrinkDelay,
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
    if event == .hoverEntered, next == .peek { Haptics.tick() }
    if next.isExpanded, !state.isExpanded { Haptics.perform(.levelChange) }  // firm tap on expand
    updatePanelFrame(for: next)  // widen the window before the content animates into it
    withAnimation(opening ? Metrics.opening : Metrics.closing) {
      state = next
    }
    // hover-region may have changed shape; re-evaluate containment so exit fires correctly
    wasInside = hoverRegion.contains(lastMouseLocation)
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

  private func scheduleDwell() {
    dwellTask = Self.debounce(
      cancelling: dwellTask, for: .seconds(Defaults[.hoverExpandDelay])
    ) { [weak self] in
      guard let self, self.wasInside else { return }
      self.apply(.hoverDwellElapsed)
    }
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
