import AppKit
import Foundation
import IOBluetooth
import IOKit

struct PeripheralBattery: Identifiable, Equatable, Sendable {
  let id: String
  let name: String
  let percent: Int

  var deviceType: PeripheralDeviceType { PeripheralDeviceType(name: name) }

  var icon: String {
    deviceType.icon
  }
}

enum PeripheralDeviceType: String, CaseIterable, Codable, Identifiable, Sendable {
  case mouse
  case trackpad
  case keyboard
  case pencil
  case other

  var id: String { rawValue }

  init(name: String) {
    let value = name.lowercased()
    if value.contains("mouse") {
      self = .mouse
    } else if value.contains("trackpad") {
      self = .trackpad
    } else if value.contains("keyboard") {
      self = .keyboard
    } else if value.contains("pencil") {
      self = .pencil
    } else {
      self = .other
    }
  }

  var title: String {
    switch self {
    case .mouse: String(localized: "Mouse")
    case .trackpad: String(localized: "Trackpad")
    case .keyboard: String(localized: "Keyboard")
    case .pencil: String(localized: "Pencil")
    case .other: String(localized: "Other devices")
    }
  }

  var icon: String {
    switch self {
    case .mouse: "magicmouse.fill"
    case .trackpad: "trackpad.fill"
    case .keyboard: "keyboard.fill"
    case .pencil: "applepencil"
    case .other: "dot.radiowaves.right"
    }
  }
}

enum PeripheralBatteryAlert: Equatable, Sendable {
  case warning(threshold: Int)
  case critical
}

struct PeripheralBatteryAlertDetector: Sendable {
  static let criticalThreshold = 10
  private var lastLevels: [String: Int] = [:]

  mutating func seed(_ peripherals: [PeripheralBattery]) {
    lastLevels = peripherals.reduce(into: [:]) { levels, peripheral in
      levels[peripheral.id] = peripheral.percent
    }
  }

  mutating func evaluate(
    _ peripherals: [PeripheralBattery], thresholds: [String: Int]
  ) -> [(device: PeripheralBattery, alert: PeripheralBatteryAlert)] {
    var alerts: [(device: PeripheralBattery, alert: PeripheralBatteryAlert)] = []
    var current: [String: Int] = [:]
    for device in peripherals {
      current[device.id] = device.percent
      guard let old = lastLevels[device.id] else { continue }
      let configured = thresholds[device.deviceType.rawValue] ?? 20
      if old > Self.criticalThreshold, device.percent <= Self.criticalThreshold {
        alerts.append((device, .critical))
      } else if configured > Self.criticalThreshold, old > configured,
        device.percent <= configured
      {
        alerts.append((device, .warning(threshold: configured)))
      }
    }
    lastLevels = current
    return alerts
  }
}

/// Reads battery levels of connected Apple input peripherals (Magic Mouse/Keyboard/Trackpad, etc.)
/// from the AppleDeviceManagementHIDEventService IORegistry entries.
enum PeripheralBatteryReader {
  static func read() -> [PeripheralBattery] {
    var iterator: io_iterator_t = 0
    guard
      IOServiceGetMatchingServices(
        kIOMainPortDefault,
        IOServiceMatching("AppleDeviceManagementHIDEventService"), &iterator) == KERN_SUCCESS
    else { return [] }
    defer { IOObjectRelease(iterator) }

    var result: [PeripheralBattery] = []
    var service = IOIteratorNext(iterator)
    while service != 0 {
      if let percent = intProp(service, "BatteryPercent"), percent > 0,
        let name = strProp(service, "Product"),
        !name.localizedCaseInsensitiveContains("internal")
      {
        result.append(
          PeripheralBattery(id: stableIdentifier(service), name: name, percent: percent))
      }
      IOObjectRelease(service)
      service = IOIteratorNext(iterator)
    }
    return result
  }

  private static func intProp(_ service: io_service_t, _ key: String) -> Int? {
    (IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
      .takeRetainedValue() as? NSNumber)?.intValue
  }

  private static func strProp(_ service: io_service_t, _ key: String) -> String? {
    IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
      .takeRetainedValue() as? String
  }

  private static func stableIdentifier(_ service: io_service_t) -> String {
    let address = ["DeviceAddress", "TransportAddress", "BD_ADDR"]
      .lazy.compactMap { strProp(service, $0) }.first
    var registryEntryID: UInt64 = 0
    let hasRegistryEntryID =
      IORegistryEntryGetRegistryEntryID(service, &registryEntryID) == KERN_SUCCESS
    return stableIdentifier(
      serialNumber: strProp(service, "SerialNumber"), deviceAddress: address,
      registryEntryID: hasRegistryEntryID ? registryEntryID : UInt64(service))
  }

  static func stableIdentifier(
    serialNumber: String?, deviceAddress: String?, registryEntryID: UInt64
  ) -> String {
    if let serialNumber = normalizedIdentity(serialNumber) { return "serial:\(serialNumber)" }
    if let deviceAddress = normalizedIdentity(deviceAddress) { return "address:\(deviceAddress)" }
    return "ioreg:\(String(registryEntryID, radix: 16))"
  }

  private static func normalizedIdentity(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
      !value.isEmpty
    else { return nil }
    return value
  }
}

/// The hardware changes that can make the peripheral battery snapshot stale.
enum PeripheralBatteryChange: Hashable, Sendable {
  /// A device may have disappeared or returned with a reading unrelated to the old connection.
  case topology
  /// A connected HID service reported a property change, so its level may have crossed a threshold.
  case powerProperty
  /// Sleep can hide a disconnect and reconnect pair. The first post-wake snapshot is a new baseline.
  case wake
}

@MainActor
protocol PeripheralBatteryChangeObserving: AnyObject {
  func start(onChange: @escaping @MainActor (PeripheralBatteryChange) -> Void)
  func stop()
}

/// Watches the public Bluetooth, workspace, and IOKit signals that can change peripheral batteries.
/// IOKit does not expose a key-filtered property notification, so the source rereads the small set
/// of battery-capable HID services after a general property-change message and ignores equal data.
@MainActor
final class PeripheralBatteryChangeObserver: NSObject, PeripheralBatteryChangeObserving {
  private var onChange: (@MainActor (PeripheralBatteryChange) -> Void)?
  private var connectNotification: IOBluetoothUserNotification?
  nonisolated(unsafe) private var bluetoothRunning = false
  nonisolated(unsafe) private var disconnectNotifications: [IOBluetoothUserNotification] = []
  private nonisolated let bluetoothLock = NSLock()

  private var wakeObserver: NSObjectProtocol?
  private var notifyPort: IONotificationPortRef?
  private var matchingIterators: [io_iterator_t] = []
  private var interestNotifications: [UInt64: io_object_t] = [:]
  private var unkeyedInterestNotifications: [io_object_t] = []

  func start(onChange: @escaping @MainActor (PeripheralBatteryChange) -> Void) {
    guard self.onChange == nil else { return }
    self.onChange = onChange

    bluetoothLock.lock()
    bluetoothRunning = true
    bluetoothLock.unlock()
    connectNotification = IOBluetoothDevice.register(
      forConnectNotifications: self, selector: #selector(deviceConnected(_:device:)))
    if let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] {
      for device in paired where device.isConnected() { registerDisconnect(for: device) }
    }

    wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      Task { @MainActor in self?.report(.wake) }
    }

    startIORegistryObservation()
  }

  func stop() {
    onChange = nil
    connectNotification?.unregister()
    connectNotification = nil

    bluetoothLock.lock()
    bluetoothRunning = false
    let registered = disconnectNotifications
    disconnectNotifications.removeAll()
    bluetoothLock.unlock()
    for notification in registered { notification.unregister() }

    if let wakeObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
      self.wakeObserver = nil
    }
    tearDownIORegistryObservation()
  }

  private func report(_ change: PeripheralBatteryChange) { onChange?(change) }

  private nonisolated func scheduleReport(_ change: PeripheralBatteryChange) {
    Task { @MainActor [weak self] in self?.report(change) }
  }

  // MARK: - Bluetooth

  private nonisolated func registerDisconnect(for device: IOBluetoothDevice) {
    bluetoothLock.lock()
    let running = bluetoothRunning
    bluetoothLock.unlock()
    guard running else { return }
    guard
      let notification = device.register(
        forDisconnectNotification: self,
        selector: #selector(deviceDisconnected(_:device:)))
    else { return }
    bluetoothLock.lock()
    if bluetoothRunning {
      disconnectNotifications.append(notification)
      bluetoothLock.unlock()
    } else {
      bluetoothLock.unlock()
      // `stop()` may race the IOBluetooth callback between registration and bookkeeping.
      notification.unregister()
    }
  }

  @objc nonisolated private func deviceConnected(
    _ notification: IOBluetoothUserNotification, device: IOBluetoothDevice
  ) {
    registerDisconnect(for: device)
    scheduleReport(.topology)
  }

  @objc nonisolated private func deviceDisconnected(
    _ notification: IOBluetoothUserNotification, device: IOBluetoothDevice
  ) {
    notification.unregister()
    bluetoothLock.lock()
    disconnectNotifications.removeAll { $0 === notification }
    bluetoothLock.unlock()
    scheduleReport(.topology)
  }

  // MARK: - IORegistry

  private func startIORegistryObservation() {
    notifyPort = IONotificationPortCreate(kIOMainPortDefault)
    guard let notifyPort else { return }
    IONotificationPortSetDispatchQueue(notifyPort, DispatchQueue.main)

    let context = Unmanaged.passUnretained(self).toOpaque()
    let matchedCallback: IOServiceMatchingCallback = { context, iterator in
      guard let context else { return }
      Unmanaged<PeripheralBatteryChangeObserver>.fromOpaque(context).takeUnretainedValue()
        .receiveMatchedServices(iterator)
    }
    let terminatedCallback: IOServiceMatchingCallback = { context, iterator in
      var registryIDs: [UInt64] = []
      var service = IOIteratorNext(iterator)
      while service != 0 {
        var registryID: UInt64 = 0
        if IORegistryEntryGetRegistryEntryID(service, &registryID) == KERN_SUCCESS {
          registryIDs.append(registryID)
        }
        IOObjectRelease(service)
        service = IOIteratorNext(iterator)
      }
      guard let context else { return }
      Unmanaged<PeripheralBatteryChangeObserver>.fromOpaque(context).takeUnretainedValue()
        .receiveTerminatedServices(registryIDs)
    }

    for (type, callback) in [
      (kIOMatchedNotification, matchedCallback),
      (kIOTerminatedNotification, terminatedCallback),
    ] {
      var iterator: io_iterator_t = 0
      let matching = IOServiceMatching("AppleDeviceManagementHIDEventService")
      guard
        IOServiceAddMatchingNotification(
          notifyPort, type, matching, callback, context, &iterator) == KERN_SUCCESS
      else {
        if iterator != 0 { IOObjectRelease(iterator) }
        continue
      }
      matchingIterators.append(iterator)
      if type == kIOMatchedNotification {
        registerInterestNotifications(from: iterator, reportTopology: false)
      } else {
        drain(iterator)
      }
    }
  }

  private nonisolated func receiveMatchedServices(_ iterator: io_iterator_t) {
    var services: [io_service_t] = []
    var service = IOIteratorNext(iterator)
    while service != 0 {
      services.append(service)
      service = IOIteratorNext(iterator)
    }
    Task { @MainActor [weak self] in
      self?.registerInterestNotifications(for: services, reportTopology: true)
      if self == nil {
        for service in services { IOObjectRelease(service) }
      }
    }
  }

  private nonisolated func receiveTerminatedServices(_ registryIDs: [UInt64]) {
    Task { @MainActor [weak self] in
      guard let self else { return }
      for registryID in registryIDs {
        if let notification = interestNotifications.removeValue(forKey: registryID) {
          IOObjectRelease(notification)
        }
      }
      report(.topology)
    }
  }

  private func registerInterestNotifications(
    from iterator: io_iterator_t, reportTopology: Bool
  ) {
    var services: [io_service_t] = []
    var service = IOIteratorNext(iterator)
    while service != 0 {
      services.append(service)
      service = IOIteratorNext(iterator)
    }
    registerInterestNotifications(for: services, reportTopology: reportTopology)
  }

  private func registerInterestNotifications(
    for services: [io_service_t], reportTopology: Bool
  ) {
    guard let notifyPort else {
      for service in services { IOObjectRelease(service) }
      return
    }
    let context = Unmanaged.passUnretained(self).toOpaque()
    let callback: IOServiceInterestCallback = { context, _, messageType, _ in
      // `kIOMessageServicePropertyChange` is not imported into Swift from IOMessage.h. Its public
      // `iokit_common_msg(0x130)` expansion is stable and evaluates to this value.
      guard messageType == 0xe000_0130, let context else { return }
      Unmanaged<PeripheralBatteryChangeObserver>.fromOpaque(context).takeUnretainedValue()
        .scheduleReport(.powerProperty)
    }
    for service in services {
      var notification: io_object_t = 0
      if IOServiceAddInterestNotification(
        notifyPort, service, kIOGeneralInterest, callback, context, &notification) == KERN_SUCCESS
      {
        var registryID: UInt64 = 0
        if IORegistryEntryGetRegistryEntryID(service, &registryID) == KERN_SUCCESS {
          if let previous = interestNotifications.updateValue(notification, forKey: registryID) {
            IOObjectRelease(previous)
          }
        } else {
          unkeyedInterestNotifications.append(notification)
        }
      } else if notification != 0 {
        IOObjectRelease(notification)
      }
      IOObjectRelease(service)
    }
    if reportTopology { report(.topology) }
  }

  private func drain(_ iterator: io_iterator_t) {
    var service = IOIteratorNext(iterator)
    while service != 0 {
      IOObjectRelease(service)
      service = IOIteratorNext(iterator)
    }
  }

  private func tearDownIORegistryObservation() {
    for notification in interestNotifications.values { IOObjectRelease(notification) }
    interestNotifications.removeAll()
    for notification in unkeyedInterestNotifications { IOObjectRelease(notification) }
    unkeyedInterestNotifications.removeAll()
    for iterator in matchingIterators { IOObjectRelease(iterator) }
    matchingIterators.removeAll()
    if let notifyPort {
      IONotificationPortDestroy(notifyPort)
      self.notifyPort = nil
    }
  }
}
