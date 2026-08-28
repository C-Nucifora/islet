import Combine
import Foundation

/// USB attach and detach.
///
/// `PortMonitor` has watched IOKit matching notifications since the Ports tab shipped and has never
/// said anything about them. This is the whole source: subscribe to the list it already publishes,
/// diff, emit.
@MainActor
final class PortEventSource: SystemEventSource {
  let id = "usb"
  let displayName = "USB devices"
  let tier = SystemEventTier.core

  private var cancellable: AnyCancellable?

  func start() {
    guard cancellable == nil else { return }
    guard PortMonitor.shared.start(owner: id) else { return }
    cancellable = PortMonitor.shared.$devices
      // The first value is the list as it stands at launch. Announcing it would fire one event per
      // already-connected device every time Islet starts.
      .dropFirst()
      .sink { [weak self] devices in
        self?.report(devices)
      }
  }

  func stop() {
    cancellable = nil
    PortMonitor.shared.stop(owner: id)
  }

  private func report(_ devices: [PortDevice]) {
    let diff = SetDiff.changes(from: PortMonitor.shared.previousDevices, to: devices)
    for device in diff.added {
      SystemEventBus.shared.emit(
        SystemEvent(
          sourceID: id, icon: "cable.connector", title: device.name,
          subtitle: [device.vendor, device.speed].compactMap { $0 }.joined(separator: " · "),
          accentHex: EventAccent.info, motion: .usb,
          announcement: "\(device.name) connected"))
    }
    for device in diff.removed {
      SystemEventBus.shared.emit(
        SystemEvent(
          sourceID: id, icon: "cable.connector.slash", title: device.name,
          subtitle: "Disconnected", accentHex: EventAccent.neutral, motion: .usb,
          urgency: .ambient,
          announcement: "\(device.name) disconnected"))
    }
  }
}
