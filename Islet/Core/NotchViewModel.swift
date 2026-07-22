import AppKit
import Combine
import Defaults
import SwiftUI

@MainActor
final class NotchViewModel: ObservableObject {
  @Published private(set) var state: NotchState = .closed
  var preventAutoClose = false

  let geometry: NotchGeometry
  private let modeOverride: InteractionMode?
  private var mode: InteractionMode { modeOverride ?? Defaults[.interactionMode] }

  private var wasInside = false
  private var lastMouseLocation: CGPoint = .zero
  private var dwellTask: Task<Void, Never>?
  private var collapseTask: Task<Void, Never>?
  private var cancellables: Set<AnyCancellable> = []

  init(geometry: NotchGeometry, modeOverride: InteractionMode? = nil) {
    self.geometry = geometry
    self.modeOverride = modeOverride
    EventMonitors.shared.mouseLocation
      .receive(on: DispatchQueue.main)
      .sink { [weak self] p in self?.handleMouseMoved(p) }
      .store(in: &cancellables)
    EventMonitors.shared.mouseDown
      .receive(on: DispatchQueue.main)
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

  func apply(_ event: NotchEvent) {
    let next = NotchStateMachine.transition(
      from: state, on: event, mode: mode, preventAutoClose: preventAutoClose)
    guard next != state else { return }
    let opening = order(next) > order(state)
    if event == .hoverEntered, next == .peek { Haptics.tick() }
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

  private func scheduleDwell() {
    dwellTask?.cancel()
    dwellTask = Task { [weak self] in
      guard let self else { return }
      try? await Task.sleep(for: .seconds(Defaults[.hoverExpandDelay]))
      guard !Task.isCancelled, self.wasInside else { return }
      self.apply(.hoverDwellElapsed)
    }
  }

  private func scheduleCollapse() {
    collapseTask?.cancel()
    collapseTask = Task { [weak self] in
      guard let self else { return }
      try? await Task.sleep(for: .seconds(Defaults[.hoverCollapseTimeout]))
      guard !Task.isCancelled, !self.wasInside else { return }
      self.apply(.collapseTimeoutElapsed)
    }
  }
}
