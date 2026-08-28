import Foundation

/// Turns the raw AppleSmartBattery / IOPS dictionaries into `BatteryMetrics`.
///
/// Deliberately actor-free and IOKit-free: it takes plain dictionaries so every rule in here is a
/// pure function the tests can drive without hardware. `SmartBatteryReader` is the only thing that
/// knows where the dictionaries come from.
enum BatteryMetricsParser {

  // MARK: - Health, capacity, cycles

  static func applyHealth(_ m: inout BatteryMetrics, from p: [String: Any]) {
    let design = int(p, "DesignCapacity").flatMap { $0 > 0 ? $0 : nil }
    m.designCapacityMAh = design
    m.nominalCapacityMAh = int(p, "NominalChargeCapacity")
    m.rawMaxCapacityMAh = int(p, "AppleRawMaxCapacity")

    if let design {
      if let nominal = m.nominalCapacityMAh { m.healthPercent = percentage(nominal, of: design) }
      if let raw = m.rawMaxCapacityMAh { m.rawHealthPercent = percentage(raw, of: design) }
    }

    m.cycleCount = int(p, "CycleCount")
    m.designCycleCount = int(p, "DesignCycleCount9C").flatMap { $0 > 0 ? $0 : nil }
  }

  /// Rounded percentage, or nil when the denominator is unusable.
  static func percentage(_ value: Int, of total: Int) -> Int? {
    guard total > 0 else { return nil }
    return Int((Double(value) / Double(total) * 100).rounded())
  }

  // MARK: - Instantaneous pack readings

  static func applyInstant(_ m: inout BatteryMetrics, from p: [String: Any]) {
    // Reported in centi-degrees Celsius.
    if let raw = int(p, "Temperature") { m.temperatureC = Double(raw) / 100.0 }
    if let mV = int(p, "Voltage") { m.voltage = Double(mV) / 1000.0 }

    // InstantAmperage is the un-averaged figure AlDente shows; Amperage is the smoothed one.
    // Both use the same two's-complement encoding.
    let mA =
      IORegistryReader.signedInt(int(p, "InstantAmperage"))
      ?? IORegistryReader.signedInt(int(p, "Amperage"))
    if let mA { m.amperage = Double(mA) / 1000.0 }

    if let v = m.voltage, let a = m.amperage { m.powerWatts = v * a }

    // 65535 is the "still calculating" sentinel; 0 means "not applicable right now".
    if let ttf = int(p, "AvgTimeToFull"), ttf > 0, ttf < 65535 { m.timeToFullMinutes = ttf }
    if let tte = int(p, "AvgTimeToEmpty"), tte > 0, tte < 65535 { m.timeToEmptyMinutes = tte }
  }

  // MARK: - Charger

  static func applyCharger(_ m: inout BatteryMetrics, from adapter: [String: Any]?) {
    guard let adapter, !adapter.isEmpty else { return }
    if let w = int(adapter, "Watts"), w > 0 { m.adapterWatts = w }
    if let d = adapter["Description"] as? String, !d.isEmpty { m.adapterDescription = d }
    if let mV = int(adapter, "AdapterVoltage"), mV > 0 { m.adapterVolts = Double(mV) / 1000.0 }
    if let mA = int(adapter, "Current"), mA > 0 { m.adapterAmps = Double(mA) / 1000.0 }
    m.adapterIsWireless = bool(adapter, "IsWireless")
    m.adapterPowerTier = int(adapter, "AdapterPowerTier")
    m.pdSelectedIndex = int(adapter, "UsbHvcHvcIndex")
    m.pdLadder = pdLadder(from: adapter["UsbHvcMenu"])
  }

  /// The negotiated USB-C PD ladder. Undocumented and absent on non-PD chargers, so a missing or
  /// unexpectedly shaped value yields an empty ladder rather than a failure.
  static func pdLadder(from raw: Any?) -> [PDProfile] {
    guard let entries = raw as? [[String: Any]] else { return [] }
    return
      entries
      .compactMap { entry -> PDProfile? in
        guard let mV = int(entry, "MaxVoltage"), mV > 0,
          let mA = int(entry, "MaxCurrent"), mA > 0
        else { return nil }
        return PDProfile(
          index: int(entry, "Index") ?? 0,
          volts: Double(mV) / 1000.0,
          amps: Double(mA) / 1000.0)
      }
      .sorted { $0.index < $1.index }
  }

  // MARK: - Power flow

  /// `PowerTelemetryData` is entirely undocumented and absent on some machines. Everything in it is
  /// milli-units; `BatteryPower` is signed, positive into the pack and negative out of it.
  static func applyTelemetry(_ m: inout BatteryMetrics, from p: [String: Any]) {
    guard let t = p["PowerTelemetryData"] as? [String: Any] else { return }
    if let mW = int(t, "SystemPowerIn") { m.systemPowerInWatts = Double(mW) / 1000.0 }
    if let mV = int(t, "SystemVoltageIn") { m.systemVoltageIn = Double(mV) / 1000.0 }
    if let mA = int(t, "SystemCurrentIn") { m.systemCurrentIn = Double(mA) / 1000.0 }
    if let mW = int(t, "SystemLoad") { m.systemLoadWatts = Double(mW) / 1000.0 }
    if let mW = IORegistryReader.signedInt(int(t, "BatteryPower")) {
      m.batteryPowerWatts = Double(mW) / 1000.0
    }
    if let mW = int(t, "AdapterEfficiencyLoss") { m.adapterLossWatts = Double(mW) / 1000.0 }
  }

  /// `PowerOutDetails` is macOS's per-port measurement for power the Mac provides to USB devices.
  /// It is absent (or an empty array) when no port is sourcing power. Despite the historical key
  /// name `Watts`, captures and the accumulator alongside it establish that this value is mW.
  static func applyPowerOutputs(_ m: inout BatteryMetrics, from p: [String: Any]) {
    guard let entries = p["PowerOutDetails"] as? [[String: Any]] else { return }
    m.usbPowerOutputs = entries.compactMap { entry in
      guard let port = int(entry, "PortIndex"), let milliwatts = int(entry, "Watts"),
        milliwatts > 0
      else { return nil }
      return USBPowerOutput(
        portIndex: port,
        watts: Double(milliwatts) / 1000.0,
        volts: int(entry, "AdapterVoltage").map { Double($0) / 1000.0 },
        amps: int(entry, "Current").map { Double($0) / 1000.0 })
    }
    .sorted { $0.portIndex < $1.portIndex }
  }

  // MARK: - Charge state

  static func applyChargeState(_ m: inout BatteryMetrics, from p: [String: Any]) {
    m.isCharging = bool(p, "IsCharging")
    m.fullyCharged = bool(p, "FullyCharged")
    m.externalConnected = bool(p, "ExternalConnected")
    if let charger = p["ChargerData"] as? [String: Any] {
      m.notChargingReason = uint64(charger, "NotChargingReason")
    }
  }

  // MARK: - Condition

  /// IOPS reports `BatteryHealthCondition` as an empty string on a healthy pack and a real string
  /// ("Service Recommended", "Permanent Battery Failure") when something is wrong. When it is blank
  /// we fall back to the `BatteryHealth` grade, translating the healthy grade into the word System
  /// Settings uses. Any non-"Good" grade is surfaced verbatim so a fault is never hidden.
  static func condition(health: String?, condition: String?) -> String? {
    if let condition, !condition.isEmpty { return condition }
    guard let health, !health.isEmpty else { return nil }
    return health == "Good" ? "Normal" : health
  }

  // MARK: - Whole snapshot

  static func parse(
    smartBattery: [String: Any],
    adapter: [String: Any]?,
    powerSource: [String: Any]?,
    lowPowerMode: Bool
  ) -> BatteryMetrics {
    var m = BatteryMetrics()
    applyHealth(&m, from: smartBattery)
    applyInstant(&m, from: smartBattery)
    applyCharger(&m, from: adapter)
    applyTelemetry(&m, from: smartBattery)
    applyPowerOutputs(&m, from: smartBattery)
    applyChargeState(&m, from: smartBattery)
    if let powerSource {
      m.condition = condition(
        health: powerSource["BatteryHealth"] as? String,
        condition: powerSource["BatteryHealthCondition"] as? String)
    }
    m.lowPowerMode = lowPowerMode
    return m
  }

  // MARK: - Typed dictionary access

  static func int(_ p: [String: Any], _ key: String) -> Int? {
    (p[key] as? NSNumber)?.intValue
  }

  static func uint64(_ p: [String: Any], _ key: String) -> UInt64? {
    (p[key] as? NSNumber)?.uint64Value
  }

  static func bool(_ p: [String: Any], _ key: String) -> Bool? {
    (p[key] as? NSNumber)?.boolValue
  }
}
