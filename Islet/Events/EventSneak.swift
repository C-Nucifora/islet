import SwiftUI

/// Pure timing and geometry for a compact, repeating text marquee.
///
/// The view owns dates and rendering; this model makes the reading phases deterministic and keeps
/// fitting content completely still.
struct MarqueeMotion {
  var viewportWidth: CGFloat
  var contentWidth: CGFloat
  var pointsPerSecond: CGFloat = 24
  var startPause: TimeInterval = 1
  var endPause: TimeInterval = 0.8
  var resetPause: TimeInterval = 0.35

  var travelDistance: CGFloat { max(0, contentWidth - viewportWidth) }

  var cycleDuration: TimeInterval {
    guard travelDistance > 0, pointsPerSecond > 0 else { return 0 }
    return startPause + TimeInterval(travelDistance / pointsPerSecond) + endPause + resetPause
  }

  func offset(at elapsed: TimeInterval) -> CGFloat {
    guard cycleDuration > 0 else { return 0 }
    let elapsedInCycle = max(0, elapsed).truncatingRemainder(dividingBy: cycleDuration)
    guard elapsedInCycle >= startPause else { return 0 }

    let scrollDuration = TimeInterval(travelDistance / pointsPerSecond)
    let scrollElapsed = elapsedInCycle - startPause
    guard scrollElapsed < scrollDuration else { return -travelDistance }
    return -travelDistance * CGFloat(scrollElapsed / scrollDuration)
  }
}

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

/// A fixed-width, single-line viewport that only moves when its content overflows.
///
/// Timeline-driven offsets avoid a long-lived task and keep speed independent of refresh rate.
/// The viewport—not the content's ideal width—is what the compact panel measures.
struct CompactMarquee<Content: View>: View {
  let viewportWidth: CGFloat
  private let content: Content

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var contentWidth: CGFloat = 0
  @State private var epoch = Date()

  init(viewportWidth: CGFloat, @ViewBuilder content: () -> Content) {
    self.viewportWidth = viewportWidth
    self.content = content()
  }

  private var motion: MarqueeMotion {
    MarqueeMotion(viewportWidth: viewportWidth, contentWidth: contentWidth)
  }

  @ViewBuilder var body: some View {
    if reduceMotion {
      content
        .lineLimit(1)
        .frame(width: viewportWidth, alignment: .leading)
        .clipped()
    } else {
      TimelineView(.animation(minimumInterval: 1 / 30, paused: motion.travelDistance == 0)) {
        timeline in
        let offset = motion.offset(at: timeline.date.timeIntervalSince(epoch))
        content
          .fixedSize(horizontal: true, vertical: false)
          .onGeometryChange(for: CGFloat.self, of: \.size.width) { width in
            guard width != contentWidth else { return }
            contentWidth = width
            epoch = Date()
          }
          .offset(x: offset)
          .frame(width: viewportWidth, alignment: .leading)
          .clipped()
          .mask {
            LinearGradient(
              stops: [
                .init(color: offset < -0.5 ? .clear : .black, location: 0),
                .init(color: .black, location: 0.06),
                .init(color: .black, location: 0.94),
                .init(
                  color: offset > -motion.travelDistance + 0.5 ? .clear : .black,
                  location: 1),
              ],
              startPoint: .leading, endPoint: .trailing)
          }
      }
    }
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
    CompactMarquee(viewportWidth: 120) {
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
    }
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
