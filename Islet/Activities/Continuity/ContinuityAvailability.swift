import Foundation

/// Why the iPhone tab is or is not showing anything.
///
/// Five dead ends look identical from the outside — an empty island — and each needs a different
/// sentence, so they are modelled rather than collapsed into "no data".
enum ContinuityAvailability: Equatable, Sendable {
  /// Islet has not been granted Accessibility. The only state the user can fix from inside Islet.
  case needsAccessibility
  /// ControlCenter could not be reached, or exposes no menu bar at all.
  case unsupported
  /// macOS has iPhone Live Activities switched off in System Settings.
  case systemDisabled
  /// Switched on, but nothing is arriving.
  case waiting
  case active

  static func resolve(
    isTrusted: Bool, controlCenterReachable: Bool, systemEnabled: Bool, cardCount: Int
  ) -> ContinuityAvailability {
    guard isTrusted else { return .needsAccessibility }
    // A card in hand outranks every other signal: whatever the settings say, something is here.
    if cardCount > 0 { return .active }
    guard controlCenterReachable else { return .unsupported }
    return systemEnabled ? .waiting : .systemDisabled
  }

  var explanation: String {
    switch self {
    case .needsAccessibility:
      return "Islet needs Accessibility access to read Live Activities from the menu bar."
    case .unsupported:
      return "This build of macOS doesn't put iPhone Live Activities in the menu bar."
    case .systemDisabled:
      return "Turn on iPhone Live Activities in System Settings to see them here."
    case .waiting:
      // Deliberately not "keep your iPhone nearby": during development this Mac sat with a
      // connected phone and an empty menu bar for two days because ControlCenter was holding stale
      // pairing state. Telling the user to move their phone would have been useless advice.
      return
        "Nothing running on your iPhone. If the menu bar shows one and this doesn't, restart Control Centre."
    case .active:
      return "Nothing running on your iPhone right now."
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
