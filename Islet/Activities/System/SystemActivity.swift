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

  func start() {
    monitor.start()
    monitor.$sample
      .receive(on: DispatchQueue.main)
      .sink { [weak self] sample in self?.handle(sample) }
      .store(in: &cancellables)
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
    guard Defaults[.systemEnabled] else { return false }
    return Defaults[.systemAlwaysVisible] || gate.isActive
  }

  // Both compact slots are fixed-width symbols with no digits, by design. A value that changes
  // every second would re-measure through `onGeometryChange` and resize the NSPanel at 1 Hz. The
  // symbol only changes when `SystemPresenceGate.reason` does, which is minutes apart at worst.
  var compactLeading: AnyView {
    AnyView(Image(systemName: "cpu").foregroundStyle(.orange).font(.caption2))
  }

  var compactTrailing: AnyView {
    let thermal = gate.reason == .thermal
    return AnyView(
      Image(systemName: thermal ? "thermometer.high" : "gauge.with.dots.needle.67percent")
        .foregroundStyle(thermal ? Color.red : Color.orange)
        .font(.caption2)
        .accessibilityLabel(thermal ? "Thermal pressure" : "High CPU"))
  }

  var expandedView: AnyView { AnyView(SystemExpandedView(monitor: monitor)) }
}
