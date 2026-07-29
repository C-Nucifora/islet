import Foundation

/// Last-known hardware-notch measurements, per display.
///
/// `NSScreen.safeAreaInsets` and `auxiliaryTopLeftArea` / `auxiliaryTopRightArea` can read empty
/// transiently — during display reconfiguration, on wake, and around a Space switch.
/// `NotchGeometry.init` reads an empty triple as "no hardware notch" and falls back to a 200pt
/// rectangle centred on the screen, which on a built-in display is visibly wrong and survives until
/// the next rebuild.
///
/// This is written as a defensive floor rather than as a claim about undocumented AppKit behaviour:
/// a built-in display that has ever reported a notch keeps it, everything else is passed straight
/// through, and the caller logs every substitution so the transition is observable before anyone
/// relies on it.
///
/// Deliberately actor-free: pure logic, so tests call it synchronously.
struct NotchStickiness: Equatable {
  /// The three numbers `NotchGeometry` needs to decide whether a screen has a hardware notch.
  struct Reading: Equatable {
    var safeAreaTop: CGFloat
    var auxLeftWidth: CGFloat
    var auxRightWidth: CGFloat

    /// Matches `NotchGeometry.init`'s test exactly. When this is false the 200pt fallback applies.
    var hasNotch: Bool { safeAreaTop > 0 && auxLeftWidth > 0 && auxRightWidth > 0 }
  }

  private var lastNotched: [String: Reading] = [:]

  init() {}

  /// Records a notched reading, and substitutes the last recorded one when a BUILT-IN display reads
  /// empty. Returns `reading` untouched in every other case, so external displays and displays that
  /// never had a notch behave exactly as before.
  mutating func resolve(displayUUID: String, isBuiltin: Bool, reading: Reading) -> Reading {
    if reading.hasNotch {
      lastNotched[displayUUID] = reading
      return reading
    }
    guard isBuiltin, let remembered = lastNotched[displayUUID] else { return reading }
    return remembered
  }
}
