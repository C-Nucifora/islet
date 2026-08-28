import CoreWLAN
import Foundation

/// Wi-Fi join, leave and network change.
///
/// `CWEventDelegate` callbacks arrive on a CoreWLAN-owned thread, so every one of them hops to the
/// main actor before touching the bus.
///
/// **The name costs a permission.** On macOS 14+ `CWInterface.ssid()` returns nil without Location
/// authorisation. Connect and disconnect are free; only the *name* is gated. Without access, Islet
/// uses a nameless "Wi-Fi connected" event.
@MainActor
final class WiFiEventSource: NSObject, SystemEventSource, CWEventDelegate {
  let id = "wifi"
  let displayName = "Wi-Fi"
  let tier = SystemEventTier.extended

  private let client = CWWiFiClient.shared()
  private var running = false
  private var lastSSID: String?

  func start() {
    guard !running else { return }
    running = true
    client.delegate = self
    lastSSID = client.interface()?.ssid()
    try? client.startMonitoringEvent(with: .ssidDidChange)
    try? client.startMonitoringEvent(with: .linkDidChange)
    try? client.startMonitoringEvent(with: .powerDidChange)
  }

  func stop() {
    guard running else { return }
    running = false
    try? client.stopMonitoringAllEvents()
    client.delegate = nil
    lastSSID = nil
  }

  // MARK: - CWEventDelegate (called off the main thread)

  nonisolated func ssidDidChangeForWiFiInterface(withName interfaceName: String) {
    Task { @MainActor [weak self] in self?.linkChanged() }
  }

  nonisolated func linkDidChangeForWiFiInterface(withName interfaceName: String) {
    Task { @MainActor [weak self] in self?.linkChanged() }
  }

  nonisolated func powerStateDidChangeForWiFiInterface(withName interfaceName: String) {
    Task { @MainActor [weak self] in self?.powerChanged() }
  }

  // MARK: - Reporting

  private func linkChanged() {
    let ssid = client.interface()?.ssid()
    guard ssid != lastSSID else { return }
    let previous = lastSSID
    lastSSID = ssid

    if let ssid {
      SystemEventBus.shared.emit(
        SystemEvent(
          sourceID: id, icon: "wifi", title: "Wi-Fi connected", subtitle: ssid,
          accentHex: EventAccent.positive, motion: .wifi,
          announcement: "Connected to \(ssid)"))
    } else if previous != nil || client.interface()?.powerOn() == true {
      // Name unavailable — either genuinely disconnected, or connected with Location refused.
      // A live BSSID tells the two apart.
      let connected = client.interface()?.powerOn() == true && client.interface()?.bssid() != nil
      SystemEventBus.shared.emit(
        SystemEvent(
          sourceID: id,
          icon: connected ? "wifi" : "wifi.slash",
          title: connected ? "Wi-Fi connected" : "Wi-Fi disconnected",
          accentHex: connected ? EventAccent.positive : EventAccent.neutral,
          motion: .wifi,
          urgency: .ambient,
          announcement: connected ? "Wi-Fi connected" : "Wi-Fi disconnected"))
    }
  }

  private func powerChanged() {
    let on = client.interface()?.powerOn() ?? false
    if !on { lastSSID = nil }
    SystemEventBus.shared.emit(
      SystemEvent(
        sourceID: id,
        icon: on ? "wifi" : "wifi.slash",
        title: on ? "Wi-Fi on" : "Wi-Fi off",
        accentHex: on ? EventAccent.info : EventAccent.neutral,
        motion: .wifi,
        urgency: .ambient,
        announcement: on ? "Wi-Fi on" : "Wi-Fi off"))
  }
}
