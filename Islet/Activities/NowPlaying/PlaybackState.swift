import Foundation

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

  /// Best-guess current position extrapolated from the last update.
  var currentElapsed: TimeInterval {
    let extrapolated = isPlaying ? elapsed + Date().timeIntervalSince(elapsedAt) : elapsed
    guard extrapolated.isFinite else { return 0 }
    guard duration > 0, duration.isFinite else { return max(0, extrapolated) }
    return min(max(0, extrapolated), duration)
  }
}
