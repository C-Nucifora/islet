import CoreAudio
import Foundation

/// Turns the raw CoreAudio process list into the source rows Islet draws.
///
/// Pure so the denylist, the helper→parent collapsing and the de-duplication are testable with
/// plain strings — none of which needs CoreAudio to be running.
enum AudioProcessReducer {
  /// One CoreAudio process object, flattened to the three properties Islet reads.
  struct RawProcess: Equatable, Sendable {
    let bundleID: String
    let pid: Int32
    let isPlayingOutput: Bool
  }

  /// One row per app that is currently producing audio output.
  ///
  /// Honest limitation: this flags *any* audio, not just music. A video call, a game and a
  /// notification chime all read as "playing". The denylist covers the system offenders observed
  /// on this machine; a Zoom call will still show a chip.
  static func reduce(
    processes: [RawProcess], runningAppBundleID: (Int32) -> String?
  ) -> [SourceID] {
    var byApp: [String: SourceID] = [:]
    for process in processes where process.isPlayingOutput {
      let bundleID = process.bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !bundleID.isEmpty else { continue }
      let display = AudioSourceResolver.displayBundleID(
        bundleID: bundleID, pid: process.pid, runningAppBundleID: runningAppBundleID)
      guard !display.isEmpty, !SourceFilter.isDenied(display), !SourceFilter.isDenied(bundleID)
      else {
        continue
      }
      // Lowest pid wins so the row identity does not flicker as helpers come and go.
      if let existing = byApp[display], existing.pid <= process.pid { continue }
      byApp[display] = SourceID(
        bundleIdentifier: bundleID, pid: process.pid, displayBundleIdentifier: display)
    }
    return byApp.values.sorted { $0.displayBundleIdentifier < $1.displayBundleIdentifier }
  }
}

/// Watches which processes are producing audio output, push-driven, with no polling.
///
/// One `AudioObjectPropertyListenerBlock` on the system object's process list, plus one per process
/// on its running-output flag. These are process *objects* (macOS 14+), not Core Audio process taps:
/// no NSAudioCaptureUsageDescription, no TCC prompt.
@MainActor
final class AudioProcessMonitor: ObservableObject {
  /// Apps currently producing audio output, de-duplicated to one entry per app.
  @Published private(set) var sources: [SourceID] = []

  private var started = false
  private var refreshPending = false
  private var listListener: AudioObjectPropertyListenerBlock?
  private var processListeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]

  private static let listAddress = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyProcessObjectList,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)
  private static let runningOutputAddress = AudioObjectPropertyAddress(
    mSelector: kAudioProcessPropertyIsRunningOutput,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)

  func start() {
    guard !started else { return }
    started = true
    let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
      Task { @MainActor in self?.scheduleRefresh() }
    }
    var address = Self.listAddress
    let status = AudioObjectAddPropertyListenerBlock(
      AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
    if status == noErr {
      listListener = block
    } else {
      Log.media.error("CoreAudio process-list listener failed with \(status)")
    }
    refresh()
  }

  func stop() {
    guard started else { return }
    started = false
    if let listListener {
      var address = Self.listAddress
      AudioObjectRemovePropertyListenerBlock(
        AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, listListener)
      self.listListener = nil
    }
    for (object, block) in processListeners {
      var address = Self.runningOutputAddress
      AudioObjectRemovePropertyListenerBlock(object, &address, DispatchQueue.main, block)
    }
    processListeners.removeAll()
    sources = []
  }

  /// Coalesces the burst of callbacks a single play/pause produces — one per listening process —
  /// into one read pass.
  private func scheduleRefresh() {
    guard !refreshPending else { return }
    refreshPending = true
    Task { @MainActor [weak self] in
      guard let self else { return }
      self.refreshPending = false
      self.refresh()
    }
  }

  func refresh() {
    let objects = Self.processObjects()
    syncListeners(for: objects)
    let raw = objects.map {
      AudioProcessReducer.RawProcess(
        bundleID: Self.bundleID($0) ?? "",
        pid: Self.pid($0),
        isPlayingOutput: Self.isRunningOutput($0))
    }
    let next = AudioProcessReducer.reduce(
      processes: raw, runningAppBundleID: AudioSourceResolver.runningAppBundleID)
    if next != sources { sources = next }
  }

  /// Adds a running-output listener to every new process object and removes the ones that died.
  private func syncListeners(for objects: [AudioObjectID]) {
    let live = Set(objects)
    for (object, block) in processListeners where !live.contains(object) {
      var address = Self.runningOutputAddress
      AudioObjectRemovePropertyListenerBlock(object, &address, DispatchQueue.main, block)
      processListeners[object] = nil
    }
    for object in objects where processListeners[object] == nil {
      let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        Task { @MainActor in self?.scheduleRefresh() }
      }
      var address = Self.runningOutputAddress
      guard
        AudioObjectAddPropertyListenerBlock(object, &address, DispatchQueue.main, block) == noErr
      else { continue }
      processListeners[object] = block
    }
  }

  static func processObjects() -> [AudioObjectID] {
    var address = listAddress
    var size: UInt32 = 0
    guard
      AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
      size > 0
    else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard
      AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr
    else { return [] }
    return ids
  }

  static func bundleID(_ object: AudioObjectID) -> String? {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioProcessPropertyBundleID,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr
    else { return nil }
    return value?.takeRetainedValue() as String?
  }

  static func pid(_ object: AudioObjectID) -> Int32 {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioProcessPropertyPID,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var value: pid_t = 0
    var size = UInt32(MemoryLayout<pid_t>.size)
    guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr
    else { return 0 }
    return value
  }

  static func isRunningOutput(_ object: AudioObjectID) -> Bool {
    var address = runningOutputAddress
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr
    else { return false }
    return value != 0
  }
}
