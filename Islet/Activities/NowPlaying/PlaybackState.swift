import Foundation

struct PlaybackState: Equatable {
  var title = ""
  var artist = ""
  var album = ""
  var bundleIdentifier = ""
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
