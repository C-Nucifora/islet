import Foundation

struct BatteryState: Equatable {
  var percent: Int = 100
  var isCharging = false
  var onAC = false
}

enum BatteryEvent: Equatable {
  case acConnected(percent: Int)
  case acDisconnected(percent: Int)
  case lowBattery(threshold: Int, percent: Int)
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
