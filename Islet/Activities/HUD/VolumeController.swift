import CoreAudio
import Foundation

/// Minimal CoreAudio volume/mute control on the default output device.
enum VolumeController {
  private static var outputDevice: AudioObjectID {
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

  private static func volumeAddress(element: UInt32) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyVolumeScalar,
      mScope: kAudioDevicePropertyScopeOutput,
      mElement: element)
  }

  static func currentVolume() -> Float {
    let device = outputDevice
    guard device != kAudioObjectUnknown else { return 0 }
    for element in [kAudioObjectPropertyElementMain, UInt32(1), 2] {
      var addr = volumeAddress(element: element)
      guard AudioObjectHasProperty(device, &addr) else { continue }
      var value: Float = 0
      var size = UInt32(MemoryLayout<Float>.size)
      if AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr {
        return max(0, min(1, value))
      }
    }
    return 0
  }

  static func setVolume(_ value: Float) {
    let device = outputDevice
    guard device != kAudioObjectUnknown else { return }
    var clamped = max(0, min(1, value))
    if clamped > 0 { setMuted(false) }
    var wrote = false
    for element in [kAudioObjectPropertyElementMain, UInt32(1), 2, 3, 4] {
      var addr = volumeAddress(element: element)
      guard AudioObjectHasProperty(device, &addr) else { continue }
      if AudioObjectSetPropertyData(
        device, &addr, 0, nil, UInt32(MemoryLayout<Float>.size), &clamped) == noErr
      {
        wrote = true
      }
    }
    _ = wrote
  }

  private static func muteAddress() -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyMute,
      mScope: kAudioDevicePropertyScopeOutput,
      mElement: kAudioObjectPropertyElementMain)
  }

  static func isMuted() -> Bool {
    let device = outputDevice
    var addr = muteAddress()
    guard device != kAudioObjectUnknown, AudioObjectHasProperty(device, &addr) else {
      return false
    }
    var muted: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &muted)
    return muted != 0
  }

  static func setMuted(_ muted: Bool) {
    let device = outputDevice
    var addr = muteAddress()
    guard device != kAudioObjectUnknown, AudioObjectHasProperty(device, &addr) else { return }
    var value: UInt32 = muted ? 1 : 0
    AudioObjectSetPropertyData(
      device, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
  }

  static func toggleMute() { setMuted(!isMuted()) }
}
