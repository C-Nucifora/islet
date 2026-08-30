import Defaults
import SwiftUI

/// Display values for the two thermal readings shown by the System activity.
///
/// macOS reports system-wide thermal pressure as a state. The battery temperature comes from a
/// separate hardware sensor, so this model keeps their labels and availability independent.
struct SystemThermalPresentation: Equatable, Sendable {
  enum Pressure: Equatable, Sendable {
    case nominal
    case fair
    case serious
    case critical
    case unavailable

    init(rawValue: Int?) {
      switch rawValue {
      case 0: self = .nominal
      case 1: self = .fair
      case 2: self = .serious
      case 3: self = .critical
      default: self = .unavailable
      }
    }

    var name: String {
      switch self {
      case .nominal: String(localized: "nominal")
      case .fair: String(localized: "fair")
      case .serious: String(localized: "serious")
      case .critical: String(localized: "critical")
      case .unavailable: String(localized: "unavailable")
      }
    }
  }

  let pressure: Pressure
  let batteryTemperatureC: Double?

  init(thermalState: Int?, batteryTemperatureC: Double?) {
    pressure = Pressure(rawValue: thermalState)
    self.batteryTemperatureC = batteryTemperatureC?.isFinite == true ? batteryTemperatureC : nil
  }

  var pressureText: String { String(localized: "System: \(pressure.name)") }

  var batteryTemperatureText: String {
    guard let batteryTemperatureC else { return String(localized: "Battery: unavailable") }
    return String(
      localized:
        "Battery: \(LocalizedFormat.number(batteryTemperatureC, fractionDigits: 1...1)) °C")
  }

  var accessibilityValue: String {
    let battery: String
    if let batteryTemperatureC {
      battery = String(
        localized:
          "Battery temperature \(PowerFormat.temperatureAccessibility(batteryTemperatureC)).")
    } else {
      battery = String(localized: "Battery temperature unavailable.")
    }
    return
      String(
        localized:
          "System thermal pressure \(pressure.name). \(battery) The readings do not map directly.")
  }

  static let helpText = String(
    localized:
      "System thermal pressure and battery sensor temperature are separate readings and do not map directly."
  )
}

/// The System tab's readout.
///
/// ```
/// CPU   38%  ▁▂▅▃▂▁▄█▅▃   P 44%  E 18%   load 3.51
/// GPU   12%  ▁▁▂▁▁▁▃▂▁▁
/// RAM   14.2 / 36 GB  ▃▃▄▄▄▅▅▅   wired 4.2   swap 12 MB
/// Disk  ↓ 1.2 MB/s  ↑ 340 KB/s   412 GB free
/// Net   ↓ 8.4 Mb/s  ↑ 1.1 Mb/s   en0
/// Therm System: nominal   Battery: 31.2 °C
/// ```
///
/// The trailing detail on each row is shown only for `.combined` — that is what makes it the
/// "everything" style. Every other style shows the label, the value and nothing else.
struct SystemExpandedView: View {
  @ObservedObject var monitor: SystemMetricsMonitor
  @Default(.metricStyles) private var metricStyles
  @Default(.processAttributionEnabled) private var processAttributionEnabled

  private var sample: SystemMetricsSample { monitor.sample }

  private func style(_ kind: SystemMetricKind) -> MetricDisplayStyle {
    MetricDisplayStyle.effective(
      for: kind, requested: MetricDisplayStyle.resolve(metricStyles[kind.rawValue]))
  }

  private func ring(_ kind: SystemMetricKind) -> MetricRing? {
    monitor.rings[kind]
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      cpuRow
      gpuRow
      memoryRow
      diskRow
      networkRow
      thermalRow
      if processAttributionEnabled {
        ProcessAttributionView(monitor: monitor.attribution)
      }
    }
    .foregroundStyle(.white)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    // 1 Hz while this view is on screen, 5 s once it leaves.
    .liveSampling(monitor.liveGate)
  }

  // MARK: - Rows

  private var cpuRow: some View {
    row(
      String(localized: "CPU"), kind: .cpu, fraction: sample.cpuTotal,
      text: percent(sample.cpuTotal), scale: .fixed(min: 0, max: 1)
    ) {
      HStack(spacing: 10) {
        if let performance = sample.cpuPerformance {
          detail(String(localized: "P \(percent(performance))"))
        }
        if let efficiency = sample.cpuEfficiency {
          detail(String(localized: "E \(percent(efficiency))"))
        }
        if let load = sample.loadAverage {
          detail(String(localized: "load \(LocalizedFormat.number(load, fractionDigits: 2...2))"))
        }
      }
    }
  }

  private var gpuRow: some View {
    row(
      String(localized: "GPU"), kind: .gpu, fraction: sample.gpu,
      text: percent(sample.gpu), scale: .fixed(min: 0, max: 1)
    ) {
      EmptyView()
    }
  }

  private var memoryRow: some View {
    let used = sample.memoryUsedBytes
    let total = sample.memoryTotalBytes
    let fraction: Double? = {
      guard let used, let total, total > 0 else { return nil }
      return Double(used) / Double(total)
    }()
    let text: String = {
      guard let used, let total else { return "—" }
      return "\(bytes(used)) / \(bytes(total))"
    }()
    return row(
      String(localized: "RAM"), kind: .memory, fraction: fraction, text: text,
      scale: .fixed(min: 0, max: 1)
    ) {
      HStack(spacing: 10) {
        if let wired = sample.memoryWiredBytes {
          detail(String(localized: "wired \(bytes(wired))"))
        }
        if let swap = sample.swapUsedBytes { detail(String(localized: "swap \(bytes(swap))")) }
      }
    }
  }

  private var diskRow: some View {
    let text: String = {
      guard let read = sample.diskReadBytesPerSec, let write = sample.diskWriteBytesPerSec
      else { return "—" }
      return "↓ \(bytesPerSecond(read))  ↑ \(bytesPerSecond(write))"
    }()
    return row(String(localized: "Disk"), kind: .disk, fraction: nil, text: text, scale: .auto) {
      if let free = sample.diskFreeBytes { detail(String(localized: "\(bytes(free)) free")) }
    }
  }

  private var networkRow: some View {
    let text: String = {
      guard let inbound = sample.netInBytesPerSec, let outbound = sample.netOutBytesPerSec
      else { return "—" }
      return "↓ \(bitsPerSecond(inbound))  ↑ \(bitsPerSecond(outbound))"
    }()
    return row(String(localized: "Net"), kind: .network, fraction: nil, text: text, scale: .auto) {
      if let interface = sample.primaryInterface { detail(interface) }
    }
  }

  private var thermalRow: some View {
    let presentation = SystemThermalPresentation(
      thermalState: sample.thermalState,
      batteryTemperatureC: sample.batteryTemperatureC)
    return row(
      String(localized: "Therm"), kind: .thermal, fraction: nil,
      text: presentation.pressureText,
      scale: .fixed(min: 0, max: 1)
    ) {
      detail(presentation.batteryTemperatureText)
    }
    .help(SystemThermalPresentation.helpText)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Thermal readings")
    .accessibilityValue(presentation.accessibilityValue)
  }

  // MARK: - Row scaffold

  @ViewBuilder
  private func row<Detail: View>(
    _ label: String, kind: SystemMetricKind, fraction: Double?, text: String,
    scale: SparklineScale, @ViewBuilder detail: () -> Detail
  ) -> some View {
    let style = style(kind)
    let content = HStack(spacing: 8) {
      Text(label)
        .font(.system(size: 10, weight: .semibold))
        .appThemeForeground(.system)
        .frame(width: 34, alignment: .leading)
      if style != .sparkline {
        Text(text)
          .font(.caption.weight(.semibold))
          .monospacedDigit()
          .lineLimit(1)
          .frame(width: 132, alignment: .leading)
      }
      if style == .numberAndBar {
        MetricBar(fraction: fraction ?? 0)
      }
      // An empty ring means either a cold start or `.thermal`, which has no series. Drawing an
      // empty 28 × 14 plate in either case is just a smudge, so skip it.
      if style.needsHistory, let history = ring(kind), !history.samples.isEmpty {
        SparklineView(history: history, scale: scale)
        Text(SystemChartHistory.timeSpanLabel)
          .font(.system(size: 9, weight: .medium))
          .monospacedDigit()
          .foregroundStyle(.secondary)
          .accessibilityLabel("Last five minutes")
      }
      if style == .combined {
        detail()
      }
      Spacer(minLength: 0)
    }
    .frame(height: 24)
    if style == .sparkline {
      content
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(text)
    } else {
      content
    }
  }

  private func detail(_ text: String) -> some View {
    Text(text)
      .font(.system(size: 10))
      .monospacedDigit()
      .foregroundStyle(.secondary)
      .lineLimit(1)
  }

  // MARK: - Formatting
  // Untested on purpose: these route through locale-aware formatters, so asserting exact strings
  // would be testing the locale.

  private func percent(_ fraction: Double?) -> String {
    guard let fraction else { return "—" }
    return LocalizedFormat.percent(fraction)
  }

  /// `.byteCount` takes an `Int64`, not a `UInt64` — the conversion is required, not incidental.
  /// `spellsOutZero: false` keeps an idle disk reading "0 bytes" rather than "Zero kB".
  private func bytes(_ value: UInt64) -> String {
    LocalizedFormat.bytes(Int64(value))
  }

  private func bytesPerSecond(_ value: Double) -> String {
    String(localized: "\(bytes(UInt64(max(value, 0))))/s")
  }

  /// Network is conventionally quoted in bits per second; disk in bytes per second.
  private func bitsPerSecond(_ bytesPerSec: Double) -> String {
    let bits = max(bytesPerSec, 0) * 8
    if bits >= 1_000_000_000 {
      return String(
        localized: "\(LocalizedFormat.number(bits / 1_000_000_000, fractionDigits: 1...1)) Gb/s")
    }
    if bits >= 1_000_000 {
      return String(
        localized: "\(LocalizedFormat.number(bits / 1_000_000, fractionDigits: 1...1)) Mb/s")
    }
    if bits >= 1_000 {
      return String(
        localized: "\(LocalizedFormat.number(bits / 1_000, fractionDigits: 0...0)) Kb/s")
    }
    return String(localized: "\(LocalizedFormat.number(bits, fractionDigits: 0...0)) b/s")
  }
}

private struct ProcessAttributionView: View {
  @ObservedObject var monitor: ProcessAttributionMonitor
  @State private var selectedMetric: ProcessMetricKind?

  private var snapshot: ProcessAttributionSnapshot? {
    if let selectedMetric, let selected = monitor.snapshots[selectedMetric] { return selected }
    if let latestMetric = monitor.latestMetric { return monitor.snapshots[latestMetric] }
    return nil
  }

  private var availableMetrics: [ProcessMetricKind] {
    ProcessMetricKind.allCases.filter { monitor.snapshots[$0] != nil }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      if !monitor.measuringMetrics.isEmpty {
        Text("Measuring top processes for one second…")
          .font(.system(size: 10))
          .foregroundStyle(.secondary)
      } else if let snapshot {
        HStack(spacing: 5) {
          Text("Top processes")
            .font(.system(size: 10, weight: .semibold))
          ForEach(availableMetrics, id: \.self) { metric in
            Button(metric.displayName) { selectedMetric = metric }
              .buttonStyle(.plain)
              .font(.system(size: 9, weight: snapshot.metric == metric ? .semibold : .regular))
              .foregroundStyle(snapshot.metric == metric ? .primary : .secondary)
          }
          Spacer(minLength: 0)
          Text("1 s estimate")
            .font(.system(size: 9))
            .foregroundStyle(.secondary)
          Text(snapshot.capturedAt, style: .relative)
            .font(.system(size: 9))
            .foregroundStyle(.secondary)
          if case .partial = snapshot.availability {
            Text("partial")
              .font(.system(size: 9))
              .foregroundStyle(.yellow)
              .help(availabilityHelp(snapshot.availability))
          }
          Button("Activity Monitor") { ActivityMonitorOpener.open() }
            .buttonStyle(.plain)
            .font(.system(size: 9, weight: .medium))
            .appThemeForeground(.system)
        }
        if snapshot.entries.isEmpty {
          Text(emptyMessage(snapshot))
            .font(.system(size: 9))
            .foregroundStyle(.secondary)
            .lineLimit(2)
        } else {
          HStack(spacing: 6) {
            ForEach(snapshot.entries) { entry in
              process(entry, metric: snapshot.metric)
            }
          }
          .help(availabilityHelp(snapshot.availability))
        }
      } else {
        Text("Process snapshots start after a threshold is crossed while this view is open.")
          .font(.system(size: 9))
          .foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, minHeight: 34, alignment: .topLeading)
    .padding(.top, 2)
    .accessibilityElement(children: .contain)
  }

  private func process(_ entry: ProcessAttributionEntry, metric: ProcessMetricKind) -> some View {
    HStack(spacing: 4) {
      Image(nsImage: icon(for: entry))
        .resizable()
        .frame(width: 16, height: 16)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 0) {
        Text(entry.name)
          .font(.system(size: 9, weight: .medium))
          .lineLimit(1)
        Text(formatted(entry.value, metric: metric))
          .font(.system(size: 8))
          .monospacedDigit()
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(entry.name)
    .accessibilityValue(formatted(entry.value, metric: metric))
  }

  private func icon(for entry: ProcessAttributionEntry) -> NSImage {
    if let path = entry.applicationPath {
      return NSWorkspace.shared.icon(forFile: path)
    }
    return NSWorkspace.shared.icon(for: .applicationBundle)
  }

  private func formatted(_ value: Double, metric: ProcessMetricKind) -> String {
    switch metric {
    case .cpu:
      return "\(Int((value * 100).rounded()))% CPU"
    case .memory:
      return Int64(value).formatted(
        .byteCount(style: .memory, allowedUnits: [.mb, .gb], spellsOutZero: false))
    case .disk:
      let bytes = Int64(value).formatted(
        .byteCount(style: .file, allowedUnits: [.kb, .mb, .gb], spellsOutZero: false))
      return "\(bytes)/s"
    case .network:
      return "Unavailable"
    }
  }

  private func emptyMessage(_ snapshot: ProcessAttributionSnapshot) -> String {
    switch snapshot.availability {
    case .unsupported(let message): return message
    case .noReadableProcesses: return "No process data was readable during this snapshot."
    case .partial:
      return "No active process had a measurable value. Some process data was unavailable."
    case .available: return "No active process had a measurable value in this one-second window."
    }
  }

  private func availabilityHelp(_ availability: ProcessAttributionAvailability) -> String {
    switch availability {
    case .available:
      return "Values are one-second estimates from macOS process counters."
    case .partial(let unreadable, let exited):
      return
        "Values are one-second estimates. \(unreadable) processes could not be read and \(exited) exited during the snapshot."
    case .noReadableProcesses:
      return "macOS did not return readable process counters."
    case .unsupported(let message):
      return message
    }
  }
}

/// The bar half of `.numberAndBar`.
private struct MetricBar: View {
  let fraction: Double
  @Environment(\.appTheme) private var appTheme

  var body: some View {
    GeometryReader { geometry in
      ZStack(alignment: .leading) {
        Capsule().fill(.white.opacity(0.12))
        Capsule().fill(appTheme.color(for: .system).opacity(0.85))
          .frame(width: geometry.size.width * min(max(fraction, 0), 1))
      }
    }
    .frame(width: 40, height: 5)
    .accessibilityHidden(true)
  }
}
