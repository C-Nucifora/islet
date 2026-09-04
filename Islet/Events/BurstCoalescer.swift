import Foundation

/// Collapses a flurry of events into one summary.
///
/// Docking a MacBook fires a display connect, several USB attaches, a power change, an audio-device
/// change and a volume mount inside about two seconds. Presented individually at the queue's 2s
/// duration plus a 250ms gap, one physical action becomes eleven seconds of island churn.
///
/// Time is a parameter rather than read from `Date()`, which keeps this a pure function of its
/// inputs — tests need no sleeps and no clock injection protocol.
///
/// Deliberately actor-free: pure logic, so tests call it synchronously.
struct BurstCoalescer {
  enum Decision: Equatable {
    /// Present this event now.
    case pass(SystemEvent)
    /// Held as part of a burst. Present nothing; `flush` will produce a summary.
    case hold
  }

  /// Events closer together than this are candidates for the same burst.
  let window: TimeInterval
  /// How many events inside `window` before coalescing starts. The first `threshold - 1` are
  /// presented normally, so an ordinary pair of events is never delayed.
  let threshold: Int
  /// Upper bound on retained events. The *count* stays exact; only the named ones are capped.
  let maxHeld: Int

  private var recentTimes: [TimeInterval] = []
  private var held: [SystemEvent] = []
  private var heldCount = 0

  init(window: TimeInterval = 2.5, threshold: Int = 3, maxHeld: Int = 12) {
    self.window = window
    self.threshold = threshold
    self.maxHeld = maxHeld
  }

  var isHolding: Bool { heldCount > 0 }

  /// Drops both a pending summary and the recent-event threshold history while preserving this
  /// instance's configured window/capacity. Lifecycle shutdown uses this so an event held before
  /// sleep/termination cannot be delivered after the bus is started again.
  mutating func reset() {
    recentTimes.removeAll(keepingCapacity: true)
    held.removeAll(keepingCapacity: true)
    heldCount = 0
  }

  mutating func accept(_ event: SystemEvent, at now: TimeInterval) -> Decision {
    // An alert is never swallowed by a burst — low battery during docking is exactly when it
    // matters. It also does not count towards the burst, so it cannot trigger one on its own.
    guard event.urgency != .alert else { return .pass(event) }

    // Callers should provide a monotonic clock. Still recover defensively if a test or future
    // caller supplies wall-clock time that jumps backwards instead of retaining a burst forever.
    if let last = recentTimes.last, now < last { reset() }
    recentTimes.removeAll { now - $0 > window }
    recentTimes.append(now)

    guard recentTimes.count >= threshold else { return .pass(event) }

    heldCount += 1
    if held.count < maxHeld { held.append(event) }
    return .hold
  }

  /// Produces the summary once the burst has gone quiet for a full window. Returns nil while the
  /// burst may still be growing, and nil when nothing is held.
  mutating func flush(at now: TimeInterval) -> SystemEvent? {
    guard heldCount > 0 else { return nil }
    guard let last = recentTimes.last, now - last >= window else { return nil }

    let count = heldCount
    let names = held.map(\.title)
    let shown = Array(names.prefix(3))
    let overflow = count - shown.count
    let subtitle =
      overflow > 0
      ? "\(shown.joined(separator: ", ")) +\(overflow)" : shown.joined(separator: ", ")

    held.removeAll()
    heldCount = 0
    recentTimes.removeAll()

    return SystemEvent(
      sourceID: "burst",
      icon: "square.stack.3d.up.fill",
      title: String(localized: "\(count) system event", comment: "Coalesced event count"),
      subtitle: subtitle,
      accentHex: EventAccent.info,
      motion: .generic,
      urgency: .normal,
      duration: 3)
  }
}
