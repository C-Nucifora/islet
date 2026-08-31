import Combine
import Foundation

/// Magic Mouse / Keyboard / Trackpad batteries crossing a low threshold.
///
/// `PeripheralBatteryReader` has been read on every `BatteryMonitor` tick since Bluetooth peripheral
/// batteries shipped, and the result has only ever been rendered in the expanded view. It is a
/// level you have to go looking for. This announces the crossing.
///
/// Crossings only, via `ThresholdDetector`: a mouse sitting at 9% must not announce once a second.
@MainActor
final class PeripheralEventSource: SystemEventSource {
  let id = "peripheral"
  let displayName = "Peripheral batteries"
  let tier = SystemEventTier.core

  private let detector = ThresholdDetector(thresholds: [20, 10], direction: .falling)
  private let reader: () -> [PeripheralBattery]
  private let observer: any PeripheralBatteryChangeObserving
  private let scheduler: any PeripheralRefreshScheduling
  private let emit: (SystemEvent) -> Void
  private let coalescingDelay: TimeInterval
  private let backstopInterval: TimeInterval

  private var lastLevels: [String: Double] = [:]
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
    lastLevels = levels(in: reader())
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
    lastLevels = [:]
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
      lastLevels = levels(in: peripherals)
      return
    }
    var currentLevels: [String: Double] = [:]
    currentLevels.reserveCapacity(peripherals.count)
    for p in peripherals {
      let level = Double(p.percent)
      currentLevels[p.id] = level
      let crossings = detector.crossings(from: lastLevels[p.id], to: level)
      guard let lowest = crossings.min() else { continue }
      emit(
        SystemEvent(
          sourceID: id, icon: p.icon, title: "\(p.name) battery low",
          subtitle: "\(p.percent)%",
          accentHex: lowest <= 10 ? EventAccent.danger : EventAccent.warning,
          motion: .peripheralLow,
          urgency: .alert, duration: 3,
          announcement: "\(p.name) battery at \(p.percent) percent"))
    }
    // Forget disconnected devices. If the same hardware later reconnects, its new level becomes a
    // fresh baseline instead of being compared with a stale value from hours or days earlier.
    lastLevels = currentLevels
  }

  private func levels(in peripherals: [PeripheralBattery]) -> [String: Double] {
    var result: [String: Double] = [:]
    result.reserveCapacity(peripherals.count)
    for peripheral in peripherals { result[peripheral.id] = Double(peripheral.percent) }
    return result
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
