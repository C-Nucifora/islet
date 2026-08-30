import Foundation

/// Decides whether the System tab earns a slot in the island.
///
/// A bare Defaults Bool would make this a permanent secondary glyph in `NotchRootView`'s compact
/// row. Combined with a value that changes every second, that drives `onGeometryChange` ->
/// `NotchViewModel.updateCompactWidths` -> `NSPanel.setFrame` once a second, forever. Presence is
/// earned by sustained pressure, with a separate recovery threshold and timer for every reason.
struct SystemPresenceGate: Equatable {
  enum Reason: Int, CaseIterable, Equatable, Sendable {
    // The raw value is the display priority when several conditions overlap. Immediate hardware
    // pressure outranks capacity risks, which outrank high activity that may be intentional.
    case networkThroughput = 0
    case diskThroughput = 1
    case cpu = 2
    case lowDiskSpace = 3
    case memoryPressure = 4
    case thermal = 5

    var priority: Int { rawValue }
  }

  struct Controls: Equatable, Sendable {
    var cpu = true
    var thermal = true
    var memoryPressure = true
    var lowDiskSpace = true
    var diskThroughput = true
    var networkThroughput = true

    func includes(_ reason: Reason) -> Bool {
      switch reason {
      case .cpu: cpu
      case .thermal: thermal
      case .memoryPressure: memoryPressure
      case .lowDiskSpace: lowDiskSpace
      case .diskThroughput: diskThroughput
      case .networkThroughput: networkThroughput
      }
    }
  }

  /// Sustained total CPU fraction that turns the tab on.
  static let activateCPU = 0.80
  /// Falling through this turns it back off. The 20-point band between the two is the hysteresis.
  static let deactivateCPU = 0.60
  static let cpuActivationDuration: TimeInterval = 5
  static let cpuRecoveryDuration: TimeInterval = 5

  /// The kernel pressure level includes compression and paging demand, unlike a RAM-used ratio.
  /// Warning or critical pressure must persist for 20 seconds. A full minute at normal avoids
  /// hiding the tab during brief relief between reclaim bursts.
  static let activateMemoryPressureLevel = 2
  static let deactivateMemoryPressureLevel = 1
  static let memoryActivationDuration: TimeInterval = 20
  static let memoryRecoveryDuration: TimeInterval = 60

  /// `volumeAvailableCapacityForImportantUsage` accounts for purgeable space. Requiring it to
  /// fall below 10 GB is deliberately late and portable because the sample has no volume size.
  /// The tab stays present until 15 GB is available, with longer timers than the rate triggers.
  static let activateDiskFreeBytes: UInt64 = 10_000_000_000
  static let deactivateDiskFreeBytes: UInt64 = 15_000_000_000
  static let lowDiskActivationDuration: TimeInterval = 60
  static let lowDiskRecoveryDuration: TimeInterval = 120

  /// Islet cannot read a reliable capacity for every storage device it sums. This fixed floor
  /// therefore means sustained heavy I/O, not device saturation. 500 MB/s excludes routine bursts;
  /// a 300 MB/s release floor supplies a wide hysteresis band.
  static let activateDiskBytesPerSecond = 500_000_000.0
  static let deactivateDiskBytesPerSecond = 300_000_000.0
  static let diskActivationDuration: TimeInterval = 20
  static let diskRecoveryDuration: TimeInterval = 30

  /// The primary interface counters do not expose trustworthy usable link capacity. 80 MB/s is a
  /// conservative absolute signal for sustained high traffic, not proof that the link is saturated.
  /// Release at 50 MB/s so normal variation around the trigger cannot flap the compact reason.
  static let activateNetworkBytesPerSecond = 80_000_000.0
  static let deactivateNetworkBytesPerSecond = 50_000_000.0
  static let networkActivationDuration: TimeInterval = 20
  static let networkRecoveryDuration: TimeInterval = 30

  /// Compatibility names used by the CPU-specific tests added with the elapsed-time gate.
  static let activationDuration = cpuActivationDuration
  static let recoveryDuration = cpuRecoveryDuration

  /// Matches the rate window. A larger gap means the app was suspended or the timer stalled, so it
  /// cannot prove continuous load or recovery.
  static let maximumSampleGap = metricsMaxSampleGap
  /// Brief missing reads are tolerated. A source missing for a full sample-gap window is stale.
  static let missingSampleTimeout = maximumSampleGap

  private(set) var isActive = false
  private(set) var reason: Reason?
  private var cpuState = SustainedState()
  private var thermalState = SustainedState()
  private var memoryState = SustainedState()
  private var lowDiskState = SustainedState()
  private var diskState = SustainedState()
  private var networkState = SustainedState()
  private var lastSampleUptime: TimeInterval?

  /// Feeds one sample at a monotonic uptime. Tests inject `uptime`; production uses system uptime.
  /// Returns true when `isActive` or the highest-priority active reason changed.
  mutating func update(
    sample: SystemMetricsSample, controls: Controls = Controls(),
    uptime: TimeInterval = ProcessInfo.processInfo.systemUptime
  ) -> Bool {
    let wasActive = isActive
    let wasReason = reason

    let hasLongGap = lastSampleUptime.map { uptime - $0 > Self.maximumSampleGap } ?? false
    let movedBackward = lastSampleUptime.map { uptime < $0 } ?? false
    lastSampleUptime = uptime
    if hasLongGap || movedBackward { resetTriggerStates() }

    Self.update(
      &cpuState, enabled: controls.cpu, value: sample.cpuTotal,
      triggers: { $0 >= Self.activateCPU }, recovers: { $0 <= Self.deactivateCPU },
      activationDuration: Self.cpuActivationDuration,
      recoveryDuration: Self.cpuRecoveryDuration, uptime: uptime)
    Self.update(
      &thermalState, enabled: controls.thermal, value: sample.thermalState,
      triggers: { $0 > 0 }, recovers: { $0 == 0 }, activationDuration: 0,
      recoveryDuration: 0, uptime: uptime)
    Self.update(
      &memoryState, enabled: controls.memoryPressure, value: sample.memoryPressureLevel,
      triggers: { $0 >= Self.activateMemoryPressureLevel },
      recovers: { $0 <= Self.deactivateMemoryPressureLevel },
      activationDuration: Self.memoryActivationDuration,
      recoveryDuration: Self.memoryRecoveryDuration, uptime: uptime)
    Self.update(
      &lowDiskState, enabled: controls.lowDiskSpace, value: sample.diskFreeBytes,
      triggers: { $0 <= Self.activateDiskFreeBytes },
      recovers: { $0 >= Self.deactivateDiskFreeBytes },
      activationDuration: Self.lowDiskActivationDuration,
      recoveryDuration: Self.lowDiskRecoveryDuration, uptime: uptime)
    Self.update(
      &diskState, enabled: controls.diskThroughput,
      value: Self.combined(sample.diskReadBytesPerSec, sample.diskWriteBytesPerSec),
      triggers: { $0 >= Self.activateDiskBytesPerSecond },
      recovers: { $0 <= Self.deactivateDiskBytesPerSecond },
      activationDuration: Self.diskActivationDuration,
      recoveryDuration: Self.diskRecoveryDuration, uptime: uptime)
    Self.update(
      &networkState, enabled: controls.networkThroughput,
      value: Self.combined(sample.netInBytesPerSec, sample.netOutBytesPerSec),
      triggers: { $0 >= Self.activateNetworkBytesPerSecond },
      recovers: { $0 <= Self.deactivateNetworkBytesPerSecond },
      activationDuration: Self.networkActivationDuration,
      recoveryDuration: Self.networkRecoveryDuration, uptime: uptime)

    return refreshPresence(controls: controls, wasActive: wasActive, wasReason: wasReason)
  }

  /// Applies preference changes without treating the monitor's cached value as a fresh sample.
  /// Disabling a trigger takes effect immediately; enabled triggers keep their existing timers.
  mutating func update(controls: Controls) -> Bool {
    let wasActive = isActive
    let wasReason = reason
    if !controls.cpu { cpuState.reset() }
    if !controls.thermal { thermalState.reset() }
    if !controls.memoryPressure { memoryState.reset() }
    if !controls.lowDiskSpace { lowDiskState.reset() }
    if !controls.diskThroughput { diskState.reset() }
    if !controls.networkThroughput { networkState.reset() }
    return refreshPresence(controls: controls, wasActive: wasActive, wasReason: wasReason)
  }

  private mutating func refreshPresence(
    controls: Controls, wasActive: Bool, wasReason: Reason?
  ) -> Bool {
    reason = Reason.allCases
      .filter { controls.includes($0) && state(for: $0).isActive }
      .max { $0.priority < $1.priority }
    isActive = reason != nil
    return isActive != wasActive || reason != wasReason
  }

  /// Keeps the CPU/thermal call site available for focused tests and older integrations.
  mutating func update(
    cpuTotal: Double?, thermalState: Int,
    uptime: TimeInterval = ProcessInfo.processInfo.systemUptime
  ) -> Bool {
    update(
      sample: SystemMetricsSample(cpuTotal: cpuTotal, thermalState: thermalState), uptime: uptime)
  }

  private func state(for reason: Reason) -> SustainedState {
    switch reason {
    case .cpu: cpuState
    case .thermal: thermalState
    case .memoryPressure: memoryState
    case .lowDiskSpace: lowDiskState
    case .diskThroughput: diskState
    case .networkThroughput: networkState
    }
  }

  private mutating func resetTriggerStates() {
    cpuState.reset()
    thermalState.reset()
    memoryState.reset()
    lowDiskState.reset()
    diskState.reset()
    networkState.reset()
  }

  private static func combined(_ first: Double?, _ second: Double?) -> Double? {
    guard let first, let second else { return nil }
    return first + second
  }

  private static func update<Value>(
    _ state: inout SustainedState, enabled: Bool, value: Value?,
    triggers: (Value) -> Bool, recovers: (Value) -> Bool,
    activationDuration: TimeInterval, recoveryDuration: TimeInterval, uptime: TimeInterval
  ) {
    guard enabled else {
      state.reset()
      return
    }
    guard let value else {
      state.interruptPendingDuration(
        uptime: uptime, missingSampleTimeout: Self.missingSampleTimeout)
      return
    }
    state.update(
      isTriggered: triggers(value), isRecovered: recovers(value),
      activationDuration: activationDuration, recoveryDuration: recoveryDuration,
      uptime: uptime)
  }
}

private struct SustainedState: Equatable {
  private(set) var isActive = false
  private var triggeredSince: TimeInterval?
  private var recoveredSince: TimeInterval?
  private var missingSince: TimeInterval?

  mutating func update(
    isTriggered: Bool, isRecovered: Bool, activationDuration: TimeInterval,
    recoveryDuration: TimeInterval, uptime: TimeInterval
  ) {
    missingSince = nil
    if isActive {
      triggeredSince = nil
      guard isRecovered else {
        recoveredSince = nil
        return
      }
      let since = recoveredSince ?? uptime
      recoveredSince = since
      guard uptime - since >= recoveryDuration else { return }
      reset()
      return
    }

    recoveredSince = nil
    guard isTriggered else {
      triggeredSince = nil
      return
    }
    let since = triggeredSince ?? uptime
    triggeredSince = since
    guard uptime - since >= activationDuration else { return }
    isActive = true
    triggeredSince = nil
  }

  mutating func interruptPendingDuration(
    uptime: TimeInterval, missingSampleTimeout: TimeInterval
  ) {
    triggeredSince = nil
    recoveredSince = nil
    guard isActive else {
      missingSince = nil
      return
    }
    let since = missingSince ?? uptime
    missingSince = since
    if uptime - since >= missingSampleTimeout { reset() }
  }

  mutating func reset() {
    isActive = false
    triggeredSince = nil
    recoveredSince = nil
    missingSince = nil
  }
}
