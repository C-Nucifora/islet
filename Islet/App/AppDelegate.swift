import AppKit
import Combine
import Defaults

enum ActivityLifecyclePolicy {
  static func shouldRun(
    activityID: String, featureEnabled: Bool = true, disabledActivities: Set<String>
  ) -> Bool {
    featureEnabled && !disabledActivities.contains(activityID)
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
    Defaults.publisher(.disabledActivities)
      .sink { [weak self] _ in self?.reconcileActivityLifecycles() }
      .store(in: &activityLifecycleCancellables)
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
    Defaults.publisher(.disabledEventSources)
      .sink { [weak self] _ in self?.reconcileActivityLifecycles() }
      .store(in: &activityLifecycleCancellables)
    reconcileActivityLifecycles()
  }

  @MainActor
  private func reconcileActivityLifecycles() {
    let disabled = Set(Defaults[.disabledActivities])

    if ActivityLifecyclePolicy.shouldRun(
      activityID: AppState.nowPlaying.id, disabledActivities: disabled)
    {
      AppState.nowPlaying.start()
    } else {
      AppState.nowPlaying.stop()
    }
    if ActivityLifecyclePolicy.shouldRun(
      activityID: AppState.battery.id, featureEnabled: Defaults[.batteryEnabled],
      disabledActivities: disabled)
    {
      AppState.battery.start()
    } else {
      AppState.battery.stop()
    }
    if ActivityLifecyclePolicy.shouldRun(
      activityID: AppState.calendar.id, featureEnabled: Defaults[.calendarEnabled],
      disabledActivities: disabled)
    {
      AppState.calendar.start()
    } else {
      AppState.calendar.stop()
    }
    if ActivityLifecyclePolicy.shouldRun(
      activityID: AppState.ports.id, featureEnabled: Defaults[.portsEnabled],
      disabledActivities: disabled)
    {
      AppState.ports.start()
    } else {
      AppState.ports.stop()
    }
    if ActivityLifecyclePolicy.shouldRun(
      activityID: AppState.clipboard.id, featureEnabled: Defaults[.clipboardEnabled],
      disabledActivities: disabled)
    {
      AppState.clipboard.start()
    } else {
      AppState.clipboard.stop()
    }
    if ActivityLifecyclePolicy.shouldRun(
      activityID: AppState.system.id, featureEnabled: Defaults[.systemEnabled],
      disabledActivities: disabled)
    {
      AppState.system.start()
    } else {
      AppState.system.stop()
    }
    if ActivityLifecyclePolicy.shouldRun(
      activityID: AppState.t3Code.id, featureEnabled: Defaults[.t3CodeEnabled],
      disabledActivities: disabled)
    {
      AppState.t3Code.start()
    } else {
      AppState.t3Code.stop()
    }
    if ActivityLifecyclePolicy.shouldRun(
      activityID: AppState.pulse.id, featureEnabled: Defaults[.pulseEnabled],
      disabledActivities: disabled)
    {
      AppState.pulse.start()
    } else {
      AppState.pulse.stop()
    }
    let audioDeviceEventsEnabled = !Defaults[.disabledEventSources].contains("audiodevice")
    if audioDeviceEventsEnabled {
      AudioDeviceMonitor.shared.start()
    } else {
      AudioDeviceMonitor.shared.stop()
    }
  }
}
