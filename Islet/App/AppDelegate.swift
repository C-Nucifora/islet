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
      AppState.battery.start()
      ActivityCenter.shared.register(AppState.battery)
      SneakQueue.shared.isSuspended = {
        ScreenManager.shared.viewModel?.state.isExpanded ?? false
      }
      HUDController.shared.startObserving()
    }
    // The HUD tap needs Accessibility; if the grant lands while running, start it on reactivation.
    NotificationCenter.default.addObserver(
      forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
    ) { _ in
      MainActor.assumeIsolated { HUDController.shared.start() }
    }
    Log.app.info("Islet launched")
  }
}
