import SwiftUI

/// The leading slot: the event's icon, tinted, wearing its source's bespoke choreography.
///
/// Sized to match the existing compact glyphs exactly (`.font(.caption)`), because the panel width
/// is derived from what this measures.
struct EventLeadingView: View {
  let event: SystemEvent

  var body: some View {
    Image(systemName: event.icon)
      .font(.caption)
      .foregroundStyle(Color(isletHex: event.accentHex) ?? .white)
      .eventMotion(event.motion)
  }
}

/// The trailing slot: title and subtitle on ONE line, side by side.
///
/// The collapsed island is a 34pt band built around single-line content — every pre-bus sneak
/// (battery percent, track title, HUD bar) is one line. A stacked title/subtitle block is ~24pt
/// tall: its second line lands inside the bottom corner-radius zone of the island shape and reads
/// as spilling out of it. Snapshot-verified in SneakSnapshotTests before this layout replaced it.
///
/// `lineLimit(1)` and the max width are load-bearing: the slots are measured and the panel is
/// sized from the measurement, so an unbounded string drags the island out to the width of a
/// device name. No `fixedSize` — it reported an ideal width the measurement pass never saw, which
/// pushed the title flush against the island's right edge. The title wins the space
/// (`layoutPriority`); the subtitle truncates first, since "Connected" cut short costs less than
/// the device's name cut short.
struct EventTrailingView: View {
  let event: SystemEvent

  var body: some View {
    HStack(spacing: 5) {
      Text(event.title)
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.white)
        .lineLimit(1)
        .layoutPriority(1)
      if let subtitle = event.subtitle, !subtitle.isEmpty {
        Text(subtitle)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
    .frame(maxWidth: 175, alignment: .leading)
  }
}

extension Sneak {
  /// Renders an event into the transient-presentation type the queue already understands.
  ///
  /// `source` becomes the event's `sourceID`, which is what gives the queue its existing coalescing
  /// behaviour for free: a second Wi-Fi event replaces a queued one instead of stacking behind it
  /// (`SneakLogic.enqueue`).
  @MainActor
  init(event: SystemEvent) {
    self.init(
      source: event.sourceID,
      duration: event.duration,
      leading: AnyView(EventLeadingView(event: event)),
      trailing: AnyView(EventTrailingView(event: event)),
      announcement: event.spokenAnnouncement)
  }
}
