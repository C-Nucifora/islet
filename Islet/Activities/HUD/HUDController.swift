import AppKit
import Combine
import Defaults

struct HUDSnapshot: Equatable {
  enum Kind: Equatable { case volume, brightness }
  var kind: Kind
  var level: Float
  var isMuted: Bool
}

enum HUDEventTapStatus: String, Equatable, Sendable {
  case disabled
  case accessibilityRequired
  case active
  case creationFailed
  case interrupted

  var summary: String {
    switch self {
    case .disabled: "Disabled"
    case .accessibilityRequired: "Accessibility permission required"
    case .active: "Active"
    case .creationFailed: "Event tap could not be created"
    case .interrupted: "Event tap interrupted"
    }
  }
}

private let kSystemDefinedEventType = CGEventType(rawValue: 14)!

/// Intercepts volume/brightness media keys, applies the change itself, and shows an in-notch HUD.
/// Consuming the key event is what suppresses the system OSD. Crash-safe by construction:
/// the tap dies with the app, so keys always revert to normal system behaviour.
@MainActor
final class HUDController: ObservableObject {
  static let shared = HUDController()

  @Published private(set) var hud: HUDSnapshot?
  @Published private(set) var eventTapStatus: HUDEventTapStatus = .disabled
  @Published private(set) var accessibilityTrusted = AXIsProcessTrusted()
  @Published private(set) var lastEventTapInterruption: Date?
  @Published private(set) var lastSuccessfulAdjustment: Date?
  @Published private(set) var lastControlFailure: String?
  @Published private(set) var externalBrightnessDisplays: [ExternalBrightnessDisplayStatus] = []

  private var eventTap: CFMachPort?
  private var runLoopSource: CFRunLoopSource?
  private var hideTask: Task<Void, Never>?
  private var cancellables: Set<AnyCancellable> = []
  private var keyConsumption = HUDKeyConsumptionState()
  private var isObserving = false
  private let externalBrightnessController: ExternalBrightnessController

  private init(externalBrightnessController: ExternalBrightnessController = .init()) {
    self.externalBrightnessController = externalBrightnessController
    externalBrightnessController.didChange = { [weak self] statuses in
      let previous = Dictionary(
        uniqueKeysWithValues: (self?.externalBrightnessDisplays ?? []).map {
          ($0.id, $0.capability)
        })
      self?.externalBrightnessDisplays = statuses
      for status in statuses {
        if case .unavailable(let failure) = status.capability,
          previous[status.id] != status.capability
        {
          Log.app.error(
            "External brightness unavailable for \(status.display.name, privacy: .public): \(failure.summary, privacy: .public)"
          )
        }
      }
    }
  }

  func startObserving() {
    guard !isObserving else {
      refreshPermissionStatus()
      start()
      return
    }
    isObserving = true
    Defaults.publisher(.hudEnabled)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] change in
        if change.newValue { self?.start() } else { self?.stop() }
      }
      .store(in: &cancellables)
    Defaults.publisher(.disabledExternalBrightnessDisplays)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in self?.refreshExternalBrightnessDisplays() }
      .store(in: &cancellables)
    NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
      .sink { [weak self] _ in
        Task { @MainActor in
          self?.refreshPermissionStatus()
          self?.start()
        }
      }
      .store(in: &cancellables)
    NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
      .sink { [weak self] _ in
        Task { @MainActor in self?.refreshExternalBrightnessDisplays() }
      }
      .store(in: &cancellables)
    NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
      .sink { [weak self] _ in
        Task { @MainActor in self?.refreshExternalBrightnessDisplays() }
      }
      .store(in: &cancellables)
    start()
  }

  var isAccessibilityTrusted: Bool { accessibilityTrusted }

  /// Refreshes the read-only TCC state. This never prompts and is safe to call on every activation.
  func refreshPermissionStatus() {
    accessibilityTrusted = AccessibilityPermission.isTrusted
    if !accessibilityTrusted {
      tearDownTap()
      eventTapStatus = Defaults[.hudEnabled] ? .accessibilityRequired : .disabled
    }
  }

  func promptForAccessibility() {
    AccessibilityPermission.prompt()
    refreshPermissionStatus()
  }

  func openAccessibilitySettings() {
    AccessibilityPermission.openSettings()
  }

  func start() {
    refreshPermissionStatus()
    guard Defaults[.hudEnabled] else {
      tearDownTap()
      externalBrightnessController.cancelAll()
      eventTapStatus = .disabled
      return
    }
    refreshExternalBrightnessDisplays()
    guard accessibilityTrusted else {
      eventTapStatus = .accessibilityRequired
      return
    }
    if let eventTap {
      eventTapStatus = CGEvent.tapIsEnabled(tap: eventTap) ? .active : .interrupted
      if !CGEvent.tapIsEnabled(tap: eventTap) {
        CGEvent.tapEnable(tap: eventTap, enable: true)
        eventTapStatus = CGEvent.tapIsEnabled(tap: eventTap) ? .active : .interrupted
      }
      return
    }
    let mask = CGEventMask(1 << kSystemDefinedEventType.rawValue)
    let tap = CGEvent.tapCreate(
      tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
      eventsOfInterest: mask,
      callback: { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let controller = Unmanaged<HUDController>.fromOpaque(userInfo)
          .takeUnretainedValue()
        // Bool is Sendable; CGEvent/Unmanaged are not, so decide inside and branch out here.
        let consume = MainActor.assumeIsolated { controller.handle(type: type, event: event) }
        return consume ? nil : Unmanaged.passUnretained(event)
      },
      userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()))
    guard let tap else {
      eventTapStatus = .creationFailed
      Log.app.error("HUD event tap creation failed (accessibility?)")
      return
    }
    eventTap = tap
    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    runLoopSource = source
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    eventTapStatus = CGEvent.tapIsEnabled(tap: tap) ? .active : .creationFailed
    Log.app.info("HUD event tap active")
  }

  func stop() {
    tearDownTap()
    hideTask?.cancel()
    hideTask = nil
    eventTapStatus = .disabled
    hud = nil
    externalBrightnessController.cancelAll()
  }

  @discardableResult
  func dismiss() -> Bool {
    guard hud != nil else { return false }
    hideTask?.cancel()
    hideTask = nil
    hud = nil
    return true
  }

  private func tearDownTap() {
    if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: false) }
    if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
    eventTap = nil
    runLoopSource = nil
    keyConsumption.reset()
  }

  /// Returns true if the event should be consumed (suppressing the system OSD).
  private func handle(type: CGEventType, event: CGEvent) -> Bool {
    // The system disables a tap that times out or is interrupted; re-enable and pass through.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      lastEventTapInterruption = Date()
      eventTapStatus = .interrupted
      if let eventTap {
        CGEvent.tapEnable(tap: eventTap, enable: true)
        if CGEvent.tapIsEnabled(tap: eventTap) { eventTapStatus = .active }
      }
      return false
    }
    guard type == kSystemDefinedEventType, let nsEvent = NSEvent(cgEvent: event),
      nsEvent.type == .systemDefined, nsEvent.subtype.rawValue == 8,
      let decoded = HUDKey.decode(data1: nsEvent.data1)
    else { return false }

    if !decoded.isKeyDown {
      // A key-up is consumed only when its corresponding down event was successfully applied.
      // If the down event failed and went to macOS, its up event must follow it.
      return keyConsumption.shouldConsumeKeyUp(decoded.key)
    }

    guard let snapshot = apply(decoded.key, modifiers: nsEvent.modifierFlags) else {
      _ = keyConsumption.recordKeyDown(decoded.key, applied: false)
      lastControlFailure = failureDescription(for: decoded.key)
      return false
    }
    // Commit observable presentation state before suppressing the system event. The root view can
    // render this same state as compact content or as an expanded overlay.
    present(snapshot)
    _ = keyConsumption.recordKeyDown(decoded.key, applied: true)
    lastSuccessfulAdjustment = Date()
    lastControlFailure = nil
    return true
  }

  private func apply(_ key: HUDKey, modifiers: NSEvent.ModifierFlags) -> HUDSnapshot? {
    let divisor: Float = modifiers.contains(.shift) && modifiers.contains(.option) ? 4 : 1
    switch key {
    case .volumeUp, .volumeDown:
      guard let current = VolumeController.readVolume() else { return nil }
      let target = HUDMath.stepped(
        current, up: key == .volumeUp, divisor: divisor)
      guard VolumeController.setVolume(target), let actual = VolumeController.readVolume() else {
        return nil
      }
      return .init(
        kind: .volume, level: actual,
        isMuted: VolumeController.readMuted() ?? (actual == 0))
    case .mute:
      guard let wasMuted = VolumeController.readMuted(),
        VolumeController.setMuted(!wasMuted), let muted = VolumeController.readMuted()
      else { return nil }
      let level = VolumeController.readVolume() ?? 0
      return .init(kind: .volume, level: muted ? 0 : level, isMuted: muted)
    case .brightnessUp, .brightnessDown:
      let screens = NSScreen.screens
      let displays = screens.compactMap { screen -> BrightnessDisplayTarget? in
        guard let displayID = screen.displayID else { return nil }
        return BrightnessDisplayTarget(displayID: displayID, frame: screen.frame)
      }
      guard
        let displayID = BrightnessTargetResolver.displayID(
          at: NSEvent.mouseLocation, displays: displays)
      else { return nil }
      let actual: Float?
      if CGDisplayIsBuiltin(displayID) == 1 {
        actual = BrightnessController.adjustBrightness(
          displayID: displayID, up: key == .brightnessUp, divisor: divisor)
      } else {
        // This is a cached state transition only. DDC work runs away from the event-tap thread.
        actual = externalBrightnessController.adjust(
          displayID: displayID, up: key == .brightnessUp, divisor: divisor)
      }
      guard let actual else { return nil }
      return .init(kind: .brightness, level: actual, isMuted: false)
    }
  }

  private func failureDescription(for key: HUDKey) -> String {
    switch key {
    case .mute: "The current output device has no writable mute control."
    case .volumeUp, .volumeDown:
      "The current output device has no writable volume control or rejected the change."
    case .brightnessUp, .brightnessDown:
      "The display under the pointer has no software brightness control or rejected the change."
    }
  }

  /// Debug-only: exercise the HUD render path without the event tap / accessibility.
  func debugPresent(_ snapshot: HUDSnapshot) { present(snapshot) }

  var externalBrightnessDiagnostics: String { externalBrightnessController.diagnostics }

  func setExternalBrightnessEnabled(_ enabled: Bool, displayID: String) {
    var disabled = Defaults[.disabledExternalBrightnessDisplays]
    if enabled {
      disabled.removeAll { $0 == displayID }
    } else if !disabled.contains(displayID) {
      disabled.append(displayID)
    }
    Defaults[.disabledExternalBrightnessDisplays] = disabled
    refreshExternalBrightnessDisplays()
  }

  private func refreshExternalBrightnessDisplays() {
    let displays = NSScreen.screens.compactMap { screen -> ExternalBrightnessDisplay? in
      guard let displayID = screen.displayID, CGDisplayIsBuiltin(displayID) == 0,
        let id = screen.displayUUID
      else { return nil }
      return ExternalBrightnessDisplay(
        displayID: displayID, id: id, name: screen.localizedName,
        vendorID: CGDisplayVendorNumber(displayID), productID: CGDisplayModelNumber(displayID),
        serialNumber: CGDisplaySerialNumber(displayID))
    }
    externalBrightnessController.refresh(
      displays: displays,
      disabledDisplayIDs: Set(Defaults[.disabledExternalBrightnessDisplays]))
  }

  private func present(_ snapshot: HUDSnapshot) {
    hud = snapshot
    let name = snapshot.kind == .volume ? "Volume" : "Brightness"
    let level = Int((snapshot.level * 100).rounded())
    A11y.announce("\(name), \(level) percent")
    hideTask?.cancel()
    hideTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(1400))
      guard !Task.isCancelled else { return }
      self?.hud = nil
    }
  }
}
