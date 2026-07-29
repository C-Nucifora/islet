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
  var supportsSkip15 = false  // podcast/audiobook ±15 s
  var parentBundleIdentifier = ""

  var isShuffleOn: Bool { shuffleMode != 0 }

  /// The app to attribute playback to — the parent app for browser/helper-hosted media.
  var sourceBundleIdentifier: String {
    parentBundleIdentifier.isEmpty ? bundleIdentifier : parentBundleIdentifier
  }

  /// Best-guess current position extrapolated from the last update.
  var currentElapsed: TimeInterval {
    guard duration > 0 else { return elapsed }
    return isPlaying ? min(elapsed + Date().timeIntervalSince(elapsedAt), duration) : elapsed
  }
}
