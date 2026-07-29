import Foundation

/// AlDente-style deep battery metrics read from the AppleSmartBattery IORegistry entry.
struct BatteryMetrics: Equatable {
  var healthPercent: Int?  // maxCapacity / designCapacity
  var cycleCount: Int?
  var temperatureC: Double?
  var powerWatts: Double?  // + charging into the battery, - discharging
  var timeToFullMinutes: Int?
  var timeToEmptyMinutes: Int?
  var adapterWatts: Int?  // rated wattage of the connected power adapter

  var hasAny: Bool {
    healthPercent != nil || cycleCount != nil || temperatureC != nil
      || powerWatts != nil || timeToFullMinutes != nil || timeToEmptyMinutes != nil
      || adapterWatts != nil
  }
}

enum SmartBatteryReader {
  /// One bulk IORegistry read of AppleSmartBattery, then a pure parse. Returns nil on a machine
  /// with no battery.
  static func read() -> BatteryMetrics? {
    guard let props = IORegistryReader.properties(matching: "AppleSmartBattery") else {
      return nil
    }
    return metrics(from: props)
  }

  /// Pure parse of one AppleSmartBattery property dictionary. Split out of `read()` so the health
  /// formula, the unit conversions and the sentinels can be tested against literal dictionaries
  /// instead of whatever the machine's battery happens to be doing.
  static func metrics(from props: [String: Any]) -> BatteryMetrics? {
    func intVal(_ key: String) -> Int? { (props[key] as? NSNumber)?.intValue }

    var m = BatteryMetrics()

    if let maxCap = intVal("AppleRawMaxCapacity") ?? intVal("MaxCapacity"),
      let design = intVal("DesignCapacity"), design > 0
    {
      m.healthPercent = Int((Double(maxCap) / Double(design) * 100).rounded())
    }
    m.cycleCount = intVal("CycleCount")
    if let rawTemp = intVal("Temperature") {
      m.temperatureC = Double(rawTemp) / 100.0  // reported in centi-degrees
    }
    if let mV = intVal("Voltage"), let mA = IORegistryReader.signedInt(intVal("Amperage")) {
      m.powerWatts = Double(mV) / 1000.0 * Double(mA) / 1000.0
    }
    // 65535 is the "still calculating" sentinel.
    if let ttf = intVal("AvgTimeToFull"), ttf > 0, ttf < 65535 { m.timeToFullMinutes = ttf }
    if let tte = intVal("AvgTimeToEmpty"), tte > 0, tte < 65535 { m.timeToEmptyMinutes = tte }
    if let adapter = props["AdapterDetails"] as? [String: Any],
      let watts = (adapter["Watts"] as? NSNumber)?.intValue, watts > 0
    {
      m.adapterWatts = watts
    }

    return m.hasAny ? m : nil
  }
}
