import Foundation

enum MediaSourceMode: String, CaseIterable, Codable { case auto, prioritized }

enum SourceFilter {
  /// A user can exclude many active apps over time, but Islet never needs an unbounded record of
  /// them. This only limits explicit exclusions, not the current in-memory CoreAudio process list.
  static let maximumAudioOnlyExclusions = 100

  /// Bundle identifiers that are never shown as a media source. These were observed in the
  /// CoreAudio process list on this machine; none is a player a user would want to switch to.
  static let denylist: Set<String> = [
    "systemsoundserverd",
    "com.apple.PowerChime",
    "com.apple.controlcenter",
    // Also observed and equally useless as a "player":
    "com.apple.audio.Core-Audio-Driver-Service",
    "com.apple.mediaremoted",
  ]

  static func isDenied(
    _ bundleID: String, ownBundleIdentifier: String? = Bundle.main.bundleIdentifier
  ) -> Bool {
    denylist.contains(bundleID) || bundleID == ownBundleIdentifier
  }

  /// CoreAudio reports every process that has audio output, including calls, games and helper
  /// processes. A user exclusion applies only to that CoreAudio-only representation. MediaRemote
  /// adapter sources keep their metadata and controls regardless of this choice.
  static func acceptsAudioOnlySource(
    _ bundleID: String, excludedBundleIdentifiers: Set<String>
  ) -> Bool {
    !bundleID.isEmpty && !isDenied(bundleID) && !excludedBundleIdentifiers.contains(bundleID)
  }

  /// Normalizes exclusions written by builds that stored the process bundle identifier. The
  /// current UI and reducer use display identities, so a Chromium helper exclusion must become
  /// the parent application's identifier. Invalid and permanently denied entries are discarded.
  ///
  /// The result is sorted and de-duplicated so it remains a small, stable user preference rather
  /// than a record of every audio process CoreAudio has ever observed.
  static func migratedAudioOnlyExclusions(_ stored: [String]) -> [String] {
    Array(
      Set(
        stored.compactMap { raw -> String? in
          let bundleID = AudioSourceResolver.inferredDisplayBundleID(for: raw)
          return acceptsAudioOnlySource(bundleID, excludedBundleIdentifiers: []) ? bundleID : nil
        })
    )
    .sorted()
    .prefix(maximumAudioOnlyExclusions)
    .map { $0 }
  }

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
