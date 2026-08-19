import Foundation

/// Merges the two streams the daemon exposes into one ordered list.
///
/// They carry different halves of the truth and arrive independently: the descriptor stream is
/// authoritative about *which* activities exist but carries no payload, while the content stream
/// carries the payload for one activity at a time and says nothing about the rest. A descriptor
/// can also land before its first content update, so the merge has to tolerate a known activity
/// with no content yet rather than dropping it.
///
/// Pure and synchronous so the ordering and diffing rules are testable without a paired iPhone.
struct LiveActivityStore: Equatable {
  private(set) var byID: [String: RawLiveActivity] = [:]

  /// What changed in `ordered`, for driving sneaks.
  struct Change: Equatable {
    var added: [LiveActivityCard] = []
    var removed: [LiveActivityCard] = []
    var isEmpty: Bool { added.isEmpty && removed.isEmpty }
  }

  /// Replaces membership from the descriptor stream, preserving payloads already received.
  ///
  /// The descriptor callback re-sends the whole set on every change and carries no content, so
  /// overwriting wholesale would blank every card each time any one activity updated.
  mutating func apply(descriptors: [RawLiveActivity], now: Date = Date()) -> Change {
    let before = ordered(now: now)
    let incoming = Set(descriptors.map(\.id))
    for descriptor in descriptors {
      if var existing = byID[descriptor.id] {
        existing.bundleIdentifier = descriptor.bundleIdentifier ?? existing.bundleIdentifier
        existing.appName = descriptor.appName ?? existing.appName
        existing.remoteDeviceIdentifier =
          descriptor.remoteDeviceIdentifier ?? existing.remoteDeviceIdentifier
        existing.createdDate = descriptor.createdDate ?? existing.createdDate
        existing.isImportant = descriptor.isImportant
        existing.isMomentary = descriptor.isMomentary
        existing.isEphemeral = descriptor.isEphemeral
        existing.attributesData = descriptor.attributesData ?? existing.attributesData
        byID[descriptor.id] = existing
      } else {
        byID[descriptor.id] = descriptor
      }
    }
    byID = byID.filter { incoming.contains($0.key) }
    return Self.change(from: before, to: ordered(now: now))
  }

  /// Applies one activity's live payload. Upserts rather than requiring a prior descriptor: the
  /// content stream is allowed to be the first thing we hear about an activity.
  mutating func apply(content: RawLiveActivity, now: Date = Date()) -> Change {
    let before = ordered(now: now)
    if var existing = byID[content.id] {
      existing.contentData = content.contentData ?? existing.contentData
      existing.staleDate = content.staleDate ?? existing.staleDate
      existing.relevanceScore = content.relevanceScore
      existing.state = content.state
      existing.bundleIdentifier = content.bundleIdentifier ?? existing.bundleIdentifier
      existing.appName = content.appName ?? existing.appName
      existing.remoteDeviceIdentifier =
        content.remoteDeviceIdentifier ?? existing.remoteDeviceIdentifier
      existing.attributesData = content.attributesData ?? existing.attributesData
      byID[content.id] = existing
    } else {
      byID[content.id] = content
    }
    return Self.change(from: before, to: ordered(now: now))
  }

  /// Live activities, most relevant first.
  ///
  /// Mac-originated activities are ordered last rather than filtered out. Filtering on
  /// `isRemote` would be the tighter rule, but if `remoteDeviceIdentifier` turns out to be unset
  /// on some replication paths it would empty the tab with no visible reason; ordering them last
  /// and badging them in the view fails loudly instead. macOS has no third-party ActivityKit, so
  /// in practice everything here came from the phone.
  func ordered(now: Date = Date()) -> [LiveActivityCard] {
    byID.values
      .filter(\.isLive)
      .map { LiveActivityCard.make(from: $0, now: now) }
      .sorted { lhs, rhs in
        if lhs.isRemote != rhs.isRemote { return lhs.isRemote }
        if lhs.relevanceScore != rhs.relevanceScore { return lhs.relevanceScore > rhs.relevanceScore }
        let l = lhs.createdDate ?? .distantPast
        let r = rhs.createdDate ?? .distantPast
        if l != r { return l > r }
        // Total order: without this, equal-scoring activities can swap places between renders and
        // the promoted card flickers.
        return lhs.id < rhs.id
      }
  }

  private static func change(from before: [LiveActivityCard], to after: [LiveActivityCard])
    -> Change
  {
    let diff = SetDiff.changes(from: before, to: after)
    return Change(added: diff.added, removed: diff.removed)
  }
}
