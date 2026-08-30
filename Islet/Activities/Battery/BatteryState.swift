import Foundation

struct BatteryState: Equatable, Sendable {
  var percent: Int = 100
  var isCharging = false
  var onAC = false
}

/// Holds a known percentage across a brief IOPS interruption. The raw missing reading remains
/// unavailable; this only keeps the UI from jumping to a made-up value before the next sample.
struct BatteryStateGracePeriod {
  static let duration: TimeInterval = 2 * BatteryMonitor.backgroundInterval

  private var lastValid: (state: BatteryState, date: Date)?

  mutating func resolve(_ sample: BatteryState?, at date: Date) -> BatteryState? {
    if let sample {
      lastValid = (sample, date)
      return sample
    }
    guard let lastValid else { return nil }
    let elapsed = date.timeIntervalSince(lastValid.date)
    guard elapsed >= 0, elapsed < Self.duration else { return nil }
    return lastValid.state
  }

  mutating func reset() {
    lastValid = nil
  }
}

/// Keeps threshold history only for freshly observed capacity readings. A retained display value
/// must not connect two real samples across an unavailable interval.
struct BatteryEventHistory {
  private var lastState: BatteryState?

  mutating func events(for sample: BatteryState?, isFresh: Bool) -> [BatteryEvent] {
    guard isFresh, let sample else {
      lastState = nil
      return []
    }
    let events = BatteryEventDetector.events(from: lastState, to: sample)
    lastState = sample
    return events
  }

  mutating func reset() {
    lastState = nil
  }
}

enum BatteryEvent: Equatable {
  case acConnected(percent: Int)
  case acDisconnected(percent: Int)
  case lowBattery(threshold: Int, percent: Int)
  /// Reached 100% while on AC. Fires once per charge, on the upward crossing only, so a battery
  /// hovering at 100 and dropping to 99 and back does not re-announce.
  case chargeComplete(percent: Int)
}

/// Pure change detection between consecutive battery snapshots.
/// Low-battery events fire once per downward crossing of a threshold, and only on battery power.
enum BatteryEventDetector {
  static let thresholds = [20, 10]

  /// Declaration order is load-bearing: dropping straight past both thresholds in one tick has to
  /// report 20 before 10.
  private static var lowBatteryDetector: ThresholdDetector {
    ThresholdDetector(thresholds: thresholds.map(Double.init), direction: .falling)
  }

  static func events(from old: BatteryState?, to new: BatteryState) -> [BatteryEvent] {
    guard let old else { return [] }  // first snapshot is baseline only
    var out: [BatteryEvent] = []
    if !old.onAC, new.onAC {
      out.append(.acConnected(percent: new.percent))
    } else if old.onAC, !new.onAC {
      out.append(.acDisconnected(percent: new.percent))
    }
    // Upward crossing of 100 while plugged in. Guarding on the crossing rather than on the level
    // means a battery sitting at 100 does not re-announce on every one of the monitor's 1 Hz ticks.
    if new.onAC, new.percent >= 100, old.percent < 100 {
      out.append(.chargeComplete(percent: new.percent))
    }
    if !new.onAC {
      let crossed = lowBatteryDetector.crossings(
        from: Double(old.percent), to: Double(new.percent))
      for t in crossed {
        out.append(.lowBattery(threshold: Int(t), percent: new.percent))
      }
    }
    return out
  }
}
