import IOKit.ps
import XCTest

@testable import Islet

final class BatteryStateReadTests: XCTestCase {
  private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)

  private func source(current: Any? = 50, maximum: Any? = 100) -> [String: Any] {
    var result: [String: Any] = [
      kIOPSIsChargingKey: false,
      kIOPSPowerSourceStateKey: kIOPSBatteryPowerValue,
    ]
    if let current { result[kIOPSCurrentCapacityKey] = current }
    if let maximum { result[kIOPSMaxCapacityKey] = maximum }
    return result
  }

  func testMissingCapacityFieldsProduceAnUnavailableSample() {
    XCTAssertNil(BatteryMetricsParser.batteryState(from: source(current: nil)))
    XCTAssertNil(BatteryMetricsParser.batteryState(from: source(maximum: nil)))
  }

  func testZeroMaximumCapacityProducesAnUnavailableSample() {
    XCTAssertNil(BatteryMetricsParser.batteryState(from: source(maximum: 0)))
  }

  func testOutOfRangeCapacityProducesAnUnavailableSample() {
    XCTAssertNil(BatteryMetricsParser.batteryState(from: source(current: -1)))
    XCTAssertNil(BatteryMetricsParser.batteryState(from: source(current: 101)))
  }

  func testBooleanFractionalAndUnsafeCapacityValuesAreUnavailable() {
    XCTAssertNil(BatteryMetricsParser.batteryState(from: source(current: true)))
    XCTAssertNil(BatteryMetricsParser.batteryState(from: source(current: 50.5)))
    XCTAssertNil(
      BatteryMetricsParser.batteryState(
        from: source(current: NSNumber(value: Double(Int.max)), maximum: Double(Int.max))))
  }

  func testGracePeriodRetainsThenExpiresTheLastValidPercentage() throws {
    var cache = BatteryStateGracePeriod()
    let valid = try XCTUnwrap(BatteryMetricsParser.batteryState(from: source(current: 42)))
    XCTAssertEqual(cache.resolve(valid, at: t0)?.percent, 42)
    XCTAssertEqual(
      cache.resolve(nil, at: t0.addingTimeInterval(BatteryStateGracePeriod.duration - 1))?.percent,
      42)
    XCTAssertNil(cache.resolve(nil, at: t0.addingTimeInterval(BatteryStateGracePeriod.duration)))
  }

  func testRecoveryReplacesAnExpiredUnavailableSample() throws {
    var cache = BatteryStateGracePeriod()
    let first = try XCTUnwrap(BatteryMetricsParser.batteryState(from: source(current: 42)))
    XCTAssertEqual(cache.resolve(first, at: t0)?.percent, 42)
    XCTAssertNil(cache.resolve(nil, at: t0.addingTimeInterval(BatteryStateGracePeriod.duration)))

    let recovered = try XCTUnwrap(BatteryMetricsParser.batteryState(from: source(current: 73)))
    XCTAssertEqual(
      cache.resolve(
        recovered, at: t0.addingTimeInterval(BatteryStateGracePeriod.duration + 1))?.percent,
      73)
  }

  func testClockMovingBackwardExpiresTheRetainedState() throws {
    var cache = BatteryStateGracePeriod()
    let valid = try XCTUnwrap(BatteryMetricsParser.batteryState(from: source(current: 42)))
    XCTAssertEqual(cache.resolve(valid, at: t0), valid)

    XCTAssertNil(cache.resolve(nil, at: t0.addingTimeInterval(-1)))
  }

  func testUnavailableGracePeriodDoesNotCreateThresholdEvents() throws {
    var cache = BatteryStateGracePeriod()
    let valid = try XCTUnwrap(BatteryMetricsParser.batteryState(from: source(current: 21)))
    XCTAssertEqual(cache.resolve(valid, at: t0), valid)
    let retained = cache.resolve(nil, at: t0.addingTimeInterval(1))

    XCTAssertEqual(retained, valid)
    var history = BatteryEventHistory()
    XCTAssertTrue(history.events(for: valid, isFresh: true).isEmpty)
    XCTAssertTrue(history.events(for: retained, isFresh: false).isEmpty)

    // The retained 21% stays visible, but a recovered 9% becomes a fresh baseline instead of a
    // synthetic 21 -> 9% threshold crossing.
    let recovered = try XCTUnwrap(BatteryMetricsParser.batteryState(from: source(current: 9)))
    XCTAssertTrue(history.events(for: recovered, isFresh: true).isEmpty)
  }
}
