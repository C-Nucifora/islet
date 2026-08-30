import Foundation

/// Decides whether the System tab earns a slot in the island.
///
/// A bare Defaults Bool would make this a permanent secondary glyph in `NotchRootView`'s compact
/// row. Combined with a value that changes every second, that drives `onGeometryChange` ->
/// `NotchViewModel.updateCompactWidths` -> `NSPanel.setFrame` once a second, forever. So presence
/// is earned: sustained load, with hysteresis so it cannot flap.
struct SystemPresenceGate: Equatable {
  enum Reason: Equatable, Sendable { case cpu, thermal }

  /// Sustained total CPU fraction that turns the tab on.
  static let activateCPU = 0.80
  /// Falling through this turns it back off. The 20-point band between the two is the hysteresis.
  static let deactivateCPU = 0.60
  /// CPU must stay at or above `activateCPU` for this long before the tab appears.
  static let activationDuration: TimeInterval = 5
  /// CPU must remain at or below `deactivateCPU` for this long before the tab disappears.
  static let recoveryDuration: TimeInterval = 5
  /// Matches the rate window. A larger gap means the app was suspended or the timer stalled, so it
  /// cannot prove continuous CPU load or recovery.
  static let maximumSampleGap = metricsMaxSampleGap

  private(set) var isActive = false
  private(set) var reason: Reason?
  private var highCPUSince: TimeInterval?
  private var recoveringSince: TimeInterval?
  private var lastSampleUptime: TimeInterval?

  /// Feeds one sample at a monotonic uptime. Tests inject `uptime`; production uses system uptime.
  /// Returns true when `isActive` or `reason` changed. The caller redraws the compact glyph off
  /// both, and the two reasons use different SF Symbols.
  mutating func update(
    cpuTotal: Double?, thermalState: Int,
    uptime: TimeInterval = ProcessInfo.processInfo.systemUptime
  ) -> Bool {
    let wasActive = isActive
    let wasReason = reason

    let hasLongGap = lastSampleUptime.map { uptime - $0 > Self.maximumSampleGap } ?? false
    let movedBackward = lastSampleUptime.map { uptime < $0 } ?? false
    lastSampleUptime = uptime

    if hasLongGap || movedBackward {
      // CPU samples cover a measurement window. A suspended or otherwise interrupted window is
      // not evidence that load stayed high or stayed low. Do not retain a stale CPU glyph.
      highCPUSince = nil
      recoveringSince = nil
      if reason == .cpu {
        isActive = false
        reason = nil
      }
    }

    if thermalState != 0 {
      isActive = true
      reason = .thermal
      // Do not bank a CPU streak while thermal is holding the tab open; when thermal clears, CPU
      // starts from zero rather than inheriting an unearned duration.
      highCPUSince = nil
      recoveringSince = nil
      return isActive != wasActive || reason != wasReason
    }

    // Thermal has cleared. A thermal-driven activation ends here; CPU has to earn its own.
    if reason == .thermal {
      isActive = false
      reason = nil
      highCPUSince = nil
      recoveringSince = nil
    }

    guard let cpu = cpuTotal else {
      // An unavailable CPU value cannot extend an in-progress duration. Keep an already-visible
      // tab through a transient read failure, but make either direction earn its full duration.
      highCPUSince = nil
      recoveringSince = nil
      return isActive != wasActive || reason != wasReason
    }

    if isActive {
      updateActiveCPU(cpu, uptime: uptime)
    } else {
      updateInactiveCPU(cpu, uptime: uptime)
    }

    return isActive != wasActive || reason != wasReason
  }

  private mutating func updateInactiveCPU(_ cpu: Double, uptime: TimeInterval) {
    recoveringSince = nil
    guard cpu >= Self.activateCPU else {
      highCPUSince = nil
      return
    }

    let highSince = highCPUSince ?? uptime
    highCPUSince = highSince
    guard uptime - highSince >= Self.activationDuration else { return }
    isActive = true
    reason = .cpu
    highCPUSince = nil
  }

  private mutating func updateActiveCPU(_ cpu: Double, uptime: TimeInterval) {
    highCPUSince = nil
    guard cpu <= Self.deactivateCPU else {
      recoveringSince = nil
      return
    }

    let lowSince = recoveringSince ?? uptime
    recoveringSince = lowSince
    guard uptime - lowSince >= Self.recoveryDuration else { return }
    isActive = false
    reason = nil
    recoveringSince = nil
  }
}
