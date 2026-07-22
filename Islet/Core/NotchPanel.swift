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
}
