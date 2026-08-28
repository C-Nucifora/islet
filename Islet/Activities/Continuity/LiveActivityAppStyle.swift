import Foundation

/// The glyph and display name for an app, keyed by iOS bundle identifier.
///
/// These apps live on the phone and have no Mac counterpart to pull an icon from — `NSWorkspace`
/// cannot resolve `com.ubercab.UberClient` to anything local — so the glyph has to be a hard-coded
/// SF Symbol. The mapping depends only on *which* app it is, never on anything we cannot read.
enum LiveActivityAppStyle {
  private static let symbols: [String: String] = [
    "com.apple.mobiletimer": "timer",
    "com.apple.Maps": "location.fill",
    "com.apple.podcasts": "waveform",
    "com.apple.Music": "music.note",
    "com.apple.reminders": "checklist",
    "com.apple.mobilecal": "calendar",
    "com.apple.Fitness": "figure.run",
    "com.apple.weather": "cloud.sun.fill",
    "com.apple.findmy": "location.magnifyingglass",
    "com.apple.Passbook": "wallet.pass.fill",
    "com.apple.stocks": "chart.line.uptrend.xyaxis",
    "com.apple.sports": "sportscourt.fill",
    "com.apple.VoiceMemos": "waveform.circle.fill",
    "com.ubercab.UberClient": "car.fill",
    "com.ubercab.eats": "takeoutbag.and.cup.and.straw.fill",
    "com.doordash.doordash": "takeoutbag.and.cup.and.straw.fill",
    "com.lyft.ios": "car.fill",
    "com.spotify.client": "music.note",
    "com.flighty.flighty": "airplane",
    "com.strava.stravaride": "figure.outdoor.cycle",
    "com.t3tools.t3code": "terminal.fill",
  ]

  /// The phone glyph, not a generic placeholder: whatever the app turns out to be, the thing worth
  /// recognising at a glance is that this came from the iPhone.
  static let fallbackSymbol = "iphone.gen3"

  static func symbol(forBundleIdentifier bundleIdentifier: String) -> String {
    symbols[bundleIdentifier] ?? fallbackSymbol
  }

  /// Used only when the accessibility description is missing. The last component of a bundle id
  /// reads far better than the whole reverse-DNS string in an island a few hundred points wide.
  static func name(forBundleIdentifier bundleIdentifier: String) -> String {
    bundleIdentifier.split(separator: ".").last.map(String.init) ?? bundleIdentifier
  }
}
