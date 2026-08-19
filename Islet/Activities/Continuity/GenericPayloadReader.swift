import Foundation

/// Pulls a renderable card out of a payload whose schema we have never seen.
///
/// This is the fallback path, and for most apps it is the *only* path — there are thousands of
/// apps shipping Live Activities and each invents its own `ContentState` keys. Rather than fail
/// closed on anything unrecognised, we read the payload structurally: find the leaf whose key
/// looks most like a title, the one that looks most like a countdown, and so on.
///
/// It is deliberately conservative. A wrong guess renders a confusing card, so a field with no
/// convincing candidate stays `nil` and the view omits it.
enum GenericPayloadReader {
  /// Key patterns per field, best first. `exact` beats `suffix` beats `contains`, and within a
  /// tier a shallower leaf beats a deeper one.
  private struct Pattern {
    let exact: [String]
    let suffix: [String]
    let contains: [String]
  }

  private static let titlePattern = Pattern(
    exact: ["title", "name", "eventname", "headline", "heading", "label", "activityname"],
    suffix: ["title", "name"],
    contains: [])

  private static let subtitlePattern = Pattern(
    exact: [
      "subtitle", "detail", "details", "message", "body", "caption", "secondary",
      "subheadline", "status", "statustext", "statusmessage", "description", "summary",
    ],
    suffix: ["subtitle", "message", "detail", "status"],
    contains: [])

  private static let symbolPattern = Pattern(
    exact: ["symbol", "sfsymbol", "systemimage", "icon", "glyph", "image", "imagename"],
    suffix: ["symbol", "icon", "glyph"],
    contains: [])

  private static let progressKeys = ["progress", "fraction", "completion", "percent", "percentage"]

  /// Numerator/denominator key pairs, so `elapsed`+`total` becomes a ring even when no field
  /// literally says "progress".
  private static let ratioKeys: [(String, String)] = [
    ("elapsed", "total"), ("current", "total"), ("completed", "total"),
    ("done", "total"), ("value", "max"), ("current", "max"), ("index", "count"),
  ]

  /// Tokens that mark a date leaf as the *end* of something. `start`/`created` are excluded
  /// explicitly: a payload almost always carries both, and counting down to the start time of an
  /// activity that has already begun renders a stuck "0:00".
  private static let endTokens = [
    "end", "eta", "deadline", "expir", "finish", "arriv", "until", "due", "target", "complet",
  ]
  private static let notEndTokens = ["start", "begin", "created", "issued", "updated", "stale"]

  static func read(
    content: PayloadValue?, attributes: PayloadValue? = nil, now: Date = Date()
  ) -> LiveActivityRender {
    // Content is the live half and attributes the static half, so content wins every field and
    // attributes only fills the gaps — an app's immutable "Pizza Palace" should never overwrite
    // its live "Out for delivery".
    var render = readOne(content, now: now)
    let fallback = readOne(attributes, now: now)
    render.title = render.title ?? fallback.title
    render.subtitle = render.subtitle ?? fallback.subtitle
    render.progress = render.progress ?? fallback.progress
    render.endDate = render.endDate ?? fallback.endDate
    render.symbol = render.symbol ?? fallback.symbol
    // A payload with one string in it should show that string as the title, not as a subtitle
    // under an empty headline.
    if render.title == nil, let promoted = render.subtitle {
      render.title = promoted
      render.subtitle = nil
    }
    return render
  }

  private static func readOne(_ payload: PayloadValue?, now: Date) -> LiveActivityRender {
    guard let payload else { return LiveActivityRender() }
    let leaves = payload.leaves
    var render = LiveActivityRender()

    let titleLeaf = bestString(in: leaves, matching: titlePattern, excluding: [])
    render.title = titleLeaf.map { text($0) }
    render.subtitle = bestString(
      in: leaves, matching: subtitlePattern, excluding: titleLeaf.map { [$0] } ?? []
    ).map { text($0) }
    render.symbol = bestString(in: leaves, matching: symbolPattern, excluding: [])
      .flatMap { leaf in leaf.value.stringValue.flatMap(symbolCandidate) }
    render.progress = progress(in: leaves)
    render.endDate = endDate(in: leaves, now: now)
    return render
  }

  private static func text(_ leaf: PayloadLeaf) -> String {
    (leaf.value.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func bestString(
    in leaves: [PayloadLeaf], matching pattern: Pattern, excluding: [PayloadLeaf]
  ) -> PayloadLeaf? {
    let candidates = leaves.filter { leaf in
      guard let s = leaf.value.stringValue else { return false }
      guard !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
      // Long prose is a body, a URL or an encoded blob, never a title or subtitle.
      guard s.count <= 140, !s.contains("://") else { return false }
      return !excluding.contains(leaf)
    }
    return candidates
      .compactMap { leaf -> (PayloadLeaf, Int, Int)? in
        guard let rank = rank(key: leaf.key, in: pattern) else { return nil }
        return (leaf, rank, leaf.depth)
      }
      .min { lhs, rhs in
        if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
        return lhs.2 < rhs.2
      }?.0
  }

  /// Lower is better. Tiers are spaced so an exact hit always beats a suffix hit regardless of the
  /// position within each list.
  private static func rank(key: String, in pattern: Pattern) -> Int? {
    let k = key.lowercased()
    if let i = pattern.exact.firstIndex(of: k) { return i }
    if let i = pattern.suffix.firstIndex(where: { k.hasSuffix($0) }) { return 100 + i }
    if let i = pattern.contains.firstIndex(where: { k.contains($0) }) { return 200 + i }
    return nil
  }

  private static func symbolCandidate(_ s: String) -> String? {
    // SF Symbol names are dot-separated lowercase tokens. Anything with a space or a capital is a
    // display string that happened to sit under an "icon" key.
    guard !s.isEmpty, s.count <= 60 else { return nil }
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.")
    return s.unicodeScalars.allSatisfy(allowed.contains) ? s : nil
  }

  private static func progress(in leaves: [PayloadLeaf]) -> Double? {
    let direct = leaves
      .compactMap { leaf -> (Double, Int)? in
        let k = leaf.key.lowercased()
        guard progressKeys.contains(where: { k.contains($0) }), let n = leaf.value.numberValue
        else { return nil }
        // A "percent" field may be 0...1 or 0...100; only the latter needs scaling.
        let scaled = (k.contains("percent") && n > 1) ? n / 100 : n
        guard (0...1).contains(scaled) else { return nil }
        return (scaled, leaf.depth)
      }
      .min { $0.1 < $1.1 }?.0
    if let direct { return direct }

    for (numeratorKey, denominatorKey) in ratioKeys {
      guard
        let n = number(in: leaves, keySuffix: numeratorKey),
        let d = number(in: leaves, keySuffix: denominatorKey),
        d > 0, n >= 0, n <= d
      else { continue }
      return n / d
    }
    return nil
  }

  private static func number(in leaves: [PayloadLeaf], keySuffix: String) -> Double? {
    leaves
      .filter { $0.key.lowercased().hasSuffix(keySuffix) }
      .compactMap { leaf in leaf.value.numberValue.map { ($0, leaf.depth) } }
      .min { $0.1 < $1.1 }?.0
  }

  private static func endDate(in leaves: [PayloadLeaf], now: Date) -> Date? {
    let candidates = leaves.compactMap { leaf -> (Date, Int)? in
      let k = leaf.key.lowercased()
      guard endTokens.contains(where: { k.contains($0) }) else { return nil }
      guard !notEndTokens.contains(where: { k.contains($0) }) else { return nil }
      guard let date = PayloadDate.interpret(leaf.value, now: now) else { return nil }
      return (date, leaf.depth)
    }
    // A countdown is only meaningful while it is still running; among several future dates take
    // the soonest, which is the next thing to actually happen.
    let future = candidates.filter { $0.0 > now }
    if let soonest = future.min(by: { $0.0 < $1.0 }) { return soonest.0 }
    return nil
  }
}
