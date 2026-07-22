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

  var notchGeometry: NotchGeometry {
    NotchGeometry(
      screenFrame: frame,
      safeAreaTop: safeAreaInsets.top,
      auxLeftWidth: auxiliaryTopLeftArea?.width ?? 0,
      auxRightWidth: auxiliaryTopRightArea?.width ?? 0,
      menuBarHeight: frame.maxY - visibleFrame.maxY)
  }
}
