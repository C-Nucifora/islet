import AppKit
import Defaults

final class AppDelegate: NSObject, NSApplicationDelegate {
  private var launchAtLoginObserver: Defaults.Observation?
  private var didBecomeActiveObserver: NSObjectProtocol?

  /// True when the app is running only as XCTest's host process. Every monitor below talks to real
  /// hardware — CoreWLAN, IOBluetooth, Spotlight, the Downloads folder — and several of them prompt
  /// for a permission, which hangs a test runner that has no one to answer the dialog. Unit tests
  /// drive the pure logic directly and need none of it running.
  private var isRunningTests: Bool {
    NSClassFromString("XCTestCase") != nil
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    guard !isRunningTests else {
      Log.app.info("Launched as a test host; skipping monitor startup")
      return
    }
    Task { @MainActor in
      // Bring a persisted activity order forward before anything renders from it: entries added to
      // the catalogue after the order was first written would otherwise be missing from Settings.
      let merged = ActivityCatalog.mergedOrder(Defaults[.activityOrder])
      if merged != Defaults[.activityOrder] { Defaults[.activityOrder] = merged }
      EventMonitors.shared.start()
      ScreenManager.shared.start()
      ActivityCenter.shared.register(AppState.demoActivity)
      AppState.nowPlaying.start()
      ActivityCenter.shared.register(AppState.nowPlaying)
      AppState.battery.start()
      ActivityCenter.shared.register(AppState.battery)
      AppState.calendar.start()
      ActivityCenter.shared.register(AppState.calendar)
      ActivityCenter.shared.register(AppState.timer)
      AppState.shelf.start()
      ActivityCenter.shared.register(AppState.shelf)
      AppState.clipboard.start()
      ActivityCenter.shared.register(AppState.clipboard)
      AppState.ports.start()
      ActivityCenter.shared.register(AppState.ports)
      AppState.system.start()
      ActivityCenter.shared.register(AppState.system)
      RemindersProvider.shared.start()
      AudioDeviceMonitor.shared.start()
      AppState.eventSources.forEach { SystemEventBus.shared.register($0) }
      SystemEventBus.shared.startEnabled()
      SneakQueue.shared.isSuspended = {
        ScreenManager.shared.viewModel?.state.isExpanded ?? false
      }
      HUDController.shared.startObserving()
      LaunchAtLogin.sync()
      launchAtLoginObserver = Defaults.observe(.launchAtLogin) { change in
        Task { @MainActor in LaunchAtLogin.apply(change.newValue) }
      }
    }
    // The HUD tap needs Accessibility; if the grant lands while running, start it on reactivation.
    didBecomeActiveObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
    ) { _ in
      MainActor.assumeIsolated { HUDController.shared.start() }
    }
    Log.app.info("Islet launched")
  }
}
