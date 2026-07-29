import AppKit
import Combine
import Defaults
import SwiftUI

/// One notch panel plus the frame plumbing that keeps its window where the model says it should be.
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

  init(screenUUID: String, panel: NotchPanel, viewModel: NotchViewModel) {
    self.screenUUID = screenUUID
    self.panel = panel
    self.viewModel = viewModel
  }

  /// The single place a notch panel's frame is ever set.
  ///
  /// The window's real frame is read straight back and pushed into the model. `NotchPanel` now
  /// returns `constrainFrameRect` unchanged so the two should always agree, but "should" is not
  /// "does": the island is drawn centred in the REAL window, so any divergence lands 1:1 on the
  /// drawn island, and a divergence nobody measures is a drift nobody can explain.
  ///
  /// `display: false` — the view reports its slot widths from inside a SwiftUI update, so this can
  /// run mid-layout, and forcing a synchronous display pass there re-enters layout.
  func apply(_ frame: CGRect) {
    guard !isApplying else { return }
    isApplying = true
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

  /// Unconditional re-push of the model's frame, deliberately bypassing the `removeDuplicates` on
  /// `$panelFrame`: republishing an unchanged value emits nothing, so a window the system moved
  /// behind our back would otherwise never be corrected. `targetPanelFrame` also returns the same
  /// value for `.closed` and `.peek`, so hovering the notch republishes nothing either — a drift
  /// used to survive every hover and clear only on a real expand.
  func reassert() { apply(viewModel.panelFrame) }

  /// The panel is `isMovable = false` and Islet never drags it, so a move we did not cause is the
  /// system relocating the window — put it back. Gated on an actual mismatch, which makes this a
  /// fixed point: a `setFrame` that lands exactly where asked posts no move, so it cannot loop.
  func reassertIfMoved() {
    guard !isApplying else { return }
    guard panel.frame != viewModel.panelFrame else {
      syncActualFrame()
      return
    }
    Log.app.notice("Panel on \(self.screenUUID, privacy: .public) moved; re-asserting its frame")
    reassert()
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
          self?.instances.values.forEach {
            $0.panel.sharingType = change.newValue ? .none : .readOnly
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

  private func targetScreens() -> [NSScreen] {
    if Defaults[.showOnAllDisplays] { return NSScreen.screens }
    if let screen = NSScreen.builtin ?? NSScreen.main { return [screen] }
    return []
  }

  func rebuild() {
    instances.values.forEach { $0.panel.close() }
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
      let panel = NotchPanel(frame: vm.panelFrame)
      panel.contentView = NSHostingView(rootView: NotchRootView(vm: vm))
      panel.alphaValue = 0
      panel.orderFrontRegardless()
      panel.setFrame(vm.panelFrame, display: true)
      panel.alphaValue = 1  // alpha-flash hides ghost frames
      panel.sharingType = Defaults[.hideFromScreenRecording] ? .none : .readOnly

      let inst = PanelInstance(screenUUID: uuid, panel: panel, viewModel: vm)
      inst.syncActualFrame()  // seed from the window we just placed, before anything is drawn
      // The panel only claims the space the island actually occupies, so the rest of the menu bar
      // stays clickable; it grows on expand and back down on collapse.
      vm.$panelFrame
        .removeDuplicates()
        .sink { [weak inst] frame in inst?.apply(frame) }
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

  /// Re-pushes every panel's frame. See `PanelInstance.reassert()` for why this cannot go through
  /// the `$panelFrame` publisher.
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
      instances.values.forEach { if !$0.panel.isVisible { $0.panel.orderFrontRegardless() } }
    }
  }

  private func applyFullscreenVisibility() {
    guard Defaults[.hideInFullscreen] else { return }
    for inst in instances.values {
      guard let screen = NSScreen.screens.first(where: { $0.displayUUID == inst.screenUUID })
      else { continue }
      let hidden = FullscreenDetector.hasFullscreenWindow(on: screen)
      // orderOut (not alpha 0) so the hidden panel's SwiftUI tree stops rendering entirely.
      if hidden, inst.panel.isVisible {
        inst.panel.orderOut(nil)
      } else if !hidden, !inst.panel.isVisible {
        inst.panel.orderFrontRegardless()
      }
    }
  }
}
