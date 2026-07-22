import AppKit
import Defaults

@MainActor
enum Haptics {
  private static var lastTick = Date.distantPast

  static func tick() {
    guard Defaults[.hapticsEnabled],
      NSEvent.pressedMouseButtons == 0,
      Date().timeIntervalSince(lastTick) > 0.5
    else { return }
    lastTick = Date()
    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
  }
}
