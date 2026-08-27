import AppKit
import Defaults

@MainActor
enum Haptics {
  private static var snapTask: Task<Void, Never>?

  /// Deliberate feedback for a discrete action (tap, expand, completion). Not throttled.
  static func perform(_ pattern: NSHapticFeedbackManager.FeedbackPattern = .generic) {
    guard Defaults[.hapticsEnabled] else { return }
    NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
  }

  /// Two pressure gates turn continued upward travel into progressively firmer tactile resistance.
  static func barrierResistance(strong: Bool) {
    perform(strong ? .levelChange : .alignment)
  }

  /// A strong two-beat release at the exact movement threshold where the island snaps open.
  static func barrierSnap() {
    perform(.generic)
    snapTask?.cancel()
    snapTask = Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(38))
      guard !Task.isCancelled else { return }
      perform(.levelChange)
    }
  }
}
