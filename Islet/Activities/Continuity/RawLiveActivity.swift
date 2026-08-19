import Foundation

/// One Live Activity, flattened out of the daemon's Objective-C objects into a value.
///
/// The bridge converts on whatever queue the daemon calls back on and hands this across, so it has
/// to be `Sendable` — and everything downstream is easier to test against a struct than against a
/// live `ACActivityDescriptor` we cannot construct.
struct RawLiveActivity: Identifiable, Equatable, Sendable {
  /// `ACActivityDescriptor.activityIdentifier` — stable for the life of the activity.
  let id: String
  /// `platterTargetBundleIdentifier`. For a replicated activity this is the *iOS* bundle id, which
  /// is what adapters key off; there is no Mac app behind it.
  var bundleIdentifier: String?
  var appName: String?
  /// Non-nil means the activity was replicated from a paired device rather than started on this
  /// Mac. This is the only thing that distinguishes "from your iPhone" from "from this Mac".
  var remoteDeviceIdentifier: String?
  var createdDate: Date?
  var isImportant: Bool = false
  var isMomentary: Bool = false
  var isEphemeral: Bool = false
  /// Serialised `ActivityAttributes` — the static half of the activity.
  var attributesData: Data?
  /// Serialised `ActivityContent.state` — the live half. Arrives via the content-update stream,
  /// which is why it is `var`: a descriptor can land before its first content update.
  var contentData: Data?
  var staleDate: Date?
  var relevanceScore: Double = 0
  /// `ActivityState`: 0 active, 1 dismissed, 2 ended, 3 stale (per ActivityKit's ordering).
  var state: Int = 0

  var isRemote: Bool { !(remoteDeviceIdentifier ?? "").isEmpty }
  /// 0 is `.active`; anything else is on its way out and should stop taking a slot in the island.
  var isLive: Bool { state == 0 }
}
