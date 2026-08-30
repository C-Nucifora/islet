import XCTest

@testable import Islet

private final class LockedValue<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Value

  init(_ value: Value) {
    self.value = value
  }

  func read() -> Value {
    lock.withLock { value }
  }

  func update<Result>(_ body: (inout Value) -> Result) -> Result {
    lock.withLock { body(&value) }
  }
}

private final class TestSleeper: @unchecked Sendable {
  private struct State {
    var intervals: [TimeInterval] = []
    var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    var cancelledBeforeRegistration: Set<UUID> = []
    var cancellationCount = 0
  }

  private let state = LockedValue(State())

  var intervals: [TimeInterval] { state.read().intervals }
  var cancellationCount: Int { state.read().cancellationCount }

  func sleep(for interval: TimeInterval) async throws {
    let id = UUID()
    try Task.checkCancellation()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let cancelled = state.update { state in
          state.intervals.append(interval)
          if state.cancelledBeforeRegistration.remove(id) != nil { return true }
          state.waiters[id] = continuation
          return false
        }
        if cancelled { continuation.resume(throwing: CancellationError()) }
      }
    } onCancel: {
      let continuation = self.state.update { state -> CheckedContinuation<Void, Error>? in
        state.cancellationCount += 1
        if let continuation = state.waiters.removeValue(forKey: id) {
          return continuation
        }
        state.cancelledBeforeRegistration.insert(id)
        return nil
      }
      continuation?.resume(throwing: CancellationError())
    }
  }

  func resumeNext() {
    let continuation = state.update { state -> CheckedContinuation<Void, Error>? in
      guard let id = state.waiters.keys.first else { return nil }
      return state.waiters.removeValue(forKey: id)
    }
    continuation?.resume()
  }
}

private final class SampleProbe: @unchecked Sendable {
  private struct State {
    var values: [Double?]
    var callCount = 0
    var activeCount = 0
    var maximumActiveCount = 0
  }

  private let state: LockedValue<State>

  init(values: [Double?]) {
    state = LockedValue(State(values: values))
  }

  var callCount: Int { state.read().callCount }
  var maximumActiveCount: Int { state.read().maximumActiveCount }

  func sample() async -> Double? {
    state.update { state in
      state.callCount += 1
      state.activeCount += 1
      state.maximumActiveCount = max(state.maximumActiveCount, state.activeCount)
    }
    defer { state.update { $0.activeCount -= 1 } }
    return state.update { state in
      state.values.isEmpty ? nil : state.values.removeFirst()
    }
  }
}

private final class BlockingSampleProbe: @unchecked Sendable {
  private struct State {
    var callCount = 0
    var activeCount = 0
    var maximumActiveCount = 0
    var cancellationCount = 0
    var waiters: [UUID: CheckedContinuation<Double?, Never>] = [:]
    var cancelledBeforeRegistration: Set<UUID> = []
  }

  private let state = LockedValue(State())

  var callCount: Int { state.read().callCount }
  var maximumActiveCount: Int { state.read().maximumActiveCount }
  var cancellationCount: Int { state.read().cancellationCount }

  func sample() async -> Double? {
    let id = UUID()
    state.update { state in
      state.callCount += 1
      state.activeCount += 1
      state.maximumActiveCount = max(state.maximumActiveCount, state.activeCount)
    }
    defer { state.update { $0.activeCount -= 1 } }

    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        let cancelled = state.update { state in
          if state.cancelledBeforeRegistration.remove(id) != nil { return true }
          state.waiters[id] = continuation
          return false
        }
        if cancelled { continuation.resume(returning: nil) }
      }
    } onCancel: {
      let continuation = self.state.update { state -> CheckedContinuation<Double?, Never>? in
        state.cancellationCount += 1
        if let continuation = state.waiters.removeValue(forKey: id) {
          return continuation
        }
        state.cancelledBeforeRegistration.insert(id)
        return nil
      }
      continuation?.resume(returning: nil)
    }
  }
}

@MainActor
final class CPUPowerSamplingTests: XCTestCase {
  private func waitUntil(
    _ description: String,
    condition: () -> Bool
  ) async {
    for _ in 0..<1_000 {
      if condition() { return }
      await Task.yield()
    }
    XCTFail("Timed out waiting for \(description)")
  }

  func testReadingStoreReportsUnavailableFreshAndStale() {
    let clock = LockedValue<TimeInterval>(10)
    let store = CPUPowerReadingStore(now: { clock.read() }, staleAfter: 5)

    XCTAssertEqual(store.reading(), .unavailable)
    store.record(watts: 7.25, at: 10)
    XCTAssertEqual(store.reading(), .fresh(watts: 7.25))
    XCTAssertEqual(store.reading().freshWatts, 7.25)

    clock.update { $0 = 15 }
    XCTAssertEqual(store.reading(), .fresh(watts: 7.25))
    clock.update { $0 = 15.001 }
    XCTAssertEqual(store.reading(), .stale(watts: 7.25))
    XCTAssertNil(store.reading().freshWatts)
  }

  func testConstrainedPolicyExtendsTheFreshnessWindow() {
    let clock = LockedValue<TimeInterval>(0)
    let store = CPUPowerReadingStore(now: { clock.read() }, staleAfter: 5)
    let sleeper = TestSleeper()
    let service = CPUPowerSamplingService(
      dependencies: CPUPowerSamplingDependencies(
        now: { clock.read() },
        sleep: { try await sleeper.sleep(for: $0) },
        sample: { nil }),
      store: store)
    store.record(watts: 3, at: 0)

    clock.update { $0 = 10 }
    XCTAssertEqual(service.cachedReading(), .stale(watts: 3))
    service.setConstrained(true)
    XCTAssertEqual(service.cachedReading(), .fresh(watts: 3))
  }

  func testRequestedCadenceKeepsAReadingFreshUntilTheFollowingSampleWindow() {
    let clock = LockedValue<TimeInterval>(0)
    let store = CPUPowerReadingStore(now: { clock.read() }, staleAfter: 5)
    let service = CPUPowerSamplingService(
      dependencies: CPUPowerSamplingDependencies(
        now: { clock.read() }, sleep: { _ in }, sample: { nil }),
      store: store)
    store.record(watts: 3, at: 0)

    service.setDemand(12, for: .battery)
    clock.update { $0 = 24 }
    XCTAssertEqual(service.cachedReading(), .fresh(watts: 3))

    clock.update { $0 = 24.001 }
    XCTAssertEqual(service.cachedReading(), .stale(watts: 3))
    service.setDemand(nil, for: .battery)
  }

  func testReadingStoreKeepsLastValidSample() {
    let clock = LockedValue<TimeInterval>(20)
    let store = CPUPowerReadingStore(now: { clock.read() }, staleAfter: 5)

    store.record(watts: 4, at: 20)
    store.record(watts: .nan, at: 21)
    store.record(watts: -1, at: 21)
    XCTAssertEqual(store.reading(), .fresh(watts: 4))
  }

  func testServiceDoesNothingWithoutAConsumer() async {
    let probe = SampleProbe(values: [2])
    let sleeper = TestSleeper()
    let service = makeService(probe: probe, sleeper: sleeper)

    for _ in 0..<10 { await Task.yield() }
    XCTAssertEqual(probe.callCount, 0)
    XCTAssertTrue(sleeper.intervals.isEmpty)
    XCTAssertEqual(service.cachedReading(), .unavailable)
  }

  func testBatteryDemandUsesItsRequestedRefreshCadence() async {
    let probe = SampleProbe(values: [4])
    let sleeper = TestSleeper()
    let service = makeService(probe: probe, sleeper: sleeper)

    service.setDemand(12, for: .battery)
    await waitUntil("the Battery cadence sleep") { sleeper.intervals.count == 1 }

    XCTAssertEqual(sleeper.intervals, [12])
    service.setDemand(nil, for: .battery)
    await waitUntil("the Battery cadence sleep to cancel") { sleeper.cancellationCount == 1 }
  }

  func testBatteryMonitorRequestsItsActiveRefreshCadence() async {
    let probe = SampleProbe(values: [4])
    let sleeper = TestSleeper()
    let clock = LockedValue<TimeInterval>(0)
    let store = CPUPowerReadingStore(now: { clock.read() }, staleAfter: 5)
    let service = CPUPowerSamplingService(
      dependencies: CPUPowerSamplingDependencies(
        now: { clock.read() },
        sleep: { try await sleeper.sleep(for: $0) },
        sample: { await probe.sample() }),
      store: store)
    let monitor = BatteryMonitor(
      cpuPowerSamplingService: service,
      energyPolicy: { EnergyPolicy(mode: .automatic, systemLowPowerMode: false) })

    monitor.start()
    monitor.liveGate.retain()
    defer {
      monitor.liveGate.release()
      monitor.stop()
    }
    await waitUntil("the Battery monitor CPU-power demand") { sleeper.intervals.count == 1 }

    XCTAssertEqual(sleeper.intervals, [12])
  }

  func testSystemMonitorDoesNotRequestUnusedCPUPowerSampling() async {
    let probe = SampleProbe(values: [9])
    let sleeper = TestSleeper()
    let service = makeService(probe: probe, sleeper: sleeper)
    let monitor = SystemMetricsMonitor(
      now: { Date(timeIntervalSinceReferenceDate: 0) },
      cpuPowerSamplingService: service)

    monitor.start()
    monitor.liveGate.retain()
    defer {
      monitor.liveGate.release()
      monitor.stop()
    }
    for _ in 0..<100 { await Task.yield() }

    XCTAssertEqual(probe.callCount, 0)
    XCTAssertTrue(sleeper.intervals.isEmpty)
  }

  func testBatteryAndSystemConsumersShareOneSamplingLoop() async {
    let probe = SampleProbe(values: [8])
    let sleeper = TestSleeper()
    let service = makeService(probe: probe, sleeper: sleeper)

    service.setDemand(CPUPowerSamplingService.normalInterval, for: .battery)
    await waitUntil("the first CPU-power sample") { sleeper.intervals.count == 1 }
    service.setDemand(CPUPowerSamplingService.normalInterval, for: .system)
    for _ in 0..<10 { await Task.yield() }

    XCTAssertEqual(probe.callCount, 1)
    XCTAssertEqual(probe.maximumActiveCount, 1)
    XCTAssertEqual(service.cachedReading(), .fresh(watts: 8))

    service.setDemand(nil, for: .battery)
    for _ in 0..<10 { await Task.yield() }
    XCTAssertEqual(sleeper.cancellationCount, 0)

    service.setDemand(nil, for: .system)
    await waitUntil("the shared loop to cancel") { sleeper.cancellationCount == 1 }
  }

  func testCadenceChangesFromNormalToConstrainedWithoutOverlap() async {
    let probe = SampleProbe(values: [1, 2, 3])
    let sleeper = TestSleeper()
    let service = makeService(probe: probe, sleeper: sleeper)

    service.setDemand(CPUPowerSamplingService.normalInterval, for: .battery)
    await waitUntil("the normal cadence") { sleeper.intervals.count == 1 }
    XCTAssertEqual(sleeper.intervals, [CPUPowerSamplingService.normalInterval])

    sleeper.resumeNext()
    await waitUntil("the second normal sample") { sleeper.intervals.count == 2 }
    service.setConstrained(true)
    await waitUntil("the constrained cadence") { sleeper.intervals.count == 3 }

    XCTAssertEqual(
      sleeper.intervals,
      [
        CPUPowerSamplingService.normalInterval,
        CPUPowerSamplingService.normalInterval,
        CPUPowerSamplingService.constrainedInterval,
      ])
    XCTAssertEqual(probe.callCount, 3)
    XCTAssertEqual(probe.maximumActiveCount, 1)

    service.setDemand(nil, for: .battery)
    await waitUntil("the constrained loop to cancel") { sleeper.cancellationCount == 2 }
  }

  func testCadenceIncludesTheSamplingWindow() async {
    let clock = LockedValue<TimeInterval>(100)
    let sleeper = TestSleeper()
    let store = CPUPowerReadingStore(now: { clock.read() }, staleAfter: 5)
    let service = CPUPowerSamplingService(
      dependencies: CPUPowerSamplingDependencies(
        now: { clock.read() },
        sleep: { try await sleeper.sleep(for: $0) },
        sample: {
          clock.update { $0 += 0.25 }
          return 6
        }),
      store: store)

    service.setDemand(CPUPowerSamplingService.normalInterval, for: .battery)
    await waitUntil("the post-sample sleep") { sleeper.intervals.count == 1 }
    XCTAssertEqual(sleeper.intervals[0], 0.75, accuracy: 0.000_001)

    service.setDemand(nil, for: .battery)
    await waitUntil("the cadence sleep to cancel") { sleeper.cancellationCount == 1 }
  }

  func testFailedSampleKeepsTheLatestValidReading() async {
    let probe = SampleProbe(values: [5, nil])
    let sleeper = TestSleeper()
    let service = makeService(probe: probe, sleeper: sleeper)

    service.setDemand(CPUPowerSamplingService.normalInterval, for: .battery)
    await waitUntil("the first cadence sleep") { sleeper.intervals.count == 1 }
    sleeper.resumeNext()
    await waitUntil("the failed sample") { sleeper.intervals.count == 2 }

    XCTAssertEqual(service.cachedReading(), .fresh(watts: 5))
    service.setDemand(nil, for: .battery)
    await waitUntil("the loop to cancel") { sleeper.cancellationCount == 1 }
  }

  func testRemovingLastConsumerCancelsAnInFlightSampleBeforeRestart() async {
    let probe = BlockingSampleProbe()
    let store = CPUPowerReadingStore(now: { 0 }, staleAfter: 5)
    let service = CPUPowerSamplingService(
      dependencies: CPUPowerSamplingDependencies(
        now: { 0 },
        sleep: { _ in XCTFail("A cancelled sample must not reach its cadence sleep") },
        sample: { await probe.sample() }),
      store: store)

    service.setDemand(CPUPowerSamplingService.normalInterval, for: .battery)
    await waitUntil("the blocking sample to start") { probe.callCount == 1 }
    service.setDemand(nil, for: .battery)
    service.setDemand(CPUPowerSamplingService.normalInterval, for: .system)
    await waitUntil("the first sample cancellation") { probe.cancellationCount == 1 }
    await waitUntil("the replacement sample") { probe.callCount == 2 }

    XCTAssertEqual(probe.maximumActiveCount, 1)
    service.setDemand(nil, for: .system)
    await waitUntil("the replacement cancellation") { probe.cancellationCount == 2 }
  }

  private func makeService(probe: SampleProbe, sleeper: TestSleeper)
    -> CPUPowerSamplingService
  {
    let clock = LockedValue<TimeInterval>(0)
    let store = CPUPowerReadingStore(now: { clock.read() }, staleAfter: 5)
    return CPUPowerSamplingService(
      dependencies: CPUPowerSamplingDependencies(
        now: { clock.read() },
        sleep: { try await sleeper.sleep(for: $0) },
        sample: { await probe.sample() }),
      store: store)
  }
}
