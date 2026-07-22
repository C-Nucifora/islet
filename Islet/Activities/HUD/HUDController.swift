import AppKit
import Combine
import Defaults

struct HUDSnapshot: Equatable {
  enum Kind: Equatable { case volume, brightness }
  var kind: Kind
  var level: Float
  var isMuted: Bool
}

private let kSystemDefinedEventType = CGEventType(rawValue: 14)!

/// Intercepts volume/brightness media keys, applies the change itself, and shows an in-notch HUD.
/// Consuming the key event is what suppresses the system OSD. Crash-safe by construction:
/// the tap dies with the app, so keys always revert to normal system behaviour.
@MainActor
final class HUDController: ObservableObject {
  static let shared = HUDController()

  @Published private(set) var hud: HUDSnapshot?

  private var eventTap: CFMachPort?
  private var runLoopSource: CFRunLoopSource?
  private var hideTask: Task<Void, Never>?
  private var cancellables: Set<AnyCancellable> = []

  func startObserving() {
    Defaults.publisher(.hudEnabled)
      .sink { [weak self] change in
        if change.newValue { self?.start() } else { self?.stop() }
      }
      .store(in: &cancellables)
    start()
  }

  var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

  func promptForAccessibility() {
    // Literal avoids referencing the non-Sendable global kAXTrustedCheckOptionPrompt.
    let options = ["AXTrustedCheckOptionPrompt": true]
    _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
  }

  func start() {
    guard Defaults[.hudEnabled], eventTap == nil, isAccessibilityTrusted else { return }
    let mask = CGEventMask(1 << kSystemDefinedEventType.rawValue)
    let tap = CGEvent.tapCreate(
      tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
      eventsOfInterest: mask,
      callback: { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passRetained(event) }
        let controller = Unmanaged<HUDController>.fromOpaque(userInfo)
          .takeUnretainedValue()
        // Bool is Sendable; CGEvent/Unmanaged are not, so decide inside and branch out here.
        let consume = MainActor.assumeIsolated { controller.handle(type: type, event: event) }
        return consume ? nil : Unmanaged.passRetained(event)
      },
      userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()))
    guard let tap else {
      Log.app.error("HUD event tap creation failed (accessibility?)")
      return
    }
    eventTap = tap
    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    runLoopSource = source
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    Log.app.info("HUD event tap active")
  }

  func stop() {
    if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: false) }
    if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
    eventTap = nil
    runLoopSource = nil
    hud = nil
  }

  /// Returns true if the event should be consumed (suppressing the system OSD).
  private func handle(type: CGEventType, event: CGEvent) -> Bool {
    // The system disables a tap that times out or is interrupted; re-enable and pass through.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
      return false
    }
    guard type == kSystemDefinedEventType, let nsEvent = NSEvent(cgEvent: event),
      nsEvent.type == .systemDefined, nsEvent.subtype.rawValue == 8,
      let decoded = HUDKey.decode(data1: nsEvent.data1)
    else { return false }

    if decoded.isKeyDown { apply(decoded.key, modifiers: nsEvent.modifierFlags) }
    return true  // consume both down and up so the system never sees the key
  }

  private func apply(_ key: HUDKey, modifiers: NSEvent.ModifierFlags) {
    let divisor: Float = modifiers.contains(.shift) && modifiers.contains(.option) ? 4 : 1
    switch key {
    case .volumeUp, .volumeDown:
      let target = HUDMath.stepped(
        VolumeController.currentVolume(), up: key == .volumeUp, divisor: divisor)
      VolumeController.setVolume(target)
      present(.init(kind: .volume, level: target, isMuted: target == 0))
    case .mute:
      VolumeController.toggleMute()
      let muted = VolumeController.isMuted()
      present(
        .init(
          kind: .volume, level: muted ? 0 : VolumeController.currentVolume(),
          isMuted: muted))
    case .brightnessUp, .brightnessDown:
      let target = HUDMath.stepped(
        BrightnessController.currentBrightness(), up: key == .brightnessUp,
        divisor: divisor)
      BrightnessController.setBrightness(target)
      present(.init(kind: .brightness, level: target, isMuted: false))
    }
  }

  /// Debug-only: exercise the HUD render path without the event tap / accessibility.
  func debugPresent(_ snapshot: HUDSnapshot) { present(snapshot) }

  private func present(_ snapshot: HUDSnapshot) {
    hud = snapshot
    hideTask?.cancel()
    hideTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(1400))
      guard !Task.isCancelled else { return }
      self?.hud = nil
    }
  }
}
