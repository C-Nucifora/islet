import CoreAudio
import Defaults
import Foundation

/// Watches the default output device and fires a connect sneak when it changes to a new device.
/// Not a persistent activity — sneak-only.
@MainActor
final class AudioDeviceMonitor {
  static let shared = AudioDeviceMonitor()

  private var lastDeviceID: AudioObjectID = kAudioObjectUnknown
  private var listenerInstalled = false

  private var address = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDefaultOutputDevice,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)

  func start() {
    guard !listenerInstalled else { return }
    listenerInstalled = true
    lastDeviceID = Self.defaultOutputDevice()
    AudioObjectAddPropertyListenerBlock(
      AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main
    ) { [weak self] _, _ in
      Task { @MainActor in self?.deviceChanged() }
    }
  }

  private func deviceChanged() {
    let device = Self.defaultOutputDevice()
    guard device != kAudioObjectUnknown, device != lastDeviceID else { return }
    lastDeviceID = device
    guard Defaults[.airpodsEnabled] else { return }

    let name = Self.deviceName(device) ?? "Audio device"
    SystemEventBus.shared.emit(
      SystemEvent(
        sourceID: "audiodevice",
        icon: Self.iconName(for: name),
        title: name,
        subtitle: "Output",
        accentHex: EventAccent.info,
        motion: .bluetooth,
        announcement: "\(name) connected"))
  }

  static func defaultOutputDevice() -> AudioObjectID {
    var id = AudioObjectID(kAudioObjectUnknown)
    var addr = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultOutputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
    return id
  }

  static func deviceName(_ device: AudioObjectID) -> String? {
    var addr = AudioObjectPropertyAddress(
      mSelector: kAudioObjectPropertyName,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var name: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &name)
    guard status == noErr else { return nil }
    return name?.takeRetainedValue() as String?
  }

  static func iconName(for name: String) -> String {
    let lower = name.lowercased()
    if lower.contains("airpod") { return "airpodspro" }
    if lower.contains("headphone") || lower.contains("beats") { return "headphones" }
    if lower.contains("macbook") || lower.contains("built-in") { return "laptopcomputer" }
    return "hifispeaker.fill"
  }
}
