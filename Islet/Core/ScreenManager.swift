import AppKit
import Combine
import Defaults
import SwiftUI

/// One notch panel plus the frame plumbing that keeps its reserved host window in place.
///
/// A class rather than a struct because re-asserting a frame needs per-panel mutable state: the
/// re-entrancy guard has to outlive any single call, or a `didMove` fired by our own `setFrame`
/// would call straight back into it.
@MainActor
private final class PanelInstance {
  let screenUUID: String
  let panel: NotchPanel
  let viewModel: NotchViewModel
  var cancellables: Set<AnyCancellable> = []
  private var isApplying = false
  private let pointerMonitoringID = UUID()

  init(screenUUID: String, panel: NotchPanel, viewModel: NotchViewModel) {
    self.screenUUID = screenUUID
    self.panel = panel
    self.viewModel = viewModel
  }

  /// Reasserts the panel's one reserved frame.
  ///
  /// The window's real frame is read straight back and pushed into the model. `NotchPanel` returns
  /// `constrainFrameRect` unchanged so the two should always agree, but the island is positioned
  /// inside the real frame, so any system adjustment still has to be measured.
  ///
  /// The visible island changes size inside this frame. Resizing the NSWindow in response to a
  /// SwiftUI geometry callback races NSHostingView constraint maintenance and AppKit terminates
  /// the process in `_postWindowNeedsUpdateConstraints`.
  private func applyReservedFrame() {
    guard !isApplying else { return }
    isApplying = true
    let frame = viewModel.reservedPanelFrame
    panel.setFrame(frame, display: false)
    let actual = panel.frame
    if actual != frame {
      Log.app.error(
        "Panel frame diverged on \(self.screenUUID, privacy: .public): requested \(NSStringFromRect(frame), privacy: .public) actual \(NSStringFromRect(actual), privacy: .public)"
      )
    }
    viewModel.setActualPanelFrame(actual)
    isApplying = false
  }

  /// Feeds the window's real frame into the model without touching the window.
  func syncActualFrame() { viewModel.setActualPanelFrame(panel.frame) }

  /// Unconditional re-push of the reserved frame. A display or Space transition can move a panel
  /// behind our back without changing any model value that could trigger a Combine publisher.
  func reassert() { applyReservedFrame() }

  /// The panel is `isMovable = false` and Islet never drags it, so a move we did not cause is the
  /// system relocating the window — put it back. Gated on an actual mismatch, which makes this a
  /// fixed point: a `setFrame` that lands exactly where asked posts no move, so it cannot loop.
  func reassertIfMoved() {
    guard !isApplying else { return }
    guard panel.frame != viewModel.reservedPanelFrame else {
      syncActualFrame()
      return
    }
    Log.app.notice("Panel on \(self.screenUUID, privacy: .public) moved; re-asserting its frame")
    reassert()
  }

  func updateMousePassthrough(
    at location: CGPoint = NSEvent.mouseLocation, allowingCompactFileDrag: Bool = false
  ) {
    EventMonitors.shared.setPointerPassthroughNeeded(
      viewModel.needsPointerPassthroughMonitoring, sourceID: pointerMonitoringID)
    let shouldIgnore = viewModel.shouldIgnorePanelMouseEvents(
      at: location, allowingCompactFileDrag: allowingCompactFileDrag)
    if panel.ignoresMouseEvents != shouldIgnore { panel.ignoresMouseEvents = shouldIgnore }
  }

  func stop() {
    EventMonitors.shared.setPointerPassthroughNeeded(false, sourceID: pointerMonitoringID)
    cancellables.removeAll()
    panel.close()
  }
}

/// One notch panel per active screen, keyed by display UUID. Rebuilds on display changes;
/// hides panels on screens showing a fullscreen app when that option is enabled.
@MainActor
final class ScreenManager {
  static let shared = ScreenManager()

  private var instances: [String: PanelInstance] = [:]
  private var cancellables: Set<AnyCancellable> = []
  private var fullscreenTimer: AnyCancellable?
  /// Last-known notch measurements per display, so a transient empty aux-area read can't downgrade
  /// a built-in screen to the 200pt fallback for the rest of the session.
  private var stickiness = NotchStickiness()

  /// The view model on the screen under the mouse (for menu-bar-driven actions), else any.
  var viewModel: NotchViewModel? {
    if let uuid = NSScreen.screenWithMouse?.displayUUID, let inst = instances[uuid] {
      return inst.viewModel
    }
    return instances.values.first?.viewModel
  }

  func start() {
    guard cancellables.isEmpty else { return }
    rebuild()
    NotificationCenter.default
      .publisher(for: NSApplication.didChangeScreenParametersNotification)
      .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
      .sink { [weak self] _ in self?.rebuild() }
      .store(in: &cancellables)
    // Undebounced companion to the rebuild above. A display reconfiguration can displace the window
    // straight away, and half a second of a visibly misplaced island is half a second too many;
    // harmless when the debounced rebuild later replaces the panel outright.
    NotificationCenter.default
      .publisher(for: NSApplication.didChangeScreenParametersNotification)
      .sink { [weak self] _ in self?.reassertAll() }
      .store(in: &cancellables)
    // Registered UNCONDITIONALLY, not behind `hideInFullscreen` (which defaults to false): a Space
    // switch is the most common way the panel ends up somewhere we did not put it.
    // `applyFullscreenVisibility` no-ops on its own when the option is off.
    NSWorkspace.shared.notificationCenter
      .publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
      .sink { [weak self] _ in
        self?.reassertAll()
        self?.applyFullscreenVisibility()
      }
      .store(in: &cancellables)
    NSWorkspace.shared.notificationCenter
      .publisher(for: NSWorkspace.didActivateApplicationNotification)
      .sink { [weak self] _ in self?.reassertAll() }
      .store(in: &cancellables)
    Defaults.publisher(.hideFromScreenRecording)
      .sink { [weak self] change in
        Task { @MainActor in
          if let instances = self?.instances.values {
            for instance in instances {
              instance.panel.sharingType = ScreenCaptureExclusionPolicy.current.sharingType(
                exclusionRequested: change.newValue)
            }
          }
        }
      }
      .store(in: &cancellables)
    Defaults.publisher(.showOnAllDisplays)
      .dropFirst()
      .sink { [weak self] _ in Task { @MainActor in self?.rebuild() } }
      .store(in: &cancellables)
    Defaults.publisher(.hideInFullscreen)
      .sink { [weak self] _ in Task { @MainActor in self?.updateFullscreenObserving() } }
      .store(in: &cancellables)
    updateFullscreenObserving()
  }

  func stop() {
    fullscreenTimer = nil
    cancellables.removeAll()
    for instance in instances.values { instance.stop() }
    instances.removeAll()
  }

  private func targetScreens() -> [NSScreen] {
    if Defaults[.showOnAllDisplays] { return NSScreen.screens }
    if let screen = NSScreen.builtin ?? NSScreen.main { return [screen] }
    return []
  }

  func rebuild() {
    for instance in instances.values { instance.stop() }
    instances.removeAll()

    for screen in targetScreens() {
      guard let uuid = screen.displayUUID else { continue }
      let raw = screen.notchReading
      let reading = stickiness.resolve(
        displayUUID: uuid, isBuiltin: screen.isBuiltin, reading: raw)
      if reading != raw {
        let kept =
          "safeAreaTop \(reading.safeAreaTop) aux \(reading.auxLeftWidth)/\(reading.auxRightWidth)"
        Log.app.notice(
          "Display \(uuid, privacy: .public) reported no notch; keeping \(kept, privacy: .public)")
      }
      let geometry = screen.notchGeometry(reading: reading)
      let vm = NotchViewModel(geometry: geometry)
      let panel = NotchPanel(frame: vm.reservedPanelFrame)
      let dropZoneID = UUID()
      panel.contentView = NotchHosting.view(for: vm)
      let inst = PanelInstance(screenUUID: uuid, panel: panel, viewModel: vm)
      panel.acceptsFileDrops = {
        ActivityCenter.shared.isAvailableInExpandedSwitcher("shelf")
          && !vm.shouldIgnorePanelMouseEvents(
            at: NSEvent.mouseLocation, allowingCompactFileDrag: true)
      }
      panel.fileDragTargetChanged = { [weak inst] targeted in
        ShelfModel.shared.setDropTarget(dropZoneID, active: targeted)
        if targeted { vm.apply(.fileDragEntered) }
        if !targeted { inst?.updateMousePassthrough() }
      }
      panel.fileURLsDropped = { urls in
        ShelfModel.shared.importDroppedURLs(urls)
      }
      panel.alphaValue = 0
      panel.orderFrontRegardless()
      panel.setFrame(vm.reservedPanelFrame, display: true)
      panel.sharingType = ScreenCaptureExclusionPolicy.current.sharingType(
        exclusionRequested: Defaults[.hideFromScreenRecording])

      inst.syncActualFrame()  // seed from the window we just placed, before anything is drawn
      inst.updateMousePassthrough()
      panel.alphaValue = 1  // alpha-flash hides ghost frames
      Publishers.CombineLatest4(
        vm.$state, vm.$expandedWidth, vm.$expandedHeight, vm.$actualPanelFrame
      )
      .sink { [weak inst] _ in inst?.updateMousePassthrough() }
      .store(in: &inst.cancellables)
      vm.$compactTargetRevision
        .dropFirst()
        .sink { [weak inst] _ in inst?.updateMousePassthrough() }
        .store(in: &inst.cancellables)
      EventMonitors.shared.pointerMovement
        .sink { [weak inst] location in inst?.updateMousePassthrough(at: location) }
        .store(in: &inst.cancellables)
      EventMonitors.shared.fileDragMovement
        .sink { [weak inst] location in
          inst?.updateMousePassthrough(at: location, allowingCompactFileDrag: true)
        }
        .store(in: &inst.cancellables)
      NotificationCenter.default
        .publisher(for: NSWindow.didMoveNotification, object: panel)
        .sink { [weak inst] _ in inst?.reassertIfMoved() }
        .store(in: &inst.cancellables)
      instances[uuid] = inst
    }
    Log.shell.info("Built \(self.instances.count) notch panel(s)")
    applyFullscreenVisibility()
  }

  /// Re-pushes every panel's reserved frame after a display, Space or app activation change.
  private func reassertAll() {
    for inst in instances.values { inst.reassert() }
  }

  // MARK: - Fullscreen awareness

  private func updateFullscreenObserving() {
    if Defaults[.hideInFullscreen] {
      // Fullscreen enter/exit moves the active Space, and that observer is now registered
      // unconditionally in `start()`. All that is left here is a slow safety poll, instead of
      // scanning every window once a second.
      fullscreenTimer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()
        .sink { [weak self] _ in self?.applyFullscreenVisibility() }
      applyFullscreenVisibility()
    } else {
      fullscreenTimer = nil
      // Restore any panel we hid.
      for instance in instances.values where !instance.panel.isVisible {
        instance.panel.orderFrontRegardless()
      }
    }
  }

  private func applyFullscreenVisibility() {
    guard Defaults[.hideInFullscreen] else { return }
    let fullscreenDisplays = FullscreenDetector.fullscreenDisplayUUIDs()
    for inst in instances.values {
      let hidden = fullscreenDisplays.contains(inst.screenUUID)
      // orderOut (not alpha 0) so the hidden panel's SwiftUI tree stops rendering entirely.
      if hidden, inst.panel.isVisible {
        inst.panel.orderOut(nil)
      } else if !hidden, !inst.panel.isVisible {
        inst.panel.orderFrontRegardless()
      }
    }
  }
}
