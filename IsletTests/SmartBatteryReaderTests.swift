import XCTest

@testable import Islet

final class SmartBatteryReaderTests: XCTestCase {
  func testEmptyDictionaryYieldsNoMetrics() {
    // hasAny is false, so the caller renders nothing rather than a grid of blanks.
    XCTAssertNil(SmartBatteryReader.metrics(from: [:]))
  }

  func testHealthComesFromRawMaxOverDesignCapacity() {
    let m = SmartBatteryReader.metrics(from: [
      "AppleRawMaxCapacity": 5364, "DesignCapacity": 6249,
    ])
    XCTAssertEqual(m?.healthPercent, 86)
  }

  func testHealthFallsBackToMaxCapacity() {
    let m = SmartBatteryReader.metrics(from: ["MaxCapacity": 5500, "DesignCapacity": 6249])
    XCTAssertEqual(m?.healthPercent, 88)
  }

  func testZeroDesignCapacityYieldsNoHealth() {
    let m = SmartBatteryReader.metrics(from: [
      "AppleRawMaxCapacity": 5364, "DesignCapacity": 0, "CycleCount": 142,
    ])
    XCTAssertNil(m?.healthPercent)
    XCTAssertEqual(m?.cycleCount, 142)
  }

  func testTemperatureIsReportedInCentiDegrees() {
    let m = SmartBatteryReader.metrics(from: ["Temperature": 3120])
    XCTAssertEqual(try XCTUnwrap(m?.temperatureC), 31.2, accuracy: 0.001)
  }

  func testDischargingPowerIsNegative() {
    // 11.25 V at -0.5 A, with the amperage in its unsigned two's-complement form.
    let m = SmartBatteryReader.metrics(from: ["Voltage": 11250, "Amperage": 4_294_966_796])
    XCTAssertEqual(try XCTUnwrap(m?.powerWatts), -5.625, accuracy: 0.0001)
  }

  func testChargingPowerIsPositive() {
    let m = SmartBatteryReader.metrics(from: ["Voltage": 12000, "Amperage": 2000])
    XCTAssertEqual(try XCTUnwrap(m?.powerWatts), 24.0, accuracy: 0.0001)
  }

  func testStillCalculatingSentinelIsIgnored() {
    let m = SmartBatteryReader.metrics(from: [
      "AvgTimeToFull": 65535, "AvgTimeToEmpty": 252, "CycleCount": 142,
    ])
    XCTAssertNil(m?.timeToFullMinutes)
    XCTAssertEqual(m?.timeToEmptyMinutes, 252)
  }

  func testAdapterWattsComeFromTheNestedDetailsDictionary() {
    let m = SmartBatteryReader.metrics(from: [
      "AdapterDetails": ["Watts": 96, "Description": "pd charger"] as [String: Any]
    ])
    XCTAssertEqual(m?.adapterWatts, 96)
    // A disconnected adapter reports 0 W; that is absence, not a reading.
    let none = SmartBatteryReader.metrics(from: [
      "AdapterDetails": ["Watts": 0] as [String: Any]
    ])
    XCTAssertNil(none)
  }
}
