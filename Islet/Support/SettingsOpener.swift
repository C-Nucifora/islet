import AppKit
import SwiftUI

enum SettingsDestination: String, Sendable {
  case overview
  case activities
  case events
  case appearance
  case permissions
  case integrations
  case pulse
  case advanced
}

extension Notification.Name {
  static let isletSettingsDestination = Notification.Name("IsletSettingsDestination")
  static let isletSettingsPage = Notification.Name("IsletSettingsPage")
}

/// Opens Islet's settings in an AppKit-managed window. This is reliable from anywhere (the notch
/// panel, the menu bar) — unlike `showSettingsWindow:`, which doesn't route in an accessory app
/// that has no key window.
@MainActor
enum SettingsOpener {
  private static var window: NSWindow?

  static func open(destination: SettingsDestination? = nil) {
    NSApp.activate(ignoringOtherApps: true)
    if let window {
      window.makeKeyAndOrderFront(nil)
      if let destination {
        NotificationCenter.default.post(
          name: .isletSettingsDestination, object: destination.rawValue)
      }
      return
    }
    createWindow(rootView: SettingsView(destination: destination ?? .overview))
  }

  static func open(page: SettingsDetailPage) {
    NSApp.activate(ignoringOtherApps: true)
    if let window {
      window.makeKeyAndOrderFront(nil)
      NotificationCenter.default.post(name: .isletSettingsPage, object: page.rawValue)
      return
    }
    createWindow(rootView: SettingsView(page: page))
  }

  private static func createWindow(rootView: SettingsView) {
    let hosting = NSHostingController(rootView: rootView)
    let win = NSWindow(contentViewController: hosting)
    win.title = String(localized: "Settings")
    win.styleMask = [.titled, .closable, .resizable]
    win.setContentSize(NSSize(width: 860, height: 650))
    win.contentMinSize = NSSize(width: 760, height: 560)
    win.setFrameAutosaveName("IsletSettingsWindow")
    win.isReleasedWhenClosed = false
    if !win.setFrameUsingName("IsletSettingsWindow") { win.center() }
    win.makeKeyAndOrderFront(nil)
    win.standardWindowButton(.miniaturizeButton)?.isEnabled = false
    win.standardWindowButton(.zoomButton)?.isEnabled = false
    window = win
  }

  static func setTitle(_ title: String) {
    window?.title = title
  }
}
