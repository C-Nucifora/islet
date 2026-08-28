import Foundation

enum MediaSourceMode: String, CaseIterable, Codable { case auto, prioritized }

enum SourceFilter {
  /// Bundle identifiers that are never shown as a media source. All four were observed in the
  /// CoreAudio process list on this machine, along with Islet itself; none of them is a player a
  /// user would want to switch to.
  static let denylist: Set<String> = [
    "systemsoundserverd",
    "com.apple.PowerChime",
    "com.apple.controlcenter",
    "dev.nedlane.Islet",
    // Also observed and equally useless as a "player":
    "com.apple.audio.Core-Audio-Driver-Service",
    "com.apple.mediaremoted",
  ]

  static func isDenied(_ bundleID: String) -> Bool { denylist.contains(bundleID) }

  /// Display rank for a source: lower sorts first, nil means "never show".
  ///
  /// `mediaPriorityList` is display order, not a filter — `.prioritized` puts listed apps first in
  /// list order and leaves everything else behind them. The old `shouldAccept` dropped unlisted
  /// bundles outright, which made a second player invisible rather than secondary.
  static func rank(bundleID: String, mode: MediaSourceMode, priorityList: [String]) -> Int? {
    guard !bundleID.isEmpty, !isDenied(bundleID) else { return nil }
    switch mode {
    case .auto:
      // Flat: every visible source ranks the same, so the caller's tiebreakers decide.
      return priorityList.count
    case .prioritized:
      return priorityList.firstIndex(of: bundleID) ?? priorityList.count
    }
  }
}
