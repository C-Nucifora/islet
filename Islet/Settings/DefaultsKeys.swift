import Defaults
import Foundation

enum HUDStyle: String, CaseIterable, Codable { case bar, gauge }

enum HapticStrength: String, CaseIterable, Codable, Sendable {
  case off
  case light
  case medium
  case strong

  var title: String {
    switch self {
    case .off: "Off"
    case .light: "Light"
    case .medium: "Medium"
    case .strong: "Strong"
    }
  }
}

/// Maps the push-distance slider onto physical cursor travel. A logarithmic curve gives the short
/// end more resolution, where a few points materially change how the notch feels, while preserving
/// the full useful range for users who prefer a deliberate push.
enum PushDistanceScale {
  static let minimum = 20.0
  static let maximum = 1_000.0

  static func distance(for sliderPosition: Double) -> Double {
    let position = min(max(sliderPosition, 0), 1)
    return minimum * pow(maximum / minimum, position)
  }

  static func sliderPosition(for distance: Double) -> Double {
    let clamped = min(max(distance, minimum), maximum)
    return log(clamped / minimum) / log(maximum / minimum)
  }

  static func roundedDistance(for sliderPosition: Double) -> Double {
    let raw = distance(for: sliderPosition)
    let increment = raw < 100 ? 2.0 : (raw < 300 ? 4.0 : 8.0)
    return (raw / increment).rounded() * increment
  }
}

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
    // Selecting Battery is an explicit request to watch its continuously changing telemetry.
    // Live mode updates every second. Automatic retains the established 12-second foreground
    // cadence, while explicit or system-imposed constrained profiles remain at 30 seconds.
    if viewIsLive {
      switch mode {
      case .live: return BatteryMonitor.liveInterval
      case .lowEnergy: return 30
      case .automatic: return systemLowPowerMode ? 30 : 12
      }
    }
    switch mode {
    case .live: return 15
    case .lowEnergy: return 120
    case .automatic:
      return systemLowPowerMode ? 120 : 60
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
extension HapticStrength: Defaults.Serializable {}

extension Defaults.Keys {
  static let onboardingVersion = Key<Int>("onboardingVersion", default: 0)
  static let appTheme = Key<AppTheme>("appTheme", default: .classic)
  static let batteryGraphStyle = Key<BatteryGraphStyle>("batteryGraphStyle", default: .coloured)
  static let mediaSourceMode = Key<MediaSourceMode>("mediaSourceMode", default: .auto)
  static let mediaPriorityList = Key<[String]>(
    "mediaPriorityList",
    default: ["com.spotify.client", "com.apple.Music"])
  static let interactionMode = Key<InteractionMode>("interactionMode", default: .hover)
  static let hoverCollapseTimeout = Key<Double>("hoverCollapseTimeout", default: 0.5)
  static let hapticsEnabled = Key<Bool>("hapticsEnabled", default: true)
  static let hapticStrength = Key<HapticStrength>("hapticStrength", default: .medium)
  static let barrierPushDistance = Key<Double>(
    "barrierPushDistance", default: Double(Metrics.barrierPushDistance))
  static let energyMode = Key<EnergyMode>("energyMode", default: .automatic)
  static let hideFromScreenRecording = Key<Bool>("hideFromScreenRecording", default: false)
  static let batteryEnabled = Key<Bool>("batteryEnabled", default: true)
  static let hudEnabled = Key<Bool>("hudEnabled", default: false)
  static let hudStyle = Key<HUDStyle>("hudStyle", default: .bar)
  static let calendarEnabled = Key<Bool>("calendarEnabled", default: true)
  static let calendarLeadMinutes = Key<Int>("calendarLeadMinutes", default: 10)
  static let hiddenCalendarIDs = Key<[String]>("hiddenCalendarIDs", default: [])
  static let remindersEnabled = Key<Bool>("remindersEnabled", default: true)
  static let showOnAllDisplays = Key<Bool>("showOnAllDisplays", default: false)
  static let hideInFullscreen = Key<Bool>("hideInFullscreen", default: false)
  static let launchAtLogin = Key<Bool>("launchAtLogin", default: false)
  static let activityOrder = Key<[String]>("activityOrder", default: ActivityCatalog.defaultOrder)
  static let disabledActivities = Key<[String]>("disabledActivities", default: [])
  static let clipboardEnabled = Key<Bool>("clipboardEnabled", default: false)
  static let portsEnabled = Key<Bool>("portsEnabled", default: true)
  /// Event sources the user has switched off. Inferred sources start off because they can be late
  /// or ambiguous; a user can explicitly enable the ones they find useful.
  static let disabledEventSources = Key<[String]>(
    "disabledEventSources", default: ["airdropOut", "airdropIn", "focus", "vpn"])
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
  static let timerSessionData = Key<Data?>("timerSessionData")
  static let timerLastPresetData = Key<Data?>("timerLastPresetData")
}
