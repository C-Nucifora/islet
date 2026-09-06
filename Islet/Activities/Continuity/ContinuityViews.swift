import AppKit
import SwiftUI

/// One accent for the whole tab, so a row from any app still reads as "your phone".
private let continuityAccent = Color.blue

struct ContinuityCompactLeading: View {
  @ObservedObject var activity: ContinuityActivity

  var body: some View {
    Image(systemName: activity.promoted?.symbol ?? LiveActivityAppStyle.fallbackSymbol)
      .font(.caption2)
      .appThemeForeground(.continuity)
  }
}

/// The app's name, or a count once more than one is running. Accessibility gives us no content to
/// show beyond identity, so the compact slot says who rather than what.
struct ContinuityCompactTrailing: View {
  @ObservedObject var activity: ContinuityActivity

  var body: some View {
    let cards = activity.monitor.cards
    if cards.count > 1 {
      Text("\(cards.count)")
        .font(.caption.weight(.semibold)).monospacedDigit()
        .appThemeForeground(.continuity)
    } else if let card = cards.first {
      Text(card.appName)
        .font(.caption.weight(.semibold))
        .appThemeForeground(.continuity)
        .lineLimit(1)
        .frame(maxWidth: 110)
    }
  }
}

struct ContinuityExpandedView: View {
  @ObservedObject var activity: ContinuityActivity

  private var cards: [LiveActivityCard] { activity.monitor.cards }
  private var availability: ContinuityAvailability { activity.monitor.availability }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Label(
        cards.isEmpty ? String(localized: "iPhone") : String(localized: "iPhone, \(cards.count)"),
        systemImage: "iphone.gen3"
      )
      .font(.caption.weight(.semibold)).foregroundStyle(.secondary)

      if cards.isEmpty {
        emptyState
      } else {
        VStack(spacing: 4) {
          ForEach(cards) { card in ContinuityCardRow(card: card) }
        }
        Spacer(minLength: 0)
        Text("Live Activities show which apps are active. macOS doesn't share their contents.")
          .font(.system(size: 9)).foregroundStyle(.tertiary)
      }
    }
    .foregroundStyle(.white)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  @ViewBuilder private var emptyState: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(availability.explanation)
        .font(.callout).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      // The one empty state the user can act on from here.
      if availability == .needsAccessibility {
        Button("Allow Accessibility access") {
          AccessibilityPermission.prompt()
          AccessibilityPermission.openSettings()
        }
        .buttonStyle(.plain)
        .font(.caption.weight(.semibold))
        .foregroundStyle(continuityAccent)
      } else if availability == .controlCenterUnavailable || availability == .incompatibleSchema {
        Button("Retry") { activity.monitor.retry() }
          .buttonStyle(.plain)
          .font(.caption.weight(.semibold))
          .foregroundStyle(continuityAccent)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}

struct ContinuityCardRow: View {
  let card: LiveActivityCard

  var body: some View {
    Button {
      // Read-only by design: the phone owns the activity, so the useful action is to reach the
      // phone. iPhone Mirroring is the only supported way in from the Mac.
      ContinuityActivity.openIPhoneMirroring()
    } label: {
      HStack(spacing: 8) {
        Image(systemName: card.symbol)
          .font(.caption).foregroundStyle(continuityAccent).frame(width: 18)
        Text(card.appName)
          .font(.caption).foregroundStyle(.white).lineLimit(1)
        Spacer(minLength: 0)
        // A Mac-side activity should not silently pass itself off as one from the phone.
        if !card.isRemote {
          Text("Mac")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 3).fill(.white.opacity(0.08)))
        }
        Image(systemName: "chevron.right")
          .font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
      }
      .padding(.vertical, 4).padding(.horizontal, 6)
      .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.06)))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help("Open iPhone Mirroring")
    .accessibilityLabel(
      card.isRemote
        ? String(localized: "\(card.appName), iPhone Live Activity")
        : String(localized: "\(card.appName), Mac Live Activity")
    )
    .accessibilityHint("Opens iPhone Mirroring")
  }
}
