import AppKit

final class NotchPanel: NSPanel {
  init(frame: CGRect) {
    super.init(
      contentRect: frame,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered, defer: false)
    isFloatingPanel = true
    isOpaque = false
    backgroundColor = .clear
    titleVisibility = .hidden
    titlebarAppearsTransparent = true
    isMovable = false
    isReleasedWhenClosed = false
    hasShadow = false
    level = .mainMenu + 3
    collectionBehavior = [.fullScreenAuxiliary, .stationary, .canJoinAllSpaces, .ignoresCycle]
    appearance = NSAppearance(named: .darkAqua)
  }

  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }

  /// AppKit is otherwise free to adjust the rect handed to `setFrame` — to keep a title bar on
  /// screen, to respect the menu bar, to fit a "usable" area. The island is positioned to the pixel
  /// against the hardware notch and deliberately overlaps the menu bar, so every such adjustment is
  /// wrong, and because the adjusted rect was never read back it was also permanent.
  override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
    frameRect
  }
}
