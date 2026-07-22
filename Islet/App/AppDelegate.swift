import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    Task { @MainActor in
      EventMonitors.shared.start()
      ScreenManager.shared.start()
    }
    Log.app.info("Islet launched")
  }
}
