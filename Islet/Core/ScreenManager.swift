import AppKit
import Combine
import Defaults
import SwiftUI

/// One notch panel per active screen, keyed by display UUID. Rebuilds on display changes;
/// hides panels on screens showing a fullscreen app when that option is enabled.
@MainActor
final class ScreenManager {
  static let shared = ScreenManager()

  private struct Instance {
    let screenUUID: String
    let panel: NotchPanel
    let viewModel: NotchViewModel
  }

  private var instances: [String: Instance] = [:]
  private var cancellables: Set<AnyCancellable> = []
  private var fullscreenTimer: AnyCancellable?
  private var fullscreenCancellables: Set<AnyCancellable> = []

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
      let geometry = screen.notchGeometry
      let vm = NotchViewModel(geometry: geometry)
      let panel = NotchPanel(frame: geometry.panelFrame)
      panel.contentView = NSHostingView(rootView: NotchRootView(vm: vm))
      panel.alphaValue = 0
      panel.orderFrontRegardless()
      panel.setFrame(geometry.panelFrame, display: true)
      panel.alphaValue = 1  // alpha-flash hides ghost frames
      panel.sharingType = Defaults[.hideFromScreenRecording] ? .none : .readOnly
      instances[uuid] = Instance(screenUUID: uuid, panel: panel, viewModel: vm)
    }
    Log.shell.info("Built \(self.instances.count) notch panel(s)")
    applyFullscreenVisibility()
  }

  // MARK: - Fullscreen awareness

  private func updateFullscreenObserving() {
    if Defaults[.hideInFullscreen] {
      // Fullscreen enter/exit moves the active Space, so react to that (near-instant, cheap) and
      // keep only a slow safety poll instead of scanning every window once a second.
      NSWorkspace.shared.notificationCenter
        .publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
        .sink { [weak self] _ in self?.applyFullscreenVisibility() }
        .store(in: &fullscreenCancellables)
      fullscreenTimer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()
        .sink { [weak self] _ in self?.applyFullscreenVisibility() }
      applyFullscreenVisibility()
    } else {
      fullscreenTimer = nil
      fullscreenCancellables.removeAll()
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
