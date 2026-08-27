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
  private var listener: AudioObjectPropertyListenerBlock?

  private var address = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDefaultOutputDevice,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)

  func start() {
    guard !listenerInstalled else { return }
    listenerInstalled = true
    lastDeviceID = Self.defaultOutputDevice()
    let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
      Task { @MainActor in self?.deviceChanged() }
    }
    let status = AudioObjectAddPropertyListenerBlock(
      AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
    if status == noErr {
      listener = block
    } else {
      listenerInstalled = false
      Log.app.error("Default audio-device listener failed with \(status)")
    }
  }

  func stop() {
    guard listenerInstalled else { return }
    listenerInstalled = false
    if let listener {
      AudioObjectRemovePropertyListenerBlock(
        AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, listener)
      self.listener = nil
    }
    lastDeviceID = kAudioObjectUnknown
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
        subtitle: "Output selected",
        accentHex: EventAccent.info,
        motion: .bluetooth,
        announcement: "\(name) selected for audio output"))
  }

  static func defaultOutputDevice() -> AudioObjectID {
    var id = AudioObjectID(kAudioObjectUnknown)
    var addr = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultOutputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    let status = AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
    return status == noErr ? id : kAudioObjectUnknown
  }

  static func deviceName(_ device: AudioObjectID) -> String? {
    var addr = AudioObjectPropertyAddress(
      mSelector: kAudioObjectPropertyName,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    // CoreAudio documents this property as a retained CF object owned by the caller.
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
