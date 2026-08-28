import AppKit
import Combine
import Defaults

enum ActivityLifecyclePolicy {
  /// Activity lineup visibility is presentation state. Providers stop only when their actual
  /// feature switch is disabled, so hiding Calendar cannot empty the Home agenda (and hiding any
  /// other activity cannot silently shut down a shared monitor).
  static func shouldRun(featureEnabled: Bool = true) -> Bool { featureEnabled }
  /// Clipboard polling and the Pulse listener retain or accept user/provider data solely for their
  /// corresponding activities. Their lineup toggles are therefore also their privacy switches.
  /// Shared providers such as Calendar stay independent because Home still consumes their data.
  static func stopsFeatureWhenHidden(_ activityID: String) -> Bool {
    activityID == "clipboard" || activityID == "pulse"
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  private var launchAtLoginObserver: Defaults.Observation?
  private var activityLifecycleCancellables: Set<AnyCancellable> = []

  /// True when the app is running only as XCTest's host process. Every monitor below talks to real
  /// hardware — CoreWLAN, IOBluetooth, Spotlight, the Downloads folder — and several of them prompt
  /// for a permission, which hangs a test runner that has no one to answer the dialog. Unit tests
  /// drive the pure logic directly and need none of it running.
  private var isRunningTests: Bool {
    NSClassFromString("XCTestCase") != nil
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    // An uncaught NSException thrown inside AppKit's display cycle aborts the app with a crash
    // report that carries the unwound stack but NOT the reason. Log both before dying, so the
    // next "it crashed when I clicked X" comes with the exception text attached.
    NSSetUncaughtExceptionHandler { exception in
      Log.app.fault(
        "Uncaught \(exception.name.rawValue, privacy: .public): \(exception.reason ?? "no reason", privacy: .public)\n\(exception.callStackSymbols.joined(separator: "\n"), privacy: .public)"
      )
    }
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
      ActivityCenter.shared.register(AppState.nowPlaying)
      ActivityCenter.shared.register(AppState.battery)
      ActivityCenter.shared.register(AppState.calendar)
      ActivityCenter.shared.register(AppState.timer)
      AppState.shelf.start()
      ActivityCenter.shared.register(AppState.shelf)
      ActivityCenter.shared.register(AppState.clipboard)
      ActivityCenter.shared.register(AppState.ports)
      ActivityCenter.shared.register(AppState.system)
      ActivityCenter.shared.register(AppState.t3Code)
      ActivityCenter.shared.register(AppState.pulse)
      ActivityCenter.shared.register(AppState.continuity)
      #if DEBUG
        let registeredIDs = Set(ActivityCenter.shared.activities.map(\.id))
        let missingIDs = Set(ActivityCatalog.defaultOrder).subtracting(registeredIDs)
        assert(
          missingIDs.isEmpty,
          "ActivityCatalog entries are not registered in AppDelegate: \(missingIDs.sorted())")
      #endif
      configureActivityLifecycles()
      RemindersProvider.shared.start()
      for source in AppState.eventSources { SystemEventBus.shared.register(source) }
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
    Log.app.info("Islet launched")
  }

  func applicationWillTerminate(_ notification: Notification) {
    guard !isRunningTests else { return }
    // AppKit invokes this delegate on the main thread. Media shutdown is intentionally synchronous:
    // otherwise the app can exit before the watcher's serial queue terminates its helper process.
    MainActor.assumeIsolated {
      AppState.nowPlaying.stop()
      AppState.battery.stop()
      AppState.calendar.stop()
      AppState.clipboard.stop()
      AppState.ports.stop()
      AppState.system.stop()
      AppState.t3Code.stop()
      AppState.pulse.stop()
      AppState.continuity.stop()
      RemindersProvider.shared.stop()
      AudioDeviceMonitor.shared.stop()
      HUDController.shared.stop()
      SystemEventBus.shared.stopAll()
      EventMonitors.shared.stop()
      ScreenManager.shared.stop()
      activityLifecycleCancellables.removeAll()
    }
    launchAtLoginObserver = nil
  }

  @MainActor
  private func configureActivityLifecycles() {
    // Builds that shipped the combined lineup toggle could persist "hidden" while leaving these
    // privacy-sensitive providers enabled. Honour that existing user choice before starting them.
    let hiddenActivities = Set(Defaults[.disabledActivities])
    if hiddenActivities.contains("clipboard") { Defaults[.clipboardEnabled] = false }
    if hiddenActivities.contains("pulse") { Defaults[.pulseEnabled] = false }

    Defaults.publisher(.batteryEnabled)
      .sink { [weak self] _ in self?.reconcileActivityLifecycles() }
      .store(in: &activityLifecycleCancellables)
    Defaults.publisher(.calendarEnabled)
      .sink { [weak self] _ in self?.reconcileActivityLifecycles() }
      .store(in: &activityLifecycleCancellables)
    Defaults.publisher(.portsEnabled)
      .sink { [weak self] _ in self?.reconcileActivityLifecycles() }
      .store(in: &activityLifecycleCancellables)
    Defaults.publisher(.clipboardEnabled)
      .sink { [weak self] _ in self?.reconcileActivityLifecycles() }
      .store(in: &activityLifecycleCancellables)
    Defaults.publisher(.systemEnabled)
      .sink { [weak self] _ in self?.reconcileActivityLifecycles() }
      .store(in: &activityLifecycleCancellables)
    Defaults.publisher(.t3CodeEnabled)
      .sink { [weak self] _ in self?.reconcileActivityLifecycles() }
      .store(in: &activityLifecycleCancellables)
    Defaults.publisher(.pulseEnabled)
      .sink { [weak self] _ in self?.reconcileActivityLifecycles() }
      .store(in: &activityLifecycleCancellables)
    Defaults.publisher(.continuityEnabled)
      .sink { [weak self] _ in self?.reconcileActivityLifecycles() }
      .store(in: &activityLifecycleCancellables)
    Defaults.publisher(.disabledEventSources)
      .sink { [weak self] _ in self?.reconcileActivityLifecycles() }
      .store(in: &activityLifecycleCancellables)
    reconcileActivityLifecycles()
  }

  @MainActor
  private func reconcileActivityLifecycles() {
    if ActivityLifecyclePolicy.shouldRun() {
      AppState.nowPlaying.start()
    } else {
      AppState.nowPlaying.stop()
    }
    if ActivityLifecyclePolicy.shouldRun(featureEnabled: Defaults[.batteryEnabled]) {
      AppState.battery.start()
    } else {
      AppState.battery.stop()
    }
    if ActivityLifecyclePolicy.shouldRun(featureEnabled: Defaults[.calendarEnabled]) {
      AppState.calendar.start()
    } else {
      AppState.calendar.stop()
    }
    if ActivityLifecyclePolicy.shouldRun(featureEnabled: Defaults[.portsEnabled]) {
      AppState.ports.start()
    } else {
      AppState.ports.stop()
    }
    if ActivityLifecyclePolicy.shouldRun(featureEnabled: Defaults[.clipboardEnabled]) {
      AppState.clipboard.start()
    } else {
      AppState.clipboard.stop()
    }
    if ActivityLifecyclePolicy.shouldRun(featureEnabled: Defaults[.systemEnabled]) {
      AppState.system.start()
    } else {
      AppState.system.stop()
    }
    if ActivityLifecyclePolicy.shouldRun(featureEnabled: Defaults[.t3CodeEnabled]) {
      AppState.t3Code.start()
    } else {
      AppState.t3Code.stop()
    }
    if ActivityLifecyclePolicy.shouldRun(featureEnabled: Defaults[.pulseEnabled]) {
      AppState.pulse.start()
    } else {
      AppState.pulse.stop()
    }
    if ActivityLifecyclePolicy.shouldRun(featureEnabled: Defaults[.continuityEnabled]) {
      AppState.continuity.start()
    } else {
      AppState.continuity.stop()
    }
    let audioDeviceEventsEnabled = !Defaults[.disabledEventSources].contains("audiodevice")
    if audioDeviceEventsEnabled {
      AudioDeviceMonitor.shared.start()
    } else {
      AudioDeviceMonitor.shared.stop()
    }
  }
}
