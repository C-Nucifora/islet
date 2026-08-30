import CoreAudio
import Foundation

struct SelectedAudioDevice: Equatable, Sendable {
  let id: AudioObjectID
  let name: String
}

struct AudioDeviceSelection: Equatable, Sendable {
  var input: SelectedAudioDevice?
  var output: SelectedAudioDevice?

  static let empty = AudioDeviceSelection(input: nil, output: nil)
}

enum AudioDeviceChange: Equatable, Sendable {
  case input(SelectedAudioDevice)
  case output(SelectedAudioDevice)
  case inputAndOutput(input: SelectedAudioDevice, output: SelectedAudioDevice)
}

/// Collects input and output callbacks into one baseline-to-latest selection change.
///
/// CoreAudio can deliver the two default-device callbacks separately for one headset switch. The
/// accumulator keeps the original selection until the quiet period ends, so the second callback
/// extends the same change instead of producing another event.
struct AudioDeviceChangeAccumulator {
  private(set) var baseline: AudioDeviceSelection
  private(set) var latest: AudioDeviceSelection

  init(selection: AudioDeviceSelection) {
    baseline = selection
    latest = selection
  }

  mutating func reset(to selection: AudioDeviceSelection) {
    baseline = selection
    latest = selection
  }

  @discardableResult
  mutating func observe(_ selection: AudioDeviceSelection) -> Bool {
    latest = selection
    return changedInput || changedOutput
  }

  mutating func drain() -> AudioDeviceChange? {
    let inputChanged = changedInput
    let outputChanged = changedOutput
    let selection = latest
    baseline = selection

    switch (inputChanged ? selection.input : nil, outputChanged ? selection.output : nil) {
    case (.some(let input), .some(let output)):
      return .inputAndOutput(input: input, output: output)
    case (.some(let input), nil):
      return .input(input)
    case (nil, .some(let output)):
      return .output(output)
    case (nil, nil):
      return nil
    }
  }

  private var changedInput: Bool { baseline.input?.id != latest.input?.id }
  private var changedOutput: Bool { baseline.output?.id != latest.output?.id }
}

@MainActor
protocol AudioDeviceProviding: AnyObject {
  var currentSelection: AudioDeviceSelection { get }
  func start(onChange: @escaping @MainActor @Sendable () -> Void) -> Bool
  func stop()
}

/// CoreAudio access and listener ownership. Keeping this separate makes listener cleanup and state
/// transitions testable without changing the Mac's real default devices.
@MainActor
final class CoreAudioDeviceProvider: AudioDeviceProviding {
  private var inputAddress = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDefaultInputDevice,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)
  private var outputAddress = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDefaultOutputDevice,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)
  private var inputListener: AudioObjectPropertyListenerBlock?
  private var outputListener: AudioObjectPropertyListenerBlock?

  var currentSelection: AudioDeviceSelection {
    AudioDeviceSelection(
      input: Self.selectedDevice(at: &inputAddress),
      output: Self.selectedDevice(at: &outputAddress))
  }

  func start(onChange: @escaping @MainActor @Sendable () -> Void) -> Bool {
    guard inputListener == nil, outputListener == nil else { return true }

    let inputBlock: AudioObjectPropertyListenerBlock = { _, _ in
      Task { @MainActor in onChange() }
    }
    var status = AudioObjectAddPropertyListenerBlock(
      AudioObjectID(kAudioObjectSystemObject), &inputAddress, DispatchQueue.main, inputBlock)
    guard status == noErr else {
      Log.app.error("Default audio-input listener failed with \(status)")
      return false
    }
    inputListener = inputBlock

    let outputBlock: AudioObjectPropertyListenerBlock = { _, _ in
      Task { @MainActor in onChange() }
    }
    status = AudioObjectAddPropertyListenerBlock(
      AudioObjectID(kAudioObjectSystemObject), &outputAddress, DispatchQueue.main, outputBlock)
    guard status == noErr else {
      AudioObjectRemovePropertyListenerBlock(
        AudioObjectID(kAudioObjectSystemObject), &inputAddress, DispatchQueue.main, inputBlock)
      inputListener = nil
      Log.app.error("Default audio-output listener failed with \(status)")
      return false
    }
    outputListener = outputBlock
    return true
  }

  func stop() {
    if let inputListener {
      AudioObjectRemovePropertyListenerBlock(
        AudioObjectID(kAudioObjectSystemObject), &inputAddress, DispatchQueue.main, inputListener)
      self.inputListener = nil
    }
    if let outputListener {
      AudioObjectRemovePropertyListenerBlock(
        AudioObjectID(kAudioObjectSystemObject), &outputAddress, DispatchQueue.main, outputListener)
      self.outputListener = nil
    }
  }

  private static func selectedDevice(
    at address: inout AudioObjectPropertyAddress
  ) -> SelectedAudioDevice? {
    var id = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    let status = AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
    guard status == noErr, id != kAudioObjectUnknown else { return nil }
    return SelectedAudioDevice(id: id, name: deviceName(id) ?? "Audio device")
  }

  private static func deviceName(_ device: AudioObjectID) -> String? {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioObjectPropertyName,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    // CoreAudio documents this property as a retained CF object owned by the caller.
    var name: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name)
    guard status == noErr else { return nil }
    return name?.takeRetainedValue() as String?
  }
}

/// Watches the default input and output devices and emits one event for each completed switch.
/// This is a transient event producer, not a persistent activity.
@MainActor
final class AudioDeviceMonitor {
  static let shared = AudioDeviceMonitor()

  private let provider: any AudioDeviceProviding
  private let coalescingDelay: Duration
  private let emit: @MainActor (SystemEvent) -> Void
  private var accumulator = AudioDeviceChangeAccumulator(selection: .empty)
  private var flushTask: Task<Void, Never>?
  private(set) var isRunning = false

  init(
    provider: any AudioDeviceProviding = CoreAudioDeviceProvider(),
    coalescingDelay: Duration = .milliseconds(250),
    emit: @escaping @MainActor (SystemEvent) -> Void = { SystemEventBus.shared.emit($0) }
  ) {
    self.provider = provider
    self.coalescingDelay = coalescingDelay
    self.emit = emit
  }

  func start() {
    guard !isRunning else { return }
    accumulator.reset(to: provider.currentSelection)
    isRunning = true
    guard provider.start(onChange: { [weak self] in self?.deviceChanged() }) else {
      isRunning = false
      accumulator.reset(to: .empty)
      return
    }
  }

  func stop() {
    guard isRunning else { return }
    isRunning = false
    flushTask?.cancel()
    flushTask = nil
    provider.stop()
    accumulator.reset(to: .empty)
  }

  private func deviceChanged() {
    guard isRunning else { return }
    guard accumulator.observe(provider.currentSelection) else { return }
    scheduleFlush()
  }

  private func scheduleFlush() {
    flushTask?.cancel()
    flushTask = Task { [weak self, coalescingDelay] in
      try? await Task.sleep(for: coalescingDelay)
      guard !Task.isCancelled else { return }
      self?.flushPendingChange()
    }
  }

  /// Internal so deterministic tests can finish a pending change without sleeping.
  func flushPendingChange() {
    flushTask?.cancel()
    flushTask = nil
    guard isRunning, let change = accumulator.drain() else { return }
    emit(Self.event(for: change))
  }

  static func event(for change: AudioDeviceChange) -> SystemEvent {
    let title: String
    let subtitle: String
    let icon: String
    let announcement: String

    switch change {
    case .input(let input):
      title = input.name
      subtitle = String(localized: "Input selected")
      icon = "mic.fill"
      announcement = String(localized: "\(input.name) selected for audio input")
    case .output(let output):
      title = output.name
      subtitle = String(localized: "Output selected")
      icon = iconName(for: output.name)
      announcement = String(localized: "\(output.name) selected for audio output")
    case .inputAndOutput(let input, let output):
      if input.id == output.id || input.name == output.name {
        title = output.name
        subtitle = String(localized: "Input and output selected")
        icon = iconName(for: output.name)
        announcement = String(localized: "\(output.name) selected for audio input and output")
      } else {
        title = String(localized: "Audio devices changed")
        subtitle = String(localized: "\(input.name) input, \(output.name) output")
        icon = "waveform"
        announcement =
          String(
            localized:
              "Audio input changed to \(input.name), and audio output changed to \(output.name)")
      }
    }

    return SystemEvent(
      sourceID: "audiodevice",
      icon: icon,
      title: title,
      subtitle: subtitle,
      accentHex: EventAccent.info,
      motion: .bluetooth,
      announcement: announcement)
  }

  static func iconName(for name: String) -> String {
    let lower = name.lowercased()
    if lower.contains("airpod") { return "airpodspro" }
    if lower.contains("headphone") || lower.contains("beats") { return "headphones" }
    if lower.contains("macbook") || lower.contains("built-in") { return "laptopcomputer" }
    return "hifispeaker.fill"
  }
}
