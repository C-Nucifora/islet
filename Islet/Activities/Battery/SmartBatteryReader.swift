import Foundation
import IOKit.ps

/// The only place in the battery stack that touches IOKit, IOPS or ProcessInfo. It gathers the
/// three dictionaries and hands them straight to `BatteryMetricsParser`, which is pure and tested.
///
/// One bulk `IORegistryEntryCreateCFProperties` replaces the per-key reads this used to do. That
/// call also drags in some large blobs (`RaTableRaw`, `PortControllerInfo`), but it is a single
/// round trip at 1 Hz and the alternative was a dozen.
enum SmartBatteryReader {
  static func read() -> BatteryMetrics? {
    guard let props = IORegistryReader.properties(matching: "AppleSmartBattery") else { return nil }

    // The registry dict is primary: it carries the description ("pd charger") and the negotiated
    // PD ladder, which the public IOPS dict strips down to little more than the wattage — showing
    // a bare "50 W" charger tile with no tooltip. IOPS remains the fallback for the moment right
    // after a plug-in when the registry key has not appeared yet.
    let adapter = (props["AdapterDetails"] as? [String: Any]) ?? externalAdapterDetails()

    var metrics = BatteryMetricsParser.parse(
      smartBattery: props,
      adapter: adapter,
      powerSource: primaryPowerSource(),
      lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled)
    metrics.inputPortType = PowerConnectorReader.activeInputPortType()

    return metrics.hasAny ? metrics : nil
  }

  /// The active USB-PD input connector. A winning option identifies USB-C; MagSafe often exposes
  /// only its option list, so it is used when it is the sole receiving connector. Older machines
  /// omit these nodes and simply fall back to the adapter description in the UI.
  private enum PowerConnectorReader {
    static func activeInputPortType() -> String? {
      let candidates = IORegistryReader.allProperties(matching: "IOPortFeaturePowerSource")
        .compactMap { props -> (type: String, winning: Bool, watts: Int)? in
          guard props["PowerSourceName"] as? String == "USB-PD",
            let type = props["ParentPortTypeDescription"] as? String,
            !type.isEmpty
          else { return nil }
          let winning = props["WinningPowerSourceOption"] as? [String: Any]
          let options = props["PowerSourceOptions"] as? [[String: Any]] ?? []
          let winningWatts = (winning?["Max Power (mW)"] as? NSNumber)?.intValue ?? 0
          let optionWatts = options.compactMap {
            ($0["Max Power (mW)"] as? NSNumber)?.intValue
          }.max() ?? 0
          return (type, winningWatts > 0, max(winningWatts, optionWatts))
        }
        .filter { $0.watts > 0 }
      if let winner = candidates.first(where: { $0.winning }) { return winner.type }
      return candidates.count == 1 ? candidates[0].type : nil
    }
  }

  /// `IOPSCopyExternalPowerAdapterDetails` returns nil on battery power.
  private static func externalAdapterDetails() -> [String: Any]? {
    guard
      let details = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any],
      !details.isEmpty
    else { return nil }
    return details
  }

  /// The IOPS description of the internal battery, for `BatteryHealth` / `BatteryHealthCondition`.
  private static func primaryPowerSource() -> [String: Any]? {
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
      let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef],
      let source = list.first
    else { return nil }
    return IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any]
  }
}
