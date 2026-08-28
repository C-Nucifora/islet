import Defaults
import SwiftUI

/// Leading compact slot for the HUD: the volume/brightness icon.
struct HUDIconView: View {
  let snapshot: HUDSnapshot

  private var iconName: String {
    switch snapshot.kind {
    case .brightness: "sun.max.fill"
    case .volume:
      if snapshot.isMuted || snapshot.level == 0 {
        "speaker.slash.fill"
      } else if snapshot
        .level < 0.5
      {
        "speaker.wave.1.fill"
      } else {
        "speaker.wave.2.fill"
      }
    }
  }

  var body: some View {
    Image(systemName: iconName)
      .font(.caption)
      .foregroundStyle(.white)
      .frame(width: 16)
  }
}

/// Trailing compact slot for the HUD: a level indicator, either a linear bar or a radial gauge.
struct HUDBarView: View {
  let snapshot: HUDSnapshot
  @Default(.hudStyle) private var style

  private var normalizedLevel: CGFloat { CGFloat(max(0, min(1, snapshot.level))) }
  private var accessibilityLabel: String {
    switch snapshot.kind {
    case .brightness: "Brightness"
    case .volume: snapshot.isMuted ? "Volume muted" : "Volume"
    }
  }

  var body: some View {
    Group {
      if style == .gauge {
        ZStack {
          Circle().stroke(.white.opacity(0.25), lineWidth: 3)
          Circle()
            .trim(from: 0, to: normalizedLevel)
            .stroke(.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
            .rotationEffect(.degrees(-90))
        }
        .frame(width: 16, height: 16)
      } else {
        Capsule()
          .fill(.white.opacity(0.25))
          .frame(width: 70, height: 4)
          .overlay(alignment: .leading) {
            Capsule()
              .fill(.white)
              .frame(width: 70 * normalizedLevel, height: 4)
          }
      }
    }
    .animation(Motion.gated(.linear(duration: 0.12)), value: snapshot.level)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityLabel)
    .accessibilityValue("\(Int((normalizedLevel * 100).rounded())) percent")
  }
}
