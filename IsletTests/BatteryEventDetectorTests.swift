import XCTest

@testable import Islet

final class BatteryEventDetectorTests: XCTestCase {
  func s(_ percent: Int, charging: Bool = false, ac: Bool = false) -> BatteryState {
    BatteryState(percent: percent, isCharging: charging, onAC: ac)
  }

  func testFirstSnapshotIsBaselineOnly() {
    XCTAssertTrue(BatteryEventDetector.events(from: nil, to: s(15)).isEmpty)
  }

  func testACConnect() {
    XCTAssertEqual(
      BatteryEventDetector.events(from: s(50), to: s(50, charging: true, ac: true)),
      [.acConnected(percent: 50)])
  }

  func testACDisconnect() {
    XCTAssertEqual(
      BatteryEventDetector.events(from: s(80, charging: true, ac: true), to: s(80)),
      [.acDisconnected(percent: 80)])
  }

  func testLowBatteryFiresOnCrossing() {
    XCTAssertEqual(
      BatteryEventDetector.events(from: s(21), to: s(20)),
      [.lowBattery(threshold: 20, percent: 20)])
  }

  func testLowBatteryDoesNotRefireBelowThreshold() {
    XCTAssertTrue(BatteryEventDetector.events(from: s(20), to: s(19)).isEmpty)
  }

  func testSkippingStraightThroughBothThresholds() {
    XCTAssertEqual(
      BatteryEventDetector.events(from: s(21), to: s(9)),
      [.lowBattery(threshold: 20, percent: 9), .lowBattery(threshold: 10, percent: 9)])
  }

  func testNoLowBatteryWhileOnAC() {
    XCTAssertTrue(
      BatteryEventDetector.events(from: s(21, ac: true), to: s(19, charging: true, ac: true))
        .isEmpty)
  }

  func testNoEventsWhenNothingChanged() {
    XCTAssertTrue(BatteryEventDetector.events(from: s(50), to: s(50)).isEmpty)
  }

  func testChargeCompleteFiresOnceOnTheUpwardCrossing() {
    let at99 = BatteryState(percent: 99, isCharging: true, onAC: true)
    let at100 = BatteryState(percent: 100, isCharging: false, onAC: true)
    XCTAssertEqual(
      BatteryEventDetector.events(from: at99, to: at100), [.chargeComplete(percent: 100)])
    // Still at 100 on the next tick: nothing more to say.
    XCTAssertTrue(BatteryEventDetector.events(from: at100, to: at100).isEmpty)
  }

  func testChargeCompleteDoesNotFireOnBattery() {
    let a = BatteryState(percent: 99, isCharging: false, onAC: false)
    let b = BatteryState(percent: 100, isCharging: false, onAC: false)
    XCTAssertTrue(BatteryEventDetector.events(from: a, to: b).isEmpty)
  }
}
