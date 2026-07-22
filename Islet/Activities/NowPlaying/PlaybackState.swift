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

  /// Best-guess current position extrapolated from the last update.
  var currentElapsed: TimeInterval {
    guard duration > 0 else { return elapsed }
    return isPlaying ? min(elapsed + Date().timeIntervalSince(elapsedAt), duration) : elapsed
  }
}
