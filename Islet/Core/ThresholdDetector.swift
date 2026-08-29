import Foundation

/// Fires once per crossing of a fixed set of thresholds on one numeric series.
///
/// Extracted from the battery low-charge check so peripheral low battery, charge complete, low
/// disk space and CPU/thermal thresholds can share it. Pure and value-typed: hold one per series.
struct ThresholdDetector: Equatable {
  enum Direction: Equatable {
    /// Fires when the value drops onto or through a threshold (battery percent, free disk).
    case falling
    /// Fires when the value rises onto or through a threshold (CPU load, temperature).
    case rising
  }

  let thresholds: [Double]
  let direction: Direction

  /// Thresholds crossed going from `old` to `new`, in the order they were declared. Empty when
  /// `old` is nil — the first sample is a baseline, not a crossing, or every launch would announce
  /// whatever state the machine happened to already be in.
  func crossings(from old: Double?, to new: Double) -> [Double] {
    guard let old else { return [] }
    switch direction {
    case .falling: return thresholds.filter { old > $0 && new <= $0 }
    case .rising: return thresholds.filter { old < $0 && new >= $0 }
    }
  }
}
