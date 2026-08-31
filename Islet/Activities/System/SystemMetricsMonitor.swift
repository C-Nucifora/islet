import Combine
import Defaults
import Foundation

/// Samples every system source and publishes a snapshot plus a timestamped five-minute history.
///
/// Cadence follows the refcounted view gate: 1 Hz while the System tab is on screen and a much
/// slower history cadence otherwise. The owner stops it entirely when System is disabled.
@MainActor
final class SystemMetricsMonitor: ObservableObject {
  static let shared = SystemMetricsMonitor()

  nonisolated static let ringCapacity = SystemChartHistory.maximumRetainedSamples
  nonisolated static let liveInterval: TimeInterval = 1
  nonisolated static let backgroundInterval: TimeInterval = 20
  nonisolated static let lowPowerBackgroundInterval: TimeInterval = 30

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
  private var isRunning = false
  private var generation = 0
  private var powerCancellable: AnyCancellable?
  private var energyCancellable: AnyCancellable?
  private let now: () -> Date

  init(now: @escaping () -> Date = Date.init) {
    self.now = now
  }

  func start() {
    guard !isRunning else { return }
    isRunning = true
    generation += 1
    clusters = CPUTopology.current()
    powerCancellable = NotificationCenter.default.publisher(
      for: .NSProcessInfoPowerStateDidChange
    ).receive(on: DispatchQueue.main).sink { [weak self] _ in
      self?.energyPolicyDidChange()
    }
    energyCancellable = Defaults.publisher(.energyMode)
      .dropFirst()
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in self?.energyPolicyDidChange() }
    restartTimer()
    tick()
  }

  func stop() {
    guard isRunning else { return }
    isRunning = false
    generation += 1
    timer = nil
    powerCancellable = nil
    energyCancellable = nil
    previous = nil
    previousDate = nil
    isSampling = false
  }

  private func setLive(_ live: Bool) {
    guard live != isLive else { return }
    isLive = live
    guard isRunning else { return }
    restartTimer()
    tick()  // don't make the user wait a whole interval for the first fast sample
  }

  private func restartTimer() {
    guard isRunning else {
      timer = nil
      return
    }
    let interval = energyPolicy.systemInterval(viewIsLive: isLive)
    timer = Timer.publish(every: interval, on: .main, in: .common).autoconnect()
      .sink { [weak self] _ in self?.tick() }
  }

  private func tick() {
    guard isRunning, !isSampling else { return }
    isSampling = true
    let expectedGeneration = generation
    Task { [weak self] in
      await self?.sampleOnce(expectedGeneration: expectedGeneration)
    }
  }

  private func sampleOnce(expectedGeneration: Int) async {
    // ~0.10 ms of kernel calls. Off the main thread anyway: it runs during island animations.
    let raw = await Task.detached(priority: .utility) { RawCounters.read() }.value
    guard isRunning, generation == expectedGeneration else {
      return
    }
    let now = now()
    let next = systemMetricsSample(
      previous: previous, previousDate: previousDate, current: raw, currentDate: now,
      clusters: clusters)
    previous = raw
    previousDate = now
    sample = next
    pushRings(next, at: now)
    isSampling = false
  }

  private var energyPolicy: EnergyPolicy {
    EnergyPolicy(
      mode: Defaults[.energyMode],
      systemLowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled)
  }

  private func energyPolicyDidChange() {
    guard isRunning else { return }
    restartTimer()
    tick()
  }

  private func pushRings(_ sample: SystemMetricsSample, at timestamp: Date) {
    // Advance every established series before selecting values. Disk and network deliberately
    // have no rate after sleep, but their stale path must still disappear from the chart.
    for kind in Array(rings.keys) {
      rings[kind]?.advance(to: timestamp)
    }

    push(.cpu, sample.cpuTotal, at: timestamp)
    push(.gpu, sample.gpu, at: timestamp)
    if let used = sample.memoryUsedBytes, let total = sample.memoryTotalBytes, total > 0 {
      push(.memory, Double(used) / Double(total), at: timestamp)
    }
    // Disk and network each have two directions but one series: the sparkline shows total
    // activity, and the numbers beside it already break out the directions.
    if let read = sample.diskReadBytesPerSec, let write = sample.diskWriteBytesPerSec {
      push(.disk, read + write, at: timestamp)
    }
    if let inbound = sample.netInBytesPerSec, let outbound = sample.netOutBytesPerSec {
      push(.network, inbound + outbound, at: timestamp)
    }
  }

  private func push(_ kind: SystemMetricKind, _ value: Double?, at timestamp: Date) {
    guard let value else { return }
    var ring = rings[kind] ?? MetricRing(capacity: Self.ringCapacity)
    ring.push(value, at: timestamp)
    rings[kind] = ring
  }
}
