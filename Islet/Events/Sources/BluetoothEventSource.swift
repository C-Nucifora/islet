import Combine
import Foundation
import IOBluetooth

/// Bluetooth devices connecting and disconnecting.
///
/// `IOBluetoothDevice.register(forConnectNotifications:selector:)` needs an Objective-C selector
/// target, so this class is `NSObject` with `@objc` handlers. No permission prompt for the
/// notifications themselves — though the Info.plist carries `NSBluetoothAlwaysUsageDescription`,
/// because registering at all trips the privacy check.
///
/// **The callbacks do NOT arrive on the main thread.** Crash-verified on macOS 26: IOBluetooth
/// forwards CoreBluetooth connection events from `CBXpcConnection`'s serial dispatch queue
/// (`-[IOBluetoothConcreteUserNotification objcNotificationRoutine:]` under
/// `dispatch_lane_serial_drain`). An implicitly `@MainActor` handler dies in
/// `_checkExpectedExecutor` the moment a device connects, and `MainActor.assumeIsolated` would
/// trap identically. So the handlers are `nonisolated`: they read everything they need from the
/// non-Sendable IOBluetooth objects on the callback thread, keep the registration bookkeeping
/// under a lock, and cross to the main actor with nothing but the device's name.
///
/// Disconnect has no global notification: it is registered per device, at the moment that device
/// connects. Devices already paired and connected when the source starts are therefore not watched
/// for disconnect until they next connect — an accepted limitation, noted here so it is not
/// rediscovered as a bug.
@MainActor
final class BluetoothEventSource: NSObject, SystemEventSource {
  let id = "bluetooth"
  let displayName = "Bluetooth devices"
  let tier = SystemEventTier.extended

  private var connectNotification: IOBluetoothUserNotification?

  /// Per-device disconnect registrations. Guarded by `lock`, not the main actor, because they are
  /// created and consumed on IOBluetooth's callback queue. `nonisolated(unsafe)` is the honest
  /// spelling: the lock is the synchronisation, and every access below takes it.
  nonisolated(unsafe) private var disconnectNotifications: [IOBluetoothUserNotification] = []
  private nonisolated let lock = NSLock()

  func start() {
    guard connectNotification == nil else { return }
    connectNotification = IOBluetoothDevice.register(
      forConnectNotifications: self, selector: #selector(deviceConnected(_:device:)))
  }

  func stop() {
    connectNotification?.unregister()
    connectNotification = nil
    lock.lock()
    let registered = disconnectNotifications
    disconnectNotifications.removeAll()
    lock.unlock()
    for notification in registered { notification.unregister() }
  }

  // MARK: - IOBluetooth callbacks (CoreBluetooth XPC queue — never assume the main actor here)

  @objc nonisolated private func deviceConnected(
    _ notification: IOBluetoothUserNotification, device: IOBluetoothDevice
  ) {
    // Read the non-Sendable device and register the per-device disconnect watch on the thread the
    // callback owns; only the name crosses the actor boundary.
    let name = device.name ?? device.addressString ?? "Bluetooth device"
    if let n = device.register(
      forDisconnectNotification: self, selector: #selector(deviceDisconnected(_:device:)))
    {
      lock.lock()
      disconnectNotifications.append(n)
      lock.unlock()
    }
    Task { @MainActor in
      SystemEventBus.shared.emit(
        SystemEvent(
          sourceID: "bluetooth", icon: "dot.radiowaves.right", title: name,
          subtitle: "Connected",
          accentHex: EventAccent.info, motion: .bluetooth,
          announcement: "\(name) connected"))
    }
  }

  @objc nonisolated private func deviceDisconnected(
    _ notification: IOBluetoothUserNotification, device: IOBluetoothDevice
  ) {
    let name = device.name ?? device.addressString ?? "Bluetooth device"
    notification.unregister()
    lock.lock()
    disconnectNotifications.removeAll { $0 === notification }
    lock.unlock()
    Task { @MainActor in
      SystemEventBus.shared.emit(
        SystemEvent(
          sourceID: "bluetooth", icon: "dot.radiowaves.right", title: name,
          subtitle: "Disconnected",
          accentHex: EventAccent.neutral, motion: .bluetooth, urgency: .ambient,
          announcement: "\(name) disconnected"))
    }
  }
}
