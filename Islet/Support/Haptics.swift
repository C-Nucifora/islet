import AppKit
import Defaults

@MainActor
enum Haptics {
  /// Deliberate feedback for a discrete action (tap, expand, completion). Not throttled.
  static func perform(_ pattern: NSHapticFeedbackManager.FeedbackPattern = .generic) {
    guard Defaults[.hapticsEnabled] else { return }
    NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
  }

  /// Light contact while the cursor is stretching the barrier, before it gives way.
  static func barrierResistance() { perform(.alignment) }

  /// Firmer release at the exact movement threshold where the island snaps open.
  static func barrierSnap() { perform(.levelChange) }
}
