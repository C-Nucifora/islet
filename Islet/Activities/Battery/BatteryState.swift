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

  static func events(from old: BatteryState?, to new: BatteryState) -> [BatteryEvent] {
    guard let old else { return [] }  // first snapshot is baseline only
    var out: [BatteryEvent] = []
    if !old.onAC, new.onAC {
      out.append(.acConnected(percent: new.percent))
    } else if old.onAC, !new.onAC {
      out.append(.acDisconnected(percent: new.percent))
    }
    if !new.onAC {
      for t in Self.thresholds where old.percent > t && new.percent <= t {
        out.append(.lowBattery(threshold: t, percent: new.percent))
      }
    }
    return out
  }
}
