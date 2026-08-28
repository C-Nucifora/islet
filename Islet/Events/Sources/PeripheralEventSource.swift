import Combine
import Foundation

/// Magic Mouse / Keyboard / Trackpad batteries crossing a low threshold.
///
/// `PeripheralBatteryReader` has been read on every `BatteryMonitor` tick since Bluetooth peripheral
/// batteries shipped, and the result has only ever been rendered in the expanded view — a level you
/// have to go looking for. This announces the crossing.
///
/// Crossings only, via `ThresholdDetector`: a mouse sitting at 9% must not announce once a second.
@MainActor
final class PeripheralEventSource: SystemEventSource {
  let id = "peripheral"
  let displayName = "Peripheral batteries"
  let tier = SystemEventTier.core

  private let detector = ThresholdDetector(thresholds: [20, 10], direction: .falling)
  private var lastLevels: [String: Double] = [:]
  private var timer: AnyCancellable?

  func start() {
    guard timer == nil else { return }
    // Seed without announcing: a peripheral already below the threshold at launch is not news.
    for p in PeripheralBatteryReader.read() { lastLevels[p.id] = Double(p.percent) }
    // These change over hours. A five-minute poll is generous and costs one IORegistry walk.
    timer = Timer.publish(every: 300, on: .main, in: .common).autoconnect()
      .sink { [weak self] _ in self?.check() }
  }

  func stop() {
    timer = nil
    lastLevels = [:]
  }

  private func check() {
    let peripherals = PeripheralBatteryReader.read()
    var currentLevels: [String: Double] = [:]
    currentLevels.reserveCapacity(peripherals.count)
    for p in peripherals {
      let level = Double(p.percent)
      currentLevels[p.id] = level
      let crossings = detector.crossings(from: lastLevels[p.id], to: level)
      guard let lowest = crossings.min() else { continue }
      SystemEventBus.shared.emit(
        SystemEvent(
          sourceID: id, icon: p.icon, title: "\(p.name) battery low",
          subtitle: "\(p.percent)%",
          accentHex: lowest <= 10 ? EventAccent.danger : EventAccent.warning,
          motion: .peripheralLow,
          urgency: .alert, duration: 3,
          announcement: "\(p.name) battery at \(p.percent) percent"))
    }
    // Forget disconnected devices. If the same hardware later reconnects, its new level becomes a
    // fresh baseline instead of being compared with a stale value from hours or days earlier.
    lastLevels = currentLevels
  }
}
