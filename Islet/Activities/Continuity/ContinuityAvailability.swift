import Foundation

/// Why the iPhone tab is or is not showing anything.
///
/// These states can all look like an empty island, but each needs a different explanation.
enum ContinuityAvailability: Equatable, Sendable {
  /// Islet has not been granted Accessibility. The only state the user can fix from inside Islet.
  case needsAccessibility
  /// ControlCenter is not running, so there is no process to inspect.
  case controlCenterUnavailable
  /// ControlCenter is running but no longer exposes the private hierarchy Islet understands.
  case incompatibleSchema
  /// macOS has iPhone Live Activities switched off in System Settings.
  case systemDisabled
  /// Switched on, but nothing is arriving.
  case waiting
  case active

  static func resolve(
    readResult: LiveActivityAXReadResult, systemEnabled: Bool, cardCount: Int
  ) -> ContinuityAvailability {
    switch readResult {
    case .permissionDenied:
      return .needsAccessibility
    case .controlCenterUnavailable:
      return .controlCenterUnavailable
    case .schemaChanged:
      return .incompatibleSchema
    case .success:
      // A card in hand outranks the preference: whatever it says, something is here now.
      if cardCount > 0 { return .active }
      return systemEnabled ? .waiting : .systemDisabled
    }
  }

  var explanation: String {
    switch self {
    case .needsAccessibility:
      return String(
        localized: "Islet needs Accessibility access to read Live Activities from the menu bar.")
    case .controlCenterUnavailable:
      return String(localized: "Control Centre is not running. Retry after macOS starts it again.")
    case .incompatibleSchema:
      return String(
        localized: "This macOS version exposes a Control Centre layout Islet cannot read.")
    case .systemDisabled:
      return String(
        localized: "Turn on iPhone Live Activities in System Settings to see them here.")
    case .waiting:
      // Deliberately not "keep your iPhone nearby": during development this Mac sat with a
      // connected phone and an empty menu bar for two days because ControlCenter was holding stale
      // pairing state. Telling the user to move their phone would have been useless advice.
      return String(
        localized:
          "Nothing running on your iPhone. If the menu bar shows one and this doesn't, restart Control Centre."
      )
    case .active:
      return String(localized: "Nothing running on your iPhone right now.")
    }
  }
}

/// ControlCenter's own view of the feature, read from its preferences.
///
/// Only ever used to explain an empty tab. `CompanionPaired` is deliberately ignored: it is a
/// cache ControlCenter rewrites only when it notices a change, and it was observed reading `false`
/// for two days while the feature was in fact available — so acting on it would produce a
/// confidently wrong empty state.
struct ControlCenterLiveActivitySettings: Equatable, Sendable {
  var remoteEnabled: Bool

  static func read() -> ControlCenterLiveActivitySettings {
    let domain = "com.apple.controlcenter" as CFString
    return parse(
      remoteEnabled: CFPreferencesCopyAppValue("RemoteLiveActivitiesEnabled" as CFString, domain),
      stateData: CFPreferencesCopyAppValue("LiveActivityState" as CFString, domain) as? Data)
  }

  /// `LiveActivityState` is a JSON blob stored as `Data`, not a plist dictionary.
  static func parse(remoteEnabled: Any?, stateData: Data?) -> ControlCenterLiveActivitySettings {
    // Absent means the user has never touched the setting, which macOS treats as on.
    let enabled = (remoteEnabled as? NSNumber)?.boolValue ?? true
    if let stateData,
      let json = try? JSONSerialization.jsonObject(with: stateData) as? [String: Any],
      let settingEnabled = json["SettingEnabled"] as? Bool, !settingEnabled
    {
      return ControlCenterLiveActivitySettings(remoteEnabled: false)
    }
    return ControlCenterLiveActivitySettings(remoteEnabled: enabled)
  }
}
