import AppKit
import SwiftUI

/// Tint for everything in this tab. One accent, so a row from any app still reads as "your phone".
private let continuityAccent = Color.blue

/// Resolves a candidate SF Symbol name, falling back when the payload's guess is not a real symbol.
///
/// `GenericPayloadReader` cannot check this — validating a symbol needs AppKit and the reader is
/// deliberately pure — so the check lands here, at the only place that actually needs the answer.
private func resolvedSymbol(_ name: String?) -> String {
  guard let name, NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil else {
    return LiveActivityAppStyle.fallbackSymbol
  }
  return name
}

struct ContinuityCompactLeading: View {
  @ObservedObject var activity: ContinuityActivity

  var body: some View {
    Image(systemName: resolvedSymbol(activity.promoted?.render.symbol))
      .font(.caption2)
      .foregroundStyle(continuityAccent)
  }
}

/// Countdown if there is one, then progress, then the title. Only one of the three, because the
/// compact island is a few dozen points wide and the panel is sized from what this measures.
struct ContinuityCompactTrailing: View {
  @ObservedObject var activity: ContinuityActivity

  var body: some View {
    if let card = activity.promoted {
      if let end = card.render.endDate {
        TimelineView(.periodic(from: .now, by: 1)) { context in
          Text(LiveActivityCountdown.text(to: end, now: context.date))
            .font(.caption.weight(.semibold)).monospacedDigit()
            .foregroundStyle(continuityAccent)
        }
      } else if let progress = card.render.progress {
        Text("\(Int((progress * 100).rounded()))%")
          .font(.caption.weight(.semibold)).monospacedDigit()
          .foregroundStyle(continuityAccent)
      } else {
        Text(card.compactText)
          .font(.caption.weight(.semibold))
          .foregroundStyle(continuityAccent)
          .lineLimit(1)
          .frame(maxWidth: 110)
      }
    }
  }
}

struct ContinuityExpandedView: View {
  @ObservedObject var activity: ContinuityActivity

  private var cards: [LiveActivityCard] { activity.monitor.cards }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Label(
        cards.isEmpty ? "iPhone" : "iPhone — \(cards.count)",
        systemImage: "iphone.gen3"
      )
      .font(.caption.weight(.semibold)).foregroundStyle(.secondary)

      if cards.isEmpty {
        VStack(alignment: .leading, spacing: 6) {
          Text(activity.monitor.availability.explanation)
            .font(.callout).foregroundStyle(.secondary)
          if activity.monitor.availability == .waiting {
            Text("Live Activities appear here the way they do in the menu bar.")
              .font(.caption).foregroundStyle(.tertiary)
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      } else {
        ScrollView(.vertical, showsIndicators: false) {
          VStack(spacing: 4) {
            ForEach(cards) { card in
              ContinuityCardRow(card: card)
            }
          }
        }
      }
    }
    .foregroundStyle(.white)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}

struct ContinuityCardRow: View {
  let card: LiveActivityCard

  var body: some View {
    Button {
      // Read-only by design: the phone owns the activity, so the useful action is to get to the
      // phone. iPhone Mirroring is the only supported way in from the Mac.
      if let url = NSWorkspace.shared.urlForApplication(
        withBundleIdentifier: "com.apple.ScreenContinuity")
      {
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
      }
    } label: {
      HStack(spacing: 8) {
        Image(systemName: resolvedSymbol(card.render.symbol))
          .font(.caption).foregroundStyle(continuityAccent).frame(width: 18)

        VStack(alignment: .leading, spacing: 1) {
          Text(card.render.title ?? card.appName)
            .font(.caption).foregroundStyle(.white).lineLimit(1)
          if let subtitle = card.render.subtitle {
            Text(subtitle)
              .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
          } else if card.render.title != nil {
            Text(card.appName)
              .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
          }
        }

        Spacer(minLength: 0)

        // A Mac-originated activity should not silently masquerade as one from the phone.
        if !card.isRemote {
          Text("Mac")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 3).fill(.white.opacity(0.08)))
        }

        if let end = card.render.endDate {
          TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(LiveActivityCountdown.text(to: end, now: context.date))
              .font(.caption.weight(.semibold)).monospacedDigit()
              .foregroundStyle(continuityAccent)
          }
        } else if let progress = card.render.progress {
          ProgressView(value: progress)
            .progressViewStyle(.linear)
            .tint(continuityAccent)
            .frame(width: 64)
        }
      }
      .padding(.vertical, 3).padding(.horizontal, 6)
      .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.06)))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help("Open iPhone Mirroring")
  }
}
