import AppKit
import Combine
import Foundation

/// Low Power Mode.
///
/// Public and notification-driven. `ProcessInfo.isLowPowerModeEnabled` plus
/// `.NSProcessInfoPowerStateDidChange` is the documented pair — never shell out to `pmset`.
@MainActor
final class PowerEventSource: SystemEventSource {
  let id = "power"
  let displayName = String(localized: "Charging and Low Power Mode")
  let tier = SystemEventTier.core

  private var cancellables: Set<AnyCancellable> = []
  private var lastLowPower: Bool?

  func start() {
    guard cancellables.isEmpty else { return }
    lastLowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    NotificationCenter.default
      .publisher(for: .NSProcessInfoPowerStateDidChange)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in self?.reportLowPower() }
      .store(in: &cancellables)
  }

  func stop() {
    cancellables.removeAll()
    lastLowPower = nil
  }

  private func reportLowPower() {
    let on = ProcessInfo.processInfo.isLowPowerModeEnabled
    guard on != lastLowPower else { return }
    lastLowPower = on
    SystemEventBus.shared.emit(
      SystemEvent(
        sourceID: id,
        icon: on ? "battery.25percent" : "battery.100percent",
        title: on
          ? String(localized: "Low Power Mode on") : String(localized: "Low Power Mode off"),
        accentHex: on ? EventAccent.warning : EventAccent.neutral,
        motion: .lowPower,
        urgency: .ambient,
        announcement: on
          ? String(localized: "Low Power Mode on") : String(localized: "Low Power Mode off")))
  }
}

/// Sleep and wake. Separate source so it gets its own toggle — it is the one people switch off
/// first, because a wake sneak competes with the login window.
@MainActor
final class SleepEventSource: SystemEventSource {
  let id = "sleep"
  let displayName = String(localized: "Sleep and wake")
  let tier = SystemEventTier.core

  private var cancellables: Set<AnyCancellable> = []

  func start() {
    guard cancellables.isEmpty else { return }
    NSWorkspace.shared.notificationCenter
      .publisher(for: NSWorkspace.didWakeNotification)
      .sink { [weak self] _ in self?.report(waking: true) }
      .store(in: &cancellables)
    NSWorkspace.shared.notificationCenter
      .publisher(for: NSWorkspace.willSleepNotification)
      .sink { [weak self] _ in self?.report(waking: false) }
      .store(in: &cancellables)
  }

  func stop() { cancellables.removeAll() }

  private func report(waking: Bool) {
    SystemEventBus.shared.emit(
      SystemEvent(
        sourceID: id,
        icon: waking ? "sun.max.fill" : "moon.fill",
        title: waking ? String(localized: "Awake") : String(localized: "Going to sleep"),
        accentHex: waking ? EventAccent.warning : EventAccent.neutral,
        motion: .sleepWake,
        urgency: .ambient,
        announcement: waking ? String(localized: "Awake") : String(localized: "Going to sleep")))
  }
}
