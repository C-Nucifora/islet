import Foundation

/// The six series the System tab can render. Raw values are the keys of `Defaults[.metricStyles]`.
enum SystemMetricKind: String, CaseIterable, Codable {
  case cpu, gpu, memory, disk, network, thermal
}

extension SystemMetricKind {
  var displayName: String {
    switch self {
    case .cpu: String(localized: "CPU")
    case .gpu: String(localized: "GPU")
    case .memory: String(localized: "Memory")
    case .disk: String(localized: "Disk")
    case .network: String(localized: "Network")
    case .thermal: String(localized: "Thermal")
    }
  }
}

/// How one metric is drawn. Configurable per metric in Settings.
enum MetricDisplayStyle: String, CaseIterable, Codable {
  case number  // 38%
  case numberAndBar  // 38%  ▓▓▓▓░░░░░░
  case sparkline  //      ▁▂▅▃▂▁▄█▅▃
  case sparklineAndNumber  // 38%  ▁▂▅▃▂▁▄█▅▃
  case combined  // 38%  ▁▂▅▃▂▁▄█▅▃  P 44%  E 18%  load 3.51
}

extension MetricDisplayStyle {
  /// Used when the stored string is missing or no longer a known case.
  static let fallback: MetricDisplayStyle = .sparklineAndNumber

  var displayName: String {
    switch self {
    case .number: String(localized: "Number")
    case .numberAndBar: String(localized: "Number + bar")
    case .sparkline: String(localized: "Sparkline")
    case .sparklineAndNumber: String(localized: "Number + sparkline")
    case .combined: String(localized: "Everything")
    }
  }

  /// True when the style reads the monitor's ring buffer. `.number` and `.numberAndBar` are the
  /// cheap path and need no history at all.
  var needsHistory: Bool {
    switch self {
    case .number, .numberAndBar: false
    case .sparkline, .sparklineAndNumber, .combined: true
    }
  }

  static func resolve(_ raw: String?) -> MetricDisplayStyle {
    guard let raw, let style = MetricDisplayStyle(rawValue: raw) else { return fallback }
    return style
  }

  /// Thermal state is a four-value enum, not a series, so the sparkline-only styles collapse to
  /// `.number` for it. `.combined` survives because its extra detail (the battery temperature) is
  /// the whole point of the thermal row.
  static func effective(for kind: SystemMetricKind, requested: MetricDisplayStyle)
    -> MetricDisplayStyle
  {
    guard kind == .thermal else { return requested }
    switch requested {
    case .sparkline, .sparklineAndNumber: return .number
    case .number, .numberAndBar, .combined: return requested
    }
  }
}

/// One published snapshot. Every field is optional because every source can independently fail or
/// be unavailable, and rate fields are additionally nil on the first sample and after a gap.
struct SystemMetricsSample: Equatable, Sendable {
  var cpuTotal: Double?
  var cpuPerformance: Double?
  var cpuEfficiency: Double?
  var loadAverage: Double?
  var gpu: Double?
  var memoryUsedBytes: UInt64?
  var memoryTotalBytes: UInt64?
  var memoryWiredBytes: UInt64?
  var memoryCompressedBytes: UInt64?
  var memoryPressureLevel: Int?
  var swapUsedBytes: UInt64?
  var diskReadBytesPerSec: Double?
  var diskWriteBytesPerSec: Double?
  var diskFreeBytes: UInt64?
  var netInBytesPerSec: Double?
  var netOutBytesPerSec: Double?
  var primaryInterface: String?
  var thermalState: Int?  // ProcessInfo.ThermalState.rawValue
  var batteryTemperatureC: Double?
}
