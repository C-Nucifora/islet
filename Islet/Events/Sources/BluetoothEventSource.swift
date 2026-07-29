import Combine
import Foundation
import IOBluetooth

/// Bluetooth devices connecting and disconnecting.
///
/// `IOBluetoothDevice.register(forConnectNotifications:selector:)` needs an Objective-C selector
/// target, so this class is `NSObject` with `@objc` handlers. No permission prompt — unlike
/// CoreBluetooth, which is for BLE peripherals and does prompt.
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
  private var disconnectNotifications: [IOBluetoothUserNotification] = []

  func start() {
    guard connectNotification == nil else { return }
    connectNotification = IOBluetoothDevice.register(
      forConnectNotifications: self, selector: #selector(deviceConnected(_:device:)))
  }

  func stop() {
    connectNotification?.unregister()
    connectNotification = nil
    disconnectNotifications.forEach { $0.unregister() }
    disconnectNotifications.removeAll()
  }

  // IOBluetooth delivers these on the main run loop but is not annotated for it, and neither
  // IOBluetoothDevice nor IOBluetoothUserNotification is Sendable. Everything needed off them is
  // read here — on the main thread, where the callback already is — and only Sendable values cross
  // into the isolated body.

  @objc private func deviceConnected(
    _ notification: IOBluetoothUserNotification, device: IOBluetoothDevice
  ) {
    let name = device.name ?? device.addressString ?? "Bluetooth device"
    SystemEventBus.shared.emit(
      SystemEvent(
        sourceID: id, icon: "dot.radiowaves.right", title: name, subtitle: "Connected",
        accentHex: EventAccent.info, motion: .bluetooth,
        announcement: "\(name) connected"))
    // Disconnect is per-device and can only be registered once the device is in hand.
    if let n = device.register(
      forDisconnectNotification: self, selector: #selector(deviceDisconnected(_:device:)))
    {
      disconnectNotifications.append(n)
    }
  }

  @objc private func deviceDisconnected(
    _ notification: IOBluetoothUserNotification, device: IOBluetoothDevice
  ) {
    let name = device.name ?? device.addressString ?? "Bluetooth device"
    notification.unregister()
    disconnectNotifications.removeAll { $0 === notification }
    SystemEventBus.shared.emit(
      SystemEvent(
        sourceID: id, icon: "dot.radiowaves.right", title: name, subtitle: "Disconnected",
        accentHex: EventAccent.neutral, motion: .bluetooth, urgency: .ambient,
        announcement: "\(name) disconnected"))
  }
}
