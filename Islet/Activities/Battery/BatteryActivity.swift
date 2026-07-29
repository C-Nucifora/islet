import Combine
import Defaults
import SwiftUI

@MainActor
final class BatteryActivity: NotchActivity, ObservableObject {
  let id = "battery"
  let priority = ActivityPriority.ambient
  private(set) var activationDate: Date?
  private let monitor = BatteryMonitor()
  private var lastState: BatteryState?
  private var cancellables: Set<AnyCancellable> = []

  // The tab is available whenever the feature is on. Gating it on AC power made the whole power
  // screen vanish the moment you unplugged — which is exactly when you want to read it.
  var isActive: Bool { Defaults[.batteryEnabled] }

  func start() {
    monitor.start()
    monitor.$state
      .receive(on: DispatchQueue.main)
      .compactMap { $0 }
      .sink { [weak self] new in self?.handle(new) }
      .store(in: &cancellables)
  }

  private func handle(_ new: BatteryState) {
    let events = BatteryEventDetector.events(from: lastState, to: new)
    lastState = new
    // Now that the tab is always active, its activation date is simply when it first had a reading.
    if activationDate == nil { activationDate = Date() }
    objectWillChange.send()

    guard Defaults[.batteryEnabled] else { return }
    for event in events {
      SneakQueue.shared.submit(Self.sneak(for: event))
    }
  }

  static func sneak(for event: BatteryEvent) -> Sneak {
    switch event {
    case .acConnected(let percent):
      Sneak(
        source: "battery",
        leading: AnyView(
          Image(systemName: "bolt.fill").foregroundStyle(.green).font(.caption)),
        trailing: AnyView(BatteryPercentText(percent: percent, color: .green)),
        announcement: "Charger connected, \(percent) percent")
    case .acDisconnected(let percent):
      Sneak(
        source: "battery",
        leading: AnyView(
          Image(systemName: "battery.100percent").foregroundStyle(.secondary)
            .font(.caption)),
        trailing: AnyView(BatteryPercentText(percent: percent, color: .secondary)),
        announcement: "Charger disconnected, \(percent) percent")
    case .lowBattery(_, let percent):
      Sneak(
        source: "battery", duration: 3,
        leading: AnyView(
          Image(systemName: "battery.25percent").foregroundStyle(.red).font(.caption)),
        trailing: AnyView(BatteryPercentText(percent: percent, color: .red)),
        announcement: "Low battery, \(percent) percent")
    }
  }

  let tabIcon = "battery.100percent.bolt"
  let preferredExpandedHeight = Metrics.tallExpandedHeight

  var compactLeading: AnyView {
    AnyView(
      Image(systemName: Self.compactSymbol(for: monitor.state))
        .foregroundStyle(Self.tint(for: monitor.state).color)
        .font(.caption2))
  }

  var compactTrailing: AnyView {
    AnyView(
      BatteryPercentText(
        percent: monitor.state?.percent ?? 0,
        color: Self.tint(for: monitor.state).color))
  }

  // These three are pure and marked `nonisolated` so the tests can call them without hopping to the
  // main actor — `BatteryActivity` is @MainActor, which would otherwise isolate its statics too.

  /// Bolt while charging, plug while topped up on AC, a filled battery on battery power.
  nonisolated static func compactSymbol(for state: BatteryState?) -> String {
    guard let state else { return "battery.100percent" }
    if state.isCharging { return "bolt.fill" }
    if state.onAC { return "powerplug.fill" }
    return batterySymbol(for: state.percent)
  }

  /// SF Symbols only ships 0/25/50/75/100 battery fills.
  nonisolated static func batterySymbol(for percent: Int) -> String {
    switch percent {
    case ..<13: "battery.0percent"
    case ..<38: "battery.25percent"
    case ..<63: "battery.50percent"
    case ..<88: "battery.75percent"
    default: "battery.100percent"
    }
  }

  /// Green while power is coming in, red under 20% on battery, neutral otherwise.
  nonisolated static func tint(for state: BatteryState?) -> BatteryTint {
    guard let state else { return .normal }
    if state.onAC { return .charging }
    return state.percent <= 20 ? .low : .normal
  }

  var expandedView: AnyView {
    AnyView(BatteryExpandedView(monitor: monitor))
  }
}

struct BatteryPercentText: View {
  let percent: Int
  let color: Color

  var body: some View {
    Text("\(percent)%")
      .font(.caption.weight(.semibold)).monospacedDigit()
      .foregroundStyle(color)
  }
}

/// The compact island's colour states, kept as an enum rather than a `Color` so the rule that picks
/// them is testable without comparing opaque style values.
enum BatteryTint: Equatable {
  case charging, low, normal

  var color: Color {
    switch self {
    case .charging: .green
    case .low: .red
    case .normal: .secondary
    }
  }
}
