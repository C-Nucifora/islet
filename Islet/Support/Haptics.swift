import AppKit
import Defaults

@MainActor
enum Haptics {
  private static var lastTick = Date.distantPast
  private static var lastOpening = Date.distantPast
  private static var openingTask: Task<Void, Never>?

  /// Subtle, throttled tick for hover.
  static func tick() {
    guard Defaults[.hapticsEnabled],
      NSEvent.pressedMouseButtons == 0,
      Date().timeIntervalSince(lastTick) > 0.5
    else { return }
    lastTick = Date()
    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
  }

  /// Deliberate feedback for a discrete action (tap, expand, completion). Not throttled.
  static func perform(_ pattern: NSHapticFeedbackManager.FeedbackPattern = .generic) {
    guard Defaults[.hapticsEnabled] else { return }
    NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
  }

  /// A two-stage "catch, then open" feel for the island. The first alignment pulse acknowledges
  /// the opening immediately; the firmer pulse lands as the expanded surface starts moving.
  /// Closely repeated opens are collapsed into one pattern so hover dithering never buzzes.
  static func opening() {
    guard Defaults[.hapticsEnabled], Date().timeIntervalSince(lastOpening) > 0.35 else { return }
    lastOpening = Date()
    openingTask?.cancel()
    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    openingTask = Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(55))
      guard !Task.isCancelled else { return }
      NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }
  }
}
