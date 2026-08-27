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
    win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
    win.setContentSize(NSSize(width: 860, height: 650))
    win.contentMinSize = NSSize(width: 760, height: 560)
    win.setFrameAutosaveName("IsletSettingsWindow")
    win.isReleasedWhenClosed = false
    if !win.setFrameUsingName("IsletSettingsWindow") { win.center() }
    win.makeKeyAndOrderFront(nil)
    window = win
  }
}
