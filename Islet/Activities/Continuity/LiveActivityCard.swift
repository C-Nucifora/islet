import Foundation

/// One row in the iPhone tab: an activity with its schema already resolved into drawable fields.
struct LiveActivityCard: Identifiable, Equatable, Sendable {
  let id: String
  var appName: String
  var bundleIdentifier: String?
  var render: LiveActivityRender
  var createdDate: Date?
  var relevanceScore: Double
  var isImportant: Bool
  /// False means the activity originated on this Mac rather than being replicated from the phone.
  /// Surfaced rather than filtered — see `LiveActivityStore.ordered`.
  var isRemote: Bool

  /// What the compact island shows when this card is the promoted one. Falls back through the
  /// title to the app name, because an activity with an unreadable payload should still say which
  /// app it belongs to rather than render blank.
  var compactText: String {
    render.title ?? appName
  }

  static func make(from raw: RawLiveActivity, now: Date = Date()) -> LiveActivityCard {
    var render = LiveActivityAdapters.render(for: raw, now: now)
    // `staleDate` is the daemon's own "this content expires at" and is schema-independent, so it
    // is a safe countdown when the payload did not yield one.
    if render.endDate == nil, let stale = raw.staleDate, stale > now { render.endDate = stale }
    if render.symbol == nil {
      render.symbol = LiveActivityAppStyle.symbol(forBundleIdentifier: raw.bundleIdentifier)
    }
    return LiveActivityCard(
      id: raw.id,
      appName: raw.appName ?? LiveActivityAppStyle.name(forBundleIdentifier: raw.bundleIdentifier),
      bundleIdentifier: raw.bundleIdentifier,
      render: render,
      createdDate: raw.createdDate,
      relevanceScore: raw.relevanceScore,
      isImportant: raw.isImportant,
      isRemote: raw.isRemote)
  }
}
