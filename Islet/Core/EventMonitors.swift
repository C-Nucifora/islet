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
  let mouseDown = PassthroughSubject<CGPoint, Never>()

  private var movementMonitor: PairedMonitor?
  private var downMonitor: PairedMonitor?
  private var interactionModeCancellable: AnyCancellable?
  private var wasInTopInteractionBand = false

  func start() {
    guard downMonitor == nil else { return }
    let down = PairedMonitor(mask: [.leftMouseDown]) { [weak self] _ in
      self?.mouseDown.send(NSEvent.mouseLocation)
    }
    downMonitor = down
    down.start()
    interactionModeCancellable = Defaults.publisher(.interactionMode)
      .sink { [weak self] change in
        Task { @MainActor in self?.setMovementMonitoring(change.newValue == .hover) }
      }
    setMovementMonitoring(Defaults[.interactionMode] == .hover)
  }

  func stop() {
    movementMonitor?.stop()
    movementMonitor = nil
    downMonitor?.stop()
    downMonitor = nil
    interactionModeCancellable = nil
    wasInTopInteractionBand = false
  }

  private func setMovementMonitoring(_ enabled: Bool) {
    if enabled {
      guard movementMonitor == nil else { return }
      let move = PairedMonitor(mask: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
        guard let self else { return }
        self.forwardMovementIfRelevant(event)
      }
      movementMonitor = move
      move.start()
    } else {
      if movementMonitor != nil {
        // Resolve any hover-owned peek/unpinned expansion before removing the only producer that
        // can deliver an exit. Without this, changing to click-to-pin while peeking can strand the
        // island in `.peek` until the next click.
        mouseMovement.send(
          MouseMovement(location: CGPoint(x: -1_000_000, y: -1_000_000), deviceDeltaY: 0))
      }
      movementMonitor?.stop()
      movementMonitor = nil
      wasInTopInteractionBand = false
    }
  }

  private func forwardMovementIfRelevant(_ event: NSEvent) {
    let location = NSEvent.mouseLocation
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
