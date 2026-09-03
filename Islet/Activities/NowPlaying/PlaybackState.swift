import Foundation

enum PlaybackSeekability: Equatable {
  case seekable
  case live
  case unavailable

  var title: String {
    switch self {
    case .seekable: ""
    case .live: "Live"
    case .unavailable: "Seeking unavailable"
    }
  }

  var symbol: String {
    switch self {
    case .seekable: ""
    case .live: "dot.radiowaves.left.and.right"
    case .unavailable: "nosign"
    }
  }

  var accessibilityLabel: String {
    switch self {
    case .seekable: ""
    case .live: "Live media. Seeking is unavailable."
    case .unavailable: "Playback position is unavailable."
    }
  }
}

struct PlaybackState: Equatable {
  var title = ""
  var artist = ""
  var album = ""
  var bundleIdentifier = ""
  /// The pid the adapter reported. Part of the source key: bundle identifier alone is not unique,
  /// because several com.apple.WebKit.GPU processes coexist, one per media-hosting web view.
  var processIdentifier: Int32 = 0
  var isPlaying = false
  var duration: TimeInterval = 0
  var elapsed: TimeInterval = 0
  var elapsedAt = Date()
  /// Explicit live metadata takes precedence over a finite duration. Some players expose a rolling
  /// duration for a live stream, but it is not a range users can seek within.
  var isLive = false
  /// `nil` means the adapter did not report a capability. Seeking fails closed in that case; a
  /// finite duration alone does not prove that a live window or protected stream is scrubbable.
  var supportsSeeking: Bool?
  var artwork: Data?

  var shuffleMode = 0  // 0 = off
  var repeatMode = 0  // 0 = off, 1 = one, 2 = all
  var isAdvertisement = false
  /// The adapter reports these independently. A player may allow forward skipping while refusing
  /// rewind, such as at the start of a streamed item.
  var supportsSkipBackward15 = false
  var supportsSkipForward15 = false
  /// Compatibility shorthand for code that only needs to know whether either 15-second action is
  /// available. Setting it applies to both directions, which is useful for synthetic test states.
  var supportsSkip15: Bool {
    get { supportsSkipBackward15 || supportsSkipForward15 }
    set {
      supportsSkipBackward15 = newValue
      supportsSkipForward15 = newValue
    }
  }
  var parentBundleIdentifier = ""

  var isShuffleOn: Bool { shuffleMode != 0 }

  /// The app to attribute playback to — the parent app for browser/helper-hosted media.
  var sourceBundleIdentifier: String {
    parentBundleIdentifier.isEmpty ? bundleIdentifier : parentBundleIdentifier
  }

  var seekability: PlaybackSeekability {
    if isLive { return .live }
    guard supportsSeeking == true, duration.isFinite, duration > 0 else { return .unavailable }
    return .seekable
  }

  /// Best-guess current position extrapolated from the last update.
  var currentElapsed: TimeInterval {
    currentElapsed(at: Date())
  }

  /// Best-guess current position at a specific time. The explicit date keeps position
  /// reconciliation deterministic and testable.
  func currentElapsed(at date: Date = Date()) -> TimeInterval {
    let extrapolated = isPlaying ? elapsed + date.timeIntervalSince(elapsedAt) : elapsed
    guard extrapolated.isFinite else { return 0 }
    guard duration > 0, duration.isFinite else { return max(0, extrapolated) }
    return min(max(0, extrapolated), duration)
  }

}

/// Tracks a drag independently of SwiftUI's transient slider state. If the primary source changes
/// while a drag is in progress, finishing that old drag must not seek whichever source replaced it.
struct PlaybackScrubSession: Equatable {
  private(set) var source: SourceID?

  var isActive: Bool { source != nil }

  mutating func begin(for source: SourceID?) {
    self.source = source
  }

  mutating func finish(value: TimeInterval, currentSource: SourceID?) -> TimeInterval? {
    defer { source = nil }
    guard source != nil, source == currentSource, value.isFinite else { return nil }
    return value
  }

  mutating func cancel() {
    source = nil
  }
}
