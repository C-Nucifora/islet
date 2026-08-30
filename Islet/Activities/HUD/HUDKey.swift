import Foundation

enum HUDKey: Hashable {
  case volumeUp, volumeDown, mute, brightnessUp, brightnessDown

  /// Decodes a system-defined NSEvent's `data1`. Returns nil for keys we don't handle.
  static func decode(data1: Int) -> (key: HUDKey, isKeyDown: Bool)? {
    let keyCode = (data1 & 0xFFFF_0000) >> 16
    let state = (data1 & 0xFF00) >> 8  // 0xA = down, 0xB = up
    guard state == 0xA || state == 0xB else { return nil }
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

/// CoreAudio devices sometimes expose both a master scalar and per-channel scalars. Writing all
/// of them can destroy a user's channel balance; prefer master when present, otherwise channels.
enum VolumeControlLayout {
  static func preferredElements(
    from available: [UInt32], master: UInt32 = 0
  ) -> [UInt32] {
    let unique = Array(Set(available))
    if unique.contains(master) { return [master] }
    return unique.sorted()
  }

  /// Shift every channel by the same delta so devices without a master scalar retain their
  /// left/right balance (subject only to unavoidable clamping at 0 and 1).
  static func shiftedValues(
    _ originals: [UInt32: Float], reference: Float, target: Float
  ) -> [UInt32: Float] {
    let delta = target - reference
    return originals.mapValues { max(0, min(1, $0 + delta)) }
  }

  /// Moves a device's virtual master in one write when it has one. Otherwise, this makes a
  /// best-effort transaction across every reported output channel and restores the old values if
  /// any write or readback fails. CoreAudio has no multi-property volume-set API for individual
  /// channels, so rollback is the closest available fallback to a single master write.
  static func apply(
    target: Float,
    reportedElements: [UInt32],
    read: (UInt32) -> Float?,
    write: (UInt32, Float) -> Bool
  ) -> Bool {
    let elements = preferredElements(from: reportedElements)
    guard !elements.isEmpty else { return false }

    let originals = Dictionary(
      uniqueKeysWithValues: elements.compactMap { element in
        read(element).map { (element, $0) }
      })
    guard originals.count == elements.count,
      let referenceElement = elements.first,
      let reference = originals[referenceElement]
    else { return false }

    let targets = shiftedValues(originals, reference: reference, target: max(0, min(1, target)))
    var written: [UInt32] = []
    for element in elements {
      guard let value = targets[element], write(element, value) else {
        restore(written, originals: originals, write: write)
        return false
      }
      written.append(element)
    }

    let verified = elements.allSatisfy { element in
      guard let value = targets[element], let readback = read(element) else { return false }
      return abs(readback - value) <= 0.02
    }
    guard verified else {
      restore(written, originals: originals, write: write)
      return false
    }
    return true
  }

  private static func restore(
    _ elements: [UInt32], originals: [UInt32: Float], write: (UInt32, Float) -> Bool
  ) {
    for element in elements.reversed() {
      guard let original = originals[element] else { continue }
      _ = write(element, original)
    }
  }
}

/// Tracks which key-up events may be suppressed. A failed key-down and its key-up must both reach
/// macOS; a successfully handled key-down and its key-up must both be hidden from macOS.
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
