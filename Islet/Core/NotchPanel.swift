import AppKit

/// The panel itself owns file-drop registration. SwiftUI hit testing is disabled while collapsed
/// so clicks reach the app underneath, which also prevents a SwiftUI `.onDrop` from being targeted.
/// AppKit's window-level drag destination remains active in both collapsed and expanded states.
final class NotchPanel: NSPanel, NSDraggingDestination {
  var acceptsFileDrops: (() -> Bool)?
  var fileDragTargetChanged: ((Bool) -> Void)?
  var fileURLsDropped: (([URL]) -> Bool)?
  private var isFileDragTargeted = false
  var keyboardCommandHandler: ((IslandKeyboardCommand) -> Bool)?

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
    registerForDraggedTypes([.fileURL])
  }

  // A nonactivating panel can accept focus without bringing the accessory app to the foreground.
  // The panel remains mouse-transparent while closed, so it only joins keyboard navigation after
  // the user or VoiceOver enters the expanded island.
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }

  func updateKeyboardFocus(isExpanded: Bool) {
    if isExpanded {
      makeKey()
    } else if isKeyWindow {
      resignKey()
    }
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    if dispatchKeyboardCommand(event) { return true }
    return super.performKeyEquivalent(with: event)
  }

  override func keyDown(with event: NSEvent) {
    if dispatchKeyboardCommand(event) { return }
    super.keyDown(with: event)
  }

  /// AppKit is otherwise free to adjust the rect handed to `setFrame` — to keep a title bar on
  /// screen, to respect the menu bar, to fit a "usable" area. The island is positioned to the pixel
  /// against the hardware notch and deliberately overlaps the menu bar, so every such adjustment is
  /// wrong, and because the adjusted rect was never read back it was also permanent.
  override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
    frameRect
  }

  func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
    fileDragOperation(for: sender.draggingPasteboard)
  }

  func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
    fileDragOperation(for: sender.draggingPasteboard)
  }

  func draggingExited(_ sender: (any NSDraggingInfo)?) {
    setFileDragTargeted(false)
  }

  func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
    performFileDrop(from: sender.draggingPasteboard)
  }

  func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
    setFileDragTargeted(false)
  }

  func draggingEnded(_ sender: any NSDraggingInfo) {
    setFileDragTargeted(false)
  }

  override func close() {
    setFileDragTargeted(false)
    super.close()
  }

  /// Internal entry points keep the pasteboard handling testable without synthesizing a private
  /// AppKit dragging session.
  func fileDragOperation(for pasteboard: NSPasteboard) -> NSDragOperation {
    guard acceptsFileDrops?() ?? true, !Self.fileURLs(from: pasteboard).isEmpty else {
      setFileDragTargeted(false)
      return []
    }
    setFileDragTargeted(true)
    return .copy
  }

  func performFileDrop(from pasteboard: NSPasteboard) -> Bool {
    guard acceptsFileDrops?() ?? true else {
      setFileDragTargeted(false)
      return false
    }
    let urls = Self.fileURLs(from: pasteboard)
    let accepted = !urls.isEmpty && (fileURLsDropped?(urls) ?? false)
    setFileDragTargeted(false)
    return accepted
  }

  static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
    let objects =
      pasteboard.readObjects(
        forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ?? []
    return objects.compactMap { object in
      guard let url = object as? NSURL else { return nil }
      return url as URL
    }
  }

  private func setFileDragTargeted(_ targeted: Bool) {
    guard targeted != isFileDragTargeted else { return }
    isFileDragTargeted = targeted
    fileDragTargetChanged?(targeted)
  }

  private func dispatchKeyboardCommand(_ event: NSEvent) -> Bool {
    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    var mappedModifiers: IslandKeyboardModifiers = []
    if modifiers.contains(.command) { mappedModifiers.insert(.command) }
    if modifiers.contains(.control) { mappedModifiers.insert(.control) }
    if modifiers.contains(.option) { mappedModifiers.insert(.option) }
    if modifiers.contains(.shift) { mappedModifiers.insert(.shift) }
    let isEditingText = firstResponder is NSTextView || firstResponder is NSTextField
    let stroke = IslandKeyStroke(
      key: event.charactersIgnoringModifiers ?? "", modifiers: mappedModifiers,
      isEditingText: isEditingText)
    guard let command = IslandKeyboardPolicy.command(for: stroke) else { return false }
    return keyboardCommandHandler?(command) ?? false
  }
}
