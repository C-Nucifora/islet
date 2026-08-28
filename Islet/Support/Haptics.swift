import AppKit
import Defaults

@MainActor
enum Haptics {
  private static var delayedTestTask: Task<Void, Never>?

  /// Deliberate feedback for a discrete action (tap, expand, completion). Not throttled.
  static func perform(_ pattern: NSHapticFeedbackManager.FeedbackPattern = .generic) {
    let strength = Defaults[.hapticStrength]
    guard Defaults[.hapticsEnabled], strength != .off else { return }
    NSHapticFeedbackManager.defaultPerformer.perform(
      resolved(pattern, strength: strength), performanceTime: .now)
  }

  /// A light acknowledgement when the pointer first engages the push-through barrier.
  static func barrierContact() {
    perform(.alignment)
  }

  /// A Button action runs on release, but the trackpad click can still be physically ringing.
  /// Waiting briefly keeps the requested preview distinct from the click that triggered it.
  static func performDelayedTest() {
    delayedTestTask?.cancel()
    delayedTestTask = Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(120))
      guard !Task.isCancelled else { return }
      perform(.generic)
      delayedTestTask = nil
    }
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
