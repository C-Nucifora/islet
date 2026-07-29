import Combine
import Foundation

/// Samples every system source and publishes a snapshot plus a 60-entry history per series.
///
/// Cadence follows the Phase 1.4 refcounted gate: 1 Hz while the System tab is on screen, 5 s
/// otherwise. It never stops, because the ring has to outlive the view — opening the tab to an
/// empty sparkline would defeat the point of having one.
@MainActor
final class SystemMetricsMonitor: ObservableObject {
  static let shared = SystemMetricsMonitor()

  static let ringCapacity = 60

  @Published private(set) var sample = SystemMetricsSample()
  @Published private(set) var rings: [SystemMetricKind: MetricRing] = [:]

  /// Retained by `SystemExpandedView` via `.liveSampling(_:)`.
  private(set) lazy var liveGate = LiveSamplingGate { [weak self] live in
    // The gate is @MainActor and only ever calls this from the main actor.
    MainActor.assumeIsolated { self?.setLive(live) }
  }

  private var timer: AnyCancellable?
  private var previous: RawCounters?
  private var previousDate: Date?
  private var clusters: [CPUCluster] = []
  private var isLive = false
  private var isSampling = false

  func start() {
    clusters = CPUTopology.current()
    restartTimer()
    tick()
  }

  private func setLive(_ live: Bool) {
    guard live != isLive else { return }
    isLive = live
    restartTimer()
    tick()  // don't make the user wait a whole interval for the first fast sample
  }

  private func restartTimer() {
    let interval = isLive ? 1.0 : 5.0
    timer = Timer.publish(every: interval, on: .main, in: .common).autoconnect()
      .sink { [weak self] _ in self?.tick() }
  }

  private func tick() {
    guard !isSampling else { return }
    isSampling = true
    Task { [weak self] in
      await self?.sampleOnce()
      self?.isSampling = false
    }
  }

  private func sampleOnce() async {
    // ~0.10 ms of kernel calls. Off the main thread anyway: it runs during island animations.
    let raw = await Task.detached(priority: .utility) { RawCounters.read() }.value
    let now = Date()
    let next = systemMetricsSample(
      previous: previous, previousDate: previousDate, current: raw, currentDate: now,
      clusters: clusters)
    previous = raw
    previousDate = now
    sample = next
    pushRings(next)
  }

  private func pushRings(_ sample: SystemMetricsSample) {
    push(.cpu, sample.cpuTotal)
    push(.gpu, sample.gpu)
    if let used = sample.memoryUsedBytes, let total = sample.memoryTotalBytes, total > 0 {
      push(.memory, Double(used) / Double(total))
    }
    // Disk and network each have two directions but one series: the sparkline shows total
    // activity, and the numbers beside it already break out the directions.
    if let read = sample.diskReadBytesPerSec, let write = sample.diskWriteBytesPerSec {
      push(.disk, read + write)
    }
    if let inbound = sample.netInBytesPerSec, let outbound = sample.netOutBytesPerSec {
      push(.network, inbound + outbound)
    }
  }

  private func push(_ kind: SystemMetricKind, _ value: Double?) {
    guard let value else { return }
    var ring = rings[kind] ?? MetricRing(capacity: Self.ringCapacity)
    ring.push(value)
    rings[kind] = ring
  }
}
