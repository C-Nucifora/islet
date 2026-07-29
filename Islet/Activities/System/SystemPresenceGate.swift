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
  /// Consecutive samples above `activateCPU` required. At 1 Hz that is five seconds of real load,
  /// which a single compile or a Spotlight index pass will not fake.
  static let sustainSamples = 5

  private(set) var isActive = false
  private(set) var reason: Reason?
  private var consecutiveHigh = 0
  private var lastCPU: Double?

  /// Activation is a *level* ("sustained above 80%"), so it is a plain comparison. Deactivation
  /// genuinely is an edge, so it goes through the shared Phase 1.6 detector.
  private let release = ThresholdDetector(
    thresholds: [SystemPresenceGate.deactivateCPU], direction: .falling)

  /// Feeds one sample. Returns true when `isActive` OR `reason` changed — the caller redraws the
  /// compact glyph off both, and the two reasons use different SF Symbols.
  mutating func update(cpuTotal: Double?, thermalState: Int) -> Bool {
    let wasActive = isActive
    let wasReason = reason

    if thermalState != 0 {
      isActive = true
      reason = .thermal
      // Do not bank a CPU streak while thermal is holding the tab open; when thermal clears, CPU
      // starts from zero rather than inheriting an unearned five seconds.
      consecutiveHigh = 0
      if let cpuTotal { lastCPU = cpuTotal }
      return isActive != wasActive || reason != wasReason
    }

    // Thermal has cleared. A thermal-driven activation ends here; CPU has to earn its own.
    if reason == .thermal {
      isActive = false
      reason = nil
    }

    guard let cpu = cpuTotal else {
      // No CPU reading — the first sample, or one discarded after a gap. Hold.
      return isActive != wasActive || reason != wasReason
    }

    let crossedDown = !release.crossings(from: lastCPU, to: cpu).isEmpty
    lastCPU = cpu

    if cpu >= Self.activateCPU {
      consecutiveHigh += 1
      if consecutiveHigh >= Self.sustainSamples {
        isActive = true
        reason = .cpu
      }
    } else {
      consecutiveHigh = 0
      if crossedDown || cpu < Self.deactivateCPU {
        isActive = false
        reason = nil
      }
    }

    return isActive != wasActive || reason != wasReason
  }
}
