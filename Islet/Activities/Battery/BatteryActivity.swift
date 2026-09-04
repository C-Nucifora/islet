import Combine
import Defaults
import SwiftUI

@MainActor
final class BatteryActivity: NotchActivity, ObservableObject {
  let id = "battery"
  let priority = ActivityPriority.ambient
  private(set) var activationDate: Date?
  private let monitor: BatteryMonitor
  private let managesMonitorLifecycle: Bool
  private let insightClock: any BatteryInsightClock
  private var insightAnalyzer: BatteryInsightAnalyzer
  private var eventHistory = BatteryEventHistory()
  private var cancellables: Set<AnyCancellable> = []
  private var isMonitoring = false

  /// Live state consumed by Home. The monitor stays owned here so Home cannot start a second IOKit
  /// observer or mutate battery data.
  var currentState: BatteryState? { monitor.state }

  // The tab is available whenever the feature is on. Gating it on AC power made the whole power
  // screen vanish the moment you unplugged — which is exactly when you want to read it.
  var isActive: Bool { true }

  init(
    insightClock: any BatteryInsightClock = SystemBatteryInsightClock(),
    monitor: BatteryMonitor = BatteryMonitor(), managesMonitorLifecycle: Bool = true
  ) {
    self.insightClock = insightClock
    self.monitor = monitor
    self.managesMonitorLifecycle = managesMonitorLifecycle
    insightAnalyzer = BatteryInsightAnalyzer(
      baseline: Defaults[.batteryDrainBaseline],
      capacityHistory: Defaults[.batteryCapacityHistory],
      lastAlertDates: Defaults[.batteryInsightLastAlertDates],
      clock: insightClock)
  }

  func start() {
    guard !isMonitoring else { return }
    isMonitoring = true
    insightAnalyzer = persistedInsightAnalyzer()
    // Subscribe before starting IOKit work so even an unusually fast first refresh cannot land in
    // the gap between monitor startup and observer installation.
    monitor.$state.combineLatest(monitor.$hasFreshState)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] state, hasFreshState in
        self?.handle(state, hasFreshState: hasFreshState)
      }
      .store(in: &cancellables)
    monitor.$lastLiveRefresh
      .compactMap { $0 }
      .sink { [weak self] _ in self?.handleCompletedRefresh() }
      .store(in: &cancellables)
    if managesMonitorLifecycle { monitor.start() }
  }

  func stop() {
    guard isMonitoring else { return }
    isMonitoring = false
    if managesMonitorLifecycle { monitor.stop() }
    cancellables.removeAll()
    eventHistory.reset()
    activationDate = nil
    KeepAwakeManager.shared.clearBatteryState()
    objectWillChange.send()
  }

  func resetLearnedBatteryData() {
    Defaults[.batteryDrainBaseline] = []
    Defaults[.batteryCapacityHistory] = []
    Defaults[.batteryInsightLastAlertDates] = [:]
    insightAnalyzer.reset()
    monitor.updateInsights(BatteryInsightSnapshot())
    objectWillChange.send()
  }

  var batteryInsightSummary: BatteryInsightSnapshot {
    isMonitoring ? monitor.insightSnapshot : insightAnalyzer.learnedDataSnapshot
  }

  private func persistedInsightAnalyzer() -> BatteryInsightAnalyzer {
    BatteryInsightAnalyzer(
      baseline: Defaults[.batteryDrainBaseline],
      capacityHistory: Defaults[.batteryCapacityHistory],
      lastAlertDates: Defaults[.batteryInsightLastAlertDates],
      clock: insightClock)
  }

  private func handleCompletedRefresh() {
    guard let state = monitor.state, let metrics = monitor.metrics else { return }
    let previousBaseline = insightAnalyzer.baseline
    let previousCapacity = insightAnalyzer.capacityHistory
    let previousAlerts = insightAnalyzer.lastAlertDates
    let update = insightAnalyzer.ingest(
      BatteryInsightSample(state: state, metrics: metrics),
      policy: BatteryInsightPolicy(
        unusualDrainEnabled: Defaults[.unusualBatteryDrainWarnings],
        chargerWarningsEnabled: Defaults[.chargerCapacityWarnings]))
    monitor.updateInsights(update.snapshot)
    if insightAnalyzer.baseline != previousBaseline {
      Defaults[.batteryDrainBaseline] = insightAnalyzer.baseline
    }
    if insightAnalyzer.capacityHistory != previousCapacity {
      Defaults[.batteryCapacityHistory] = insightAnalyzer.capacityHistory
    }
    if insightAnalyzer.lastAlertDates != previousAlerts {
      Defaults[.batteryInsightLastAlertDates] = insightAnalyzer.lastAlertDates
    }
    guard ActivityEnablement.isEnabled("battery") else { return }
    for alert in update.alerts {
      SystemEventBus.shared.emit(Self.event(for: alert))
    }
    objectWillChange.send()
  }

  private func handle(_ new: BatteryState?, hasFreshState: Bool) {
    let events = eventHistory.events(for: new, isFresh: hasFreshState)
    guard hasFreshState, let new else { return }
    KeepAwakeManager.shared.handleBattery(
      new, lowBatteryThreshold: Defaults[.keepAwakeLowBatteryThreshold])
    // Now that the tab is always active, its activation date is simply when it first had a reading.
    if activationDate == nil { activationDate = Date() }
    objectWillChange.send()

    for event in events {
      SystemEventBus.shared.emit(Self.event(for: event))
    }
  }

  static func event(for event: BatteryEvent) -> SystemEvent {
    switch event {
    case .acConnected(let percent):
      SystemEvent(
        sourceID: "battery", icon: "bolt.fill", title: "Charging",
        subtitle: "\(percent)%", accentHex: EventAccent.positive, motion: .generic,
        announcement: "Charger connected, \(percent) percent")
    case .acDisconnected(let percent):
      SystemEvent(
        sourceID: "battery", icon: "battery.100percent", title: "On battery",
        subtitle: "\(percent)%", accentHex: EventAccent.neutral, motion: .generic,
        announcement: "Charger disconnected, \(percent) percent")
    case .lowBattery(_, let percent):
      SystemEvent(
        sourceID: "battery", icon: "battery.25percent", title: "Low battery",
        subtitle: "\(percent)%", accentHex: EventAccent.danger, motion: .peripheralLow,
        urgency: .alert, duration: 3,
        announcement: "Low battery, \(percent) percent")
    case .chargeComplete(let percent):
      SystemEvent(
        sourceID: "battery", icon: "checkmark.circle.fill", title: "Charged",
        subtitle: "\(percent)%", accentHex: EventAccent.positive, motion: .chargeComplete,
        announcement: "Battery fully charged")
    }
  }

  static func event(for alert: BatteryInsightAlert) -> SystemEvent {
    switch alert {
    case .unusualDrain(let current, let baseline):
      SystemEvent(
        sourceID: "battery", icon: "bolt.trianglebadge.exclamationmark.fill",
        title: "Unusual battery drain",
        subtitle: String(format: "%.1f W now · %.1f W usual", current, baseline),
        accentHex: EventAccent.warning, motion: .peripheralLow, urgency: .alert, duration: 3,
        announcement: String(
          format: "Unusual battery drain, %.1f watts now, usually %.1f watts", current, baseline))
    case .chargerDischarging(let watts):
      SystemEvent(
        sourceID: "battery", icon: "powerplug.portrait.fill", title: "Charger can't keep up",
        subtitle: String(format: "Battery supplying %.1f W", watts),
        accentHex: EventAccent.danger, motion: .peripheralLow, urgency: .alert, duration: 3,
        announcement: String(
          format: "Charger cannot meet demand, battery supplying %.1f watts", watts))
    case .slowCharging(let watts):
      SystemEvent(
        sourceID: "battery", icon: "battery.25percent", title: "Charging slowly",
        subtitle: String(format: "%.1f W into battery", watts),
        accentHex: EventAccent.warning, motion: .generic, urgency: .alert, duration: 3,
        announcement: String(format: "Battery charging slowly at %.1f watts", watts))
    }
  }

  let tabIcon = "battery.100percent.bolt"
  let preferredExpandedHeight = Metrics.tallExpandedHeight

  var compactLeading: AnyView {
    AnyView(
      BatteryCompactIcon(
        symbol: Self.compactSymbol(for: monitor.state), tint: Self.tint(for: monitor.state)))
  }

  var compactTrailing: AnyView {
    AnyView(
      BatteryPercentText(
        percent: monitor.state?.percent ?? 0,
        tint: Self.tint(for: monitor.state)))
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

  /// Themed for ordinary power states, but always red under 20% on battery.
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
  @Environment(\.appTheme) private var appTheme
  let percent: Int
  let tint: BatteryTint

  var body: some View {
    Text("\(percent)%")
      .font(.caption.weight(.semibold)).monospacedDigit()
      .foregroundStyle(tint.color(for: appTheme))
  }
}

private struct BatteryCompactIcon: View {
  @Environment(\.appTheme) private var appTheme
  let symbol: String
  let tint: BatteryTint

  var body: some View {
    Image(systemName: symbol)
      .foregroundStyle(tint.color(for: appTheme))
      .font(.caption2)
  }
}

/// The compact island's colour states, kept as an enum rather than a `Color` so the rule that picks
/// them is testable without comparing opaque style values.
enum BatteryTint: Equatable {
  case charging, low, normal

  func color(for theme: AppTheme) -> Color {
    switch self {
    case .charging, .normal: theme.color(for: .battery)
    case .low: .red
    }
  }
}
