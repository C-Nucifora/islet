import AppKit
import Defaults

@MainActor
enum Haptics {
  private static var lastTick = Date.distantPast

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
}
