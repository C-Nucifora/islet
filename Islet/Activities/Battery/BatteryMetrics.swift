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

/// Live power the Mac is sourcing to a peripheral through one USB-C port. AppleSmartBattery
/// publishes these entries only while power is flowing out; the values are milli-units.
struct USBPowerOutput: Identifiable, Equatable {
  let portIndex: Int
  var watts: Double
  let volts: Double?
  let amps: Double?

  var id: Int { portIndex }
}

/// Deep battery, charger and power-flow telemetry, read from AppleSmartBattery, IOPS and
/// ProcessInfo.
///
/// Every reading is optional on purpose. Most of these registry keys are undocumented and several
/// are absent on machines other than the one this was developed against, so the panel omits a tile
/// rather than rendering a zero for something it never read. `hasAny` is the "did we read anything
/// worth showing at all" test that decides whether the metrics block appears.
struct BatteryMetrics: Equatable {
  // Health. Two numbers, deliberately, because there is no single right one.
  //
  // `healthPercent` is NominalChargeCapacity/DesignCapacity — the closest thing to what System
  // Settings → Battery shows, but NOT identical to it. Measured on this machine: the ratio gives
  // 88% (5511/6249) while System Settings says 90%, and NominalChargeCapacity itself drifts between
  // samples (5533 an hour earlier). macOS evidently smooths or latches its figure, and no public
  // IOKit key reproduces it — `MaxCapacity` is a percentage sentinel fixed at 100 on Apple Silicon.
  //
  // `rawHealthPercent` is AppleRawMaxCapacity/DesignCapacity, which is what AlDente and
  // coconutBattery show — 86% here.
  //
  // Both are displayed, labelled, so a reading that disagrees with another tool reads as a
  // different definition rather than as a bug.
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
  /// `ParentPortTypeDescription` from the active IOPortFeaturePowerSource node.
  var inputPortType: String?

  // Power flow, from the undocumented PowerTelemetryData dictionary. All watts.
  var systemPowerInWatts: Double?  // SystemPowerIn — what the wall is delivering
  var systemVoltageIn: Double?
  var systemCurrentIn: Double?
  var systemLoadWatts: Double?  // SystemLoad — what the machine is drawing
  var batteryPowerWatts: Double?  // BatteryPower — + into the pack, - out of it
  var adapterLossWatts: Double?  // AdapterEfficiencyLoss
  var usbPowerOutputs: [USBPowerOutput] = []  // PowerOutDetails, one entry per sourcing port

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
      || systemPowerInWatts != nil || batteryPowerWatts != nil || !usbPowerOutputs.isEmpty
  }
}
