import Combine
import Defaults
import SwiftUI

/// The System tab: CPU, GPU, RAM, disk, network and thermal in a 250 pt-tall expanded island.
@MainActor
final class SystemActivity: NotchActivity, ObservableObject {
  let id = "system"
  let priority = ActivityPriority.ambient
  let tabIcon = "cpu"
  private(set) var activationDate: Date?

  /// The six-row readout does not fit the 190 pt base tier.
  var preferredExpandedHeight: CGFloat { Metrics.tallExpandedHeight }

  private let monitor = SystemMetricsMonitor.shared
  private var gate = SystemPresenceGate()
  private var cancellables: Set<AnyCancellable> = []
  private var isMonitoring = false

  func start() {
    guard !isMonitoring else { return }
    isMonitoring = true
    monitor.start()
    monitor.$sample
      .receive(on: DispatchQueue.main)
      .sink { [weak self] sample in self?.handle(sample) }
      .store(in: &cancellables)
  }

  func stop() {
    guard isMonitoring else { return }
    isMonitoring = false
    monitor.stop()
    cancellables.removeAll()
    gate = SystemPresenceGate()
    activationDate = nil
    objectWillChange.send()
  }

  /// Republishes ONLY on a gate transition. A per-sample `objectWillChange` would push
  /// `ActivityCenter` — and through it the whole compact row — through a layout pass every second.
  private func handle(_ sample: SystemMetricsSample) {
    guard gate.update(cpuTotal: sample.cpuTotal, thermalState: sample.thermalState ?? 0) else {
      return
    }
    activationDate = gate.isActive ? Date() : nil
    objectWillChange.send()
  }

  var isActive: Bool {
    return Defaults[.systemAlwaysVisible] || gate.isActive
  }

  // Both compact slots are fixed-width symbols with no digits, by design. A value that changes
  // every second would re-measure through `onGeometryChange` and resize the NSPanel at 1 Hz. The
  // symbol only changes when `SystemPresenceGate.reason` does, which is minutes apart at worst.
  var compactLeading: AnyView {
    AnyView(Image(systemName: "cpu").appThemeForeground(.system).font(.caption2))
  }

  var compactTrailing: AnyView {
    let thermal = gate.reason == .thermal
    if thermal {
      return AnyView(
        Image(systemName: "thermometer.high")
          .foregroundStyle(.red)
          .font(.caption2)
          .accessibilityLabel("Thermal pressure"))
    }
    return AnyView(
      Image(systemName: "gauge.with.dots.needle.67percent")
        .appThemeForeground(.system)
        .font(.caption2)
        .accessibilityLabel("High CPU"))
  }

  var expandedView: AnyView { AnyView(SystemExpandedView(monitor: monitor)) }
}
