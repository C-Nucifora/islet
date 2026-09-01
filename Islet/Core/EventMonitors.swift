import AppKit
import Combine
import Defaults

/// Paired global+local NSEvent monitors. Global monitors miss our own events,
/// local ones miss other apps' — you need both (NotchDrop pattern).
final class PairedMonitor {
  private let mask: NSEvent.EventTypeMask
  private let handler: (NSEvent) -> Void
  private var global: Any?
  private var local: Any?

  init(mask: NSEvent.EventTypeMask, handler: @escaping (NSEvent) -> Void) {
    self.mask = mask
    self.handler = handler
  }

  func start() {
    global = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
      self?.handler(event)
    }
    local = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
      self?.handler(event)
      return event
    }
  }

  func stop() {
    if let global { NSEvent.removeMonitor(global) }
    if let local { NSEvent.removeMonitor(local) }
    global = nil
    local = nil
  }
}

struct MouseMovement: Equatable {
  let location: CGPoint
  let deviceDeltaY: CGFloat
}

@MainActor
final class EventMonitors {
  static let shared = EventMonitors()

  let mouseMovement = CurrentValueSubject<MouseMovement, Never>(
    MouseMovement(location: .zero, deviceDeltaY: 0))
  /// Pointer movement in the top interaction band, including in click-to-pin mode. The oversized
  /// expanded hosting window uses this to pass events through wherever no island is drawn.
  let pointerMovement = PassthroughSubject<CGPoint, Never>()
  let fileDragMovement = PassthroughSubject<CGPoint, Never>()
  let mouseDown = PassthroughSubject<CGPoint, Never>()

  private var movementMonitor: PairedMonitor?
  private var fileDragMonitor: PairedMonitor?
  private var downMonitor: PairedMonitor?
  private var interactionModeCancellable: AnyCancellable?
  private var wasInTopInteractionBand = false
  private var wasPointerInTopInteractionBand = false
  private var wasFileDragInTopInteractionBand = false
  private var forwardsHoverMovement = false
  private var pointerPassthroughDemand: Set<UUID> = []

  func start() {
    guard downMonitor == nil else { return }
    let down = PairedMonitor(mask: [.leftMouseDown]) { [weak self] _ in
      self?.mouseDown.send(NSEvent.mouseLocation)
    }
    downMonitor = down
    down.start()
    let fileDrag = PairedMonitor(mask: [.leftMouseDragged]) { [weak self] _ in
      guard Self.dragPasteboardContainsFileURLs() else { return }
      guard let self else { return }
      self.forwardFileDragIfRelevant(
        NSEvent.mouseLocation,
        shelfAvailable: ActivityCenter.shared.isAvailableInExpandedSwitcher("shelf"))
    }
    fileDragMonitor = fileDrag
    fileDrag.start()
    interactionModeCancellable = Defaults.publisher(.interactionMode)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] change in self?.setMovementMonitoring(change.newValue == .hover) }
    setMovementMonitoring(Defaults[.interactionMode] == .hover)
  }

  func stop() {
    movementMonitor?.stop()
    movementMonitor = nil
    fileDragMonitor?.stop()
    fileDragMonitor = nil
    downMonitor?.stop()
    downMonitor = nil
    interactionModeCancellable = nil
    pointerPassthroughDemand.removeAll()
    wasInTopInteractionBand = false
    wasPointerInTopInteractionBand = false
    wasFileDragInTopInteractionBand = false
  }

  private func setMovementMonitoring(_ enabled: Bool) {
    if !enabled, forwardsHoverMovement {
      // Resolve any hover-owned peek/unpinned expansion before stopping hover delivery. The
      // underlying pointer monitor stays active because window passthrough needs it in both modes.
      mouseMovement.send(
        MouseMovement(location: CGPoint(x: -1_000_000, y: -1_000_000), deviceDeltaY: 0))
      wasInTopInteractionBand = false
    }
    forwardsHoverMovement = enabled
    updateMovementMonitor()
  }

  func setPointerPassthroughNeeded(_ needed: Bool, sourceID: UUID) {
    if needed {
      pointerPassthroughDemand.insert(sourceID)
    } else {
      pointerPassthroughDemand.remove(sourceID)
    }
    updateMovementMonitor()
  }

  private func updateMovementMonitor() {
    let shouldRun = Self.shouldRunMovementMonitor(
      hoverEnabled: forwardsHoverMovement,
      pointerPassthroughDemandCount: pointerPassthroughDemand.count)
    guard shouldRun != (movementMonitor != nil) else { return }
    guard shouldRun else {
      movementMonitor?.stop()
      movementMonitor = nil
      wasPointerInTopInteractionBand = false
      return
    }

    let move = PairedMonitor(mask: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
      guard let self else { return }
      let location = NSEvent.mouseLocation
      if !self.pointerPassthroughDemand.isEmpty {
        self.forwardPointerMovementIfRelevant(location)
      }
      // A Finder drag hovering over the notch opens the Shelf immediately. Do not also feed the
      // same event into the ordinary hover barrier.
      if event.type == .leftMouseDragged, Self.dragPasteboardContainsFileURLs() { return }
      guard self.forwardsHoverMovement else { return }
      self.forwardMovementIfRelevant(event, location: location)
    }
    movementMonitor = move
    move.start()
  }

  nonisolated static func shouldRunMovementMonitor(
    hoverEnabled: Bool, pointerPassthroughDemandCount: Int
  ) -> Bool {
    hoverEnabled || pointerPassthroughDemandCount > 0
  }

  nonisolated static func pasteboardContainsFileURLs(_ pasteboard: NSPasteboard) -> Bool {
    pasteboard.canReadObject(
      forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
  }

  private nonisolated static func dragPasteboardContainsFileURLs() -> Bool {
    pasteboardContainsFileURLs(NSPasteboard(name: .drag))
  }

  private func forwardMovementIfRelevant(_ event: NSEvent, location: CGPoint) {
    let isRelevant = Self.isInTopInteractionBand(
      location, screenFrames: NSScreen.screens.map(\.frame))
    // Forward the first event outside the band as well. That is the event that tells an expanded
    // island its pointer exited; every later movement in the rest of the desktop is irrelevant.
    guard isRelevant || wasInTopInteractionBand else { return }
    wasInTopInteractionBand = isRelevant

    // The on-screen cursor stops changing at a display edge, but Core Graphics keeps the raw
    // device delta in the event. Preserve it so pressure gestures can continue past that edge.
    let rawDelta = event.cgEvent?.getIntegerValueField(.mouseEventDeltaY) ?? 0
    mouseMovement.send(
      MouseMovement(
        location: location,
        deviceDeltaY: rawDelta == 0 ? event.deltaY : CGFloat(rawDelta)))
  }

  private func forwardPointerMovementIfRelevant(_ location: CGPoint) {
    let screenFrames = NSScreen.screens.map(\.frame)
    let isRelevant = Self.isInTopInteractionBand(location, screenFrames: screenFrames)
    let shouldForward = Self.shouldForwardTopBandMovement(
      location, screenFrames: screenFrames,
      wasInTopInteractionBand: wasPointerInTopInteractionBand)
    wasPointerInTopInteractionBand = isRelevant
    if shouldForward { pointerMovement.send(location) }
  }

  private func forwardFileDragIfRelevant(_ location: CGPoint, shelfAvailable: Bool) {
    guard shelfAvailable else {
      if wasFileDragInTopInteractionBand {
        fileDragMovement.send(CGPoint(x: -1_000_000, y: -1_000_000))
      }
      wasFileDragInTopInteractionBand = false
      return
    }

    let screenFrames = NSScreen.screens.map(\.frame)
    let isRelevant = Self.isInTopInteractionBand(location, screenFrames: screenFrames)
    let shouldForward = Self.shouldForwardFileDrag(
      location, screenFrames: screenFrames, shelfAvailable: shelfAvailable,
      wasInTopInteractionBand: wasFileDragInTopInteractionBand)
    wasFileDragInTopInteractionBand = isRelevant
    if shouldForward { fileDragMovement.send(location) }
  }

  nonisolated static func shouldForwardTopBandMovement(
    _ location: CGPoint, screenFrames: [CGRect], wasInTopInteractionBand: Bool
  ) -> Bool {
    isInTopInteractionBand(location, screenFrames: screenFrames) || wasInTopInteractionBand
  }

  nonisolated static func shouldForwardFileDrag(
    _ location: CGPoint, screenFrames: [CGRect], shelfAvailable: Bool,
    wasInTopInteractionBand: Bool
  ) -> Bool {
    shelfAvailable
      && shouldForwardTopBandMovement(
        location, screenFrames: screenFrames,
        wasInTopInteractionBand: wasInTopInteractionBand)
  }

  nonisolated static func isInTopInteractionBand(
    _ location: CGPoint, screenFrames: [CGRect]
  ) -> Bool {
    // Tall content plus a generous exit margin. The global monitor still receives OS events, but
    // this prevents Combine and every per-display view model from processing desktop-wide motion.
    let depth = Metrics.tallExpandedHeight + Metrics.shadowPadding + 64
    return screenFrames.contains { frame in
      return location.x >= frame.minX && location.x <= frame.maxX
        && location.y >= frame.maxY - depth && location.y <= frame.maxY
    }
  }
}
