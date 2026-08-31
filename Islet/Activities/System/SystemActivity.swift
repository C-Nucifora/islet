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
    observePresenceControls()
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
    guard gate.update(sample: sample, controls: presenceControls) else {
      return
    }
    publishGateChange()
  }

  private func publishGateChange() {
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
    switch gate.reason {
    case .thermal:
      return AnyView(
        Image(systemName: "thermometer.high")
          .foregroundStyle(.red)
          .font(.caption2)
          .accessibilityLabel("Thermal pressure"))
    case .memoryPressure:
      return AnyView(
        Image(systemName: "memorychip")
          .foregroundStyle(.orange)
          .font(.caption2)
          .accessibilityLabel("Memory pressure"))
    case .lowDiskSpace:
      return AnyView(
        Image(systemName: "externaldrive.fill.badge.exclamationmark")
          .foregroundStyle(.orange)
          .font(.caption2)
          .accessibilityLabel("Low disk space"))
    case .diskThroughput:
      return AnyView(
        Image(systemName: "externaldrive.fill")
          .appThemeForeground(.system)
          .font(.caption2)
          .accessibilityLabel("Heavy disk activity"))
    case .networkThroughput:
      return AnyView(
        Image(systemName: "arrow.up.arrow.down.circle.fill")
          .appThemeForeground(.system)
          .font(.caption2)
          .accessibilityLabel("High network traffic"))
    case .cpu:
      return AnyView(
        Image(systemName: "gauge.with.dots.needle.67percent")
          .appThemeForeground(.system)
          .font(.caption2)
          .accessibilityLabel("High CPU"))
    case .none:
      return AnyView(
        Image(systemName: "gauge")
          .appThemeForeground(.system)
          .font(.caption2)
          .accessibilityLabel("System metrics"))
    }
  }

  var expandedView: AnyView { AnyView(SystemExpandedView(monitor: monitor)) }

  private var presenceControls: SystemPresenceGate.Controls {
    SystemPresenceGate.Controls(
      cpu: Defaults[.systemAutoPresentCPU],
      thermal: Defaults[.systemAutoPresentThermal],
      memoryPressure: Defaults[.systemAutoPresentMemoryPressure],
      lowDiskSpace: Defaults[.systemAutoPresentLowDiskSpace],
      diskThroughput: Defaults[.systemAutoPresentDiskThroughput],
      networkThroughput: Defaults[.systemAutoPresentNetworkThroughput])
  }

  private func observePresenceControls() {
    let changes: [AnyPublisher<Void, Never>] = [
      Defaults.publisher(.systemAutoPresentCPU).dropFirst().map { _ in () }.eraseToAnyPublisher(),
      Defaults.publisher(.systemAutoPresentThermal).dropFirst().map { _ in () }
        .eraseToAnyPublisher(),
      Defaults.publisher(.systemAutoPresentMemoryPressure).dropFirst().map { _ in () }
        .eraseToAnyPublisher(),
      Defaults.publisher(.systemAutoPresentLowDiskSpace).dropFirst().map { _ in () }
        .eraseToAnyPublisher(),
      Defaults.publisher(.systemAutoPresentDiskThroughput).dropFirst().map { _ in () }
        .eraseToAnyPublisher(),
      Defaults.publisher(.systemAutoPresentNetworkThroughput).dropFirst().map { _ in () }
        .eraseToAnyPublisher(),
    ]
    Publishers.MergeMany(changes)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in
        guard let self else { return }
        guard self.gate.update(controls: self.presenceControls) else { return }
        self.publishGateChange()
      }
      .store(in: &cancellables)
  }
}
