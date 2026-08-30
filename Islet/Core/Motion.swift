import AppKit
import SwiftUI

/// Every animation Islet plays, in one place. Split out of `Metrics` — which now owns sizes only —
/// so per-source event choreography and the Reduce Motion gate have somewhere to live.
enum Motion {
  static let closingDuration: TimeInterval = 0.4
  static let opening: Animation = .bouncy(duration: 0.4)
  static let closing: Animation = .smooth(duration: closingDuration)
  static let compact: Animation = .snappy(duration: 0.4)
  static let hudAppearing: Animation = .snappy(duration: 0.16)

  /// Media-key feedback should arrive almost immediately. Returning to the underlying compact
  /// activity uses the normal duration, as do activity lineup changes.
  static func compactChange(hudVisible: Bool) -> Animation {
    hudVisible ? hudAppearing : compact
  }
  /// The panel has to stay oversized until the closing animation has finished drawing — but not a
  /// frame longer, since every extra millisecond is menu bar nobody can click.
  static let panelShrinkDelay: Duration = .milliseconds(Int(closingDuration * 1000) + 32)

  /// System Settings → Accessibility → Display → Reduce Motion.
  @MainActor
  static var reduceMotion: Bool {
    NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
  }

  /// Collapses `animation` to `nil` when Reduce Motion is on. `withAnimation(nil) { ... }` and
  /// `.animation(nil, value:)` both mean "apply the change with no animation", so a call site gates
  /// itself by wrapping its animation in this.
  @MainActor
  static func gated(_ animation: Animation) -> Animation? {
    gated(animation, reduceMotion: reduceMotion)
  }

  /// Testable core of `gated(_:)`, so the decision can be covered without changing the tester's
  /// accessibility settings.
  static func gated(_ animation: Animation, reduceMotion: Bool) -> Animation? {
    reduceMotion ? nil : animation
  }

  /// Repeating and symbol-driven effects do not follow SwiftUI's transaction animation. Views
  /// use this policy to remove those effects completely under Reduce Motion.
  static func allowsDecorativeMotion(reduceMotion: Bool) -> Bool {
    !reduceMotion
  }
}

/// Per-source event choreography. A Phase 3 `SystemEvent` names one of these and the sneak renderer
/// turns it into the actual symbol effect or phase animator.
enum MotionProfile: String, CaseIterable, Codable, Sendable {
  case wifi, bluetooth, usb, airdrop, volumeMount, display, chargeComplete,
    lowPower, screenshot, lock, sleepWake, peripheralLow, focus, vpn, generic
}
