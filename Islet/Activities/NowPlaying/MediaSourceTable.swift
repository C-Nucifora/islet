import Foundation

/// Every media source Islet currently knows about, keyed by `SourceID`.
///
/// Pure and actor-free on purpose: the insert / update / remove / idle-expiry state machine and the
/// display ordering are the parts worth testing, and tests call them synchronously.
struct MediaSourceTable: Equatable {
  /// Deactivate a paused source this long after it paused, so a paused track eventually leaves the
  /// island. Was a single 60s timer on the activity; it is per-source now.
  let idleTimeout: TimeInterval
  private(set) var states: [SourceID: PlaybackState] = [:]
  /// When each source first appeared, used as the recency tiebreaker.
  private(set) var firstSeen: [SourceID: Date] = [:]
  /// When each paused source becomes eligible for eviction. Absent while playing.
  private(set) var idleDeadlines: [SourceID: Date] = [:]
  /// Display identities that CoreAudio currently reports as producing output. MediaRemote can
  /// leave a browser session marked paused while its audio helper is still playing.
  private(set) var activeAudioBundleIdentifiers: Set<String> = []

  init(idleTimeout: TimeInterval = 60) { self.idleTimeout = idleTimeout }

  var isEmpty: Bool { states.isEmpty }

  /// The soonest idle deadline, so a single timer can drive expiry for the whole table.
  var nextDeadline: Date? { idleDeadlines.values.min() }

  /// States corrected for presentation using the independent CoreAudio playback signal.
  var presentationStates: [SourceID: PlaybackState] {
    Dictionary(uniqueKeysWithValues: states.map { key, state in
      guard !state.isPlaying, isEffectivelyPlaying(key, state: state) else {
        return (key, state)
      }
      var presented = state
      presented.isPlaying = true
      return (key, presented)
    })
  }

  private func isEffectivelyPlaying(_ key: SourceID, state: PlaybackState) -> Bool {
    state.isPlaying || activeAudioBundleIdentifiers.contains(key.displayBundleIdentifier)
  }

  /// Inserts or updates a source. Returns true when the key was not already present.
  @discardableResult
  mutating func upsert(_ key: SourceID, _ state: PlaybackState, now: Date) -> Bool {
    let isNew = states[key] == nil
    states[key] = state
    if isNew { firstSeen[key] = now }
    if isEffectivelyPlaying(key, state: state) {
      idleDeadlines[key] = nil
    } else if idleDeadlines[key] == nil {
      // The countdown starts when playback pauses, and repeated paused updates do not push it
      // back — otherwise a chatty player keeps a paused track on screen forever.
      idleDeadlines[key] = now.addingTimeInterval(idleTimeout)
    }
    return isNew
  }

  /// Removes a source. Returns true when something was actually removed.
  @discardableResult
  mutating func remove(_ key: SourceID) -> Bool {
    guard states.removeValue(forKey: key) != nil else { return false }
    firstSeen[key] = nil
    idleDeadlines[key] = nil
    return true
  }

  mutating func removeAll() {
    states.removeAll()
    firstSeen.removeAll()
    idleDeadlines.removeAll()
  }

  /// Reconciles MediaRemote's sometimes-stale paused flag with CoreAudio's live process signal.
  mutating func setActiveAudioSources(_ sources: [SourceID], now: Date) {
    activeAudioBundleIdentifiers = Set(sources.map(\.displayBundleIdentifier))
    for (key, state) in states {
      if isEffectivelyPlaying(key, state: state) {
        idleDeadlines[key] = nil
      } else if idleDeadlines[key] == nil {
        idleDeadlines[key] = now.addingTimeInterval(idleTimeout)
      }
    }
  }

  /// Evicts every source whose paused deadline has passed. Returns the keys removed.
  @discardableResult
  mutating func expire(now: Date) -> [SourceID] {
    let due = idleDeadlines.filter { $0.value <= now }.keys.sorted { $0.pid < $1.pid }
    for key in due { remove(key) }
    return due
  }

  /// Display order: rank first (hidden sources dropped), then playing before paused, then most
  /// recently seen, then pid so the order is deterministic.
  func ordered(mode: MediaSourceMode, priorityList: [String]) -> [SourceID] {
    states.keys
      .compactMap { key -> (SourceID, Int)? in
        guard
          let rank = SourceFilter.rank(
            bundleID: key.displayBundleIdentifier, mode: mode, priorityList: priorityList)
        else { return nil }
        return (key, rank)
      }
      .sorted { left, right in
        if left.1 != right.1 { return left.1 < right.1 }
        let leftPlaying = states[left.0].map { isEffectivelyPlaying(left.0, state: $0) } ?? false
        let rightPlaying = states[right.0].map { isEffectivelyPlaying(right.0, state: $0) } ?? false
        if leftPlaying != rightPlaying { return leftPlaying }
        let leftSeen = firstSeen[left.0] ?? .distantPast
        let rightSeen = firstSeen[right.0] ?? .distantPast
        if leftSeen != rightSeen { return leftSeen > rightSeen }
        return left.0.pid < right.0.pid
      }
      .map(\.0)
  }

  /// The source that owns the hero player.
  func primaryKey(mode: MediaSourceMode, priorityList: [String]) -> SourceID? {
    ordered(mode: mode, priorityList: priorityList).first
  }
}

/// Reduces the known sources into the chip strip drawn under the hero player. Pure so the cap and
/// the de-duplication are testable without a view.
enum SourceStrip {
  /// Adapter sources (which have metadata) come first; CoreAudio sources are appended unless the
  /// same app is already represented, which would draw Spotify twice.
  static func merge(adapter: [SourceID], audio: [SourceID]) -> [SourceID] {
    let known = Set(adapter.map(\.displayBundleIdentifier))
    return adapter + audio.filter { !known.contains($0.displayBundleIdentifier) }
  }

  /// Everything except the app holding the hero. Compared on display identity, so a second
  /// WebKit.GPU process of the same Safari does not become its own chip.
  static func secondary(all: [SourceID], primary: SourceID?) -> [SourceID] {
    guard let primary else { return all }
    return all.filter { $0.displayBundleIdentifier != primary.displayBundleIdentifier }
  }

  /// At most `limit` chips, then a "+N" pill. The collapsed island's width is derived from the
  /// measured widths of its compact slots, so an uncapped strip would widen the island itself.
  static func layout(_ sources: [SourceID], limit: Int = 3) -> (shown: [SourceID], overflow: Int) {
    guard sources.count > limit else { return (sources, 0) }
    return (Array(sources.prefix(limit)), sources.count - limit)
  }
}

/// The presentation and preference change behind the source-strip overflow control. Keeping this
/// separate from SwiftUI makes the bounded strip and every chooser entry easy to verify.
enum MediaSourceChooser {
  struct Layout: Equatable {
    let primary: SourceID?
    let shown: [SourceID]
    let hidden: [SourceID]
  }

  struct Selection: Equatable {
    let mode: MediaSourceMode
    let priorityList: [String]
  }

  /// The primary is shown in the chooser as a status row. The selectable rows are exactly the
  /// sources that did not fit in the three-chip strip.
  static func layout(primary: SourceID?, secondary: [SourceID], limit: Int = 3) -> Layout {
    let strip = SourceStrip.layout(secondary, limit: limit)
    return Layout(
      primary: primary,
      shown: strip.shown,
      hidden: Array(secondary.dropFirst(strip.shown.count)))
  }

  /// A direct source choice is an explicit preference, so promote the display identity to the
  /// start of the existing prioritized-player list. This deliberately keeps the other entries in
  /// their current order and removes only duplicates of the chosen app.
  static func selection(for source: SourceID, priorityList: [String]) -> Selection {
    let bundleID = source.displayBundleIdentifier
    guard !bundleID.isEmpty else {
      return Selection(mode: .auto, priorityList: priorityList)
    }
    return Selection(
      mode: .prioritized,
      priorityList: [bundleID] + priorityList.filter { $0 != bundleID })
  }

  static func accessibilityLabel(
    appName: String, isPlaying: Bool, isPrimary: Bool, isAdapterBacked: Bool = true
  ) -> String {
    let status = isAdapterBacked ? (isPlaying ? "Playing" : "Paused") : "Audio detected only"
    return "\(appName), \(status), \(isPrimary ? "Primary source" : "Additional source")"
  }

  static func accessibilityHint(appName: String, isAdapterBacked: Bool = true) -> String {
    if isAdapterBacked { return "Makes \(appName) the preferred player" }
    return "Brings \(appName) forward; Islet cannot control this audio source directly"
  }
}
