import AppKit
import Darwin
import Defaults
import Foundation

enum ProcessMetricKind: String, CaseIterable, Sendable {
  case cpu
  case memory
  case disk
  case network

  var displayName: String {
    switch self {
    case .cpu: "CPU"
    case .memory: "Memory"
    case .disk: "Disk"
    case .network: "Network"
    }
  }
}

struct ProcessAttributionThresholds: Equatable, Sendable {
  let cpuFraction: Double
  let memoryFraction: Double
  let diskBytesPerSecond: Double
  let networkBytesPerSecond: Double

  static var current: Self {
    Self(
      cpuFraction: Defaults[.processCPUThreshold],
      memoryFraction: Defaults[.processMemoryThreshold],
      diskBytesPerSecond: Defaults[.processDiskThresholdMBPerSecond] * 1_000_000,
      networkBytesPerSecond: Defaults[.processNetworkThresholdMBPerSecond] * 1_000_000)
  }

  func value(for kind: ProcessMetricKind, in sample: SystemMetricsSample) -> Double? {
    switch kind {
    case .cpu:
      return sample.cpuTotal
    case .memory:
      guard let used = sample.memoryUsedBytes, let total = sample.memoryTotalBytes, total > 0 else {
        return nil
      }
      return Double(used) / Double(total)
    case .disk:
      guard let read = sample.diskReadBytesPerSec, let write = sample.diskWriteBytesPerSec else {
        return nil
      }
      return read + write
    case .network:
      guard let received = sample.netInBytesPerSec, let sent = sample.netOutBytesPerSec else {
        return nil
      }
      return received + sent
    }
  }

  func threshold(for kind: ProcessMetricKind) -> Double {
    switch kind {
    case .cpu: cpuFraction
    case .memory: memoryFraction
    case .disk: diskBytesPerSecond
    case .network: networkBytesPerSecond
    }
  }
}

/// Detects a rising threshold edge. Reset it whenever the System view disappears so hidden samples
/// cannot arm process enumeration, and reopening onto an existing spike gets one bounded snapshot.
struct ProcessAttributionTrigger: Equatable, Sendable {
  private var aboveThreshold: [ProcessMetricKind: Bool] = [:]

  mutating func observe(
    _ sample: SystemMetricsSample, thresholds: ProcessAttributionThresholds
  ) -> Set<ProcessMetricKind> {
    var crossings: Set<ProcessMetricKind> = []
    for kind in ProcessMetricKind.allCases {
      guard let value = thresholds.value(for: kind, in: sample), value.isFinite else { continue }
      let isAbove = value >= thresholds.threshold(for: kind)
      if isAbove, aboveThreshold[kind] != true { crossings.insert(kind) }
      aboveThreshold[kind] = isAbove
    }
    return crossings
  }

  mutating func reset() {
    aboveThreshold.removeAll(keepingCapacity: true)
  }
}

struct ProcessUsage: Equatable, Sendable {
  let pid: pid_t
  let startTime: UInt64
  let name: String
  let applicationPath: String?
  let cpuNanoseconds: UInt64
  let residentBytes: UInt64
  let diskBytes: UInt64
}

struct ProcessUsageCapture: Equatable, Sendable {
  let capturedAt: TimeInterval
  let processes: [pid_t: ProcessUsage]
  let listedCount: Int
  let unreadableCount: Int
}

struct ProcessAttributionEntry: Equatable, Identifiable, Sendable {
  let pid: pid_t
  let name: String
  let applicationPath: String?
  let value: Double

  var id: pid_t { pid }
}

enum ProcessAttributionAvailability: Equatable, Sendable {
  case available
  case partial(unreadableCount: Int, exitedCount: Int)
  case noReadableProcesses
  case unsupported(String)
}

struct ProcessAttributionSnapshot: Equatable, Sendable {
  let metric: ProcessMetricKind
  let entries: [ProcessAttributionEntry]
  let availability: ProcessAttributionAvailability
  let capturedAt: Date
}

enum ProcessAttributionMath {
  static let maximumEntries = 3

  static func snapshots(
    for metrics: Set<ProcessMetricKind>, baseline: ProcessUsageCapture,
    final: ProcessUsageCapture, capturedAt: Date
  ) -> [ProcessMetricKind: ProcessAttributionSnapshot] {
    var result: [ProcessMetricKind: ProcessAttributionSnapshot] = [:]
    let elapsed = final.capturedAt - baseline.capturedAt
    let exitedCount = baseline.processes.keys.filter { final.processes[$0] == nil }.count
    let unreadableCount = max(baseline.unreadableCount, final.unreadableCount)

    for metric in metrics {
      if metric == .network {
        result[metric] = ProcessAttributionSnapshot(
          metric: metric, entries: [],
          availability: .unsupported(
            "macOS does not provide reliable per-process network totals to Islet."),
          capturedAt: capturedAt)
        continue
      }

      var entries: [ProcessAttributionEntry] = []
      for process in final.processes.values {
        let value: Double?
        switch metric {
        case .cpu:
          guard elapsed > 0, let old = matchingBaseline(for: process, in: baseline) else {
            continue
          }
          guard let delta = monotonicDelta(from: old.cpuNanoseconds, to: process.cpuNanoseconds)
          else { continue }
          value = Double(delta) / 1_000_000_000 / elapsed
        case .memory:
          value = Double(process.residentBytes)
        case .disk:
          guard elapsed > 0, let old = matchingBaseline(for: process, in: baseline) else {
            continue
          }
          guard let delta = monotonicDelta(from: old.diskBytes, to: process.diskBytes) else {
            continue
          }
          value = Double(delta) / elapsed
        case .network:
          value = nil
        }
        guard let value, value.isFinite, value > 0 else { continue }
        entries.append(
          ProcessAttributionEntry(
            pid: process.pid, name: process.name, applicationPath: process.applicationPath,
            value: value))
      }
      entries.sort {
        if $0.value != $1.value { return $0.value > $1.value }
        return $0.pid < $1.pid
      }
      if entries.count > maximumEntries {
        entries.removeSubrange(maximumEntries...)
      }

      let availability: ProcessAttributionAvailability
      if final.processes.isEmpty {
        availability = .noReadableProcesses
      } else if unreadableCount > 0 || exitedCount > 0 {
        availability = .partial(unreadableCount: unreadableCount, exitedCount: exitedCount)
      } else {
        availability = .available
      }
      result[metric] = ProcessAttributionSnapshot(
        metric: metric, entries: entries, availability: availability, capturedAt: capturedAt)
    }
    return result
  }

  private static func matchingBaseline(
    for process: ProcessUsage, in capture: ProcessUsageCapture
  ) -> ProcessUsage? {
    guard let old = capture.processes[process.pid], old.startTime == process.startTime else {
      return nil
    }
    return old
  }

  private static func monotonicDelta(from old: UInt64, to new: UInt64) -> UInt64? {
    guard new >= old else { return nil }
    return new - old
  }
}

enum ProcessUsageReader {
  static func capture(uptime: TimeInterval = ProcessInfo.processInfo.systemUptime)
    -> ProcessUsageCapture
  {
    let count = proc_listallpids(nil, 0)
    guard count > 0 else {
      return ProcessUsageCapture(
        capturedAt: uptime, processes: [:], listedCount: 0, unreadableCount: 0)
    }
    // Leave room for processes created between the sizing call and the real read.
    var pids = [pid_t](repeating: 0, count: Int(count) + 32)
    let bytes = pids.count * MemoryLayout<pid_t>.stride
    let readCount = pids.withUnsafeMutableBytes { buffer in
      proc_listallpids(buffer.baseAddress, Int32(bytes))
    }
    guard readCount > 0 else {
      return ProcessUsageCapture(
        capturedAt: uptime, processes: [:], listedCount: 0, unreadableCount: 0)
    }

    var processes: [pid_t: ProcessUsage] = [:]
    var unreadable = 0
    for pid in pids.prefix(Int(readCount)) where pid > 0 {
      guard let usage = usage(for: pid) else {
        unreadable += 1
        continue
      }
      processes[pid] = usage
    }
    return ProcessUsageCapture(
      capturedAt: uptime, processes: processes, listedCount: Int(readCount),
      unreadableCount: unreadable)
  }

  private static func usage(for pid: pid_t) -> ProcessUsage? {
    var info = rusage_info_v4()
    let result = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
        proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
      }
    }
    guard result == 0 else { return nil }

    let path = processPath(pid)
    return ProcessUsage(
      pid: pid, startTime: info.ri_proc_start_abstime,
      name: processName(pid, path: path), applicationPath: enclosingApplication(path),
      cpuNanoseconds: info.ri_user_time &+ info.ri_system_time,
      residentBytes: info.ri_resident_size,
      diskBytes: info.ri_diskio_bytesread &+ info.ri_diskio_byteswritten)
  }

  private static func processName(_ pid: pid_t, path: String?) -> String {
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    let length = proc_name(pid, &buffer, UInt32(buffer.count))
    if length > 0 {
      return String(
        decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
    if let path { return URL(fileURLWithPath: path).lastPathComponent }
    return "Process \(pid)"
  }

  private static func processPath(_ pid: pid_t) -> String? {
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
    let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
    guard length > 0 else { return nil }
    return String(
      decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
  }

  private static func enclosingApplication(_ path: String?) -> String? {
    guard let path else { return nil }
    let components = URL(fileURLWithPath: path).pathComponents
    guard let index = components.lastIndex(where: { $0.hasSuffix(".app") }) else { return nil }
    return NSString.path(withComponents: Array(components[...index]))
  }
}

@MainActor
final class ProcessAttributionMonitor: ObservableObject {
  static let sampleWindow: TimeInterval = 1

  typealias UsageCapture = @Sendable () async -> ProcessUsageCapture
  typealias SampleDelay = @Sendable () async throws -> Void

  @Published private(set) var snapshots: [ProcessMetricKind: ProcessAttributionSnapshot] = [:]
  @Published private(set) var measuringMetrics: Set<ProcessMetricKind> = []
  @Published private(set) var latestMetric: ProcessMetricKind?

  private var trigger = ProcessAttributionTrigger()
  private var sampleTask: Task<Void, Never>?
  private var isVisible = false
  private let usageCapture: UsageCapture
  private let sampleDelay: SampleDelay

  init(
    usageCapture: @escaping UsageCapture = {
      await Task.detached(priority: .utility) { ProcessUsageReader.capture() }.value
    },
    sampleDelay: @escaping SampleDelay = {
      try await Task.sleep(for: .seconds(ProcessAttributionMonitor.sampleWindow))
    }
  ) {
    self.usageCapture = usageCapture
    self.sampleDelay = sampleDelay
  }

  deinit {
    sampleTask?.cancel()
  }

  func setVisible(_ visible: Bool) {
    guard visible != isVisible else { return }
    isVisible = visible
    if !visible {
      sampleTask?.cancel()
      sampleTask = nil
      measuringMetrics = []
      trigger.reset()
    }
  }

  func stop() {
    isVisible = false
    sampleTask?.cancel()
    sampleTask = nil
    measuringMetrics = []
    trigger.reset()
    snapshots = [:]
    latestMetric = nil
  }

  func observe(_ sample: SystemMetricsSample) {
    guard isVisible else { return }
    guard Defaults[.processAttributionEnabled] else {
      sampleTask?.cancel()
      sampleTask = nil
      measuringMetrics = []
      trigger.reset()
      return
    }
    let crossings = trigger.observe(sample, thresholds: .current)
    guard !crossings.isEmpty else { return }

    let unsupported = crossings.intersection([.network])
    if !unsupported.isEmpty {
      snapshots.merge(
        ProcessAttributionMath.snapshots(
          for: unsupported,
          baseline: ProcessUsageCapture(
            capturedAt: 0, processes: [:], listedCount: 0, unreadableCount: 0),
          final: ProcessUsageCapture(
            capturedAt: 0, processes: [:], listedCount: 0, unreadableCount: 0),
          capturedAt: Date())
      ) { _, new in new }
      latestMetric = .network
    }

    let supported = crossings.subtracting(unsupported)
    guard !supported.isEmpty else { return }
    measuringMetrics.formUnion(supported)
    guard sampleTask == nil else { return }
    let usageCapture = usageCapture
    let sampleDelay = sampleDelay
    sampleTask = Task { [weak self] in
      guard !Task.isCancelled, self?.isVisible == true else { return }
      let baseline = await usageCapture()
      guard !Task.isCancelled, self?.isVisible == true else { return }
      do {
        try await sampleDelay()
      } catch {
        return
      }
      guard !Task.isCancelled, self?.isVisible == true else { return }
      let final = await usageCapture()
      guard !Task.isCancelled, let self, self.isVisible else { return }
      let measured = self.measuringMetrics
      self.snapshots.merge(
        ProcessAttributionMath.snapshots(
          for: measured, baseline: baseline, final: final, capturedAt: Date())
      ) { _, new in new }
      self.latestMetric = ProcessMetricKind.allCases.first(where: measured.contains)
      self.measuringMetrics = []
      self.sampleTask = nil
    }
  }
}

enum ActivityMonitorOpener {
  @MainActor
  static func open() {
    let workspace = NSWorkspace.shared
    if let running = workspace.runningApplications.first(where: {
      $0.bundleIdentifier == "com.apple.ActivityMonitor"
    }) {
      running.activate()
      return
    }
    guard let url = workspace.urlForApplication(withBundleIdentifier: "com.apple.ActivityMonitor")
    else { return }
    workspace.openApplication(at: url, configuration: .init())
  }
}
