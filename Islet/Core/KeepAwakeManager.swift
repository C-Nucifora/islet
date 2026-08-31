import AppKit
import Combine
import Darwin
import Defaults
import Foundation
import IOKit.pwr_mgt

enum KeepAwakeDuration: Equatable, Sendable {
  case indefinitely
  case timed(TimeInterval)

  static let presets: [(title: String, duration: KeepAwakeDuration)] = [
    ("30 minutes", .timed(30 * 60)),
    ("1 hour", .timed(60 * 60)),
    ("2 hours", .timed(2 * 60 * 60)),
    ("4 hours", .timed(4 * 60 * 60)),
  ]
}

enum KeepAwakeEndReason: String, Equatable, Sendable {
  case manual
  case timer
  case battery
  case quit
}

enum KeepAwakeAssertionKind: Equatable, Sendable {
  case systemSleep
  case displaySleep
}

protocol KeepAwakeAssertionProviding {
  func create(_ kind: KeepAwakeAssertionKind, reason: String) throws -> UInt32
  func release(_ assertionID: UInt32) throws
}

enum KeepAwakeAssertionError: LocalizedError {
  case create(kind: KeepAwakeAssertionKind, code: IOReturn)
  case nullAssertion(kind: KeepAwakeAssertionKind)
  case release(assertionID: UInt32, code: IOReturn)

  var errorDescription: String? {
    switch self {
    case .create(let kind, let code):
      "Could not create the \(kind.description) power assertion (IOKit error \(code))."
    case .nullAssertion(let kind):
      "IOKit returned an invalid ID for the \(kind.description) power assertion."
    case .release(let assertionID, let code):
      "Could not release power assertion \(assertionID) (IOKit error \(code))."
    }
  }
}

extension KeepAwakeAssertionKind {
  fileprivate var description: String {
    switch self {
    case .systemSleep: "system-sleep"
    case .displaySleep: "display-sleep"
    }
  }
}

struct IOKitKeepAwakeAssertionProvider: KeepAwakeAssertionProviding {
  func create(_ kind: KeepAwakeAssertionKind, reason: String) throws -> UInt32 {
    let type: CFString =
      switch kind {
      case .systemSleep: kIOPMAssertionTypePreventUserIdleSystemSleep as CFString
      case .displaySleep: kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString
      }
    var assertionID = IOPMAssertionID(kIOPMNullAssertionID)
    let result = IOPMAssertionCreateWithName(
      type, IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &assertionID)
    guard result == kIOReturnSuccess else {
      throw KeepAwakeAssertionError.create(kind: kind, code: result)
    }
    guard assertionID != kIOPMNullAssertionID else {
      throw KeepAwakeAssertionError.nullAssertion(kind: kind)
    }
    return assertionID
  }

  func release(_ assertionID: UInt32) throws {
    let result = IOPMAssertionRelease(IOPMAssertionID(assertionID))
    guard result == kIOReturnSuccess else {
      throw KeepAwakeAssertionError.release(assertionID: assertionID, code: result)
    }
  }
}

protocol KeepAwakeClock {
  var wallNow: Date { get }
  var monotonicNow: TimeInterval { get }
}

struct SystemKeepAwakeClock: KeepAwakeClock {
  var wallNow: Date { Date() }

  var monotonicNow: TimeInterval {
    var timebase = mach_timebase_info_data_t()
    mach_timebase_info(&timebase)
    let nanoseconds =
      Double(mach_continuous_time()) * Double(timebase.numer) / Double(timebase.denom)
    return nanoseconds / 1_000_000_000
  }
}

@MainActor
protocol KeepAwakeScheduledTask: AnyObject {
  func cancel()
}

@MainActor
protocol KeepAwakeScheduling {
  func schedule(after delay: TimeInterval, action: @escaping @MainActor () -> Void)
    -> KeepAwakeScheduledTask
}

private final class DispatchKeepAwakeTask: KeepAwakeScheduledTask {
  private var workItem: DispatchWorkItem?

  init(workItem: DispatchWorkItem) {
    self.workItem = workItem
  }

  func cancel() {
    workItem?.cancel()
    workItem = nil
  }
}

struct DispatchKeepAwakeScheduler: KeepAwakeScheduling {
  func schedule(after delay: TimeInterval, action: @escaping @MainActor () -> Void)
    -> KeepAwakeScheduledTask
  {
    let item = DispatchWorkItem {
      MainActor.assumeIsolated { action() }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay), execute: item)
    return DispatchKeepAwakeTask(workItem: item)
  }
}

extension Notification.Name {
  static let keepAwakeSessionDidChange = Notification.Name("KeepAwakeSessionDidChange")
}

@MainActor
final class KeepAwakeManager: ObservableObject {
  static let shared = KeepAwakeManager(
    assertionProvider: IOKitKeepAwakeAssertionProvider(), clock: SystemKeepAwakeClock(),
    scheduler: DispatchKeepAwakeScheduler(), allowDisplaySleep: Defaults[.allowDisplaySleep],
    lowBatteryThreshold: Defaults[.keepAwakeLowBatteryThreshold],
    batteryStateProvider: { BatteryMonitor.readState() },
    keepAwakeWithLidClosed: Defaults[.keepAwakeWithLidClosed],
    powerProtectProvider: SystemPowerProtectProvider(),
    observeSystemChanges: true, observePreferenceChanges: true)

  @Published private(set) var isActive = false
  @Published private(set) var allowDisplaySleep: Bool
  @Published private(set) var keepAwakeWithLidClosed: Bool
  @Published private(set) var powerProtectInstalled: Bool
  @Published private(set) var isInstallingPowerProtect = false
  @Published private(set) var duration: KeepAwakeDuration = .indefinitely
  @Published private(set) var remainingTime: TimeInterval?
  @Published private(set) var endsAt: Date?
  @Published private(set) var lastEndReason: KeepAwakeEndReason?
  @Published private(set) var lastError: String?

  /// True when a power override still belongs to this manager, including one whose release
  /// failed and is awaiting a bounded retry at the next lifecycle transition.
  var hasUnreleasedAssertions: Bool {
    systemAssertionID != nil || displayAssertionID != nil || powerProtectEnabled
  }

  /// The preference is the requested state. This value reports what the owned assertion state
  /// actually does, so a failed display release is never presented as though it succeeded.
  var effectivelyAllowsDisplaySleep: Bool { displayAssertionID == nil }

  private let assertionProvider: KeepAwakeAssertionProviding
  private let clock: KeepAwakeClock
  private let scheduler: KeepAwakeScheduling
  private let batteryStateProvider: () -> BatteryState?
  private let powerProtectProvider: any PowerProtectProviding
  private var lowBatteryThreshold: Int
  private var latestBatteryState: BatteryState?
  private var systemAssertionID: UInt32?
  private var displayAssertionID: UInt32?
  private var powerProtectEnabled = false
  private var monotonicDeadline: TimeInterval?
  private var scheduledTask: KeepAwakeScheduledTask?
  private var scheduleGeneration: UInt64 = 0
  private var cancellables: Set<AnyCancellable> = []

  init(
    assertionProvider: KeepAwakeAssertionProviding, clock: KeepAwakeClock,
    scheduler: KeepAwakeScheduling, allowDisplaySleep: Bool,
    lowBatteryThreshold: Int, batteryStateProvider: @escaping () -> BatteryState?,
    keepAwakeWithLidClosed: Bool = false,
    powerProtectProvider: any PowerProtectProviding = SystemPowerProtectProvider(),
    observeSystemChanges: Bool = false, observePreferenceChanges: Bool = false
  ) {
    self.assertionProvider = assertionProvider
    self.clock = clock
    self.scheduler = scheduler
    self.allowDisplaySleep = allowDisplaySleep
    self.keepAwakeWithLidClosed = keepAwakeWithLidClosed
    self.lowBatteryThreshold = lowBatteryThreshold
    self.batteryStateProvider = batteryStateProvider
    self.powerProtectProvider = powerProtectProvider
    self.powerProtectInstalled = powerProtectProvider.isInstalled

    if observePreferenceChanges {
      Defaults.publisher(.allowDisplaySleep)
        .sink { [weak self] change in
          Task { @MainActor in self?.setAllowDisplaySleep(change.newValue) }
        }
        .store(in: &cancellables)
      Defaults.publisher(.keepAwakeLowBatteryThreshold)
        .sink { [weak self] change in
          Task { @MainActor in self?.setLowBatteryThreshold(change.newValue) }
        }
        .store(in: &cancellables)
      Defaults.publisher(.keepAwakeWithLidClosed)
        .sink { [weak self] change in
          Task { @MainActor in self?.setKeepAwakeWithLidClosed(change.newValue) }
        }
        .store(in: &cancellables)
    }
    if observeSystemChanges {
      NotificationCenter.default.publisher(for: .NSSystemClockDidChange)
        .sink { [weak self] _ in Task { @MainActor in self?.systemTimeDidChange() } }
        .store(in: &cancellables)
      NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
        .sink { [weak self] _ in Task { @MainActor in self?.systemTimeDidChange() } }
        .store(in: &cancellables)
    }
    recoverStalePowerProtectState()
  }

  @discardableResult
  func start(duration newDuration: KeepAwakeDuration) -> Bool {
    lastError = nil
    lastEndReason = nil

    guard Self.isValid(newDuration) else {
      recordError("Keep-awake duration must be finite and greater than zero.")
      return false
    }

    refreshBatteryState()
    guard !batteryProtectionApplies else {
      if isActive {
        stop(reason: .battery)
      } else {
        lastEndReason = .battery
        recordError(
          "Keep awake did not start because the battery is at or below \(lowBatteryThreshold)% while unplugged."
        )
      }
      return false
    }

    if isActive {
      configureTimer(for: newDuration)
      return true
    }

    retryOwnedAssertionReleases()
    guard !hasUnreleasedAssertions else {
      recordError("Could not start a new session while a previous power assertion is unreleased.")
      return false
    }

    if keepAwakeWithLidClosed {
      guard enablePowerProtect() else {
        clearTimerState()
        return false
      }
    }

    do {
      let systemID = try assertionProvider.create(
        .systemSleep, reason: "Islet keep-awake session")
      guard systemID != kIOPMNullAssertionID else {
        throw KeepAwakeAssertionError.nullAssertion(kind: .systemSleep)
      }
      systemAssertionID = systemID
      if !allowDisplaySleep {
        do {
          let displayID = try assertionProvider.create(
            .displaySleep, reason: "Islet keep-awake session")
          guard displayID != kIOPMNullAssertionID else {
            throw KeepAwakeAssertionError.nullAssertion(kind: .displaySleep)
          }
          displayAssertionID = displayID
        } catch {
          releaseSystemAssertion()
          throw error
        }
      }
    } catch {
      disablePowerProtect()
      recordError(error.localizedDescription)
      clearTimerState()
      return false
    }

    isActive = true
    configureTimer(for: newDuration)
    NotificationCenter.default.post(name: .keepAwakeSessionDidChange, object: self)
    return true
  }

  func stop(reason: KeepAwakeEndReason = .manual) {
    guard isActive || systemAssertionID != nil || displayAssertionID != nil || powerProtectEnabled
    else { return }
    isActive = false
    clearTimerState()

    lastError = nil
    retryOwnedAssertionReleases()
    if reason == .quit, hasUnreleasedAssertions {
      retryOwnedAssertionReleases()
    }

    lastEndReason = reason
    NotificationCenter.default.post(name: .keepAwakeSessionDidChange, object: self)
  }

  func setKeepAwakeWithLidClosed(_ enabled: Bool) {
    guard enabled != keepAwakeWithLidClosed else { return }
    lastError = nil
    keepAwakeWithLidClosed = enabled
    guard isActive else { return }
    if enabled {
      _ = enablePowerProtect()
    } else {
      disablePowerProtect()
    }
  }

  func refreshPowerProtectInstallation() {
    powerProtectInstalled = powerProtectProvider.isInstalled
  }

  func installPowerProtect() async {
    guard !isInstallingPowerProtect else { return }
    isInstallingPowerProtect = true
    lastError = nil
    let provider = powerProtectProvider
    do {
      try await Task.detached(priority: .userInitiated) {
        try provider.install()
      }.value
      powerProtectInstalled = provider.isInstalled
      if isActive, keepAwakeWithLidClosed {
        _ = enablePowerProtect()
      }
    } catch {
      powerProtectInstalled = provider.isInstalled
      recordError(error.localizedDescription)
    }
    isInstallingPowerProtect = false
  }

  func setAllowDisplaySleep(_ allow: Bool) {
    guard allow != allowDisplaySleep else { return }
    lastError = nil
    allowDisplaySleep = allow
    guard isActive else { return }
    reconcileDisplayAssertionWithPreference()
  }

  func handleBattery(_ state: BatteryState, lowBatteryThreshold: Int) {
    latestBatteryState = state
    self.lowBatteryThreshold = lowBatteryThreshold
    stopForBatteryIfNeeded()
  }

  func clearBatteryState() {
    latestBatteryState = nil
  }

  func setLowBatteryThreshold(_ threshold: Int) {
    lowBatteryThreshold = threshold
    refreshBatteryState()
    stopForBatteryIfNeeded()
  }

  func retryUnreleasedAssertions() {
    lastError = nil
    if isActive {
      reconcileDisplayAssertionWithPreference()
      if keepAwakeWithLidClosed {
        _ = enablePowerProtect()
      } else {
        disablePowerProtect()
      }
    } else {
      guard hasUnreleasedAssertions else { return }
      retryOwnedAssertionReleases()
    }
    NotificationCenter.default.post(name: .keepAwakeSessionDidChange, object: self)
  }

  func systemTimeDidChange() {
    guard isActive, monotonicDeadline != nil else { return }
    reconcileTimer()
  }

  var statusText: String {
    guard isActive else { return "Off" }
    guard let remainingTime else { return "Indefinitely" }
    let seconds = max(0, Int(remainingTime.rounded(.up)))
    let hours = seconds / 3_600
    let minutes = (seconds % 3_600) / 60
    if hours > 0 { return String(format: "%d:%02d", hours, minutes) }
    let remainingSeconds = seconds % 60
    return String(format: "%d:%02d", minutes, remainingSeconds)
  }

  private func configureTimer(for newDuration: KeepAwakeDuration) {
    cancelScheduledTask()
    duration = newDuration
    switch newDuration {
    case .indefinitely:
      monotonicDeadline = nil
      remainingTime = nil
      endsAt = nil
    case .timed(let interval):
      monotonicDeadline = clock.monotonicNow + interval
      remainingTime = interval
      endsAt = clock.wallNow.addingTimeInterval(interval)
      scheduleNextTick()
    }
  }

  private func reconcileTimer() {
    guard let deadline = monotonicDeadline else { return }
    let remaining = deadline - clock.monotonicNow
    if remaining <= 0 {
      stop(reason: .timer)
      return
    }
    remainingTime = remaining
    endsAt = clock.wallNow.addingTimeInterval(remaining)
    scheduleNextTick()
  }

  private func scheduleNextTick() {
    cancelScheduledTask()
    guard let deadline = monotonicDeadline else { return }
    let remaining = deadline - clock.monotonicNow
    guard remaining > 0 else {
      stop(reason: .timer)
      return
    }
    remainingTime = remaining
    scheduleGeneration &+= 1
    let expectedGeneration = scheduleGeneration
    scheduledTask = scheduler.schedule(after: min(1, remaining)) { [weak self] in
      guard let self, self.scheduleGeneration == expectedGeneration, self.isActive else { return }
      self.reconcileTimer()
    }
  }

  private func cancelScheduledTask() {
    scheduleGeneration &+= 1
    scheduledTask?.cancel()
    scheduledTask = nil
  }

  private func clearTimerState() {
    cancelScheduledTask()
    duration = .indefinitely
    monotonicDeadline = nil
    remainingTime = nil
    endsAt = nil
  }

  private func retryOwnedAssertionReleases() {
    if displayAssertionID != nil { releaseDisplayAssertion() }
    if systemAssertionID != nil { releaseSystemAssertion() }
    if powerProtectEnabled { disablePowerProtect() }
  }

  private func enablePowerProtect() -> Bool {
    guard !powerProtectEnabled else { return true }
    powerProtectInstalled = powerProtectProvider.isInstalled
    guard powerProtectInstalled else {
      recordError(PowerProtectError.notInstalled.localizedDescription)
      return false
    }
    do {
      try powerProtectProvider.enable()
      powerProtectEnabled = true
      return true
    } catch {
      recordError(error.localizedDescription)
      return false
    }
  }

  private func disablePowerProtect() {
    guard powerProtectEnabled else { return }
    do {
      try powerProtectProvider.disable()
      powerProtectEnabled = false
    } catch {
      recordError(error.localizedDescription)
    }
  }

  private func recoverStalePowerProtectState() {
    guard powerProtectInstalled else { return }
    do {
      try powerProtectProvider.disable()
    } catch {
      recordError(
        "Power Protect could not restore sleep after the previous Islet session. \(error.localizedDescription)"
      )
    }
  }

  private func reconcileDisplayAssertionWithPreference() {
    if allowDisplaySleep {
      releaseDisplayAssertion()
      return
    }
    guard displayAssertionID == nil else { return }
    do {
      let displayID = try assertionProvider.create(
        .displaySleep, reason: "Islet keep-awake session")
      guard displayID != kIOPMNullAssertionID else {
        throw KeepAwakeAssertionError.nullAssertion(kind: .displaySleep)
      }
      displayAssertionID = displayID
    } catch {
      recordError(error.localizedDescription)
    }
  }

  private static func isValid(_ duration: KeepAwakeDuration) -> Bool {
    switch duration {
    case .indefinitely:
      true
    case .timed(let interval):
      interval.isFinite && interval > 0
    }
  }

  private var batteryProtectionApplies: Bool {
    guard let latestBatteryState else { return false }
    return lowBatteryThreshold > 0 && !latestBatteryState.onAC
      && latestBatteryState.percent <= lowBatteryThreshold
  }

  private func refreshBatteryState() {
    if let state = batteryStateProvider() { latestBatteryState = state }
  }

  private func stopForBatteryIfNeeded() {
    guard isActive, batteryProtectionApplies else { return }
    stop(reason: .battery)
  }

  private func releaseDisplayAssertion() {
    guard let assertionID = displayAssertionID else { return }
    do {
      try assertionProvider.release(assertionID)
      displayAssertionID = nil
    } catch {
      recordError(error.localizedDescription)
    }
  }

  private func releaseSystemAssertion() {
    guard let assertionID = systemAssertionID else { return }
    do {
      try assertionProvider.release(assertionID)
      systemAssertionID = nil
    } catch {
      recordError(error.localizedDescription)
    }
  }

  private func recordError(_ message: String) {
    guard lastError?.contains(message) != true else { return }
    if let lastError {
      self.lastError = "\(lastError) \(message)"
    } else {
      lastError = message
    }
  }
}
