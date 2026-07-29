import XCTest

@testable import Islet

final class BatteryMetricsTests: XCTestCase {

  // MARK: - Model

  func testEmptyMetricsHasNothing() {
    XCTAssertFalse(BatteryMetrics().hasAny)
    XCTAssertTrue(BatteryMetrics().pdLadder.isEmpty)
    XCTAssertFalse(BatteryMetrics().lowPowerMode)
  }

  func testAnySingleReadingMakesItPresent() {
    var m = BatteryMetrics()
    m.cycleCount = 224
    XCTAssertTrue(m.hasAny)

    var n = BatteryMetrics()
    n.batteryPowerWatts = -5.715
    XCTAssertTrue(n.hasAny)

    // Low Power Mode alone is not a battery reading — it must not resurrect an empty panel.
    var o = BatteryMetrics()
    o.lowPowerMode = true
    XCTAssertFalse(o.hasAny)
  }

  func testPDProfileComputesWatts() {
    let rung = PDProfile(index: 4, volts: 20.0, amps: 1.49)
    XCTAssertEqual(rung.id, 4)
    XCTAssertEqual(rung.watts, 29.8, accuracy: 0.0001)
  }

  // MARK: - Fixtures
  //
  // Real values captured from `ioreg -r -c AppleSmartBattery` on an M-series MacBook Pro,
  // 2026-07-29. Numbers read back through NSNumber.intValue, which already applies the sign.
  //
  // Computed, not stored: a `static let` of a non-Sendable `[String: Any]` is a Swift 6 strict
  // concurrency error ("not concurrency-safe because non-'Sendable' type may have shared mutable
  // state"). A computed static has no storage and no such diagnostic.

  static var smartBattery: [String: Any] {
    [
      "Voltage": 11203,
      "Amperage": -322,
      "InstantAmperage": -322,
      "Temperature": 3068,
      "AppleRawMaxCapacity": 5381,
      "NominalChargeCapacity": 5533,
      "DesignCapacity": 6249,
      "CycleCount": 224,
      "DesignCycleCount9C": 1000,
      "AvgTimeToEmpty": 142,
      "AvgTimeToFull": 65535,
      "IsCharging": false,
      "FullyCharged": false,
      "ExternalConnected": true,
      "ChargerData": [
        "NotChargingReason": 36_028_797_018_963_968,
        "ChargingCurrent": 0,
        "ChargingVoltage": 3795,
      ] as [String: Any],
      "PowerTelemetryData": [
        "SystemPowerIn": 28407,
        "SystemVoltageIn": 19803,
        "SystemCurrentIn": 1434,
        "SystemLoad": 34122,
        "BatteryPower": -5715,
        "AdapterEfficiencyLoss": 696,
      ] as [String: Any],
    ]
  }

  static var adapter: [String: Any] {
    [
      "Watts": 30,
      "Description": "pd charger",
      "AdapterVoltage": 20000,
      "Current": 1490,
      "IsWireless": false,
      "AdapterPowerTier": 1,
      "UsbHvcHvcIndex": 4,
      "UsbHvcMenu": [
        ["Index": 0, "MaxVoltage": 5000, "MaxCurrent": 2960],
        ["Index": 1, "MaxVoltage": 9000, "MaxCurrent": 2980],
        ["Index": 2, "MaxVoltage": 12000, "MaxCurrent": 2480],
        ["Index": 3, "MaxVoltage": 15000, "MaxCurrent": 1990],
        ["Index": 4, "MaxVoltage": 20000, "MaxCurrent": 1490],
      ] as [[String: Any]],
    ]
  }

  static var powerSource: [String: Any] {
    ["BatteryHealth": "Good", "BatteryHealthCondition": ""]
  }

  // MARK: - Health

  func testHealthUsesNominalChargeCapacityOverDesign() {
    var m = BatteryMetrics()
    BatteryMetricsParser.applyHealth(&m, from: Self.smartBattery)
    // 5533 / 6249 = 88.54% -> 89, which is what System Settings shows.
    XCTAssertEqual(m.healthPercent, 89)
  }

  func testRawHealthUsesAppleRawMaxCapacityOverDesign() {
    var m = BatteryMetrics()
    BatteryMetricsParser.applyHealth(&m, from: Self.smartBattery)
    // 5381 / 6249 = 86.11% -> 86, which is what AlDente and coconutBattery show.
    XCTAssertEqual(m.rawHealthPercent, 86)
  }

  func testCapacitiesAndCyclesCarryThrough() {
    var m = BatteryMetrics()
    BatteryMetricsParser.applyHealth(&m, from: Self.smartBattery)
    XCTAssertEqual(m.rawMaxCapacityMAh, 5381)
    XCTAssertEqual(m.nominalCapacityMAh, 5533)
    XCTAssertEqual(m.designCapacityMAh, 6249)
    XCTAssertEqual(m.cycleCount, 224)
    XCTAssertEqual(m.designCycleCount, 1000)
  }

  func testHealthIsAbsentWithoutDesignCapacity() {
    var m = BatteryMetrics()
    BatteryMetricsParser.applyHealth(
      &m, from: ["NominalChargeCapacity": 5533, "AppleRawMaxCapacity": 5381])
    XCTAssertNil(m.healthPercent)
    XCTAssertNil(m.rawHealthPercent)
    XCTAssertNil(m.designCapacityMAh)
    XCTAssertEqual(m.nominalCapacityMAh, 5533)
  }

  func testHealthIsAbsentWhenDesignCapacityIsZero() {
    var m = BatteryMetrics()
    BatteryMetricsParser.applyHealth(
      &m, from: ["NominalChargeCapacity": 5533, "DesignCapacity": 0, "DesignCycleCount9C": 0])
    XCTAssertNil(m.healthPercent)
    XCTAssertNil(m.designCapacityMAh)
    XCTAssertNil(m.designCycleCount)
    XCTAssertNil(BatteryMetricsParser.percentage(5533, of: 0))
  }

  // MARK: - Instantaneous readings

  func testTemperatureIsCentiDegrees() throws {
    var m = BatteryMetrics()
    BatteryMetricsParser.applyInstant(&m, from: Self.smartBattery)
    XCTAssertEqual(try XCTUnwrap(m.temperatureC), 30.68, accuracy: 0.0001)
  }

  func testVoltageIsMillivolts() throws {
    var m = BatteryMetrics()
    BatteryMetricsParser.applyInstant(&m, from: Self.smartBattery)
    XCTAssertEqual(try XCTUnwrap(m.voltage), 11.203, accuracy: 0.0001)
  }

  func testAmperageIsSignedAndPrefersTheInstantReading() throws {
    var m = BatteryMetrics()
    BatteryMetricsParser.applyInstant(
      &m, from: ["Voltage": 11203, "Amperage": -900, "InstantAmperage": -322])
    XCTAssertEqual(try XCTUnwrap(m.amperage), -0.322, accuracy: 0.0001)
  }

  func testAmperageFallsBackToTheAveragedReading() throws {
    var m = BatteryMetrics()
    BatteryMetricsParser.applyInstant(&m, from: ["Voltage": 11203, "Amperage": -900])
    XCTAssertEqual(try XCTUnwrap(m.amperage), -0.900, accuracy: 0.0001)
  }

  func testAmperageDecodesTwosComplement() throws {
    // Some machines widen an unsigned 32-bit amperage into Int rather than sign-extending it.
    // 4294967284 == 2^32 - 12, i.e. -12 mA.
    var m = BatteryMetrics()
    BatteryMetricsParser.applyInstant(
      &m, from: ["Voltage": 11203, "InstantAmperage": 4_294_967_284])
    XCTAssertEqual(try XCTUnwrap(m.amperage), -0.012, accuracy: 0.0001)
    XCTAssertEqual(IORegistryReader.signedInt(4_294_967_284), -12)
    XCTAssertEqual(IORegistryReader.signedInt(-322), -322)
  }

  func testPowerWattsIsVoltageTimesAmperageAndKeepsTheSign() throws {
    var m = BatteryMetrics()
    BatteryMetricsParser.applyInstant(&m, from: Self.smartBattery)
    // 11.203 V * -0.322 A = -3.607366 W, negative because the pack is supplying the machine.
    XCTAssertEqual(try XCTUnwrap(m.powerWatts), -3.607366, accuracy: 0.0001)
  }

  func testTimeRemainingSentinelsAreDropped() {
    var m = BatteryMetrics()
    BatteryMetricsParser.applyInstant(&m, from: Self.smartBattery)
    XCTAssertNil(m.timeToFullMinutes)  // 65535 is the "still calculating" sentinel
    XCTAssertEqual(m.timeToEmptyMinutes, 142)

    var zeroed = BatteryMetrics()
    BatteryMetricsParser.applyInstant(&zeroed, from: ["AvgTimeToEmpty": 0, "AvgTimeToFull": 0])
    XCTAssertNil(zeroed.timeToEmptyMinutes)
    XCTAssertNil(zeroed.timeToFullMinutes)
  }

  // MARK: - Charger

  func testAdapterWattsAndDescription() {
    var m = BatteryMetrics()
    BatteryMetricsParser.applyCharger(&m, from: Self.adapter)
    XCTAssertEqual(m.adapterWatts, 30)
    XCTAssertEqual(m.adapterDescription, "pd charger")
    XCTAssertEqual(m.adapterIsWireless, false)
    XCTAssertEqual(m.adapterPowerTier, 1)
    XCTAssertEqual(m.pdSelectedIndex, 4)
  }

  func testAdapterVoltageAndCurrent() throws {
    var m = BatteryMetrics()
    BatteryMetricsParser.applyCharger(&m, from: Self.adapter)
    XCTAssertEqual(try XCTUnwrap(m.adapterVolts), 20.0, accuracy: 0.0001)
    XCTAssertEqual(try XCTUnwrap(m.adapterAmps), 1.49, accuracy: 0.0001)
  }

  func testPDLadderParsesEveryRungInIndexOrder() throws {
    var m = BatteryMetrics()
    BatteryMetricsParser.applyCharger(&m, from: Self.adapter)
    XCTAssertEqual(m.pdLadder.count, 5)
    XCTAssertEqual(m.pdLadder.map(\.index), [0, 1, 2, 3, 4])
    XCTAssertEqual(try XCTUnwrap(m.pdLadder.first).volts, 5.0, accuracy: 0.0001)
    XCTAssertEqual(try XCTUnwrap(m.pdLadder.first).amps, 2.96, accuracy: 0.0001)
    XCTAssertEqual(try XCTUnwrap(m.pdLadder.last).volts, 20.0, accuracy: 0.0001)
    XCTAssertEqual(try XCTUnwrap(m.pdLadder.last).watts, 29.8, accuracy: 0.0001)
  }

  func testPDLadderSkipsMalformedRungs() {
    let ladder = BatteryMetricsParser.pdLadder(
      from: [
        ["Index": 1, "MaxVoltage": 9000, "MaxCurrent": 2980],
        ["Index": 0, "MaxVoltage": 0, "MaxCurrent": 2960],  // zero volts
        ["Index": 2, "MaxCurrent": 2480],  // no voltage key
        ["nonsense": true],
      ] as [[String: Any]])
    XCTAssertEqual(ladder.count, 1)
    XCTAssertEqual(ladder.first?.index, 1)
  }

  func testNoAdapterLeavesEveryChargerFieldEmpty() {
    var m = BatteryMetrics()
    BatteryMetricsParser.applyCharger(&m, from: nil)
    XCTAssertNil(m.adapterWatts)
    XCTAssertNil(m.adapterDescription)
    XCTAssertNil(m.adapterVolts)
    XCTAssertNil(m.adapterAmps)
    XCTAssertTrue(m.pdLadder.isEmpty)
    XCTAssertFalse(m.hasAny)
  }

  // MARK: - Power flow

  func testPowerTelemetryConvertsMilliwattsToWatts() throws {
    var m = BatteryMetrics()
    BatteryMetricsParser.applyTelemetry(&m, from: Self.smartBattery)
    XCTAssertEqual(try XCTUnwrap(m.systemPowerInWatts), 28.407, accuracy: 0.0001)
    XCTAssertEqual(try XCTUnwrap(m.systemVoltageIn), 19.803, accuracy: 0.0001)
    XCTAssertEqual(try XCTUnwrap(m.systemCurrentIn), 1.434, accuracy: 0.0001)
    XCTAssertEqual(try XCTUnwrap(m.systemLoadWatts), 34.122, accuracy: 0.0001)
    XCTAssertEqual(try XCTUnwrap(m.adapterLossWatts), 0.696, accuracy: 0.0001)
  }

  func testBatteryPowerIsNegativeWhileTheAdapterFallsShort() throws {
    var m = BatteryMetrics()
    BatteryMetricsParser.applyTelemetry(&m, from: Self.smartBattery)
    XCTAssertEqual(try XCTUnwrap(m.batteryPowerWatts), -5.715, accuracy: 0.0001)
  }

  func testSystemLoadEqualsAdapterInputMinusBatteryPower() throws {
    // The identity that pins down the sign convention: 28.407 - (-5.715) = 34.122.
    var m = BatteryMetrics()
    BatteryMetricsParser.applyTelemetry(&m, from: Self.smartBattery)
    let inW = try XCTUnwrap(m.systemPowerInWatts)
    let battW = try XCTUnwrap(m.batteryPowerWatts)
    XCTAssertEqual(try XCTUnwrap(m.systemLoadWatts), inW - battW, accuracy: 0.0005)
  }

  func testBatteryPowerDecodesTwosComplement() throws {
    var m = BatteryMetrics()
    BatteryMetricsParser.applyTelemetry(
      &m, from: ["PowerTelemetryData": ["BatteryPower": 4_294_961_581] as [String: Any]])
    XCTAssertEqual(try XCTUnwrap(m.batteryPowerWatts), -5.715, accuracy: 0.0001)
  }

  func testTelemetryIsAbsentWhenTheKeyIsMissing() {
    var m = BatteryMetrics()
    BatteryMetricsParser.applyTelemetry(&m, from: ["Voltage": 11203])
    XCTAssertNil(m.systemPowerInWatts)
    XCTAssertNil(m.systemLoadWatts)
    XCTAssertNil(m.batteryPowerWatts)
    XCTAssertNil(m.adapterLossWatts)
  }
}
