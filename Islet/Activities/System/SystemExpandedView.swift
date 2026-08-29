import Defaults
import SwiftUI

/// The System tab's readout.
///
/// ```
/// CPU   38%  ▁▂▅▃▂▁▄█▅▃   P 44%  E 18%   load 3.51
/// GPU   12%  ▁▁▂▁▁▁▃▂▁▁
/// RAM   14.2 / 36 GB  ▃▃▄▄▄▅▅▅   wired 4.2   swap 12 MB
/// Disk  ↓ 1.2 MB/s  ↑ 340 KB/s   412 GB free
/// Net   ↓ 8.4 Mb/s  ↑ 1.1 Mb/s   en0
/// Therm nominal   31.2 °C
/// ```
///
/// The trailing detail on each row is shown only for `.combined` — that is what makes it the
/// "everything" style. Every other style shows the label, the value and nothing else.
struct SystemExpandedView: View {
  @ObservedObject var monitor: SystemMetricsMonitor
  @Default(.metricStyles) private var metricStyles

  private var sample: SystemMetricsSample { monitor.sample }

  private func style(_ kind: SystemMetricKind) -> MetricDisplayStyle {
    MetricDisplayStyle.effective(
      for: kind, requested: MetricDisplayStyle.resolve(metricStyles[kind.rawValue]))
  }

  private func ring(_ kind: SystemMetricKind) -> [Double] {
    monitor.rings[kind]?.values ?? []
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      cpuRow
      gpuRow
      memoryRow
      diskRow
      networkRow
      thermalRow
    }
    .foregroundStyle(.white)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    // 1 Hz while this view is on screen, 5 s once it leaves.
    .liveSampling(monitor.liveGate)
  }

  // MARK: - Rows

  private var cpuRow: some View {
    row(
      "CPU", kind: .cpu, fraction: sample.cpuTotal,
      text: percent(sample.cpuTotal), scale: .fixed(min: 0, max: 1)
    ) {
      HStack(spacing: 10) {
        if let performance = sample.cpuPerformance {
          detail("P \(percent(performance))")
        }
        if let efficiency = sample.cpuEfficiency {
          detail("E \(percent(efficiency))")
        }
        if let load = sample.loadAverage {
          detail(String(format: "load %.2f", load))
        }
      }
    }
  }

  private var gpuRow: some View {
    row(
      "GPU", kind: .gpu, fraction: sample.gpu,
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
      "RAM", kind: .memory, fraction: fraction, text: text, scale: .fixed(min: 0, max: 1)
    ) {
      HStack(spacing: 10) {
        if let wired = sample.memoryWiredBytes { detail("wired \(bytes(wired))") }
        if let swap = sample.swapUsedBytes { detail("swap \(bytes(swap))") }
      }
    }
  }

  private var diskRow: some View {
    let text: String = {
      guard let read = sample.diskReadBytesPerSec, let write = sample.diskWriteBytesPerSec
      else { return "—" }
      return "↓ \(bytesPerSecond(read))  ↑ \(bytesPerSecond(write))"
    }()
    return row("Disk", kind: .disk, fraction: nil, text: text, scale: .auto) {
      if let free = sample.diskFreeBytes { detail("\(bytes(free)) free") }
    }
  }

  private var networkRow: some View {
    let text: String = {
      guard let inbound = sample.netInBytesPerSec, let outbound = sample.netOutBytesPerSec
      else { return "—" }
      return "↓ \(bitsPerSecond(inbound))  ↑ \(bitsPerSecond(outbound))"
    }()
    return row("Net", kind: .network, fraction: nil, text: text, scale: .auto) {
      if let interface = sample.primaryInterface { detail(interface) }
    }
  }

  private var thermalRow: some View {
    row(
      "Therm", kind: .thermal, fraction: nil, text: thermalName(sample.thermalState),
      scale: .fixed(min: 0, max: 1)
    ) {
      if let temperature = sample.batteryTemperatureC {
        detail(String(format: "%.1f °C", temperature))
      }
    }
  }

  // MARK: - Row scaffold

  @ViewBuilder
  private func row<Detail: View>(
    _ label: String, kind: SystemMetricKind, fraction: Double?, text: String,
    scale: SparklineScale, @ViewBuilder detail: () -> Detail
  ) -> some View {
    let style = style(kind)
    HStack(spacing: 8) {
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
      if style.needsHistory, !ring(kind).isEmpty {
        SparklineView(values: ring(kind), scale: scale)
      }
      if style == .combined {
        detail()
      }
      Spacer(minLength: 0)
    }
    .frame(height: 24)
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
    return "\(Int((fraction * 100).rounded()))%"
  }

  /// `.byteCount` takes an `Int64`, not a `UInt64` — the conversion is required, not incidental.
  /// `spellsOutZero: false` keeps an idle disk reading "0 bytes" rather than "Zero kB".
  private func bytes(_ value: UInt64) -> String {
    Int64(value).formatted(
      .byteCount(style: .file, allowedUnits: [.kb, .mb, .gb, .tb], spellsOutZero: false))
  }

  private func bytesPerSecond(_ value: Double) -> String {
    "\(bytes(UInt64(max(value, 0))))/s"
  }

  /// Network is conventionally quoted in bits per second; disk in bytes per second.
  private func bitsPerSecond(_ bytesPerSec: Double) -> String {
    let bits = max(bytesPerSec, 0) * 8
    if bits >= 1_000_000_000 { return String(format: "%.1f Gb/s", bits / 1_000_000_000) }
    if bits >= 1_000_000 { return String(format: "%.1f Mb/s", bits / 1_000_000) }
    if bits >= 1_000 { return String(format: "%.0f Kb/s", bits / 1_000) }
    return String(format: "%.0f b/s", bits)
  }

  private func thermalName(_ raw: Int?) -> String {
    switch raw {
    case 0: "nominal"
    case 1: "fair"
    case 2: "serious"
    case 3: "critical"
    default: "—"
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
