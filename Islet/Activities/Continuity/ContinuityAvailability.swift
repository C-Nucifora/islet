import Foundation

/// Why the iPhone tab is or is not showing anything.
///
/// Four distinct dead ends look identical from the outside — an empty island — and each needs a
/// different sentence to the user, so they are modelled rather than collapsed into "no data".
enum ContinuityAvailability: Equatable, Sendable {
  /// The private API did not resolve. A macOS update moved it; nothing the user can do.
  case unsupported
  /// macOS has iPhone Live Activities switched off in System Settings.
  case systemDisabled
  /// Switched on, but no iPhone is currently connected to forward anything.
  case waiting
  /// Activities are flowing.
  case active

  static func resolve(
    bridgeAvailable: Bool, systemEnabled: Bool, companionPaired: Bool, cardCount: Int
  ) -> ContinuityAvailability {
    guard bridgeAvailable else { return .unsupported }
    // Cards outrank every other signal. `companionPaired` is ControlCenter's cached view and is
    // only rewritten when ControlCenter notices a change, so it can read stale — but an activity
    // in hand is proof the pipe is open regardless of what the cache says.
    if cardCount > 0 { return .active }
    guard systemEnabled else { return .systemDisabled }
    return companionPaired ? .active : .waiting
  }

  var explanation: String {
    switch self {
    case .unsupported:
      return "This build of macOS doesn't expose iPhone Live Activities."
    case .systemDisabled:
      return "Turn on iPhone Live Activities in System Settings to see them here."
    case .waiting:
      return "No iPhone connected. Keep it nearby and locked."
    case .active:
      return "Nothing running on your iPhone right now."
    }
  }
}

/// ControlCenter's own view of the feature, read from its preferences.
///
/// Islet is unsandboxed, so it can read another app's domain directly. This is only ever used to
/// explain an empty tab — never to gate the subscription, which is cheap and harmless to hold open
/// even when the feature is off.
struct ControlCenterLiveActivitySettings: Equatable, Sendable {
  var remoteEnabled: Bool
  var companionPaired: Bool

  static let domain = "com.apple.controlcenter"

  static func read() -> ControlCenterLiveActivitySettings {
    let domain = domain as CFString
    return parse(
      remoteEnabled: CFPreferencesCopyAppValue("RemoteLiveActivitiesEnabled" as CFString, domain),
      stateData: CFPreferencesCopyAppValue("LiveActivityState" as CFString, domain) as? Data)
  }

  /// `LiveActivityState` is a JSON blob stored as `Data`, not a plist dictionary.
  static func parse(remoteEnabled: Any?, stateData: Data?) -> ControlCenterLiveActivitySettings {
    // Absent means the user has never touched the setting, which macOS treats as on.
    let enabled = (remoteEnabled as? NSNumber)?.boolValue ?? true
    var paired = false
    if let stateData, case .object(let state)? = PayloadValue.decode(stateData) {
      if case .bool(let v)? = state["CompanionPaired"] { paired = v }
      if case .bool(let v)? = state["SettingEnabled"], !v {
        return ControlCenterLiveActivitySettings(remoteEnabled: false, companionPaired: paired)
      }
    }
    return ControlCenterLiveActivitySettings(remoteEnabled: enabled, companionPaired: paired)
  }
}
