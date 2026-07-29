import Defaults
import SwiftUI
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

  // MARK: - Charge state

  func testChargeStateFlags() {
    var m = BatteryMetrics()
    BatteryMetricsParser.applyChargeState(&m, from: Self.smartBattery)
    XCTAssertEqual(m.isCharging, false)
    XCTAssertEqual(m.fullyCharged, false)
    XCTAssertEqual(m.externalConnected, true)
  }

  func testNotChargingReasonIsReadFromChargerData() {
    var m = BatteryMetrics()
    BatteryMetricsParser.applyChargeState(&m, from: Self.smartBattery)
    XCTAssertEqual(m.notChargingReason, 36_028_797_018_963_968)
  }

  func testNotChargingReasonIsAbsentWithoutChargerData() {
    var m = BatteryMetrics()
    BatteryMetricsParser.applyChargeState(&m, from: ["IsCharging": true])
    XCTAssertNil(m.notChargingReason)
    XCTAssertEqual(m.isCharging, true)
  }

  func testNotChargingReasonSetBits() {
    XCTAssertEqual(NotChargingReason.setBits(36_028_797_018_963_968), [55])
    XCTAssertEqual(NotChargingReason.setBits(0), [])
    XCTAssertEqual(NotChargingReason.setBits(0b1011), [0, 1, 3])
  }

  func testNotChargingReasonCode() {
    XCTAssertEqual(NotChargingReason.code(36_028_797_018_963_968), "0x80000000000000")
    XCTAssertEqual(NotChargingReason.code(0), "0x0")
    XCTAssertEqual(NotChargingReason.code(255), "0xFF")
  }

  // MARK: - Status line

  func testStatusOnBattery() {
    XCTAssertEqual(
      PowerStatus.text(
        onAC: false, isCharging: false, fullyCharged: false, batteryWatts: -3.6,
        notChargingReason: nil),
      "On battery")
  }

  func testStatusCharging() {
    XCTAssertEqual(
      PowerStatus.text(
        onAC: true, isCharging: true, fullyCharged: false, batteryWatts: 30.0,
        notChargingReason: 0),
      "Charging")
  }

  func testStatusCharged() {
    XCTAssertEqual(
      PowerStatus.text(
        onAC: true, isCharging: false, fullyCharged: true, batteryWatts: 0,
        notChargingReason: 0),
      "Charged")
  }

  func testStatusAdapterCannotKeepUp() {
    // The real state on the development machine: AC attached, not charging, and the pack is
    // supplying 5.7 W because the 30 W adapter is smaller than the 34 W load.
    XCTAssertEqual(
      PowerStatus.text(
        onAC: true, isCharging: false, fullyCharged: false, batteryWatts: -5.715,
        notChargingReason: 36_028_797_018_963_968),
      "Adapter can't keep up")
  }

  func testStatusNotChargingSurfacesTheRawCode() {
    // Held, but not because the adapter is undersized: report the code rather than invent a reason.
    XCTAssertEqual(
      PowerStatus.text(
        onAC: true, isCharging: false, fullyCharged: false, batteryWatts: -0.05,
        notChargingReason: 36_028_797_018_963_968),
      "Not charging · 0x80000000000000")
  }

  func testStatusNotChargingWithoutAReason() {
    XCTAssertEqual(
      PowerStatus.text(
        onAC: true, isCharging: false, fullyCharged: false, batteryWatts: 0,
        notChargingReason: 0),
      "Not charging")
    XCTAssertEqual(
      PowerStatus.text(
        onAC: true, isCharging: false, fullyCharged: false, batteryWatts: nil,
        notChargingReason: nil),
      "Not charging")
  }

  // MARK: - Condition

  func testConditionIsNormalWhenTheGradeIsGoodAndTheConditionIsBlank() {
    // IOPS reports BatteryHealthCondition as an empty string on a healthy pack; System Settings
    // renders that as "Normal".
    XCTAssertEqual(BatteryMetricsParser.condition(health: "Good", condition: ""), "Normal")
    XCTAssertEqual(BatteryMetricsParser.condition(health: "Good", condition: nil), "Normal")
  }

  func testConditionSurfacesARealFaultVerbatim() {
    XCTAssertEqual(
      BatteryMetricsParser.condition(health: "Poor", condition: "Service Recommended"),
      "Service Recommended")
    XCTAssertEqual(BatteryMetricsParser.condition(health: "Fair", condition: ""), "Fair")
  }

  func testConditionIsNilWhenNothingWasReported() {
    XCTAssertNil(BatteryMetricsParser.condition(health: nil, condition: nil))
    XCTAssertNil(BatteryMetricsParser.condition(health: "", condition: ""))
  }

  // MARK: - Whole snapshot

  func testParseOfTheRealSnapshot() throws {
    let m = BatteryMetricsParser.parse(
      smartBattery: Self.smartBattery,
      adapter: Self.adapter,
      powerSource: Self.powerSource,
      lowPowerMode: true)

    XCTAssertTrue(m.hasAny)
    XCTAssertEqual(m.healthPercent, 89)
    XCTAssertEqual(m.rawHealthPercent, 86)
    XCTAssertEqual(m.cycleCount, 224)
    XCTAssertEqual(m.designCycleCount, 1000)
    XCTAssertEqual(m.condition, "Normal")
    XCTAssertEqual(try XCTUnwrap(m.temperatureC), 30.68, accuracy: 0.0001)
    XCTAssertEqual(try XCTUnwrap(m.amperage), -0.322, accuracy: 0.0001)
    XCTAssertEqual(m.adapterWatts, 30)
    XCTAssertEqual(m.adapterDescription, "pd charger")
    XCTAssertEqual(m.pdLadder.count, 5)
    XCTAssertEqual(try XCTUnwrap(m.systemLoadWatts), 34.122, accuracy: 0.0001)
    XCTAssertEqual(m.notChargingReason, 36_028_797_018_963_968)
    XCTAssertTrue(m.lowPowerMode)
    XCTAssertEqual(m.externalConnected, true)
    XCTAssertNil(m.timeToFullMinutes)
    XCTAssertEqual(m.timeToEmptyMinutes, 142)
  }

  func testParseOfAnEmptyRegistryReadsNothing() {
    let m = BatteryMetricsParser.parse(
      smartBattery: [:], adapter: nil, powerSource: nil, lowPowerMode: false)
    XCTAssertFalse(m.hasAny)
    XCTAssertNil(m.condition)
    XCTAssertTrue(m.pdLadder.isEmpty)
  }

  // MARK: - Formatting

  func testTimeFormat() {
    XCTAssertEqual(PowerFormat.time(minutes: 0), "0m")
    XCTAssertEqual(PowerFormat.time(minutes: 45), "45m")
    XCTAssertEqual(PowerFormat.time(minutes: 59), "59m")
    XCTAssertEqual(PowerFormat.time(minutes: 60), "1h 00m")
    XCTAssertEqual(PowerFormat.time(minutes: 86), "1h 26m")
    XCTAssertEqual(PowerFormat.time(minutes: 142), "2h 22m")
    XCTAssertEqual(PowerFormat.time(minutes: 252), "4h 12m")
  }

  func testCapacityFormat() {
    XCTAssertEqual(PowerFormat.capacity(5381, of: 6249), "5381 / 6249 mAh")
    XCTAssertEqual(PowerFormat.capacity(5381, of: nil), "5381 mAh")
    XCTAssertEqual(PowerFormat.capacity(5381, of: 0), "5381 mAh")
    XCTAssertNil(PowerFormat.capacity(nil, of: 6249))
  }

  func testCyclesFormat() {
    XCTAssertEqual(PowerFormat.cycles(224, of: 1000), "224 / 1000")
    XCTAssertEqual(PowerFormat.cycles(224, of: nil), "224")
    XCTAssertEqual(PowerFormat.cycles(224, of: 0), "224")
  }

  func testWattsCarryTheirSign() {
    XCTAssertEqual(PowerFormat.watts(-3.607366), "-3.6 W")
    XCTAssertEqual(PowerFormat.watts(67.9), "+67.9 W")
    XCTAssertEqual(PowerFormat.watts(0), "+0.0 W")
    XCTAssertEqual(PowerFormat.wattsUnsigned(34.122), "34.1 W")
    XCTAssertEqual(PowerFormat.wattsUnsigned(0.696), "0.7 W")
  }

  func testAmpsVoltsAndTemperature() {
    XCTAssertEqual(PowerFormat.amps(-0.322), "-0.32 A")
    XCTAssertEqual(PowerFormat.amps(1.49), "+1.49 A")
    XCTAssertEqual(PowerFormat.volts(11.203), "11.20 V")
    XCTAssertEqual(PowerFormat.temperature(30.68), "30.7°C")
  }

  func testChargerSummary() {
    XCTAssertEqual(
      PowerFormat.chargerSummary(watts: 30, description: "pd charger"), "30 W · pd charger")
    XCTAssertEqual(PowerFormat.chargerSummary(watts: 30, description: nil), "30 W")
    XCTAssertEqual(PowerFormat.chargerSummary(watts: nil, description: "pd charger"), "pd charger")
    XCTAssertNil(PowerFormat.chargerSummary(watts: nil, description: nil))
  }

  func testLadderSummary() {
    let ladder = BatteryMetricsParser.pdLadder(from: Self.adapter["UsbHvcMenu"])
    XCTAssertEqual(
      PowerFormat.ladderSummary(ladder),
      "5V/2.96A · 9V/2.98A · 12V/2.48A · 15V/1.99A · 20V/1.49A")
    XCTAssertNil(PowerFormat.ladderSummary([]))
  }

  func testRemainingPrefersTimeToFullWhenCharging() {
    let full = PowerFormat.remaining(timeToFull: 86, timeToEmpty: 142)
    XCTAssertEqual(full?.label, "Full in")
    XCTAssertEqual(full?.value, "1h 26m")

    let empty = PowerFormat.remaining(timeToFull: nil, timeToEmpty: 142)
    XCTAssertEqual(empty?.label, "Left")
    XCTAssertEqual(empty?.value, "2h 22m")

    XCTAssertNil(PowerFormat.remaining(timeToFull: nil, timeToEmpty: nil))
  }

  // MARK: - Smoothing

  func testBlendWithoutAPreviousValueReturnsTheSample() throws {
    XCTAssertEqual(
      try XCTUnwrap(PowerSmoothing.blend(previous: nil, sample: 10)), 10, accuracy: 1e-9)
  }

  func testBlendMovesPartWayTowardTheSample() throws {
    XCTAssertEqual(
      try XCTUnwrap(PowerSmoothing.blend(previous: 10, sample: 20, factor: 0.5)), 15,
      accuracy: 1e-9)
    XCTAssertEqual(
      try XCTUnwrap(PowerSmoothing.blend(previous: 30.0, sample: 31.0, factor: 0.35)), 30.35,
      accuracy: 1e-9)
  }

  func testBlendDropsWhenTheSampleDisappears() {
    // Unplugging removes a key entirely; the panel must lose the tile, not keep a ghost value.
    XCTAssertNil(PowerSmoothing.blend(previous: 30, sample: nil))
  }

  func testBlendConvergesToExactEquality() throws {
    // An asymptote would defeat the Equatable diff in BatteryMonitor.refresh and republish forever,
    // so blend snaps to the sample once it is inside display precision.
    var value: Double? = 0
    for _ in 0..<40 { value = PowerSmoothing.blend(previous: value, sample: 100) }
    XCTAssertEqual(try XCTUnwrap(value), 100)
  }

  func testSmoothLeavesStableFieldsUntouched() throws {
    var old = BatteryMetrics()
    old.temperatureC = 30.0
    old.cycleCount = 224
    old.healthPercent = 89

    var new = BatteryMetrics()
    new.temperatureC = 31.0
    new.cycleCount = 225
    new.healthPercent = 88

    let out = PowerSmoothing.smooth(old, into: new)
    XCTAssertEqual(try XCTUnwrap(out.temperatureC), 30.35, accuracy: 1e-9)
    XCTAssertEqual(out.cycleCount, 225)
    XCTAssertEqual(out.healthPercent, 88)
  }

  func testSmoothWithNoPreviousSnapshotIsIdentity() {
    var new = BatteryMetrics()
    new.temperatureC = 31.0
    new.batteryPowerWatts = -5.715
    XCTAssertEqual(PowerSmoothing.smooth(nil, into: new), new)
  }

  // MARK: - Compact island

  func testBatterySymbolBuckets() {
    // SF Symbols only ships 0/25/50/75/100 fills, so the buckets are centred on those.
    XCTAssertEqual(BatteryActivity.batterySymbol(for: 0), "battery.0percent")
    XCTAssertEqual(BatteryActivity.batterySymbol(for: 12), "battery.0percent")
    XCTAssertEqual(BatteryActivity.batterySymbol(for: 13), "battery.25percent")
    XCTAssertEqual(BatteryActivity.batterySymbol(for: 37), "battery.25percent")
    XCTAssertEqual(BatteryActivity.batterySymbol(for: 38), "battery.50percent")
    XCTAssertEqual(BatteryActivity.batterySymbol(for: 62), "battery.50percent")
    XCTAssertEqual(BatteryActivity.batterySymbol(for: 63), "battery.75percent")
    XCTAssertEqual(BatteryActivity.batterySymbol(for: 87), "battery.75percent")
    XCTAssertEqual(BatteryActivity.batterySymbol(for: 88), "battery.100percent")
    XCTAssertEqual(BatteryActivity.batterySymbol(for: 100), "battery.100percent")
  }

  func testTintIsGreenWheneverPowerIsComingIn() {
    XCTAssertEqual(
      BatteryActivity.tint(for: BatteryState(percent: 8, isCharging: true, onAC: true)), .charging)
    XCTAssertEqual(
      BatteryActivity.tint(for: BatteryState(percent: 100, isCharging: false, onAC: true)),
      .charging)
  }

  func testTintIsRedOnBatteryUnderTwentyPercent() {
    XCTAssertEqual(
      BatteryActivity.tint(for: BatteryState(percent: 20, isCharging: false, onAC: false)), .low)
    XCTAssertEqual(
      BatteryActivity.tint(for: BatteryState(percent: 21, isCharging: false, onAC: false)),
      .normal)
  }

  func testTintIsNeutralWithoutAReading() {
    XCTAssertEqual(BatteryActivity.tint(for: nil), .normal)
  }

  @MainActor func testBatteryTabStaysActiveOffAC() {
    let saved = Defaults[.batteryEnabled]
    defer { Defaults[.batteryEnabled] = saved }

    // The monitor has never produced a state, so `onAC` is false. The tab must still be active.
    let activity = BatteryActivity()
    Defaults[.batteryEnabled] = true
    XCTAssertTrue(activity.isActive)
    Defaults[.batteryEnabled] = false
    XCTAssertFalse(activity.isActive)
  }

  // MARK: - Height tier

  @MainActor func testBatteryRequestsTheTallTier() {
    XCTAssertEqual(BatteryActivity().preferredExpandedHeight, Metrics.tallExpandedHeight)
    XCTAssertEqual(Metrics.tallExpandedHeight, 250)
  }
}
