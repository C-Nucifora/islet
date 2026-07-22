import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    Task { @MainActor in
      EventMonitors.shared.start()
      ScreenManager.shared.start()
      ActivityCenter.shared.register(AppState.demoActivity)
      AppState.nowPlaying.start()
      ActivityCenter.shared.register(AppState.nowPlaying)
    }
    Log.app.info("Islet launched")
  }
}
