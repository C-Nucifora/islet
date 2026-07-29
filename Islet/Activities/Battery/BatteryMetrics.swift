import Foundation

/// One rung of the USB-C Power Delivery ladder the attached charger advertises
/// (`AdapterDetails.UsbHvcMenu`), in volts and amps.
struct PDProfile: Identifiable, Equatable {
  let index: Int
  let volts: Double
  let amps: Double

  var id: Int { index }
  var watts: Double { volts * amps }
}

/// Deep battery, charger and power-flow telemetry, read from AppleSmartBattery, IOPS and
/// ProcessInfo.
///
/// Every reading is optional on purpose. Most of these registry keys are undocumented and several
/// are absent on machines other than the one this was developed against, so the panel omits a tile
/// rather than rendering a zero for something it never read. `hasAny` is the "did we read anything
/// worth showing at all" test that decides whether the metrics block appears.
struct BatteryMetrics: Equatable {
  // Health. Two numbers, deliberately: `healthPercent` matches System Settings → Battery,
  // `rawHealthPercent` matches AlDente and coconutBattery. They disagree by 2-3 points and both
  // are shown, labelled, so neither reads as a bug.
  var healthPercent: Int?  // NominalChargeCapacity / DesignCapacity
  var rawHealthPercent: Int?  // AppleRawMaxCapacity / DesignCapacity
  var rawMaxCapacityMAh: Int?
  var nominalCapacityMAh: Int?
  var designCapacityMAh: Int?
  var cycleCount: Int?
  var designCycleCount: Int?  // DesignCycleCount9C
  var condition: String?  // IOPS BatteryHealthCondition, else the BatteryHealth grade

  // Instantaneous pack readings.
  var temperatureC: Double?
  var voltage: Double?  // V
  var amperage: Double?  // A, negative while discharging
  var powerWatts: Double?  // voltage * amperage, negative while discharging
  var timeToFullMinutes: Int?
  var timeToEmptyMinutes: Int?

  // The attached charger.
  var adapterWatts: Int?
  var adapterDescription: String?
  var adapterVolts: Double?
  var adapterAmps: Double?
  var adapterIsWireless: Bool?
  var adapterPowerTier: Int?
  var pdLadder: [PDProfile] = []
  var pdSelectedIndex: Int?

  // Power flow, from the undocumented PowerTelemetryData dictionary. All watts.
  var systemPowerInWatts: Double?  // SystemPowerIn — what the wall is delivering
  var systemVoltageIn: Double?
  var systemCurrentIn: Double?
  var systemLoadWatts: Double?  // SystemLoad — what the machine is drawing
  var batteryPowerWatts: Double?  // BatteryPower — + into the pack, - out of it
  var adapterLossWatts: Double?  // AdapterEfficiencyLoss

  // Charge state.
  var isCharging: Bool?
  var fullyCharged: Bool?
  var externalConnected: Bool?
  var notChargingReason: UInt64?

  var lowPowerMode = false

  /// True when at least one real reading landed. Low Power Mode is excluded — it is a system flag,
  /// not a battery reading, and on its own it should not make an empty panel appear.
  var hasAny: Bool {
    healthPercent != nil || rawHealthPercent != nil || cycleCount != nil
      || temperatureC != nil || voltage != nil || amperage != nil || powerWatts != nil
      || timeToFullMinutes != nil || timeToEmptyMinutes != nil
      || adapterWatts != nil || adapterDescription != nil
      || systemPowerInWatts != nil || batteryPowerWatts != nil
  }
}
