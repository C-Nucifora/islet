import AppKit

extension NSScreen {
  var isBuiltin: Bool {
    guard let n = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
    else { return false }
    return CGDisplayIsBuiltin(n.uint32Value) == 1
  }

  static var builtin: NSScreen? { screens.first { $0.isBuiltin } }

  static var screenWithMouse: NSScreen? {
    let location = NSEvent.mouseLocation
    return screens.first { NSMouseInRect(location, $0.frame, false) }
  }

  /// Stable identifier that survives display reconfiguration (unlike NSScreen identity).
  var displayUUID: String? {
    guard let n = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
      let uuid = CGDisplayCreateUUIDFromDisplayID(n.uint32Value)?.takeRetainedValue()
    else { return nil }
    return CFUUIDCreateString(nil, uuid) as String
  }

  /// The notch numbers AppKit reports right now. Split out from geometry construction so callers
  /// can run the reading through `NotchStickiness` first — these can come back empty transiently,
  /// and an empty reading silently means "no notch, use the 200pt fallback".
  var notchReading: NotchStickiness.Reading {
    NotchStickiness.Reading(
      safeAreaTop: safeAreaInsets.top,
      auxLeftWidth: auxiliaryTopLeftArea?.width ?? 0,
      auxRightWidth: auxiliaryTopRightArea?.width ?? 0)
  }

  /// Geometry for this screen from an explicit reading, so the caller decides whether that reading
  /// is the live one or a remembered one.
  func notchGeometry(reading: NotchStickiness.Reading) -> NotchGeometry {
    NotchGeometry(
      screenFrame: frame,
      safeAreaTop: reading.safeAreaTop,
      auxLeftWidth: reading.auxLeftWidth,
      auxRightWidth: reading.auxRightWidth,
      menuBarHeight: frame.maxY - visibleFrame.maxY)
  }
}
