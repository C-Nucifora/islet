import Defaults
import Foundation

enum HUDStyle: String, CaseIterable, Codable { case bar, gauge }

extension InteractionMode: Defaults.Serializable {}
extension MediaSourceMode: Defaults.Serializable {}
extension HUDStyle: Defaults.Serializable {}

extension Defaults.Keys {
  static let mediaSourceMode = Key<MediaSourceMode>("mediaSourceMode", default: .auto)
  static let mediaPriorityList = Key<[String]>(
    "mediaPriorityList",
    default: ["com.spotify.client", "com.apple.Music"])
  static let interactionMode = Key<InteractionMode>("interactionMode", default: .hover)
  static let hoverCollapseTimeout = Key<Double>("hoverCollapseTimeout", default: 0.5)
  static let hapticsEnabled = Key<Bool>("hapticsEnabled", default: true)
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
  static let t3CodeEnabled = Key<Bool>("t3CodeEnabled", default: true)
  static let t3RemoteEnvironments = Key<[T3EnvironmentProfile]>(
    "t3RemoteEnvironments", default: [])
}
