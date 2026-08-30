import Combine
import Foundation
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
  /// The negotiated bit rate exposed by the USB host stack, in bits per second.
  let linkSpeed: Int?
  /// The USB host connection-speed ID exposed by the matching property.
  let usbSpeed: Int?

  init(
    registryEntryID: UInt64?,
    servicePath: String?,
    locationID: UInt32?,
    productName: String?,
    vendorName: String?,
    deviceSpeed: Int?,
    linkSpeed: Int? = nil,
    usbSpeed: Int? = nil
  ) {
    self.registryEntryID = registryEntryID
    self.servicePath = servicePath
    self.locationID = locationID
    self.productName = productName
    self.vendorName = vendorName
    self.deviceSpeed = deviceSpeed
    self.linkSpeed = linkSpeed
    self.usbSpeed = usbSpeed
  }
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

/// A failed IOKit match is different from a successful enumeration with no devices. Keeping the
/// failure typed stops callers from interpreting a reader outage as a simultaneous detach.
enum PortEnumerationError: Error, Equatable, LocalizedError {
  case matchingServices(kern_return_t)

  var errorDescription: String? {
    switch self {
    case .matchingServices(let result):
      return String(format: "IOKit matching failed (0x%08X)", UInt32(bitPattern: result))
    }
  }
}

enum PortEnumerationResult: Equatable {
  case devices([PortDevice])
  case error(PortEnumerationError)
}

enum PortReaderHealth: Equatable {
  case awaitingFirstRead
  case current(lastSuccessfulRead: Date)
  case stale(error: PortEnumerationError, lastSuccessfulRead: Date)
  case failed(error: PortEnumerationError, lastSuccessfulRead: Date?)

  var summary: String {
    switch self {
    case .awaitingFirstRead:
      "Waiting for first enumeration"
    case .current:
      "Available"
    case .stale(let error, _):
      "Using the last USB snapshot. \(error.localizedDescription)"
    case .failed(let error, _):
      error.localizedDescription
    }
  }
}

/// Enumerates connected USB devices (name, vendor, negotiated speed, port).
enum PortsReader {
  static func read() -> PortEnumerationResult {
    var iterator: io_iterator_t = 0
    let result = IOServiceGetMatchingServices(
      kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator)
    guard result == KERN_SUCCESS else {
      if iterator != 0 { IOObjectRelease(iterator) }
      return .error(.matchingServices(result))
    }
    defer { IOObjectRelease(iterator) }

    var out: [PortDevice] = []
    var service = IOIteratorNext(iterator)
    while service != 0 {
      if let device = device(from: registryEntry(for: service)) { out.append(device) }
      IOObjectRelease(service)
      service = IOIteratorNext(iterator)
    }
    return .devices(out.sorted { $0.id < $1.id })
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
      speed: speedString(for: entry),
      locationID: entry.locationID)
  }

  private static func registryEntry(for service: io_service_t) -> USBDeviceRegistryEntry {
    USBDeviceRegistryEntry(
      registryEntryID: registryEntryID(service),
      servicePath: registryPath(service),
      locationID: intProp(service, kUSBHostPropertyLocationID).map {
        UInt32(truncatingIfNeeded: $0)
      },
      productName: strProp(service, kUSBProductString),
      vendorName: strProp(service, kUSBVendorString),
      deviceSpeed: intProp(service, kUSBDevicePropertySpeed),
      linkSpeed: intProp(service, kUSBHostPropertyLinkSpeed),
      usbSpeed: intProp(service, kUSBHostMatchingPropertySpeed))
  }

  private static func speedString(for entry: USBDeviceRegistryEntry) -> String? {
    if let linkSpeed = entry.linkSpeed {
      return linkSpeedString(linkSpeed)
    }
    if let usbSpeed = entry.usbSpeed {
      return usbSpeedString(usbSpeed)
    }
    return deviceSpeedString(entry.deviceSpeed)
  }

  private static func linkSpeedString(_ speed: Int) -> String {
    switch UInt64(bitPattern: Int64(speed)) {
    case UInt64(kIOUSBLinkSpeedLow): "1.5 Mbps"
    case UInt64(kIOUSBLinkSpeedFull): "12 Mbps"
    case UInt64(kIOUSBLinkSpeedHigh): "480 Mbps"
    case UInt64(kIOUSBLinkSpeed5Gbps): "5 Gbps"
    case UInt64(kIOUSBLinkSpeed10Gbps): "10 Gbps"
    case UInt64(kIOUSBLinkSpeed20Gbps): "20 Gbps"
    case UInt64(kIOUSBLinkSpeed40Gbps): "40 Gbps"
    case UInt64(kIOUSBLinkSpeed80Gbps): "80 Gbps"
    default: "Unknown (\(speed))"
    }
  }

  private static func usbSpeedString(_ speed: Int) -> String {
    switch speed {
    case Int(kIOUSBHostConnectionSpeedNone.rawValue): "Unknown (\(speed))"
    case Int(kIOUSBHostConnectionSpeedFull.rawValue): "12 Mbps"
    case Int(kIOUSBHostConnectionSpeedLow.rawValue): "1.5 Mbps"
    case Int(kIOUSBHostConnectionSpeedHigh.rawValue): "480 Mbps"
    case Int(kIOUSBHostConnectionSpeedSuper.rawValue): "5 Gbps"
    case Int(kIOUSBHostConnectionSpeedSuperPlus.rawValue): "10 Gbps"
    case Int(kIOUSBHostConnectionSpeedSuperPlusBy2.rawValue): "20 Gbps"
    case Int(kIOUSBHostConnectionSpeedOther.rawValue): "Unknown (\(speed))"
    default: "Unknown (\(speed))"
    }
  }

  private static func deviceSpeedString(_ speed: Int?) -> String? {
    switch speed {
    case Int(kUSBDeviceSpeedLow): "1.5 Mbps"
    case Int(kUSBDeviceSpeedFull): "12 Mbps"
    case Int(kUSBDeviceSpeedHigh): "480 Mbps"
    case Int(kUSBDeviceSpeedSuper): "5 Gbps"
    case Int(kUSBDeviceSpeedSuperPlus): "10 Gbps"
    case Int(kUSBDeviceSpeedSuperPlusBy2): "20 Gbps"
    case let speed?: "Unknown (\(speed))"
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
  /// Changes only after a successful IOKit enumeration. Event sources subscribe here rather than
  /// `devices`, because the UI deliberately clears an expired stale snapshot after a read failure.
  @Published private(set) var eventDevices: [PortDevice] = []
  @Published private(set) var readerHealth: PortReaderHealth = .awaitingFirstRead

  private var notifyPort: IONotificationPortRef?
  private var iterators: [io_iterator_t] = []
  private var owners: Set<String> = []
  private let reader: () -> PortEnumerationResult
  private let now: () -> Date
  private let monotonicNow: () -> TimeInterval
  private let gracePeriod: TimeInterval
  private var lastSuccessfulRead: Date?
  private var staleStartedAt: TimeInterval?
  private var graceExpiryTask: Task<Void, Never>?

  init(
    reader: @escaping () -> PortEnumerationResult = PortsReader.read,
    now: @escaping () -> Date = Date.init,
    monotonicNow: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
    gracePeriod: TimeInterval = 30
  ) {
    self.reader = reader
    self.now = now
    self.monotonicNow = monotonicNow
    self.gracePeriod = gracePeriod
  }

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
    graceExpiryTask?.cancel()
    graceExpiryTask = nil
    previousDevices = []
    devices = []
    eventDevices = []
    lastSuccessfulRead = nil
    staleStartedAt = nil
    readerHealth = .awaitingFirstRead
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

  /// The list as it was before the most recent successful enumeration, so an observer can diff the
  /// two. Keeping it here avoids duplicate notifications if IOKit fires twice before an observer.
  private(set) var previousDevices: [PortDevice] = []

  func refresh() {
    let timestamp = now()
    switch reader() {
    case .devices(let next):
      accept(next, at: timestamp)
    case .error(let error):
      record(error)
    }
  }

  /// Performs an immediate read for the diagnostics button or a caller that needs to recover from
  /// a failed matching pass without waiting for another IOKit notification.
  func retry() { refresh() }

  /// Called by the grace timer and exposed internally for deterministic clock-driven tests.
  func expireGraceIfNeeded() {
    guard case .stale(let error, let lastSuccessfulRead) = readerHealth,
      let staleStartedAt
    else { return }
    guard monotonicNow() >= staleStartedAt + gracePeriod else {
      scheduleGraceExpiry(from: staleStartedAt)
      return
    }

    readerHealth = .failed(error: error, lastSuccessfulRead: lastSuccessfulRead)
    if !devices.isEmpty { devices = [] }
    graceExpiryTask = nil
  }

  private func accept(_ next: [PortDevice], at timestamp: Date) {
    let isFirstSuccess = lastSuccessfulRead == nil
    graceExpiryTask?.cancel()
    graceExpiryTask = nil
    staleStartedAt = nil
    lastSuccessfulRead = timestamp
    readerHealth = .current(lastSuccessfulRead: timestamp)

    if next != devices { devices = next }
    guard next != eventDevices else { return }
    previousDevices = isFirstSuccess ? next : eventDevices
    eventDevices = next
  }

  private func record(_ error: PortEnumerationError) {
    guard let lastSuccessfulRead, gracePeriod > 0 else {
      staleStartedAt = nil
      graceExpiryTask?.cancel()
      graceExpiryTask = nil
      readerHealth = .failed(error: error, lastSuccessfulRead: lastSuccessfulRead)
      if !devices.isEmpty { devices = [] }
      return
    }

    let current = monotonicNow()
    let staleStartedAt = self.staleStartedAt ?? current
    guard current < staleStartedAt + gracePeriod else {
      graceExpiryTask?.cancel()
      graceExpiryTask = nil
      readerHealth = .failed(error: error, lastSuccessfulRead: lastSuccessfulRead)
      if !devices.isEmpty { devices = [] }
      return
    }

    self.staleStartedAt = staleStartedAt
    readerHealth = .stale(error: error, lastSuccessfulRead: lastSuccessfulRead)
    scheduleGraceExpiry(from: staleStartedAt)
  }

  private func scheduleGraceExpiry(from staleStartedAt: TimeInterval) {
    graceExpiryTask?.cancel()
    let delay = max(0, staleStartedAt + gracePeriod - monotonicNow())
    graceExpiryTask = Task { [weak self] in
      do {
        try await Task.sleep(for: .seconds(delay))
      } catch {
        return
      }
      guard !Task.isCancelled else { return }
      self?.expireGraceIfNeeded()
    }
  }
}
