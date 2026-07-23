import AppKit
import SwiftUI

/// Opens Islet's settings in an AppKit-managed window. This is reliable from anywhere (the notch
/// panel, the menu bar) — unlike `showSettingsWindow:`, which doesn't route in an accessory app
/// that has no key window.
@MainActor
enum SettingsOpener {
  private static var window: NSWindow?

  static func open() {
    NSApp.activate(ignoringOtherApps: true)
    if let window {
      window.makeKeyAndOrderFront(nil)
      return
    }
    let hosting = NSHostingController(rootView: SettingsView())
    let win = NSWindow(contentViewController: hosting)
    win.title = "Islet Settings"
    win.styleMask = [.titled, .closable, .miniaturizable]
    win.isReleasedWhenClosed = false
    win.center()
    win.makeKeyAndOrderFront(nil)
    window = win
  }
}
