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

  // Show the persistent indicator whenever on AC power (charging OR plugged-in-and-full),
  // so the power status is visible the whole time you're plugged in — not only while charging.
  var isActive: Bool {
    Defaults[.batteryEnabled] && (monitor.state?.onAC ?? false)
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
    let wasActive = lastState?.onAC ?? false
    lastState = new
    if !wasActive, new.onAC { activationDate = Date() }
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
    let charging = monitor.state?.isCharging ?? false
    return AnyView(
      Image(systemName: charging ? "bolt.fill" : "powerplug.fill")
        .foregroundStyle(.green).font(.caption2))
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

  private var onAC: Bool { monitor.state?.onAC ?? false }
  private var iconName: String {
    if monitor.state?.isCharging == true { return "bolt.fill" }
    if onAC { return "powerplug.fill" }
    return "battery.100percent"
  }
  private var statusText: String {
    if monitor.state?.isCharging == true { return "Charging" }
    if onAC { return "Plugged in" }
    return "On battery"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .center, spacing: 20) {
        // Charge summary
        VStack(spacing: 4) {
          Image(systemName: iconName)
            .font(.largeTitle)
            .foregroundStyle(onAC ? .green : .secondary)
          Text("\(monitor.state?.percent ?? 0)%")
            .font(.title2.weight(.bold)).monospacedDigit()
          Text(statusText)
            .font(.caption2).foregroundStyle(.secondary)
        }
        .frame(width: 96)

        // AlDente-style metrics grid
        if let m = monitor.metrics {
          LazyVGrid(
            columns: [
              GridItem(.flexible(), alignment: .leading),
              GridItem(.flexible(), alignment: .leading),
            ],
            alignment: .leading, spacing: 6
          ) {
            if let h = m.healthPercent { metric("Health", "\(h)%") }
            if let c = m.cycleCount { metric("Cycles", "\(c)") }
            if let t = m.temperatureC { metric("Temp", String(format: "%.1f°C", t)) }
            if let w = m.powerWatts { metric("Power", String(format: "%+.1f W", w)) }
            if let ttf = m.timeToFullMinutes {
              metric("Full in", timeString(ttf))
            } else if let tte = m.timeToEmptyMinutes {
              metric("Left", timeString(tte))
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      }

      // Connected peripherals (Magic Mouse/Keyboard/Trackpad, ...) — populates when present.
      if !monitor.peripherals.isEmpty {
        HStack(spacing: 14) {
          ForEach(monitor.peripherals) { device in
            HStack(spacing: 4) {
              Image(systemName: device.icon).font(.caption2).foregroundStyle(.secondary)
              Text("\(device.percent)%").font(.caption2.weight(.semibold)).monospacedDigit()
                .foregroundStyle(device.percent <= 15 ? .red : .white)
            }
          }
          Spacer(minLength: 0)
        }
      }
    }
    .foregroundStyle(.white)
  }

  private func metric(_ label: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
      Text(value).font(.caption.weight(.semibold)).monospacedDigit()
    }
  }

  private func timeString(_ minutes: Int) -> String {
    minutes < 60 ? "\(minutes)m" : String(format: "%dh %02dm", minutes / 60, minutes % 60)
  }
}
