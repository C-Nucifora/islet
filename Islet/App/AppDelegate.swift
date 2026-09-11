import AppKit
import Combine
import Defaults

enum ActivityLifecyclePolicy {
  static func shouldRun(
    activityID: String, disabledActivities: [String], additionalRuntimeDemand: Bool = false
  ) -> Bool {
    ActivityEnablement.isEnabled(activityID, disabledActivities: disabledActivities)
      || additionalRuntimeDemand
  }
}

@MainActor
struct ActivityLifecycleControl {
  let activityID: String
  var additionalRuntimeDemand: () -> Bool = { false }
  let start: () -> Void
  let stop: () -> Void
}

/// Applies the canonical activity switch to every observer and server while the app is running.
/// Calendar can add provider demand because Home also reads it when the Calendar activity is off.
@MainActor
final class ActivityLifecycleController {
  private let controls: [ActivityLifecycleControl]
  private var cancellables: Set<AnyCancellable> = []

  init(controls: [ActivityLifecycleControl]) {
    self.controls = controls
  }

  func startObserving() {
    guard cancellables.isEmpty else { return }
    Defaults.publisher(.disabledActivities)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in self?.reconcile() }
      .store(in: &cancellables)
    Defaults.publisher(.calendarEnabled)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in self?.reconcile() }
      .store(in: &cancellables)
    NotificationCenter.default.publisher(for: .keepAwakeSessionDidChange)
      .sink { [weak self] _ in Task { @MainActor in self?.reconcile() } }
      .store(in: &cancellables)
    reconcile()
  }

  func stopObserving() {
    cancellables.removeAll()
  }

  func reconcile() {
    let disabledActivities = Defaults[.disabledActivities]
    for control in controls {
      if ActivityLifecyclePolicy.shouldRun(
        activityID: control.activityID, disabledActivities: disabledActivities,
        additionalRuntimeDemand: control.additionalRuntimeDemand())
      {
        control.start()
      } else {
        control.stop()
      }
    }
  }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private var launchAtLoginObserver: AnyCancellable?
  private var activityLifecycleController: ActivityLifecycleController?
  private var audioDeviceLifecycleCancellable: AnyCancellable?
  private let reminderCommandHotKey = ReminderCommandHotKey.shared
  /// Kept by the delegate for the entire app lifetime so notification responses still reach the
  /// timer when Islet has no normal application window.
  private let timerCompletionNotifications = TimerCompletionNotifications.shared
  private var singleInstanceCoordinator: SingleInstanceCoordinator?
  private var shouldStartServices = false

  /// True when the app is running only as XCTest's host process. Every monitor below talks to real
  /// hardware — CoreWLAN, IOBluetooth, Spotlight, the Downloads folder — and several of them prompt
  /// for a permission, which hangs a test runner that has no one to answer the dialog. Unit tests
  /// drive the pure logic directly and need none of it running.
  private var isRunningTests: Bool {
    NSClassFromString("XCTestCase") != nil
  }

  func applicationWillFinishLaunching(_ notification: Notification) {
    guard !isRunningTests else { return }

    let owner = SingleInstanceOwner.current()
    do {
      let coordinator = try SingleInstanceCoordinator(bundleIdentifier: owner.bundleIdentifier)
      let resolution = try SingleInstanceLaunchResolver.resolve(
        coordinator: coordinator,
        owner: owner,
        activate: {
          ExistingInstanceActivator.activate(
            owner: $0, bundleIdentifier: owner.bundleIdentifier)
        })
      switch resolution {
      case .primary:
        singleInstanceCoordinator = coordinator
        shouldStartServices = true
      case .activatedExisting:
        Log.app.info("Activated the existing Islet process")
      case .secondaryStillOwned:
        Log.app.warning("Another Islet process owns the instance lock but is not yet activatable")
      }
    } catch {
      // A lock setup failure should not make a single installed copy unusable. Fall back to the
      // process list, which catches normal duplicate launches even though it cannot close a race.
      if ExistingInstanceActivator.activate(
        owner: nil,
        bundleIdentifier: owner.bundleIdentifier)
      {
        Log.app.warning("Instance lock failed; activated an existing Islet process: \(error)")
      } else {
        shouldStartServices = true
        Log.app.error("Instance lock failed; continuing without race protection: \(error)")
      }
    }
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
    guard shouldStartServices else {
      NSApp.terminate(nil)
      return
    }
    reminderCommandHotKey.start()
    timerCompletionNotifications.start()
    Task { @MainActor in
      ActivityEnablement.migrateLegacyPreferencesIfNeeded()
      AppUpdateController.shared.start()
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
      ActivityCenter.shared.register(AppState.shelf)
      ActivityCenter.shared.register(AppState.clipboard)
      ActivityCenter.shared.register(AppState.ports)
      ActivityCenter.shared.register(AppState.system)
      ActivityCenter.shared.register(AppState.t3Code)
      ActivityCenter.shared.register(AppState.pulse)
      ActivityCenter.shared.register(AppState.continuity)
      await AppState.t3Code.loadConnectAccount()
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
      if OnboardingState.isComplete { SystemEventBus.shared.startEnabled() }
      ContextRuleCenter.shared.start()
      SneakQueue.shared.isSuspended = {
        ScreenManager.shared.isAnyPanelExpanded
      }
      HUDController.shared.startObserving()
      LaunchAtLogin.sync()
      GlobalShortcutManager.shared.start()
      launchAtLoginObserver = LaunchAtLogin.observe()
      OnboardingOpener.openIfNeeded()
    }
    Log.app.info("Islet launched")
  }

  func applicationDidBecomeActive(_ notification: Notification) {
    guard !isRunningTests else { return }
    reminderCommandHotKey.start()
  }

  func applicationWillTerminate(_ notification: Notification) {
    guard !isRunningTests, shouldStartServices else { return }
    // AppKit invokes this delegate on the main thread. Media shutdown is intentionally synchronous:
    // otherwise the app can exit before the watcher's serial queue terminates its helper process.
    MainActor.assumeIsolated {
      reminderCommandHotKey.stop()
      KeepAwakeManager.shared.stop(reason: .quit)
      PulseCenter.shared.flushRevisionPersistence()
      AppState.nowPlaying.stop()
      AppState.battery.stop()
      AppState.calendar.stop()
      AppState.shelf.stop()
      AppState.clipboard.stop()
      AppState.ports.stop()
      AppState.system.stop()
      AppState.t3Code.stop()
      AppState.pulse.stop()
      PulseCenter.shared.flushHistoryPersistence()
      AppState.continuity.stop()
      RemindersProvider.shared.stop()
      AudioDeviceMonitor.shared.stop()
      HUDController.shared.stop()
      SystemEventBus.shared.stopAll()
      EventSourcePreferences.shared.flush()
      ContextRuleCenter.shared.stop()
      EventMonitors.shared.stop()
      ScreenManager.shared.stop()
      GlobalShortcutManager.shared.stop()
      activityLifecycleController?.stopObserving()
      activityLifecycleController = nil
      audioDeviceLifecycleCancellable = nil
    }
    launchAtLoginObserver = nil
  }

  @MainActor
  private func configureActivityLifecycles() {
    let controller = ActivityLifecycleController(controls: [
      ActivityLifecycleControl(
        activityID: "nowPlaying", start: { AppState.nowPlaying.start() },
        stop: { AppState.nowPlaying.stop() }),
      ActivityLifecycleControl(
        activityID: "battery", additionalRuntimeDemand: { KeepAwakeManager.shared.isActive },
        start: { AppState.battery.start() },
        stop: { AppState.battery.stop() }),
      ActivityLifecycleControl(
        activityID: "calendar", additionalRuntimeDemand: { Defaults[.calendarEnabled] },
        start: { AppState.calendar.start() }, stop: { AppState.calendar.stop() }),
      ActivityLifecycleControl(
        activityID: "shelf", start: { AppState.shelf.start() },
        stop: { AppState.shelf.stop() }),
      ActivityLifecycleControl(
        activityID: "ports", start: { AppState.ports.start() },
        stop: { AppState.ports.stop() }),
      ActivityLifecycleControl(
        activityID: "clipboard", start: { AppState.clipboard.start() },
        stop: { AppState.clipboard.stop() }),
      ActivityLifecycleControl(
        activityID: "system", start: { AppState.system.start() },
        stop: { AppState.system.stop() }),
      ActivityLifecycleControl(
        activityID: "t3Code", start: { AppState.t3Code.start() },
        stop: { AppState.t3Code.stop() }),
      ActivityLifecycleControl(
        activityID: "pulse", start: { AppState.pulse.start() },
        stop: { AppState.pulse.stop() }),
      ActivityLifecycleControl(
        activityID: "continuity", start: { AppState.continuity.start() },
        stop: { AppState.continuity.stop() }),
    ])
    activityLifecycleController = controller
    controller.startObserving()
    audioDeviceLifecycleCancellable = EventSourcePreferences.shared.$disabledSourceIDs
      .sink { [weak self] _ in Task { @MainActor in self?.reconcileAudioDeviceLifecycle() } }
    reconcileAudioDeviceLifecycle()
  }

  @MainActor
  private func reconcileAudioDeviceLifecycle() {
    if !EventSourcePreferences.shared.isEnabled("audiodevice") {
      AudioDeviceMonitor.shared.stop()
    } else {
      AudioDeviceMonitor.shared.start()
    }
  }
}
