import SwiftUI

/// Small helpers building the audio-device sneak's compact views.
enum AnyViewBox {
  static func icon(_ systemName: String) -> AnyView {
    AnyView(
      Image(systemName: systemName)
        .font(.caption).foregroundStyle(.white))
  }

  static func name(_ text: String) -> AnyView {
    AnyView(
      Text(text)
        .font(.caption2.weight(.medium)).foregroundStyle(.white)
        .lineLimit(1).frame(maxWidth: 150))
  }
}
