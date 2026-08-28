import CoreAudio
import Foundation

/// Minimal CoreAudio volume/mute control on the default output device.
enum VolumeController {
  /// Whether the current device exposes at least one writable, readable scalar-volume control.
  /// A default device alone is not enough: HDMI, AirPlay, and many USB devices deliberately expose
  /// no software volume control and must be left to macOS.
  static var canControlVolume: Bool {
    let device = outputDevice
    return device != kAudioObjectUnknown && !writableVolumeElements(on: device).isEmpty
  }

  /// Whether the current device exposes a writable, readable mute control.
  static var canControlMute: Bool {
    let device = outputDevice
    guard device != kAudioObjectUnknown else { return false }
    var address = muteAddress()
    return isReadableAndSettable(device, address: &address)
  }

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

  static func readVolume() -> Float? {
    let device = outputDevice
    guard device != kAudioObjectUnknown else { return nil }
    let preferred = writableVolumeElements(on: device)
    for element in preferred + [kAudioObjectPropertyElementMain, UInt32(1), 2] {
      if let value = readVolume(on: device, element: element) { return value }
    }
    return nil
  }

  /// Compatibility value for UI callers. Control code should use `readVolume()` so read failure is
  /// not confused with a genuine zero volume.
  static func currentVolume() -> Float { readVolume() ?? 0 }

  /// Applies volume and verifies it by reading every control that accepted the write. On devices
  /// with per-channel controls but no master scalar, every channel moves by the same delta so a
  /// pre-existing balance is preserved.
  /// Returning false is a hard instruction to the event tap to pass the media key through.
  @discardableResult
  static func setVolume(_ value: Float) -> Bool {
    let device = outputDevice
    guard device != kAudioObjectUnknown else { return false }
    let elements = writableVolumeElements(on: device)
    guard !elements.isEmpty else { return false }
    let clamped = max(0, min(1, value))
    let originalMute = readMuted()
    if clamped > 0, originalMute == true, !setMuted(false) { return false }

    let originals = Dictionary(
      uniqueKeysWithValues: elements.compactMap { element in
        readVolume(on: device, element: element).map { (element, $0) }
      })
    guard originals.count == elements.count else {
      if originalMute == true { _ = setMuted(true) }
      return false
    }
    guard let referenceElement = elements.first, let reference = originals[referenceElement] else {
      if originalMute == true { _ = setMuted(true) }
      return false
    }
    let targets = VolumeControlLayout.shiftedValues(
      originals, reference: reference, target: clamped)

    var written: [UInt32] = []
    for element in elements {
      var addr = volumeAddress(element: element)
      guard var target = targets[element] else { continue }
      if AudioObjectSetPropertyData(
        device, &addr, 0, nil, UInt32(MemoryLayout<Float>.size), &target) == noErr
      {
        written.append(element)
      }
    }
    guard written.count == elements.count else {
      restoreVolumes(originals, on: device)
      if originalMute == true { _ = setMuted(true) }
      return false
    }

    // CoreAudio scalar controls are synchronous, though some devices quantise to coarse steps.
    // Two percent tolerates that quantisation without treating a silently ignored write as success.
    let verified = written.allSatisfy { element in
      guard let readback = readVolume(on: device, element: element),
        let target = targets[element]
      else { return false }
      return abs(readback - target) <= 0.02
    }
    if !verified {
      restoreVolumes(originals, on: device)
      if originalMute == true { _ = setMuted(true) }
    }
    return verified
  }

  private static func muteAddress() -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyMute,
      mScope: kAudioDevicePropertyScopeOutput,
      mElement: kAudioObjectPropertyElementMain)
  }

  static func readMuted() -> Bool? {
    let device = outputDevice
    var addr = muteAddress()
    guard device != kAudioObjectUnknown, AudioObjectHasProperty(device, &addr) else {
      return nil
    }
    var muted: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &muted) == noErr else {
      return nil
    }
    return muted != 0
  }

  static func isMuted() -> Bool { readMuted() ?? false }

  @discardableResult
  static func setMuted(_ muted: Bool) -> Bool {
    let device = outputDevice
    var addr = muteAddress()
    guard device != kAudioObjectUnknown, isReadableAndSettable(device, address: &addr) else {
      return false
    }
    var value: UInt32 = muted ? 1 : 0
    guard AudioObjectSetPropertyData(
      device, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    else { return false }
    return readMuted() == muted
  }

  @discardableResult
  static func toggleMute() -> Bool {
    guard let muted = readMuted() else { return false }
    return setMuted(!muted)
  }

  private static func writableVolumeElements(on device: AudioObjectID) -> [UInt32] {
    let available = [kAudioObjectPropertyElementMain, UInt32(1), 2, 3, 4].filter { element in
      var address = volumeAddress(element: element)
      return isReadableAndSettable(device, address: &address)
        && readVolume(on: device, element: element) != nil
    }
    return VolumeControlLayout.preferredElements(
      from: available, master: kAudioObjectPropertyElementMain)
  }

  private static func restoreVolumes(_ originals: [UInt32: Float], on device: AudioObjectID) {
    for (element, original) in originals {
      var address = volumeAddress(element: element)
      var value = original
      _ = AudioObjectSetPropertyData(
        device, &address, 0, nil, UInt32(MemoryLayout<Float>.size), &value)
    }
  }

  private static func readVolume(on device: AudioObjectID, element: UInt32) -> Float? {
    var address = volumeAddress(element: element)
    guard AudioObjectHasProperty(device, &address) else { return nil }
    var value: Float = 0
    var size = UInt32(MemoryLayout<Float>.size)
    guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else {
      return nil
    }
    return max(0, min(1, value))
  }

  private static func isReadableAndSettable(
    _ object: AudioObjectID, address: inout AudioObjectPropertyAddress
  ) -> Bool {
    guard AudioObjectHasProperty(object, &address) else { return false }
    var settable = DarwinBoolean(false)
    guard AudioObjectIsPropertySettable(object, &address, &settable) == noErr else { return false }
    return settable.boolValue
  }
}
