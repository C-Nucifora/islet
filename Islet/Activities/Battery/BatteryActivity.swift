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

  var isActive: Bool {
    Defaults[.batteryEnabled] && (monitor.state?.isCharging ?? false)
  }

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
    let wasActive = lastState?.isCharging ?? false
    lastState = new
    if !wasActive, new.isCharging { activationDate = Date() }
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
        trailing: AnyView(BatteryPercentText(percent: percent, color: .green)))
    case .acDisconnected(let percent):
      Sneak(
        source: "battery",
        leading: AnyView(
          Image(systemName: "battery.100percent").foregroundStyle(.secondary)
            .font(.caption)),
        trailing: AnyView(BatteryPercentText(percent: percent, color: .secondary)))
    case .lowBattery(_, let percent):
      Sneak(
        source: "battery", duration: 3,
        leading: AnyView(
          Image(systemName: "battery.25percent").foregroundStyle(.red).font(.caption)),
        trailing: AnyView(BatteryPercentText(percent: percent, color: .red)))
    }
  }

  let tabIcon = "battery.100percent.bolt"
  var compactLeading: AnyView {
    AnyView(Image(systemName: "bolt.fill").foregroundStyle(.green).font(.caption2))
  }

  var compactTrailing: AnyView {
    AnyView(BatteryPercentText(percent: monitor.state?.percent ?? 0, color: .green))
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

struct BatteryExpandedView: View {
  @ObservedObject var monitor: BatteryMonitor

  var body: some View {
    VStack(spacing: 8) {
      Image(systemName: monitor.state?.isCharging == true ? "bolt.fill" : "battery.100percent")
        .font(.largeTitle)
        .foregroundStyle(monitor.state?.isCharging == true ? .green : .secondary)
      Text("\(monitor.state?.percent ?? 0)%")
        .font(.title2.weight(.bold)).monospacedDigit()
      Text(monitor.state?.isCharging == true ? "Charging" : "On battery")
        .font(.caption).foregroundStyle(.secondary)
    }
    .foregroundStyle(.white)
  }
}
