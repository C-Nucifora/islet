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

/// Trailing compact slot for the HUD: a slim level bar.
struct HUDBarView: View {
  let snapshot: HUDSnapshot

  var body: some View {
    Capsule()
      .fill(.white.opacity(0.25))
      .frame(width: 70, height: 4)
      .overlay(alignment: .leading) {
        Capsule()
          .fill(.white)
          .frame(width: max(2, 70 * CGFloat(snapshot.level)), height: 4)
      }
      .animation(.linear(duration: 0.12), value: snapshot.level)
  }
}
