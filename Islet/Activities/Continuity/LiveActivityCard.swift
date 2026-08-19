import CoreGraphics
import Foundation

/// One Live Activity as ControlCenter exposes it in the menu bar, before interpretation.
struct MenuBarLiveActivity: Equatable, Sendable {
  let axIdentifier: String
  /// ControlCenter's `AXDescription` — the app's display name, e.g. "T3 Code".
  let appName: String?
  /// Left edge of the item. Used only for ordering, so the island lists activities in the same
  /// order the menu bar does.
  let minX: CGFloat
}

/// One row in the iPhone tab.
///
/// Deliberately thin. Accessibility exposes the app behind an activity and nothing about what it
/// says — the content is a scene replicated from the phone, opaque to everything but the pixels —
/// so a card is an identity, not a payload.
struct LiveActivityCard: Identifiable, Equatable, Sendable {
  /// The accessibility identifier, stable for as long as the activity is on screen.
  let id: String
  let bundleIdentifier: String
  let appName: String
  let symbol: String
  /// False when the bundle identifier resolves to an app installed on this Mac, so a Mac-side
  /// activity cannot quietly pass itself off as one from the phone.
  let isRemote: Bool
}

/// Turns a menu bar reading into ordered cards.
///
/// Pure, with app lookup injected, so the filtering and ordering rules are testable without a
/// running ControlCenter — the same shape `AudioProcessReducer` uses for its bundle lookups.
enum LiveActivityCatalog {
  static func cards(
    from items: [MenuBarLiveActivity], isInstalledLocally: (String) -> Bool
  ) -> [LiveActivityCard] {
    var seen: Set<String> = []
    return
      items
      .sorted { $0.minX < $1.minX }
      .compactMap { item -> LiveActivityCard? in
        // Overflow and empty placeholders are ControlCenter's own bookkeeping, not activities.
        guard case .app(let bundleIdentifier)? = LiveActivityIdentifier.parse(item.axIdentifier)
        else { return nil }
        // One card per app: ControlCenter shows a single item per app, and a duplicate would
        // render twice under the same name with no way to tell them apart.
        guard seen.insert(bundleIdentifier).inserted else { return nil }
        let name = item.appName.flatMap { $0.isEmpty ? nil : $0 }
          ?? LiveActivityAppStyle.name(forBundleIdentifier: bundleIdentifier)
        return LiveActivityCard(
          id: item.axIdentifier,
          bundleIdentifier: bundleIdentifier,
          appName: name,
          symbol: LiveActivityAppStyle.symbol(forBundleIdentifier: bundleIdentifier),
          isRemote: !isInstalledLocally(bundleIdentifier))
      }
  }
}
