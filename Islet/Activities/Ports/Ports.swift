import Combine
import IOKit
import IOKit.usb
import SwiftUI

struct PortDevice: Identifiable, Equatable {
  /// A registry-entry ID plus the IOService path. The path is part of the key so moving a device
  /// to a different physical port is intentionally reported as a detach followed by an attach.
  let id: String
  let name: String
  let vendor: String?
  let speed: String?
  let locationID: UInt32?

  /// A short port label derived from the location ID's controller nibble.
  var portLabel: String {
    guard let locationID else { return "Port unavailable" }
    return String(format: "Port %X", (locationID >> 24) & 0xFF)
  }
}

/// The identity inputs IOKit exposes for one USB registry entry. Keeping them separate from
/// `PortDevice` lets the identity rule be tested without a physical USB device.
struct USBDeviceRegistryEntry {
  let registryEntryID: UInt64?
  let servicePath: String?
  let locationID: UInt32?
  let productName: String?
  let vendorName: String?
  let deviceSpeed: Int?
}

enum PortDeviceIdentity {
  /// Builds a key from data owned by the registry entry, never from a display property such as a
  /// product name. The registry ID is stable for the connected entry. The service path identifies
  /// its physical attachment point, so a move gets a new identity even if IOKit reuses an ID.
  ///
  /// If neither source is available, there is no stable unique key to publish. The reader omits
  /// that entry rather than creating a product-name collision in SwiftUI or device diffs.
  static func make(registryEntryID: UInt64?, servicePath: String?) -> String? {
    let path = servicePath?.trimmingCharacters(in: .whitespacesAndNewlines)
    switch (registryEntryID, path?.isEmpty == false ? path : nil) {
    case (let entryID?, let path?):
      return String(format: "registry:%016llX|path:%@", entryID, path)
    case (let entryID?, nil):
      return String(format: "registry:%016llX", entryID)
    case (nil, let path?):
      return "path:\(path)"
    case (nil, nil):
      return nil
    }
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
      if let device = device(from: registryEntry(for: service)) { out.append(device) }
      IOObjectRelease(service)
      service = IOIteratorNext(iterator)
    }
    return out.sorted { $0.id < $1.id }
  }

  static func device(from entry: USBDeviceRegistryEntry) -> PortDevice? {
    guard
      let id = PortDeviceIdentity.make(
        registryEntryID: entry.registryEntryID, servicePath: entry.servicePath)
    else { return nil }
    let name = entry.productName?.isEmpty == false ? entry.productName : nil

    return PortDevice(
      id: id,
      name: name ?? "USB Device",
      vendor: entry.vendorName,
      speed: speedString(entry.deviceSpeed),
      locationID: entry.locationID)
  }

  private static func registryEntry(for service: io_service_t) -> USBDeviceRegistryEntry {
    USBDeviceRegistryEntry(
      registryEntryID: registryEntryID(service),
      servicePath: registryPath(service),
      locationID: intProp(service, "locationID").map { UInt32(truncatingIfNeeded: $0) },
      productName: strProp(service, "USB Product Name"),
      vendorName: strProp(service, "USB Vendor Name"),
      deviceSpeed: intProp(service, "Device Speed"))
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

  private static func registryEntryID(_ service: io_service_t) -> UInt64? {
    var entryID: UInt64 = 0
    guard IORegistryEntryGetRegistryEntryID(service, &entryID) == KERN_SUCCESS else { return nil }
    return entryID
  }

  private static func registryPath(_ service: io_service_t) -> String? {
    var path = [CChar](repeating: 0, count: 1_024)
    let result = path.withUnsafeMutableBufferPointer {
      IORegistryEntryGetPath(service, kIOServicePlane, $0.baseAddress)
    }
    guard result == KERN_SUCCESS else { return nil }
    return String(cString: path)
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

  @discardableResult
  func start(owner: String) -> Bool {
    let inserted = owners.insert(owner).inserted
    guard inserted, notifyPort == nil else { return notifyPort != nil }
    refresh()
    notifyPort = IONotificationPortCreate(kIOMainPortDefault)
    guard let notifyPort else {
      // Do not strand the owner in a logically-running state after setup fails. A later lifecycle
      // reconciliation must be able to retry rather than hitting the duplicate-owner guard.
      owners.remove(owner)
      return false
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
      return false
    }
    return true
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
