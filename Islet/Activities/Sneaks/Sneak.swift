import SwiftUI

/// A transient compact-island presentation (charger plugged in, track change, ...).
struct Sneak: Identifiable {
  let id = UUID()
  let source: String  // coalescing key: a queued sneak with the same source is replaced
  var duration: TimeInterval = 2
  let leading: AnyView
  let trailing: AnyView
  /// Spoken by VoiceOver when the sneak appears (the visual is otherwise invisible to it).
  var announcement: String? = nil
}

/// Pure queue semantics, kept AppKit-free for testing.
struct SneakLogic {
  private(set) var pending: [Sneak] = []

  mutating func enqueue(_ sneak: Sneak) {
    if let i = pending.firstIndex(where: { $0.source == sneak.source }) {
      pending[i] = sneak
    } else {
      pending.append(sneak)
    }
  }

  mutating func popNext() -> Sneak? {
    pending.isEmpty ? nil : pending.removeFirst()
  }
}
