import Foundation

/// Recovers a `Date` from whatever a third-party app happened to encode.
///
/// There is no agreement to lean on. `JSONEncoder`'s default strategy writes a `Date` as seconds
/// since the 2001 reference date, but plenty of apps set `.secondsSince1970`, some ship
/// milliseconds from a JavaScript backend, and some send ISO-8601 strings. All four arrive here as
/// an indistinguishable number or string.
///
/// The disambiguator is magnitude. Right now reference-date seconds are ~8.1e8, epoch seconds
/// ~1.79e9 and epoch milliseconds ~1.79e12 — three orders of magnitude apart, so a value that
/// lands inside a plausible window under one reading lands in 1970 or 2057 under the others. We
/// try each and keep the reading that is actually near today.
enum PayloadDate {
  /// How far either side of "now" a decoded date has to land to be believed. A Live Activity's
  /// dates cluster around the present; anything outside this is a misread scale, not a real date.
  static let pastTolerance: TimeInterval = -30 * 24 * 3600
  static let futureTolerance: TimeInterval = 400 * 24 * 3600

  static func interpret(_ value: PayloadValue, now: Date) -> Date? {
    if let s = value.stringValue, let iso = parseISO8601(s) { return plausible(iso, now: now) }
    guard let raw = value.numberValue, raw.isFinite else { return nil }
    // Ordered by likelihood, but the readings are mutually exclusive in practice, so order only
    // decides genuinely ambiguous values (all of which are decades away from now).
    let candidates = [
      Date(timeIntervalSinceReferenceDate: raw),
      Date(timeIntervalSince1970: raw),
      Date(timeIntervalSince1970: raw / 1000),
    ]
    return candidates.lazy.compactMap { plausible($0, now: now) }.first
  }

  private static func plausible(_ date: Date, now: Date) -> Date? {
    let delta = date.timeIntervalSince(now)
    return (pastTolerance...futureTolerance).contains(delta) ? date : nil
  }

  private static func parseISO8601(_ s: String) -> Date? {
    // Fractional seconds are optional in the wild and the formatter is strict about it, so try both.
    let withFraction = ISO8601DateFormatter()
    withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = withFraction.date(from: s) { return d }
    return ISO8601DateFormatter().date(from: s)
  }
}
