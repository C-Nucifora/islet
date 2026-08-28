import Foundation
import IOKit.ps

/// Chooses the Mac's internal pack from IOPS descriptions. UPS batteries can appear first in the
/// API's list; treating `list.first` as the Mac battery reports the UPS charge and health in the
/// notch whenever one is attached.
enum IOPSPowerSourceSelector {
  static func internalBattery(in descriptions: [[String: Any]]) -> [String: Any]? {
    descriptions.first {
      ($0[kIOPSTypeKey] as? String) == (kIOPSInternalBatteryType as String)
    }
  }
}

/// The only place in the battery stack that touches IOKit, IOPS or ProcessInfo. It gathers the
/// three dictionaries and hands them straight to `BatteryMetricsParser`, which is pure and tested.
///
/// Reads are split into live telemetry and stable health/topology fields. The reader asks IOKit
/// only for properties Islet displays, rather than bridging the node's large calibration and
/// controller blobs into Swift on every sample.
enum SmartBatteryReader {
  private static let liveKeys = [
    "Temperature", "Voltage", "InstantAmperage", "Amperage", "AvgTimeToFull",
    "AvgTimeToEmpty", "AdapterDetails", "PowerTelemetryData", "PowerOutDetails",
    "IsCharging", "FullyCharged", "ExternalConnected", "ChargerData",
  ]
  private static let stableKeys = [
    "DesignCapacity", "NominalChargeCapacity", "AppleRawMaxCapacity", "CycleCount",
    "DesignCycleCount9C",
  ]

  static func read(includeStable: Bool = true) -> BatteryMetrics? {
    let keys = includeStable ? liveKeys + stableKeys : liveKeys
    guard
      let props = IORegistryReader.properties(matching: "AppleSmartBattery", keys: keys)
    else { return nil }

    // IOReport is sampled only after confirming this Mac has an internal battery. It is a private,
    // optional estimate, so failure never prevents the public/IOKit battery snapshot from landing.
    let cpuPowerWatts = CPUPowerReader.shared.readWatts()

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
    metrics.cpuPowerWatts = cpuPowerWatts
    if includeStable { metrics.inputPortType = PowerConnectorReader.activeInputPortType() }

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
          let optionWatts =
            options.compactMap {
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
      let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
    else { return nil }
    let descriptions = list.compactMap {
      IOPSGetPowerSourceDescription(info, $0)?.takeUnretainedValue() as? [String: Any]
    }
    return IOPSPowerSourceSelector.internalBattery(in: descriptions)
  }
}
