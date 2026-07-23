import Foundation
import IOKit

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
  static func read() -> BatteryMetrics? {
    let service = IOServiceGetMatchingService(
      kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
    guard service != 0 else { return nil }
    defer { IOObjectRelease(service) }

    func intVal(_ key: String) -> Int? {
      guard
        let prop = IORegistryEntryCreateCFProperty(
          service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
      else { return nil }
      return (prop as? NSNumber)?.intValue
    }

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
    if let mV = intVal("Voltage"), let mA = signedAmperage(intVal("Amperage")) {
      m.powerWatts = Double(mV) / 1000.0 * Double(mA) / 1000.0
    }
    // 65535 is the "still calculating" sentinel.
    if let ttf = intVal("AvgTimeToFull"), ttf > 0, ttf < 65535 { m.timeToFullMinutes = ttf }
    if let tte = intVal("AvgTimeToEmpty"), tte > 0, tte < 65535 { m.timeToEmptyMinutes = tte }
    if let adapter = IORegistryEntryCreateCFProperty(
      service, "AdapterDetails" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
      as? [String: Any],
      let watts = adapter["Watts"] as? Int, watts > 0
    {
      m.adapterWatts = watts
    }

    return m.hasAny ? m : nil
  }

  /// AppleSmartBattery reports amperage as a 64-bit value; large values are negative (discharge).
  private static func signedAmperage(_ raw: Int?) -> Int? {
    guard let raw else { return nil }
    if raw > Int(Int32.max) { return raw - Int(UInt32.max) - 1 }
    return raw
  }
}
