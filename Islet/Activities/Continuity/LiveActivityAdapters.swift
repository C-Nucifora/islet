import Foundation

/// Turns one app's payload into drawable fields when the generic reader is not good enough.
///
/// Adapters exist because `ContentState` is app-defined: every app invents its own key names, and
/// some encode the interesting parts in ways no heuristic recovers — an enum case rendered as
/// `"stage": 3`, say, which only means something if you know the app.
protocol LiveActivityAdapter: Sendable {
  /// iOS bundle identifiers this adapter claims.
  static var bundleIdentifiers: [String] { get }
  /// Return `nil` to decline and fall through to the generic reader.
  static func render(content: PayloadValue?, attributes: PayloadValue?, now: Date)
    -> LiveActivityRender?
}

enum LiveActivityAdapters {
  /// Payload adapters, consulted before the generic reader.
  ///
  /// Deliberately empty. An adapter asserts what a specific app's keys mean, and asserting that
  /// without having seen the app's real payload produces confidently wrong cards — worse than the
  /// generic reader's honest gaps. Add one here once a capture shows what the app actually sends;
  /// `ContinuityCapture` exists to produce exactly that.
  static let payloadAdapters: [any LiveActivityAdapter.Type] = []

  static func render(for raw: RawLiveActivity, now: Date = Date()) -> LiveActivityRender {
    let content = raw.contentData.flatMap(PayloadValue.decode)
    let attributes = raw.attributesData.flatMap(PayloadValue.decode)
    if let bundleIdentifier = raw.bundleIdentifier {
      for adapter in payloadAdapters
      where adapter.bundleIdentifiers.contains(bundleIdentifier) {
        if let rendered = adapter.render(content: content, attributes: attributes, now: now) {
          return rendered
        }
      }
    }
    return GenericPayloadReader.read(content: content, attributes: attributes, now: now)
  }
}

/// Presentation for an app, keyed by bundle identifier.
///
/// Separate from `LiveActivityAdapter` on purpose: an icon and an accent depend only on *which*
/// app it is, never on the payload's schema, so this map can be correct without having seen a
/// single real payload. The apps below ship Live Activities on iOS and have no Mac counterpart to
/// read an icon from, which is why the glyph has to be hard-coded rather than resolved.
enum LiveActivityAppStyle {
  private static let symbols: [String: String] = [
    "com.apple.mobiletimer": "timer",
    "com.apple.mobiletimer.timer": "timer",
    "com.apple.Maps": "location.fill",
    "com.apple.podcasts": "waveform",
    "com.apple.Music": "music.note",
    "com.apple.news": "newspaper.fill",
    "com.apple.reminders": "checklist",
    "com.apple.mobilecal": "calendar",
    "com.apple.Fitness": "figure.run",
    "com.apple.weather": "cloud.sun.fill",
    "com.apple.findmy": "location.magnifyingglass",
    "com.apple.Passbook": "wallet.pass.fill",
    "com.apple.stocks": "chart.line.uptrend.xyaxis",
    "com.apple.tv": "tv",
    "com.apple.sports": "sportscourt.fill",
    "com.apple.Home": "house.fill",
    "com.apple.VoiceMemos": "waveform.circle.fill",
    "com.ubercab.UberClient": "car.fill",
    "com.ubercab.eats": "takeoutbag.and.cup.and.straw.fill",
    "com.doordash.doordash": "takeoutbag.and.cup.and.straw.fill",
    "com.lyft.ios": "car.fill",
    "com.spotify.client": "music.note",
    "com.flighty.flighty": "airplane",
    "com.strava.stravaride": "figure.outdoor.cycle",
  ]

  /// Falls back to the phone glyph rather than a generic placeholder: whatever the app is, the
  /// thing the user needs to recognise at a glance is that this came from their iPhone.
  static let fallbackSymbol = "iphone.gen3"

  static func symbol(forBundleIdentifier bundleIdentifier: String?) -> String {
    guard let bundleIdentifier else { return fallbackSymbol }
    return symbols[bundleIdentifier] ?? fallbackSymbol
  }

  /// Last-resort display name when the daemon gave us no `localizedAppName`: the final component
  /// of the bundle id reads far better than the whole reverse-DNS string in a 200pt-wide island.
  static func name(forBundleIdentifier bundleIdentifier: String?) -> String {
    guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return "iPhone" }
    return bundleIdentifier.split(separator: ".").last.map(String.init) ?? bundleIdentifier
  }
}
