import AppKit
import Combine
import Defaults
import SwiftUI

@MainActor
final class ScreenManager {
  static let shared = ScreenManager()
  private(set) var panel: NotchPanel?
  private(set) var viewModel: NotchViewModel?
  private var cancellables: Set<AnyCancellable> = []

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
          self?.panel?.sharingType = change.newValue ? .none : .readOnly
        }
      }
      .store(in: &cancellables)
  }

  func rebuild() {
    panel?.close()
    panel = nil
    viewModel = nil

    guard let screen = NSScreen.builtin ?? NSScreen.main else {
      Log.shell.error("No screen available")
      return
    }
    let geometry = screen.notchGeometry
    let vm = NotchViewModel(geometry: geometry)
    let p = NotchPanel(frame: geometry.panelFrame)
    p.contentView = NSHostingView(rootView: NotchRootView(vm: vm))
    p.alphaValue = 0
    p.orderFrontRegardless()
    p.setFrame(geometry.panelFrame, display: true)
    p.alphaValue = 1  // alpha-flash hides ghost frames
    p.sharingType = Defaults[.hideFromScreenRecording] ? .none : .readOnly
    panel = p
    viewModel = vm
    Log.shell.info("Notch panel built: notch \(String(describing: geometry.notchSize))")
  }
}
