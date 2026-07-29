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

/// The trailing slot: title, plus subtitle when there is one and it fits.
///
/// `lineLimit(1)` and a max width are load-bearing. The compact slots are measured and the panel is
/// sized from the measurement, so an unbounded string drags the island out to the width of a track
/// title — the creep `NotchRootView` already warns about.
struct EventTrailingView: View {
  let event: SystemEvent

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(event.title)
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.white)
        .lineLimit(1)
      if let subtitle = event.subtitle, !subtitle.isEmpty {
        Text(subtitle)
          .font(.system(size: 9))
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
    .frame(maxWidth: 150, alignment: .leading)
    .fixedSize(horizontal: true, vertical: false)
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
