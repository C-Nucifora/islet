import Foundation

/// The only place in the battery stack that talks to IOKit. Everything it reads is handed to
/// `BatteryMetricsParser`, which is pure and tested.
///
/// Interim shape: Task 10 widens this to read IOPS and ProcessInfo too. It exists now so
/// `BatteryMonitor.refresh()` keeps compiling while the parser is built up task by task.
enum SmartBatteryReader {
  static func read() -> BatteryMetrics? {
    guard let props = IORegistryReader.properties(matching: "AppleSmartBattery") else {
      return nil
    }
    var m = BatteryMetrics()
    BatteryMetricsParser.applyHealth(&m, from: props)
    BatteryMetricsParser.applyInstant(&m, from: props)
    BatteryMetricsParser.applyCharger(&m, from: props["AdapterDetails"] as? [String: Any])
    BatteryMetricsParser.applyTelemetry(&m, from: props)
    return m.hasAny ? m : nil
  }
}
