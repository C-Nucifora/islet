import Foundation

/// The activities the user can reorder in the expanded switcher (Home is always pinned first).
enum ActivityCatalog {
  static let orderable: [(id: String, name: String, icon: String)] = [
    ("timer", "Timer", "timer"),
    ("nowPlaying", "Now Playing", "music.note"),
    ("shelf", "File Shelf", "tray.full.fill"),
    ("clipboard", "Clipboard", "doc.on.clipboard"),
    ("ports", "Ports", "cable.connector"),
    ("calendar", "Calendar", "calendar"),
    ("battery", "Battery", "battery.100percent.bolt"),
    ("system", "System", "cpu"),
    ("continuity", "iPhone", "iphone.gen3"),
  ]

  static var defaultOrder: [String] { orderable.map(\.id) }

  /// The user's stored order, with any catalogue entries it predates appended at the end.
  ///
  /// `Defaults[.activityOrder]` is persisted, so an install from before a new activity shipped
  /// never contains its id — and the Settings menu-order list renders from the stored array, which
  /// made the new tab impossible to reorder or disable there. Ranking already treated unlisted ids
  /// as last (`ActivityCenter.activeActivities`), so appending preserves what the user sees.
  /// Unknown ids are kept: deleting them would throw away the ordering of an activity a newer
  /// build might reintroduce.
  static func mergedOrder(_ stored: [String]) -> [String] {
    stored + defaultOrder.filter { !stored.contains($0) }
  }

  static func name(for id: String) -> String {
    orderable.first { $0.id == id }?.name ?? id
  }

  static func icon(for id: String) -> String {
    orderable.first { $0.id == id }?.icon ?? "app.dashed"
  }
}
