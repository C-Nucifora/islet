import Combine
import IOKit
import IOKit.usb
import SwiftUI

struct PortDevice: Identifiable, Equatable {
  let id: String  // locationID hex — unique per physical port path
  let name: String
  let vendor: String?
  let speed: String?

  /// A short port label derived from the location ID's controller nibble.
  var portLabel: String {
    guard id.hasPrefix("0x"), let value = UInt32(id.dropFirst(2), radix: 16) else { return id }
    return String(format: "Port %X", (value >> 24) & 0xFF)
  }
}

/// Enumerates connected USB devices (name, vendor, negotiated speed, port).
enum PortsReader {
  static func read() -> [PortDevice] {
    var iterator: io_iterator_t = 0
    guard
      IOServiceGetMatchingServices(
        kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator) == KERN_SUCCESS
    else { return [] }
    defer { IOObjectRelease(iterator) }

    var out: [PortDevice] = []
    var service = IOIteratorNext(iterator)
    while service != 0 {
      if let name = strProp(service, "USB Product Name") {
        let loc =
          intProp(service, "locationID")
          .map { String(format: "0x%08X", UInt32(truncatingIfNeeded: $0)) } ?? name
        out.append(
          PortDevice(
            id: loc, name: name, vendor: strProp(service, "USB Vendor Name"),
            speed: speedString(intProp(service, "Device Speed"))))
      }
      IOObjectRelease(service)
      service = IOIteratorNext(iterator)
    }
    return out.sorted { $0.id < $1.id }
  }

  private static func speedString(_ speed: Int?) -> String? {
    switch speed {
    case 0: "1.5 Mbps"
    case 1: "12 Mbps"
    case 2: "480 Mbps"
    case 3: "5 Gbps"
    case 4: "10 Gbps"
    case 5: "20 Gbps"
    default: nil
    }
  }

  private static func strProp(_ service: io_service_t, _ key: String) -> String? {
    IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
      .takeRetainedValue() as? String
  }

  private static func intProp(_ service: io_service_t, _ key: String) -> Int? {
    (IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
      .takeRetainedValue() as? NSNumber)?.intValue
  }
}

/// Watches USB attach/detach via IOKit matching notifications (no polling) and republishes.
@MainActor
final class PortMonitor: ObservableObject {
  static let shared = PortMonitor()

  @Published private(set) var devices: [PortDevice] = []

  private var notifyPort: IONotificationPortRef?
  private var iterators: [io_iterator_t] = []
  private var owners: Set<String> = []

  func start(owner: String) {
    let inserted = owners.insert(owner).inserted
    guard inserted, notifyPort == nil else { return }
    refresh()
    notifyPort = IONotificationPortCreate(kIOMainPortDefault)
    guard let notifyPort else {
      // Do not strand the owner in a logically-running state after setup fails. A later lifecycle
      // reconciliation must be able to retry rather than hitting the duplicate-owner guard.
      owners.remove(owner)
      return
    }
    IONotificationPortSetDispatchQueue(notifyPort, DispatchQueue.main)

    let context = Unmanaged.passUnretained(self).toOpaque()
    let callback: IOServiceMatchingCallback = { context, iterator in
      var service = IOIteratorNext(iterator)
      while service != 0 {  // draining re-arms the notification
        IOObjectRelease(service)
        service = IOIteratorNext(iterator)
      }
      if let context {
        Unmanaged<PortMonitor>.fromOpaque(context).takeUnretainedValue().scheduleRefresh()
      }
    }

    for type in [kIOMatchedNotification, kIOTerminatedNotification] {
      var iterator: io_iterator_t = 0
      let match = IOServiceMatching("IOUSBHostDevice")
      if IOServiceAddMatchingNotification(notifyPort, type, match, callback, context, &iterator)
        == KERN_SUCCESS
      {
        var service = IOIteratorNext(iterator)  // arm
        while service != 0 {
          IOObjectRelease(service)
          service = IOIteratorNext(iterator)
        }
        iterators.append(iterator)
      } else if iterator != 0 {
        IOObjectRelease(iterator)
      }
    }
    if iterators.count != 2 {
      tearDownNotifications()
      owners.remove(owner)
      Log.app.error("Could not register both USB matching notifications")
    }
  }

  func stop(owner: String) {
    owners.remove(owner)
    guard owners.isEmpty else { return }
    tearDownNotifications()
    previousDevices = devices
    devices = []
  }

  private func tearDownNotifications() {
    for iterator in iterators { IOObjectRelease(iterator) }
    iterators.removeAll()
    if let notifyPort {
      IONotificationPortDestroy(notifyPort)
      self.notifyPort = nil
    }
  }

  nonisolated private func scheduleRefresh() {
    Task { @MainActor in self.refresh() }
  }

  /// The list as it was before the most recent refresh, so an observer can diff the two. Kept here
  /// rather than in the observer because the IOKit callback can fire twice before an observer runs,
  /// and a diff against a stale snapshot reports a device twice.
  private(set) var previousDevices: [PortDevice] = []

  func refresh() {
    let next = PortsReader.read()
    guard next != devices else { return }  // IOKit re-arms fire spuriously; don't republish
    previousDevices = devices
    devices = next
  }
}
