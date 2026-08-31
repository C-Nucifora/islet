import XCTest

@testable import Islet

@MainActor
final class PeripheralEventSourceTests: XCTestCase {
  private final class Observer: PeripheralBatteryChangeObserving {
    private var onChange: (@MainActor (PeripheralBatteryChange) -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func start(onChange: @escaping @MainActor (PeripheralBatteryChange) -> Void) {
      startCount += 1
      self.onChange = onChange
    }

    func stop() {
      stopCount += 1
      onChange = nil
    }

    func send(_ change: PeripheralBatteryChange) { onChange?(change) }
  }

  private final class Scheduler: PeripheralRefreshScheduling {
    private final class Scheduled: PeripheralRefreshTask {
      var deadline: TimeInterval
      let interval: TimeInterval?
      let action: @MainActor () -> Void
      var cancelled = false

      init(
        deadline: TimeInterval, interval: TimeInterval?,
        action: @escaping @MainActor () -> Void
      ) {
        self.deadline = deadline
        self.interval = interval
        self.action = action
      }

      func cancel() { cancelled = true }
    }

    private var now: TimeInterval = 0
    private var jobs: [Scheduled] = []

    var activeJobCount: Int { jobs.count { !$0.cancelled } }

    func schedule(
      after delay: TimeInterval, repeating interval: TimeInterval?,
      action: @escaping @MainActor () -> Void
    ) -> any PeripheralRefreshTask {
      let job = Scheduled(deadline: now + delay, interval: interval, action: action)
      jobs.append(job)
      return job
    }

    func advance(by delta: TimeInterval) {
      let destination = now + delta
      while let next = jobs.filter({ !$0.cancelled && $0.deadline <= destination }).min(by: {
        $0.deadline < $1.deadline
      }) {
        now = next.deadline
        next.action()
        if let interval = next.interval {
          next.deadline = now + interval
        } else {
          next.cancelled = true
        }
      }
      now = destination
      jobs.removeAll { $0.cancelled }
    }
  }

  private struct Fixture {
    let observer: Observer
    let scheduler: Scheduler
    let source: PeripheralEventSource
    let reads: () -> Int
    let events: () -> [SystemEvent]
  }

  private func fixture(initial: [PeripheralBattery]) -> (
    Fixture, ([PeripheralBattery]) -> Void
  ) {
    let observer = Observer()
    let scheduler = Scheduler()
    var snapshot = initial
    var readCount = 0
    var emitted: [SystemEvent] = []
    let source = PeripheralEventSource(
      reader: {
        readCount += 1
        return snapshot
      }, observer: observer, scheduler: scheduler, coalescingDelay: 0.25,
      backstopInterval: 300, emit: { emitted.append($0) })
    return (
      Fixture(
        observer: observer, scheduler: scheduler, source: source, reads: { readCount },
        events: { emitted }),
      { snapshot = $0 }
    )
  }

  private func mouse(_ percent: Int) -> PeripheralBattery {
    PeripheralBattery(id: "mouse-1", name: "Magic Mouse", percent: percent)
  }

  func testPowerPropertyChangeRefreshesAfterCoalescingDelay() {
    let (fixture, setSnapshot) = fixture(initial: [mouse(21)])
    fixture.source.start()
    setSnapshot([mouse(20)])

    fixture.observer.send(.powerProperty)
    fixture.scheduler.advance(by: 0.24)
    XCTAssertEqual(fixture.reads(), 1)
    XCTAssertTrue(fixture.events().isEmpty)

    fixture.scheduler.advance(by: 0.01)
    XCTAssertEqual(fixture.reads(), 2)
    XCTAssertEqual(fixture.events().map(\.subtitle), ["20%"])
  }

  func testDuplicateHardwareNotificationsUseOneRead() {
    let (fixture, setSnapshot) = fixture(initial: [mouse(21)])
    fixture.source.start()
    setSnapshot([mouse(19)])

    fixture.observer.send(.powerProperty)
    fixture.observer.send(.powerProperty)
    fixture.observer.send(.powerProperty)
    fixture.scheduler.advance(by: 0.25)

    XCTAssertEqual(fixture.reads(), 2)
    XCTAssertEqual(fixture.events().count, 1)
  }

  func testReconnectBelowThresholdBecomesANewBaseline() {
    let (fixture, setSnapshot) = fixture(initial: [mouse(45)])
    fixture.source.start()

    setSnapshot([])
    fixture.observer.send(.topology)
    setSnapshot([mouse(9)])
    fixture.observer.send(.topology)
    fixture.scheduler.advance(by: 0.25)

    XCTAssertEqual(fixture.reads(), 2)
    XCTAssertTrue(fixture.events().isEmpty)
  }

  func testWakeDropsAStalePreSleepBaseline() {
    let (fixture, setSnapshot) = fixture(initial: [mouse(60)])
    fixture.source.start()
    setSnapshot([mouse(8)])

    fixture.observer.send(.wake)
    fixture.scheduler.advance(by: 0.25)
    XCTAssertTrue(fixture.events().isEmpty)

    setSnapshot([mouse(7)])
    fixture.observer.send(.powerProperty)
    fixture.scheduler.advance(by: 0.25)
    XCTAssertTrue(fixture.events().isEmpty, "the post-wake 8% reading must remain the baseline")
  }

  func testFiveMinuteTimerIsOnlyABackstop() {
    let (fixture, setSnapshot) = fixture(initial: [mouse(21)])
    fixture.source.start()
    setSnapshot([mouse(10)])

    fixture.scheduler.advance(by: 299.99)
    XCTAssertEqual(fixture.reads(), 1)
    fixture.scheduler.advance(by: 0.01)
    XCTAssertEqual(fixture.reads(), 1, "the backstop still goes through the coalescing window")
    fixture.scheduler.advance(by: 0.25)

    XCTAssertEqual(fixture.reads(), 2)
    XCTAssertEqual(fixture.events().map(\.subtitle), ["10%"])
  }

  func testStopCancelsObservationAndBothTimers() {
    let (fixture, setSnapshot) = fixture(initial: [mouse(21)])
    fixture.source.start()
    setSnapshot([mouse(19)])
    fixture.observer.send(.powerProperty)
    XCTAssertEqual(fixture.scheduler.activeJobCount, 2)

    fixture.source.stop()
    XCTAssertEqual(fixture.observer.stopCount, 1)
    XCTAssertEqual(fixture.scheduler.activeJobCount, 0)
    fixture.scheduler.advance(by: 400)
    XCTAssertEqual(fixture.reads(), 1)
    XCTAssertTrue(fixture.events().isEmpty)
  }
}
