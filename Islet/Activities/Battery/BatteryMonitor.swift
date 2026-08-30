import Combine
import Defaults
import Foundation
import IOKit.ps

private struct BatteryReadSnapshot: Sendable {
  let state: BatteryState?
  let metrics: BatteryMetrics?
  let peripherals: [PeripheralBattery]?
  let cpuPowerReading: CPUPowerReading
}

/// Owns one power-source notification on one run loop. Registering in common modes keeps IOPS
/// callbacks flowing while AppKit switches the main loop into menu tracking or a modal mode.
final class PowerSourceRunLoopRegistration {
  private let runLoop: CFRunLoop
  private var source: CFRunLoopSource?

  init(runLoop: CFRunLoop) {
    self.runLoop = runLoop
  }

  @discardableResult
  func install(_ source: CFRunLoopSource) -> Bool {
    guard self.source == nil else { return false }
    self.source = source
    CFRunLoopAddSource(runLoop, source, .commonModes)
    return true
  }

  @discardableResult
  func remove() -> Bool {
    guard let source else { return false }
    self.source = nil
    CFRunLoopRemoveSource(runLoop, source, .commonModes)
    return true
  }

  deinit {
    guard let source else { return }
    CFRunLoopRemoveSource(runLoop, source, .commonModes)
  }
}

/// Publishes battery snapshots from IOKit power-source notifications, plus AlDente-style deep
/// metrics (health, cycles, temperature, power, time remaining) refreshed on a short timer.
@MainActor
final class BatteryMonitor: ObservableObject {
  /// The selected Battery screen updates every second so its power-flow readings visibly track
  /// load changes. Slower background intervals avoid that wake-up rate when nobody is watching.
  nonisolated static let liveInterval: TimeInterval = 1
  nonisolated static let backgroundInterval: TimeInterval = 60
  nonisolated static let stableInterval: TimeInterval = 5 * 60

  @Published private(set) var state: BatteryState?
  /// `state` may briefly retain the last valid UI value. Event detection uses this to distinguish
  /// that display grace period from a fresh IOPS reading.
  @Published private(set) var hasFreshState = false
  @Published private(set) var metrics: BatteryMetrics?
  @Published private(set) var peripherals: [PeripheralBattery] = []
  @Published private(set) var cpuPowerReading = CPUPowerReading.unavailable

  /// Seeded snapshots keep off-screen previews deterministic without starting the IOKit readers.
  init(
    state: BatteryState? = nil,
    metrics: BatteryMetrics? = nil,
    peripherals: [PeripheralBattery] = []
  ) {
    self.state = state
    self.metrics = metrics
    self.peripherals = peripherals
  }

  private let powerSourceRegistration = PowerSourceRunLoopRegistration(
    runLoop: CFRunLoopGetMain())
  private var metricsTimer: AnyCancellable?
  private var cancellables: Set<AnyCancellable> = []
  private var fastMetrics = false
  private var isRunning = false
  private var isSampling = false
  /// A power-source callback may arrive while a live telemetry read is in flight. Remember the
  /// strongest dropped request so charger topology, peripherals and health do not wait for the
  /// next five-minute stable timer.
  private var pendingStableRefresh = false
  private var samplingTask: Task<Void, Never>?
  private var lastStableRead: Date?
  private var generation = 0
  private var stateGracePeriod = BatteryStateGracePeriod()

  /// Temperature/power/charger change continuously, so refresh at a human-readable cadence while
  /// a battery view is on screen and slowly otherwise. Charge-source callbacks remain immediate.
  ///
  /// Refcounted rather than a Bool: during a tab cross-fade the incoming view's `onAppear` lands
  /// before the outgoing view's `onDisappear`, so a Bool would leave sampling switched off with a
  /// subscriber still visible. `lazy var` rather than `let` because the callback captures `self`.
  private(set) lazy var liveGate = LiveSamplingGate { [weak self] live in
    self?.setFastMetrics(live)
  }

  func start() {
    guard !isRunning else { return }
    isRunning = true
    generation += 1
    updateCPUPowerSampling()
    scheduleRefresh(includeStable: true)
    let opaque = Unmanaged.passUnretained(self).toOpaque()
    let callback: IOPowerSourceCallbackType = { context in
      guard let context else { return }
      let monitor = Unmanaged<BatteryMonitor>.fromOpaque(context).takeUnretainedValue()
      Task { @MainActor in monitor.scheduleRefresh(includeStable: true) }
    }
    if let source = IOPSNotificationCreateRunLoopSource(callback, opaque)?.takeRetainedValue() {
      powerSourceRegistration.install(source)
    } else {
      Log.app.error("IOPSNotificationCreateRunLoopSource failed")
    }
    restartMetricsTimer()
    // Low Power Mode is a ProcessInfo flag, not an IOKit property, so nothing else wakes us when
    // it flips. Never shell out to pmset for this.
    NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in self?.energyPolicyDidChange() }
      .store(in: &cancellables)
    Defaults.publisher(.energyMode)
      .dropFirst()
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in self?.energyPolicyDidChange() }
      .store(in: &cancellables)
  }

  func stop() {
    guard isRunning else { return }
    isRunning = false
    generation += 1
    CPUPowerSamplingService.shared.setNeeded(false, for: .battery)
    samplingTask?.cancel()
    samplingTask = nil
    isSampling = false
    pendingStableRefresh = false
    metricsTimer = nil
    cancellables.removeAll()
    powerSourceRegistration.remove()
    // A stopped private monitor must not replay its last snapshot when BatteryActivity subscribes
    // again. The first fresh sample becomes a baseline, so charger/low-battery transitions that
    // occurred while the feature was disabled are not announced after restart.
    state = nil
    hasFreshState = false
    metrics = nil
    peripherals = []
    cpuPowerReading = .unavailable
    lastStableRead = nil
    stateGracePeriod.reset()
  }

  private func setFastMetrics(_ live: Bool) {
    guard live != fastMetrics else { return }
    fastMetrics = live
    updateCPUPowerSampling()
    guard isRunning else { return }
    restartMetricsTimer()
    scheduleRefresh(includeStable: false)  // update immediately on the transition
  }

  private func restartMetricsTimer() {
    guard isRunning else {
      metricsTimer = nil
      return
    }
    let interval = energyPolicy.batteryInterval(viewIsLive: fastMetrics)
    metricsTimer = Timer.publish(every: interval, on: .main, in: .common).autoconnect()
      .sink { [weak self] _ in
        guard let self else { return }
        let stableDue =
          self.lastStableRead.map {
            Date().timeIntervalSince($0) >= self.energyPolicy.batteryStableInterval
          } ?? true
        self.scheduleRefresh(includeStable: stableDue)
      }
  }

  /// Every value here is `Equatable`; assigning an unchanged snapshot still redraws the whole
  /// expanded island, so manual/test reads follow the same diff-before-publish policy.
  func refresh() {
    applyState(Self.readState())

    let reading = CPUPowerReadingStore.shared.reading()
    if reading != cpuPowerReading { cpuPowerReading = reading }
    let fresh = SmartBatteryReader.read(cpuPowerReading: reading)
    let smoothed = fresh.map { PowerSmoothing.smooth(metrics, into: $0) }
    if smoothed != metrics { metrics = smoothed }

    let freshPeripherals = PeripheralBatteryReader.read()
    if freshPeripherals != peripherals { peripherals = freshPeripherals }
    lastStableRead = Date()
  }

  /// IOKit and IOPS can bridge sizeable property dictionaries. Keep that work off the main actor;
  /// only the small, equatable value snapshot crosses back for publication.
  private func scheduleRefresh(includeStable: Bool) {
    guard isRunning else { return }
    if isSampling {
      pendingStableRefresh = pendingStableRefresh || includeStable
      return
    }
    isSampling = true
    let expectedGeneration = generation
    samplingTask = Task { [weak self] in
      let snapshot = await Task.detached(priority: .utility) {
        let cpuPowerReading = CPUPowerReadingStore.shared.reading()
        return BatteryReadSnapshot(
          state: BatteryMonitor.readState(),
          metrics: SmartBatteryReader.read(
            includeStable: includeStable, cpuPowerReading: cpuPowerReading),
          peripherals: includeStable ? PeripheralBatteryReader.read() : nil,
          cpuPowerReading: cpuPowerReading)
      }.value
      guard let self else { return }
      guard self.isRunning, self.generation == expectedGeneration else {
        return
      }
      self.apply(snapshot, includeStable: includeStable)
      self.isSampling = false
      let followUpNeedsStable = self.pendingStableRefresh
      self.pendingStableRefresh = false
      if followUpNeedsStable { self.scheduleRefresh(includeStable: true) }
    }
  }

  private var energyPolicy: EnergyPolicy {
    EnergyPolicy(
      mode: Defaults[.energyMode],
      systemLowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled)
  }

  private func energyPolicyDidChange() {
    guard isRunning else { return }
    updateCPUPowerSampling()
    restartMetricsTimer()
    scheduleRefresh(includeStable: false)
  }

  private func updateCPUPowerSampling() {
    CPUPowerSamplingService.shared.setConstrained(energyPolicy.isConstrained)
    CPUPowerSamplingService.shared.setNeeded(isRunning && fastMetrics, for: .battery)
  }

  private func apply(_ snapshot: BatteryReadSnapshot, includeStable: Bool) {
    applyState(snapshot.state)
    if snapshot.cpuPowerReading != cpuPowerReading {
      cpuPowerReading = snapshot.cpuPowerReading
    }

    var fresh = snapshot.metrics
    if !includeStable, var current = fresh, let previous = metrics {
      current.retainStableFields(from: previous)
      fresh = current
    }
    let smoothed = fresh.map { PowerSmoothing.smooth(metrics, into: $0) }
    if smoothed != metrics { metrics = smoothed }

    if let nextPeripherals = snapshot.peripherals, nextPeripherals != peripherals {
      peripherals = nextPeripherals
    }
    if includeStable { lastStableRead = Date() }
  }

  private func applyState(_ sample: BatteryState?, now: Date = Date()) {
    let resolved = stateGracePeriod.resolve(sample, at: now)
    if resolved != state { state = resolved }
    let hasFreshState = sample != nil
    if hasFreshState != self.hasFreshState { self.hasFreshState = hasFreshState }
  }

  nonisolated static func readState() -> BatteryState? {
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
      let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
    else { return nil }
    let descriptions = list.compactMap {
      IOPSGetPowerSourceDescription(info, $0)?.takeUnretainedValue() as? [String: Any]
    }
    guard let desc = IOPSPowerSourceSelector.internalBattery(in: descriptions) else { return nil }

    return BatteryMetricsParser.batteryState(from: desc)
  }
}

extension BatteryMetrics {
  /// A live sample intentionally omits slow-changing health and connector topology fields. Carry
  /// those values forward from the most recent five-minute/deferred notification read.
  fileprivate mutating func retainStableFields(from previous: BatteryMetrics) {
    healthPercent = previous.healthPercent
    rawHealthPercent = previous.rawHealthPercent
    rawMaxCapacityMAh = previous.rawMaxCapacityMAh
    nominalCapacityMAh = previous.nominalCapacityMAh
    designCapacityMAh = previous.designCapacityMAh
    cycleCount = previous.cycleCount
    designCycleCount = previous.designCycleCount
    condition = previous.condition
    inputPortType = previous.inputPortType
  }
}
