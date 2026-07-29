import Combine
import Foundation
import IOKit.ps

/// Publishes battery snapshots from IOKit power-source notifications, plus AlDente-style deep
/// metrics (health, cycles, temperature, power, time remaining) refreshed on a short timer.
@MainActor
final class BatteryMonitor: ObservableObject {
  @Published private(set) var state: BatteryState?
  @Published private(set) var metrics: BatteryMetrics?
  @Published private(set) var peripherals: [PeripheralBattery] = []

  private var runLoopSource: CFRunLoopSource?
  private var metricsTimer: AnyCancellable?
  private var fastMetrics = false

  /// Temperature/power/charger change continuously, so refresh fast (1 s) while a battery view is
  /// on screen and slowly (5 s) otherwise. The slow tick also re-reads `state` as a fallback poll.
  ///
  /// Refcounted rather than a Bool: during a tab cross-fade the incoming view's `onAppear` lands
  /// before the outgoing view's `onDisappear`, so a Bool would leave sampling switched off with a
  /// subscriber still visible. `lazy var` rather than `let` because the callback captures `self`.
  private(set) lazy var liveGate = LiveSamplingGate { [weak self] live in
    self?.setFastMetrics(live)
  }

  func start() {
    refresh()
    let opaque = Unmanaged.passUnretained(self).toOpaque()
    let callback: IOPowerSourceCallbackType = { context in
      guard let context else { return }
      let monitor = Unmanaged<BatteryMonitor>.fromOpaque(context).takeUnretainedValue()
      Task { @MainActor in monitor.refresh() }
    }
    guard
      let source = IOPSNotificationCreateRunLoopSource(callback, opaque)?
        .takeRetainedValue()
    else {
      Log.app.error("IOPSNotificationCreateRunLoopSource failed")
      return
    }
    runLoopSource = source
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
    restartMetricsTimer()
  }

  private func setFastMetrics(_ live: Bool) {
    guard live != fastMetrics else { return }
    fastMetrics = live
    restartMetricsTimer()
    refresh()  // update immediately on the transition
  }

  private func restartMetricsTimer() {
    let interval = fastMetrics ? 1.0 : 5.0
    metricsTimer = Timer.publish(every: interval, on: .main, in: .common).autoconnect()
      .sink { [weak self] _ in self?.refresh() }
  }

  /// Every value here is `Equatable`, and at 1 Hz almost all of them are unchanged from the last
  /// tick. Assigning regardless republishes three `@Published`s a second and redraws the whole
  /// expanded island for nothing, so diff first.
  func refresh() {
    let newState = Self.readState()
    if newState != state { state = newState }
    let newMetrics = SmartBatteryReader.read()
    if newMetrics != metrics { metrics = newMetrics }
    let newPeripherals = PeripheralBatteryReader.read()
    if newPeripherals != peripherals { peripherals = newPeripherals }
  }

  static func readState() -> BatteryState? {
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
      let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef],
      let source = list.first,
      let desc = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue()
        as? [String: Any]
    else { return nil }

    let current = desc[kIOPSCurrentCapacityKey] as? Int ?? 0
    let max = desc[kIOPSMaxCapacityKey] as? Int ?? 100
    let charging = desc[kIOPSIsChargingKey] as? Bool ?? false
    let onAC = (desc[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
    let percent = max > 0 ? Int((Double(current) / Double(max) * 100).rounded()) : 0
    return BatteryState(percent: percent, isCharging: charging, onAC: onAC)
  }
}
