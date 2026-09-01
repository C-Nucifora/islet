import Foundation

/// The logical readings that make up the expanded battery diagnostics. A registry key can be
/// absent because a Mac does not publish it, while a present key can still fail to produce a
/// usable value in one sample. Keeping those states separate stops the UI from calling every
/// blank value a hardware limitation.
enum BatteryTelemetryField: String, CaseIterable, Hashable, Identifiable, Sendable {
  case health
  case temperature
  case voltage
  case current
  case timeToFull
  case timeToEmpty
  case charger
  case systemInput
  case systemLoad
  case batteryPower
  case usbPowerOutput
  case cpuPower

  var id: String { rawValue }

  var label: String {
    switch self {
    case .health: return "Battery health"
    case .temperature: return "Temperature"
    case .voltage: return "Voltage"
    case .current: return "Current"
    case .timeToFull: return "Time to full"
    case .timeToEmpty: return "Time remaining"
    case .charger: return "Charger details"
    case .systemInput: return "System input"
    case .systemLoad: return "System load"
    case .batteryPower: return "Battery power"
    case .usbPowerOutput: return "USB power output"
    case .cpuPower: return "CPU power"
    }
  }
}

/// What the last read told us about one advanced battery value. `unsupported` is reserved for a
/// key the service did not publish. A present but unusable value remains an unavailable sample so
/// it is not mistaken for a hardware capability decision.
enum BatteryTelemetryStatus: Equatable, Sendable {
  case available
  case unsupported
  case unavailable(BatteryTelemetryUnavailableReason)

  var diagnosticReason: String {
    switch self {
    case .available: return "Available"
    case .unsupported: return "Not reported by this Mac"
    case .unavailable(let reason): return reason.diagnosticReason
    }
  }
}

enum BatteryTelemetryUnavailableReason: Equatable, Sendable {
  case unreadable
  case calculating
  case inactive
  case stale
  case noSample
  case transient

  var diagnosticReason: String {
    switch self {
    case .unreadable: return "Last value could not be read"
    case .calculating: return "Still calculating"
    case .inactive: return "Not active right now"
    case .stale: return "Last sample is stale"
    case .noSample: return "No sample yet"
    case .transient: return "Temporarily unavailable"
    }
  }
}

/// One rung of the USB-C Power Delivery ladder the attached charger advertises
/// (`AdapterDetails.UsbHvcMenu`), in volts and amps.
struct PDProfile: Identifiable, Equatable, Sendable {
  let index: Int
  let volts: Double
  let amps: Double

  var id: Int { index }
  var watts: Double { volts * amps }
}

/// Live power the Mac is sourcing to a peripheral through one USB-C port. AppleSmartBattery
/// publishes these entries only while power is flowing out; the values are milli-units.
struct USBPowerOutput: Identifiable, Equatable, Sendable {
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
struct BatteryMetrics: Equatable, Sendable {
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

  // Power flow, from undocumented AppleSmartBattery and IOReport telemetry. All watts.
  var systemPowerInWatts: Double?  // SystemPowerIn — what the wall is delivering
  var systemVoltageIn: Double?
  var systemCurrentIn: Double?
  var systemLoadWatts: Double?  // SystemLoad — what the machine is drawing
  var cpuPowerWatts: Double?  // IOReport Energy Model — estimated aggregate CPU power
  var batteryPowerWatts: Double?  // BatteryPower — + into the pack, - out of it
  var adapterLossWatts: Double?  // AdapterEfficiencyLoss
  var usbPowerOutputs: [USBPowerOutput] = []  // PowerOutDetails, one entry per sourcing port

  // Charge state.
  var isCharging: Bool?
  var fullyCharged: Bool?
  var externalConnected: Bool?
  var notChargingReason: UInt64?

  var lowPowerMode = false

  /// The support and last-read state for the fields in the expanded diagnostics. The parser fills
  /// every entry whenever it receives an AppleSmartBattery dictionary. Empty test fixtures and
  /// manually-seeded previews may leave this empty rather than claiming an unperformed read.
  var telemetryStatus: [BatteryTelemetryField: BatteryTelemetryStatus] = [:]

  /// Fields that have produced a usable value during this monitor session. This survives a later
  /// partial registry read so a transient omission is not presented as a hardware limitation.
  var observedTelemetryFields: Set<BatteryTelemetryField> = []

  mutating func reconcileTelemetryCapability(from previous: BatteryMetrics?) {
    if let previous {
      observedTelemetryFields.formUnion(previous.observedTelemetryFields)
      observedTelemetryFields.formUnion(previous.availableTelemetryFields)
    }
    observedTelemetryFields.formUnion(availableTelemetryFields)
    for field in observedTelemetryFields where telemetryStatus[field] == .unsupported {
      telemetryStatus[field] = .unavailable(.transient)
    }
  }

  private var availableTelemetryFields: Set<BatteryTelemetryField> {
    Set(telemetryStatus.compactMap { field, status in status == .available ? field : nil })
  }

  func status(for field: BatteryTelemetryField) -> BatteryTelemetryStatus? {
    telemetryStatus[field]
  }

  var unavailableTelemetry: [(field: BatteryTelemetryField, status: BatteryTelemetryStatus)] {
    BatteryTelemetryField.allCases.compactMap { field in
      guard let status = status(for: field), status != .available else { return nil }
      return (field, status)
    }
  }

  /// True when at least one real reading landed. Low Power Mode is excluded — it is a system flag,
  /// not a battery reading, and on its own it should not make an empty panel appear.
  var hasAny: Bool {
    healthPercent != nil || rawHealthPercent != nil || cycleCount != nil
      || temperatureC != nil || voltage != nil || amperage != nil || powerWatts != nil
      || timeToFullMinutes != nil || timeToEmptyMinutes != nil
      || adapterWatts != nil || adapterDescription != nil
      || systemPowerInWatts != nil || cpuPowerWatts != nil || batteryPowerWatts != nil
      || !usbPowerOutputs.isEmpty
  }
}
