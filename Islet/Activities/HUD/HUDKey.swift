import Foundation

enum HUDKey: Hashable {
  case volumeUp, volumeDown, mute, brightnessUp, brightnessDown

  /// Decodes a system-defined NSEvent's `data1`. Returns nil for keys we don't handle.
  static func decode(data1: Int) -> (key: HUDKey, isKeyDown: Bool)? {
    let keyCode = (data1 & 0xFFFF_0000) >> 16
    let state = (data1 & 0xFF00) >> 8  // 0xA = down, 0xB = up
    let key: HUDKey
    switch keyCode {
    case 0: key = .volumeUp
    case 1: key = .volumeDown
    case 7: key = .mute
    case 2: key = .brightnessUp
    case 3: key = .brightnessDown
    default: return nil
    }
    return (key, state == 0xA)
  }

  var isBrightness: Bool { self == .brightnessUp || self == .brightnessDown }
}

enum HUDMath {
  static let step: Float = 1.0 / 16.0

  /// One media-key press of movement. `divisor` > 1 gives finer steps (e.g. option+shift).
  static func stepped(_ value: Float, up: Bool, divisor: Float = 1) -> Float {
    let delta = step / max(divisor, 0.25)
    return max(0, min(1, value + (up ? delta : -delta)))
  }
}

struct HUDKeyConsumptionState {
  private var consumedKeyDowns: Set<HUDKey> = []

  mutating func recordKeyDown(_ key: HUDKey, applied: Bool) -> Bool {
    if applied {
      consumedKeyDowns.insert(key)
    } else {
      consumedKeyDowns.remove(key)
    }
    return applied
  }

  mutating func shouldConsumeKeyUp(_ key: HUDKey) -> Bool {
    consumedKeyDowns.remove(key) != nil
  }

  mutating func reset() {
    consumedKeyDowns.removeAll()
  }
}
