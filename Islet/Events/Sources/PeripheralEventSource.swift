import Combine
import Defaults
import Foundation

/// Magic Mouse / Keyboard / Trackpad batteries crossing their configured early-warning threshold
/// or the fixed 10% critical threshold.
///
/// `PeripheralBatteryReader` has been read on every `BatteryMonitor` tick since Bluetooth peripheral
/// batteries shipped, and the result has only ever been rendered in the expanded view. It is a
/// level you have to go looking for. This announces the crossing.
///
/// Crossings only: a mouse sitting at 9% must not announce on every poll.
@MainActor
final class PeripheralEventSource: SystemEventSource {
  let id = "peripheral"
  let displayName = "Peripheral batteries"
  let tier = SystemEventTier.core

  private var detector = PeripheralBatteryAlertDetector()
  private let reader: () -> [PeripheralBattery]
  private let observer: any PeripheralBatteryChangeObserving
  private let scheduler: any PeripheralRefreshScheduling
  private let emit: (SystemEvent) -> Void
  private let coalescingDelay: TimeInterval
  private let backstopInterval: TimeInterval

  private var pendingChanges: Set<PeripheralBatteryChange> = []
  private var coalescingTask: (any PeripheralRefreshTask)?
  private var backstopTask: (any PeripheralRefreshTask)?

  init(
    reader: @escaping () -> [PeripheralBattery] = PeripheralBatteryReader.read,
    observer: (any PeripheralBatteryChangeObserving)? = nil,
    scheduler: (any PeripheralRefreshScheduling)? = nil,
    coalescingDelay: TimeInterval = 0.35,
    backstopInterval: TimeInterval = 300,
    emit: @escaping (SystemEvent) -> Void = { SystemEventBus.shared.emit($0) }
  ) {
    self.reader = reader
    self.observer = observer ?? PeripheralBatteryChangeObserver()
    self.scheduler = scheduler ?? RunLoopPeripheralRefreshScheduler()
    self.coalescingDelay = coalescingDelay
    self.backstopInterval = backstopInterval
    self.emit = emit
  }

  func start() {
    guard backstopTask == nil else { return }
    // Seed without announcing: a peripheral already below the threshold at launch is not news.
    detector.seed(reader())
    observer.start { [weak self] change in self?.requestRefresh(for: change) }
    // Hardware callbacks drive normal updates. This remains only as recovery for a missed callback.
    backstopTask = scheduler.schedule(after: backstopInterval, repeating: backstopInterval) {
      [weak self] in
      self?.requestRefresh(for: .powerProperty)
    }
  }

  func stop() {
    observer.stop()
    coalescingTask?.cancel()
    coalescingTask = nil
    backstopTask?.cancel()
    backstopTask = nil
    pendingChanges.removeAll()
    detector = PeripheralBatteryAlertDetector()
  }

  private func requestRefresh(for change: PeripheralBatteryChange) {
    pendingChanges.insert(change)
    guard coalescingTask == nil else { return }
    coalescingTask = scheduler.schedule(after: coalescingDelay, repeating: nil) { [weak self] in
      self?.runPendingRefresh()
    }
  }

  private func runPendingRefresh() {
    coalescingTask = nil
    let resetBaseline = pendingChanges.contains(.topology) || pendingChanges.contains(.wake)
    pendingChanges.removeAll()
    check(resetBaseline: resetBaseline)
  }

  private func check(resetBaseline: Bool) {
    let peripherals = reader()
    if resetBaseline {
      // A disconnect/reconnect may happen entirely inside the coalescing window. Do not compare the
      // returned device with a reading from its previous connection.
      detector.seed(peripherals)
      return
    }
    for result in detector.evaluate(
      peripherals, thresholds: Defaults[.peripheralBatteryWarningThresholds])
    {
      let p = result.device
      let critical = result.alert == .critical
      emit(
        SystemEvent(
          sourceID: id, icon: p.icon,
          title: critical ? "\(p.name) battery critical" : "\(p.name) battery low",
          subtitle: "\(p.percent)%",
          accentHex: critical ? EventAccent.danger : EventAccent.warning,
          motion: .peripheralLow,
          urgency: .alert, duration: 3,
          announcement: "\(p.name) battery at \(p.percent) percent"))
    }
  }
}

@MainActor
protocol PeripheralRefreshTask: AnyObject {
  func cancel()
}

@MainActor
protocol PeripheralRefreshScheduling: AnyObject {
  func schedule(
    after delay: TimeInterval, repeating interval: TimeInterval?,
    action: @escaping @MainActor () -> Void
  ) -> any PeripheralRefreshTask
}

@MainActor
private final class CombinePeripheralRefreshTask: PeripheralRefreshTask {
  private var cancellable: AnyCancellable?

  init(_ cancellable: AnyCancellable) { self.cancellable = cancellable }

  func cancel() {
    cancellable?.cancel()
    cancellable = nil
  }
}

@MainActor
final class RunLoopPeripheralRefreshScheduler: PeripheralRefreshScheduling {
  func schedule(
    after delay: TimeInterval, repeating interval: TimeInterval?,
    action: @escaping @MainActor () -> Void
  ) -> any PeripheralRefreshTask {
    let publisher = Timer.publish(every: interval ?? delay, on: .main, in: .common).autoconnect()
    let cancellable: AnyCancellable
    if interval == nil {
      cancellable = publisher.first().sink { _ in action() }
    } else {
      cancellable = publisher.sink { _ in action() }
    }
    return CombinePeripheralRefreshTask(cancellable)
  }
}
