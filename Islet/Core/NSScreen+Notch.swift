import AppKit

extension NSScreen {
  var isBuiltin: Bool {
    guard let n = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
    else { return false }
    return CGDisplayIsBuiltin(n.uint32Value) == 1
  }

  static var builtin: NSScreen? { screens.first { $0.isBuiltin } }

  var notchGeometry: NotchGeometry {
    NotchGeometry(
      screenFrame: frame,
      safeAreaTop: safeAreaInsets.top,
      auxLeftWidth: auxiliaryTopLeftArea?.width ?? 0,
      auxRightWidth: auxiliaryTopRightArea?.width ?? 0,
      menuBarHeight: frame.maxY - visibleFrame.maxY)
  }
}
