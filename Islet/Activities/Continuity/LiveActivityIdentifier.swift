import Foundation

/// Reads meaning out of the accessibility identifier ControlCenter puts on a Live Activity.
///
/// The identifier is the one dependable handle we have. macOS names these menu bar items
/// `<iOS bundle identifier>.liveActivity` — `com.t3tools.t3code.liveActivity` — which both marks
/// the item as a Live Activity and names the app behind it. No other status item is shaped that
/// way, so this doubles as the filter and the identity.
enum LiveActivityIdentifier {
  static let suffix = ".liveActivity"

  enum Kind: Equatable, Sendable {
    case app(bundleIdentifier: String)
    /// ControlCenter collapses surplus activities into one item rather than filling the menu bar.
    case overflow
    /// A placeholder ControlCenter keeps around when it has nothing to show.
    case empty
  }

  private static let overflowIdentifier = "com.apple.ControlCenter.overflow" + suffix
  private static let emptyIdentifier = "com.apple.ControlCenter.empty" + suffix

  /// Returns `nil` for anything that is not a Live Activity — Wi-Fi, the clock, third-party
  /// status items — which is how the reader filters the menu bar down.
  static func parse(_ axIdentifier: String) -> Kind? {
    guard axIdentifier.hasSuffix(suffix) else { return nil }
    if axIdentifier == overflowIdentifier { return .overflow }
    if axIdentifier == emptyIdentifier { return .empty }
    let bundleIdentifier = String(axIdentifier.dropLast(suffix.count))
    // A bare ".liveActivity" names no app; treating it as one would produce an empty-titled card.
    guard !bundleIdentifier.isEmpty else { return nil }
    return .app(bundleIdentifier: bundleIdentifier)
  }
}
