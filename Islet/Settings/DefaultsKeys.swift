import Defaults
import Foundation

enum HUDStyle: String, CaseIterable, Codable { case bar, gauge }

/// Controls how aggressively Islet refreshes sources that can wake the CPU or radios.
///
/// Automatic follows macOS Low Power Mode. Low Energy is an explicit always-constrained profile;
/// Live keeps user-visible data especially fresh and is the only profile that overrides macOS Low
/// Power Mode for optional remote polling.
enum EnergyMode: String, CaseIterable, Codable, Sendable {
  case automatic
  case lowEnergy
  case live
}

/// Pure cadence policy shared by the battery, system and T3 monitors. Keeping these decisions in
/// one value makes profile changes atomic and lets tests cover the energy contract without
/// starting timers or touching hardware.
struct EnergyPolicy: Equatable, Sendable {
  let mode: EnergyMode
  let systemLowPowerMode: Bool

  var isConstrained: Bool {
    mode == .lowEnergy || (mode == .automatic && systemLowPowerMode)
  }

  var allowsRemotePolling: Bool {
    mode == .live || !isConstrained
  }

  func batteryInterval(viewIsLive: Bool) -> TimeInterval {
    switch mode {
    case .live: return viewIsLive ? 3 : 15
    case .lowEnergy: return viewIsLive ? 30 : 120
    case .automatic:
      if systemLowPowerMode { return viewIsLive ? 30 : 120 }
      return viewIsLive ? 12 : 60
    }
  }

  var batteryStableInterval: TimeInterval {
    switch mode {
    case .live: 2 * 60
    case .lowEnergy: 10 * 60
    case .automatic: systemLowPowerMode ? 10 * 60 : 5 * 60
    }
  }

  func systemInterval(viewIsLive: Bool) -> TimeInterval {
    switch mode {
    case .live: return viewIsLive ? 0.5 : 5
    case .lowEnergy: return viewIsLive ? 3 : 45
    case .automatic:
      if systemLowPowerMode { return viewIsLive ? 3 : 30 }
      return viewIsLive ? 1 : 20
    }
  }

  func t3PollInterval(busy: Bool, expanded: Bool) -> TimeInterval {
    if isConstrained { return 30 }
    if mode == .live {
      if expanded { return busy ? 2 : 3 }
      return busy ? 3 : 6
    }
    if expanded { return busy ? 3 : 5 }
    return busy ? 5 : 12
  }

  var tunnelPollingInterval: TimeInterval {
    if isConstrained { return 30 }
    return mode == .live ? 2 : 10
  }
}

extension InteractionMode: Defaults.Serializable {}
extension MediaSourceMode: Defaults.Serializable {}
extension HUDStyle: Defaults.Serializable {}
extension EnergyMode: Defaults.Serializable {}

extension Defaults.Keys {
  static let mediaSourceMode = Key<MediaSourceMode>("mediaSourceMode", default: .auto)
  static let mediaPriorityList = Key<[String]>(
    "mediaPriorityList",
    default: ["com.spotify.client", "com.apple.Music"])
  static let interactionMode = Key<InteractionMode>("interactionMode", default: .hover)
  static let hoverCollapseTimeout = Key<Double>("hoverCollapseTimeout", default: 0.5)
  static let hapticsEnabled = Key<Bool>("hapticsEnabled", default: true)
  static let energyMode = Key<EnergyMode>("energyMode", default: .automatic)
  static let hideFromScreenRecording = Key<Bool>("hideFromScreenRecording", default: false)
  static let batteryEnabled = Key<Bool>("batteryEnabled", default: true)
  static let hudEnabled = Key<Bool>("hudEnabled", default: false)
  static let hudStyle = Key<HUDStyle>("hudStyle", default: .bar)
  static let calendarEnabled = Key<Bool>("calendarEnabled", default: true)
  static let calendarLeadMinutes = Key<Int>("calendarLeadMinutes", default: 10)
  static let remindersEnabled = Key<Bool>("remindersEnabled", default: true)
  static let airpodsEnabled = Key<Bool>("airpodsEnabled", default: false)
  static let showOnAllDisplays = Key<Bool>("showOnAllDisplays", default: false)
  static let hideInFullscreen = Key<Bool>("hideInFullscreen", default: false)
  static let launchAtLogin = Key<Bool>("launchAtLogin", default: false)
  static let activityOrder = Key<[String]>("activityOrder", default: ActivityCatalog.defaultOrder)
  static let disabledActivities = Key<[String]>("disabledActivities", default: [])
  static let clipboardEnabled = Key<Bool>("clipboardEnabled", default: false)
  static let portsEnabled = Key<Bool>("portsEnabled", default: true)
  /// Event sources the user has switched off. Absent means on — every source ships enabled, and a
  /// disabled source is fully stopped rather than merely silenced.
  static let disabledEventSources = Key<[String]>("disabledEventSources", default: [])
  static let systemEnabled = Key<Bool>("systemEnabled", default: true)
  /// Off: the System tab appears only while `SystemPresenceGate` is hot. On: it is always in the
  /// switcher, which is how you look at an idle machine's stats.
  static let systemAlwaysVisible = Key<Bool>("systemAlwaysVisible", default: false)
  /// Keyed by `SystemMetricKind.rawValue`, valued by `MetricDisplayStyle.rawValue`. Stored as
  /// strings so an unknown value from a future build resolves to the fallback instead of failing
  /// to decode the whole dictionary.
  static let metricStyles = Key<[String: String]>("metricStyles", default: [:])
  static let continuityEnabled = Key<Bool>("continuityEnabled", default: true)
  /// Off: the iPhone tab appears only while the phone has something running. On: it stays in the
  /// switcher so the empty state can explain why nothing is arriving. Mirrors `systemAlwaysVisible`.
  static let continuityAlwaysVisible = Key<Bool>("continuityAlwaysVisible", default: false)
  static let continuitySneaks = Key<Bool>("continuitySneaks", default: true)
  static let t3CodeEnabled = Key<Bool>("t3CodeEnabled", default: true)
  static let pulseEnabled = Key<Bool>("pulseEnabled", default: true)
  static let t3RemoteEnvironments = Key<[T3EnvironmentProfile]>(
    "t3RemoteEnvironments", default: [])
}
