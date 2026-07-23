import AppKit

/// Opens the SwiftUI Settings window from anywhere (e.g. a button inside the notch panel),
/// activating the accessory app so the window comes to the front.
@MainActor
enum SettingsOpener {
  static func open() {
    NSApp.activate(ignoringOtherApps: true)
    // The selector name changed in macOS 13; 14+ uses showSettingsWindow:.
    let selector =
      NSApp.responds(to: Selector(("showSettingsWindow:")))
      ? Selector(("showSettingsWindow:"))
      : Selector(("showPreferencesWindow:"))
    NSApp.sendAction(selector, to: nil, from: nil)
  }
}
