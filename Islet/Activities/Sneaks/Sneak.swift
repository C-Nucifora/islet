import SwiftUI

/// A transient compact-island presentation (charger plugged in, track change, ...).
struct Sneak: Identifiable {
  let id = UUID()
  let source: String  // coalescing key: a queued sneak with the same source is replaced
  /// Queue priority. Non-system sneaks retain the existing normal-priority behavior.
  var urgency: SystemEventUrgency = .normal
  var duration: TimeInterval = 2
  let leading: AnyView
  let trailing: AnyView
  /// Spoken by VoiceOver when the sneak appears (the visual is otherwise invisible to it).
  var announcement: String? = nil
}

/// Pure queue semantics, kept AppKit-free for testing.
struct SneakLogic {
  /// An ambient item waiting behind this many alerts gets the next presentation slot. This bounds
  /// its wait during an alert storm without interrupting the sneak already on screen.
  static let maximumConsecutiveAlerts = 3

  private(set) var pending: [Sneak] = []
  private var consecutiveAlertCount = 0

  mutating func enqueue(_ sneak: Sneak) {
    if let i = pending.firstIndex(where: { $0.source == sneak.source }) {
      // Keep a same-priority replacement in place, preserving its source's FIFO position. A
      // changed priority joins the new priority's line at the tail, so FIFO holds within that
      // level and an escalation can bypass lower-priority items.
      if pending[i].urgency == sneak.urgency {
        pending[i] = sneak
      } else {
        pending.remove(at: i)
        pending.append(sneak)
      }
    } else {
      pending.append(sneak)
    }
  }

  mutating func popNext() -> Sneak? {
    guard !pending.isEmpty else {
      // An idle queue ends the burst. A later alert must not inherit fairness debt from work that
      // has already drained.
      consecutiveAlertCount = 0
      return nil
    }

    if let alertIndex = pending.firstIndex(where: { $0.urgency == .alert }) {
      if consecutiveAlertCount >= Self.maximumConsecutiveAlerts,
        let ambientIndex = pending.firstIndex(where: { $0.urgency == .ambient })
      {
        consecutiveAlertCount = 0
        return pending.remove(at: ambientIndex)
      }

      consecutiveAlertCount = min(consecutiveAlertCount + 1, Self.maximumConsecutiveAlerts)
      return pending.remove(at: alertIndex)
    }

    consecutiveAlertCount = 0
    if let normalIndex = pending.firstIndex(where: { $0.urgency == .normal }) {
      return pending.remove(at: normalIndex)
    }
    return pending.removeFirst()
  }
}
