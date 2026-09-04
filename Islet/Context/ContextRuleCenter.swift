import AppKit
import Combine
import CoreWLAN
import Defaults
import Foundation
import IOKit.ps

@MainActor
final class ContextRuleCenter: ObservableObject {
  static let shared = ContextRuleCenter()

  @Published private(set) var rules: [ContextRule]
  @Published private(set) var snapshot = ContextSnapshot()
  @Published private(set) var resolution = ContextRuleResolution.none

  /// Unlike `@Published`, this emits after `resolution` has been assigned. Subscribers that
  /// rebuild policy by reading the center therefore cannot observe the previous rule result.
  var resolutionChanges: AnyPublisher<ContextRuleResolution, Never> {
    resolutionChangesSubject.eraseToAnyPublisher()
  }

  private var runtime = ContextRuleRuntime()
  private let resolutionChangesSubject = PassthroughSubject<ContextRuleResolution, Never>()
  private var cancellables: Set<AnyCancellable> = []
  private var timer: AnyCancellable?
  private var overrideExpiryTask: Task<Void, Never>?
  private var powerSource: CFRunLoopSource?
  private var running = false

  init(rules: [ContextRule]? = nil) {
    self.rules = Self.validated(rules ?? Defaults[.contextRules])
  }

  var manualOverride: ContextManualOverride? { Defaults[.contextManualOverride] }

  func start() {
    guard !running else { return }
    running = true

    Defaults.publisher(.contextRules)
      .dropFirst()
      .sink { [weak self] change in
        guard let self else { return }
        self.rules = Self.validated(change.newValue)
        self.updatePolling()
        self.refresh()
      }
      .store(in: &cancellables)
    Defaults.publisher(.contextManualOverride)
      .dropFirst()
      .sink { [weak self] _ in self?.refresh() }
      .store(in: &cancellables)

    let workspace = NSWorkspace.shared.notificationCenter
    workspace.publisher(for: NSWorkspace.didActivateApplicationNotification)
      .merge(with: workspace.publisher(for: NSWorkspace.activeSpaceDidChangeNotification))
      .sink { [weak self] _ in self?.refresh() }
      .store(in: &cancellables)
    workspace.publisher(for: NSWorkspace.willSleepNotification)
      .sink { [weak self] _ in self?.sleep() }
      .store(in: &cancellables)
    workspace.publisher(for: NSWorkspace.didWakeNotification)
      .merge(with: workspace.publisher(for: NSWorkspace.sessionDidBecomeActiveNotification))
      .sink { [weak self] _ in self?.wake() }
      .store(in: &cancellables)
    NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)
      .merge(
        with: NotificationCenter.default.publisher(
          for: NSApplication.didChangeScreenParametersNotification)
      )
      .sink { [weak self] _ in self?.refresh() }
      .store(in: &cancellables)
    EventMonitors.shared.pointerMovement
      .map { location in
        NSScreen.screens.first { NSMouseInRect(location, $0.frame, false) }?.displayUUID
      }
      .removeDuplicates()
      .dropFirst()
      .sink { [weak self] _ in self?.refresh() }
      .store(in: &cancellables)

    installPowerSourceNotification()
    updatePolling()
    refresh()
    scheduleOverrideExpiry()
  }

  func stop() {
    guard running else { return }
    running = false
    cancellables.removeAll()
    timer = nil
    overrideExpiryTask?.cancel()
    overrideExpiryTask = nil
    if let powerSource {
      CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSource, .commonModes)
      self.powerSource = nil
    }
    runtime.sleep()
    publishRuntimeResolution()
  }

  func add(_ rule: ContextRule) {
    guard rule.isValid, rules.count < ContextRule.maximumCount else { return }
    store(rules + [rule])
  }

  func update(_ rule: ContextRule) {
    guard rule.isValid, let index = rules.firstIndex(where: { $0.id == rule.id }) else { return }
    var next = rules
    next[index] = rule
    store(next)
  }

  func setEnabled(_ enabled: Bool, for id: UUID) {
    guard let index = rules.firstIndex(where: { $0.id == id }) else { return }
    var next = rules
    next[index].isEnabled = enabled
    store(next)
  }

  func delete(at offsets: IndexSet) {
    var next = rules
    next.remove(atOffsets: offsets)
    store(next)
  }

  func move(from offsets: IndexSet, to destination: Int) {
    var next = rules
    next.move(fromOffsets: offsets, toOffset: destination)
    store(next)
  }

  func setManualOverride(action: ContextRuleAction, duration: TimeInterval, now: Date = Date()) {
    guard !action.isEmpty, duration > 0 else { return }
    Defaults[.contextManualOverride] = ContextManualOverride(
      action: action, expiresAt: now.addingTimeInterval(duration))
    scheduleOverrideExpiry()
  }

  func clearManualOverride() {
    Defaults[.contextManualOverride] = nil
    overrideExpiryTask?.cancel()
    overrideExpiryTask = nil
  }

  func effectiveEnergyMode(baseline: EnergyMode) -> EnergyMode {
    resolution.energyMode(baseline: baseline)
  }

  func isActivityVisible(_ id: String, baselineVisible: Bool) -> Bool {
    resolution.isActivityVisible(id, baselineVisible: baselineVisible)
  }

  func refresh(now: Date = Date()) {
    guard !runtime.isSleeping else { return }
    if let manualOverride, !manualOverride.isActive(at: now) {
      Defaults[.contextManualOverride] = nil
    }
    snapshot = sampleSnapshot(at: now)
    runtime.evaluate(
      rules: rules, snapshot: snapshot, manualOverride: Defaults[.contextManualOverride], now: now)
    publishRuntimeResolution()
  }

  private func sleep() {
    runtime.sleep()
    publishRuntimeResolution()
  }

  private func wake() {
    let now = Date()
    if let manualOverride, !manualOverride.isActive(at: now) {
      Defaults[.contextManualOverride] = nil
    }
    snapshot = sampleSnapshot(at: now)
    runtime.wake(
      rules: rules, snapshot: snapshot, manualOverride: Defaults[.contextManualOverride], now: now)
    publishRuntimeResolution()
    scheduleOverrideExpiry()
  }

  private func publishRuntimeResolution() {
    if resolution != runtime.resolution {
      resolution = runtime.resolution
      resolutionChangesSubject.send(resolution)
    }
    PulseCenter.shared.ruleDeliveryProfile = resolution.action?.pulseDelivery
  }

  private func store(_ next: [ContextRule]) {
    let validated = Self.validated(next)
    rules = validated
    Defaults[.contextRules] = validated
    updatePolling()
    refresh()
  }

  private static func validated(_ rules: [ContextRule]) -> [ContextRule] {
    var seen: Set<UUID> = []
    return rules.prefix(ContextRule.maximumCount).filter { rule in
      rule.isValid && seen.insert(rule.id).inserted
    }
  }

  private func sampleSnapshot(at date: Date) -> ContextSnapshot {
    let calendar = Calendar.autoupdatingCurrent
    let activeScreen = NSScreen.screenWithMouse ?? NSScreen.main
    return ContextSnapshot(
      focusMode: Self.activeFocusMode(),
      powerSource: BatteryMonitor.readState().map { $0.onAC ? .ac : .battery },
      lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
      frontmostBundleIdentifier: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
      isFullscreenPresentation: !FullscreenDetector.fullscreenDisplayUUIDs().isEmpty,
      minuteOfDay: calendar.component(.hour, from: date) * 60
        + calendar.component(.minute, from: date),
      activeDisplayID: activeScreen?.displayUUID,
      activeDisplayName: activeScreen?.localizedName,
      wifiNetwork: CWWiFiClient.shared().interface()?.ssid())
  }

  private static func activeFocusMode() -> String? {
    let url = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/DoNotDisturb/DB/Assertions.json")
    guard let data = try? Data(contentsOf: url) else { return nil }
    return FocusEventSource.inspect(data: data).activeIdentifier
  }

  private func installPowerSourceNotification() {
    guard powerSource == nil else { return }
    let opaque = Unmanaged.passUnretained(self).toOpaque()
    let callback: IOPowerSourceCallbackType = { context in
      guard let context else { return }
      let center = Unmanaged<ContextRuleCenter>.fromOpaque(context).takeUnretainedValue()
      Task { @MainActor in center.refresh() }
    }
    guard let source = IOPSNotificationCreateRunLoopSource(callback, opaque)?.takeRetainedValue()
    else { return }
    powerSource = source
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
  }

  private func updatePolling() {
    let needsPolling = Self.requiresPeriodicRefresh(rules)
    guard running, needsPolling else {
      timer = nil
      return
    }
    guard timer == nil else { return }
    timer = Timer.publish(every: 15, on: .main, in: .common).autoconnect()
      .sink { [weak self] _ in self?.refresh() }
  }

  static func requiresPeriodicRefresh(_ rules: [ContextRule]) -> Bool {
    let pollingKinds: Set<ContextTriggerKind> = [
      .focusMode, .fullscreenPresentation, .timeRange, .activeDisplay, .wifiNetwork,
    ]
    return rules.contains { rule in
      rule.isEnabled && pollingKinds.contains(rule.trigger.kind)
    }
  }

  private func scheduleOverrideExpiry() {
    overrideExpiryTask?.cancel()
    guard running, let manualOverride, manualOverride.isActive(at: Date()) else {
      overrideExpiryTask = nil
      return
    }
    overrideExpiryTask = Task { [weak self] in
      let delay = max(0, manualOverride.expiresAt.timeIntervalSinceNow)
      try? await Task.sleep(for: .seconds(delay))
      guard !Task.isCancelled else { return }
      self?.refresh()
    }
  }
}
