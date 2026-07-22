import AppKit
import Combine

/// Paired global+local NSEvent monitors. Global monitors miss our own events,
/// local ones miss other apps' — you need both (NotchDrop pattern).
final class PairedMonitor {
  private let mask: NSEvent.EventTypeMask
  private let handler: () -> Void
  private var global: Any?
  private var local: Any?

  init(mask: NSEvent.EventTypeMask, handler: @escaping () -> Void) {
    self.mask = mask
    self.handler = handler
  }

  func start() {
    global = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
      self?.handler()
    }
    local = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
      self?.handler()
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

@MainActor
final class EventMonitors {
  static let shared = EventMonitors()

  let mouseLocation = CurrentValueSubject<CGPoint, Never>(.zero)
  let mouseDown = PassthroughSubject<CGPoint, Never>()

  private var monitors: [PairedMonitor] = []

  func start() {
    guard monitors.isEmpty else { return }
    let move = PairedMonitor(mask: [.mouseMoved, .leftMouseDragged]) { [weak self] in
      self?.mouseLocation.send(NSEvent.mouseLocation)
    }
    let down = PairedMonitor(mask: [.leftMouseDown]) { [weak self] in
      self?.mouseDown.send(NSEvent.mouseLocation)
    }
    monitors = [move, down]
    for monitor in monitors { monitor.start() }
  }
}
