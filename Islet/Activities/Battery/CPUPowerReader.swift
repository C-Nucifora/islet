import Darwin
import Foundation

/// Converts an IOReport energy delta into average power. Energy Model's simple counters are
/// millijoules, so mJ / seconds / 1,000 is watts.
enum CPUPowerMath {
  static func watts(millijoules: Int, elapsedSeconds: TimeInterval) -> Double? {
    guard millijoules >= 0, elapsedSeconds > 0 else { return nil }
    let watts = Double(millijoules) / elapsedSeconds / 1000
    return watts.isFinite ? watts : nil
  }
}

/// The state of the last valid IOReport sample. A stale value remains useful as context, but callers
/// can distinguish it from a value collected inside the current freshness window.
enum CPUPowerReading: Equatable, Sendable {
  case fresh(watts: Double)
  case stale(watts: Double)
  case unavailable

  var freshWatts: Double? {
    guard case .fresh(let watts) = self else { return nil }
    return watts
  }
}

/// A lock-backed cache lets the synchronous battery registry reader use the sampler's last value
/// without hopping to the main actor or waiting for a new 250 ms IOReport window.
final class CPUPowerReadingStore: @unchecked Sendable {
  static let shared = CPUPowerReadingStore(
    now: { ProcessInfo.processInfo.systemUptime },
    staleAfter: CPUPowerSamplingService.normalStaleAfter)

  private struct Sample {
    let watts: Double
    let instant: TimeInterval
  }

  private let lock = NSLock()
  private let now: @Sendable () -> TimeInterval
  private var latest: Sample?
  private var staleAfter: TimeInterval

  init(now: @escaping @Sendable () -> TimeInterval, staleAfter: TimeInterval) {
    self.now = now
    self.staleAfter = staleAfter
  }

  func record(watts: Double, at instant: TimeInterval) {
    guard watts.isFinite, watts >= 0, instant.isFinite else { return }
    lock.withLock { latest = Sample(watts: watts, instant: instant) }
  }

  func setStaleAfter(_ interval: TimeInterval) {
    guard interval.isFinite, interval > 0 else { return }
    lock.withLock { staleAfter = interval }
  }

  func reading() -> CPUPowerReading {
    lock.withLock {
      guard let latest else { return .unavailable }
      let age = max(now() - latest.instant, 0)
      return age <= staleAfter ? .fresh(watts: latest.watts) : .stale(watts: latest.watts)
    }
  }
}

enum CPUPowerConsumer: Hashable, Sendable {
  case battery
  case system
}

struct CPUPowerSamplingDependencies: Sendable {
  let now: @Sendable () -> TimeInterval
  let sleep: @Sendable (TimeInterval) async throws -> Void
  let sample: @Sendable () async -> Double?

  static let live = CPUPowerSamplingDependencies(
    now: { ProcessInfo.processInfo.systemUptime },
    sleep: { interval in
      let nanoseconds = UInt64(max(interval, 0) * 1_000_000_000)
      try await Task.sleep(nanoseconds: nanoseconds)
    },
    sample: { await CPUPowerReader.shared.readWatts() })
}

/// Owns the one process-wide CPU-power stream. Battery and System register only while their views
/// need the reading. The service stops with no clients, uses a slower cadence under constrained
/// power policy, and never starts a replacement loop until a cancelled sample has returned.
@MainActor
final class CPUPowerSamplingService {
  static let shared = CPUPowerSamplingService()

  nonisolated static let normalInterval: TimeInterval = 1
  nonisolated static let constrainedInterval: TimeInterval = 30
  nonisolated static let normalStaleAfter: TimeInterval = 5
  nonisolated static let constrainedStaleAfter: TimeInterval = 60

  private enum Phase {
    case idle
    case sampling
    case sleeping
  }

  private let dependencies: CPUPowerSamplingDependencies
  private let store: CPUPowerReadingStore
  private var demands: [CPUPowerConsumer: TimeInterval] = [:]
  private var constrained = false
  private var phase = Phase.idle
  private var loopTask: Task<Void, Never>?

  init(
    dependencies: CPUPowerSamplingDependencies = .live,
    store: CPUPowerReadingStore = .shared
  ) {
    self.dependencies = dependencies
    self.store = store
  }

  func setDemand(_ interval: TimeInterval?, for consumer: CPUPowerConsumer) {
    let previousInterval = samplingInterval
    if let interval, interval.isFinite, interval > 0 {
      demands[consumer] = interval
    } else {
      demands.removeValue(forKey: consumer)
    }
    updateFreshnessWindow()
    reconcileLoop(restartSleepingLoop: samplingInterval != previousInterval)
  }

  func setConstrained(_ constrained: Bool) {
    guard constrained != self.constrained else { return }
    self.constrained = constrained
    updateFreshnessWindow()
    reconcileLoop(restartSleepingLoop: true)
  }

  nonisolated func cachedReading() -> CPUPowerReading {
    store.reading()
  }

  private func reconcileLoop(restartSleepingLoop: Bool) {
    guard !demands.isEmpty else {
      loopTask?.cancel()
      return
    }
    guard loopTask != nil else {
      startLoop()
      return
    }
    if restartSleepingLoop, phase == .sleeping {
      loopTask?.cancel()
    }
  }

  private func startLoop() {
    guard loopTask == nil, !demands.isEmpty else { return }
    loopTask = Task { [weak self] in
      await self?.runLoop()
    }
  }

  private func runLoop() async {
    while !Task.isCancelled, !demands.isEmpty {
      phase = .sampling
      let sampleStarted = dependencies.now()
      let watts = await dependencies.sample()
      guard !Task.isCancelled, !demands.isEmpty else { break }
      if let watts, watts.isFinite, watts >= 0 {
        store.record(watts: watts, at: dependencies.now())
      }

      phase = .sleeping
      do {
        let interval = samplingInterval ?? Self.normalInterval
        let measuredElapsed = dependencies.now() - sampleStarted
        let elapsed = measuredElapsed.isFinite ? max(measuredElapsed, 0) : 0
        try await dependencies.sleep(max(interval - elapsed, 0))
      } catch {
        break
      }
    }

    phase = .idle
    loopTask = nil
    if !demands.isEmpty { startLoop() }
  }

  private var samplingInterval: TimeInterval? {
    guard let requested = demands.values.min() else { return nil }
    return constrained ? max(requested, Self.constrainedInterval) : requested
  }

  private func updateFreshnessWindow() {
    let baseline = constrained ? Self.constrainedStaleAfter : Self.normalStaleAfter
    let cadenceWindow = samplingInterval.map { $0 * 2 } ?? 0
    store.setStaleAfter(max(baseline, cadenceWindow))
  }
}

/// Reads Apple's estimated aggregate CPU energy on Apple Silicon without invoking the root-only
/// `powermetrics` process.
///
/// IOReport is private and its channels differ between chips, so every lookup is dynamic and every
/// result is optional. Failure simply leaves the existing whole-Mac branch intact. The subscription
/// is retained for this process's lifetime. The shared sampling service is its only normal caller,
/// and the reader also rejects an overlapping request because IOReport subscriptions are stateful.
actor CPUPowerReader {
  static let shared = CPUPowerReader()

  private static let sampleDuration: TimeInterval = 0.25

  private let library: IOReportLibrary?
  private let subscription: UnsafeRawPointer?
  private let subscribedChannels: CFMutableDictionary?
  private var isSampling = false

  private init() {
    guard let library = IOReportLibrary() else {
      self.library = nil
      subscription = nil
      subscribedChannels = nil
      return
    }

    guard
      let desired = library.copyChannelsInGroup(
        "Energy Model" as CFString, nil, 0, 0, 0)?.takeRetainedValue()
    else {
      self.library = library
      subscription = nil
      subscribedChannels = nil
      return
    }

    var unmanagedChannels: Unmanaged<CFMutableDictionary>?
    let subscription = library.createSubscription(
      nil, desired, &unmanagedChannels, 0, nil)

    self.library = library
    self.subscription = subscription
    subscribedChannels = unmanagedChannels?.takeRetainedValue()
  }

  /// Average CPU watts over a short window. The cancellable suspension lets the sampling service
  /// stop before collecting the second half of a sample when the last view disappears.
  func readWatts() async -> Double? {
    guard !isSampling else { return nil }
    isSampling = true
    defer { isSampling = false }

    guard let library, let subscription, let subscribedChannels,
      let first = library.createSamples(subscription, subscribedChannels, nil)?.takeRetainedValue()
    else { return nil }

    let started = DispatchTime.now().uptimeNanoseconds
    do {
      try await Task.sleep(nanoseconds: UInt64(Self.sampleDuration * 1_000_000_000))
    } catch {
      return nil
    }
    guard
      let second = library.createSamples(subscription, subscribedChannels, nil)?.takeRetainedValue()
    else { return nil }
    let finished = DispatchTime.now().uptimeNanoseconds
    let elapsed = Double(finished - started) / 1_000_000_000

    guard
      let delta = library.createSamplesDelta(first, second, nil)?.takeRetainedValue(),
      let millijoules = cpuEnergyMillijoules(in: delta, using: library)
    else { return nil }
    return CPUPowerMath.watts(millijoules: millijoules, elapsedSeconds: elapsed)
  }

  /// Newer Apple Silicon publishes one `CPU Energy` total. The exact ECPU/PCPU totals are used
  /// only as a fallback for a chip that omits that aggregate; per-core, SRAM and fabric siblings
  /// are deliberately ignored because summing them would count the same CPU work twice.
  private func cpuEnergyMillijoules(
    in samples: CFDictionary, using library: IOReportLibrary
  ) -> Int? {
    let dictionary = samples as NSDictionary
    guard
      let channels = dictionary["IOReportChannels"] as? [NSDictionary]
    else { return nil }

    var efficiencyCluster: Int?
    var performanceCluster: Int?
    for channel in channels {
      guard
        let legend = channel["LegendChannel"] as? [Any], legend.count >= 3,
        let name = legend[2] as? String
      else { continue }

      let sample = unsafeBitCast(channel, to: CFDictionary.self)
      let value = library.simpleGetIntegerValue(sample, 0)
      guard value >= 0 else { continue }

      if matchesUnit(name, "CPU Energy") { return value }
      if matchesUnit(name, "ECPU") { efficiencyCluster = value }
      if matchesUnit(name, "PCPU") { performanceCluster = value }
    }
    guard let efficiencyCluster, let performanceCluster else { return nil }
    return efficiencyCluster + performanceCluster
  }

  private func matchesUnit(_ name: String, _ unit: String) -> Bool {
    name == unit || name.hasSuffix(" \(unit)")
  }
}

/// Runtime bindings keep the private library out of Islet's link contract. A macOS update can
/// remove any symbol without preventing the app from launching; the CPU split then disappears.
private final class IOReportLibrary: @unchecked Sendable {
  typealias CopyChannelsInGroup =
    @convention(c) (CFString, CFString?, UInt64, UInt64, UInt64) ->
    Unmanaged<CFMutableDictionary>?
  typealias CreateSubscription =
    @convention(c) (
      UnsafeMutableRawPointer?, CFMutableDictionary,
      UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>, UInt64, UnsafeRawPointer?
    ) -> UnsafeRawPointer?
  typealias CreateSamples =
    @convention(c) (UnsafeRawPointer, CFMutableDictionary, UnsafeRawPointer?) ->
    Unmanaged<CFDictionary>?
  typealias CreateSamplesDelta =
    @convention(c) (CFDictionary, CFDictionary, UnsafeRawPointer?) -> Unmanaged<CFDictionary>?
  typealias SimpleGetIntegerValue = @convention(c) (CFDictionary, Int32) -> Int

  private let handle: UnsafeMutableRawPointer
  let copyChannelsInGroup: CopyChannelsInGroup
  let createSubscription: CreateSubscription
  let createSamples: CreateSamples
  let createSamplesDelta: CreateSamplesDelta
  let simpleGetIntegerValue: SimpleGetIntegerValue

  init?() {
    guard let libraryHandle = dlopen("/usr/lib/libIOReport.dylib", RTLD_LAZY | RTLD_LOCAL) else {
      return nil
    }
    guard
      let copyChannelsInGroup: CopyChannelsInGroup = Self.symbol(
        "IOReportCopyChannelsInGroup", in: libraryHandle),
      let createSubscription: CreateSubscription = Self.symbol(
        "IOReportCreateSubscription", in: libraryHandle),
      let createSamples: CreateSamples = Self.symbol("IOReportCreateSamples", in: libraryHandle),
      let createSamplesDelta: CreateSamplesDelta = Self.symbol(
        "IOReportCreateSamplesDelta", in: libraryHandle),
      let simpleGetIntegerValue: SimpleGetIntegerValue = Self.symbol(
        "IOReportSimpleGetIntegerValue", in: libraryHandle)
    else {
      dlclose(libraryHandle)
      return nil
    }

    self.handle = libraryHandle
    self.copyChannelsInGroup = copyChannelsInGroup
    self.createSubscription = createSubscription
    self.createSamples = createSamples
    self.createSamplesDelta = createSamplesDelta
    self.simpleGetIntegerValue = simpleGetIntegerValue
  }

  deinit { dlclose(handle) }

  private static func symbol<T>(_ name: String, in handle: UnsafeMutableRawPointer) -> T? {
    guard let pointer = dlsym(handle, name) else { return nil }
    return unsafeBitCast(pointer, to: T.self)
  }
}
