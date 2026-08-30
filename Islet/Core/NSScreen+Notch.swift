import AppKit

extension NSScreen {
  /// Quartz display id behind this screen. Keep the conversion in one place: AppKit screen frames
  /// use a bottom-left coordinate system, while CGWindow bounds and CGDisplayBounds use Quartz's
  /// top-left display coordinates.
  var displayID: CGDirectDisplayID? {
    (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
  }

  var isBuiltin: Bool {
    guard let displayID else { return false }
    return CGDisplayIsBuiltin(displayID) == 1
  }

  static var builtin: NSScreen? { screens.first { $0.isBuiltin } }

  static var screenWithMouse: NSScreen? {
    let location = NSEvent.mouseLocation
    return screens.first { NSMouseInRect(location, $0.frame, false) }
  }

  /// Stable identifier that survives display reconfiguration (unlike NSScreen identity).
  var displayUUID: String? {
    guard let displayID,
      let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue()
    else { return nil }
    return CFUUIDCreateString(nil, uuid) as String
  }

  /// A conservative fallback for the rare reconfiguration where macOS changes a display UUID.
  /// Built-in displays are unique. An external display must report a serial number before it is
  /// safe to distinguish it from another monitor of the same model.
  var displayHardwareIdentity: DisplayHardwareIdentity? {
    guard let displayID else { return nil }
    if isBuiltin { return .builtin }
    let serial = CGDisplaySerialNumber(displayID)
    guard serial != 0 else { return nil }
    return .external(
      vendor: CGDisplayVendorNumber(displayID), model: CGDisplayModelNumber(displayID),
      serial: serial)
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
