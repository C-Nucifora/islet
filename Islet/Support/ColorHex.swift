import CoreGraphics
import SwiftUI

/// Converts an EventKit calendar/list `CGColor` to a stable `#RRGGBB` string for the data model.
enum ColorHex {
  static func string(from cgColor: CGColor?) -> String? {
    guard let cgColor,
      let srgb = CGColorSpace(name: CGColorSpace.sRGB),
      let converted = cgColor.converted(to: srgb, intent: .defaultIntent, options: nil),
      let c = converted.components, c.count >= 3
    else { return nil }
    return String(
      format: "#%02X%02X%02X",
      Int((c[0] * 255).rounded()), Int((c[1] * 255).rounded()),
      Int((c[2] * 255).rounded()))
  }
}

extension Color {
  /// Builds a `Color` from a `#RRGGBB` string; nil input or bad format returns nil.
  init?(isletHex hex: String?) {
    guard var s = hex else { return nil }
    if s.hasPrefix("#") { s.removeFirst() }
    guard s.count == 6, let v = Int(s, radix: 16) else { return nil }
    self.init(
      .sRGB,
      red: Double((v >> 16) & 0xFF) / 255,
      green: Double((v >> 8) & 0xFF) / 255,
      blue: Double(v & 0xFF) / 255)
  }
}
