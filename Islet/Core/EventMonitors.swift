import AppKit
import Combine

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

  private var monitors: [PairedMonitor] = []

  func start() {
    guard monitors.isEmpty else { return }
    let move = PairedMonitor(mask: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
      self?.mouseMovement.send(
        MouseMovement(location: NSEvent.mouseLocation, deviceDeltaY: event.deltaY))
    }
    let down = PairedMonitor(mask: [.leftMouseDown]) { [weak self] _ in
      self?.mouseDown.send(NSEvent.mouseLocation)
    }
    monitors = [move, down]
    for monitor in monitors { monitor.start() }
  }
}
