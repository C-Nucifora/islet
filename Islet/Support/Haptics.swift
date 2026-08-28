import AppKit
import Defaults

@MainActor
enum Haptics {
  /// Deliberate feedback for a discrete action (tap, expand, completion). Not throttled.
  static func perform(_ pattern: NSHapticFeedbackManager.FeedbackPattern = .generic) {
    let strength = Defaults[.hapticStrength]
    guard Defaults[.hapticsEnabled], strength != .off else { return }
    NSHapticFeedbackManager.defaultPerformer.perform(
      resolved(pattern, strength: strength), performanceTime: .now)
  }

  /// Two pressure gates turn continued upward travel into progressively firmer tactile resistance.
  static func barrierResistance(strong: Bool) {
    perform(strong ? .levelChange : .alignment)
  }

  /// One decisive release at the exact movement threshold where the island snaps open. The
  /// level-change pattern is the firmest single macOS pulse; generic can feel like a double beat.
  static func barrierSnap() {
    guard Defaults[.hapticsEnabled], Defaults[.hapticStrength] != .off else { return }
    NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
  }

  private static func resolved(
    _ requested: NSHapticFeedbackManager.FeedbackPattern, strength: HapticStrength
  ) -> NSHapticFeedbackManager.FeedbackPattern {
    switch strength {
    case .off, .light:
      return .alignment
    case .medium:
      return requested
    case .strong:
      switch requested {
      case .alignment, .generic: return .levelChange
      default: return requested
      }
    }
  }
}
