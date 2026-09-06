import AppKit
import Combine

/// Screen lock, screen unlock and Caps Lock.
///
/// Lock and unlock arrive on `DistributedNotificationCenter` under undocumented-but-stable names
/// that every screen-lock utility on macOS has used for a decade. Caps Lock comes off a global
/// `.flagsChanged` monitor — the same mechanism `EventMonitors` already uses, and unlike the HUD's
/// event tap it needs no Accessibility grant, because it only observes.
@MainActor
final class SessionEventSource: SystemEventSource {
  let id = "session"
  let displayName = String(localized: "Screen lock and Caps Lock")
  let tier = SystemEventTier.extended

  private var cancellables: Set<AnyCancellable> = []
  private var flagsMonitor: Any?
  private var lastCapsLock = false

  func start() {
    guard cancellables.isEmpty, flagsMonitor == nil else { return }
    let dnc = DistributedNotificationCenter.default()
    dnc.publisher(for: Notification.Name("com.apple.screenIsLocked"))
      .sink { [weak self] _ in self?.reportLock(locked: true) }
      .store(in: &cancellables)
    dnc.publisher(for: Notification.Name("com.apple.screenIsUnlocked"))
      .sink { [weak self] _ in self?.reportLock(locked: false) }
      .store(in: &cancellables)

    lastCapsLock = NSEvent.modifierFlags.contains(.capsLock)
    flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
      MainActor.assumeIsolated { self?.reportCapsLock(event.modifierFlags.contains(.capsLock)) }
    }
  }

  func stop() {
    cancellables.removeAll()
    if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
    flagsMonitor = nil
  }

  private func reportLock(locked: Bool) {
    SystemEventBus.shared.emit(
      SystemEvent(
        sourceID: id,
        icon: locked ? "lock.fill" : "lock.open.fill",
        title: locked ? String(localized: "Locked") : String(localized: "Unlocked"),
        accentHex: locked ? EventAccent.neutral : EventAccent.positive,
        motion: .lock,
        urgency: .ambient,
        announcement: locked
          ? String(localized: "Screen locked") : String(localized: "Screen unlocked")))
  }

  private func reportCapsLock(_ on: Bool) {
    guard on != lastCapsLock else { return }
    lastCapsLock = on
    SystemEventBus.shared.emit(
      SystemEvent(
        sourceID: id,
        icon: on ? "capslock.fill" : "capslock",
        title: on ? String(localized: "Caps Lock on") : String(localized: "Caps Lock off"),
        accentHex: on ? EventAccent.warning : EventAccent.neutral,
        motion: .lock,
        urgency: .ambient,
        duration: 1.2,
        announcement: on ? String(localized: "Caps Lock on") : String(localized: "Caps Lock off")))
  }
}
