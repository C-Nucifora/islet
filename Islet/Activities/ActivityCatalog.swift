import Foundation

/// The activities the user can reorder in the expanded switcher (Home is always pinned first).
enum ActivityCatalog {
  static let orderable: [(id: String, name: String, icon: String)] = [
    ("pulse", String(localized: "Pulse"), "waveform.path.ecg"),
    ("t3Code", String(localized: "T3 Code"), "terminal.fill"),
    ("timer", String(localized: "Timer"), "timer"),
    ("nowPlaying", String(localized: "Now Playing"), "music.note"),
    ("shelf", String(localized: "File Shelf"), "tray.full.fill"),
    ("clipboard", String(localized: "Clipboard"), "doc.on.clipboard"),
    ("ports", String(localized: "Ports"), "cable.connector"),
    ("calendar", String(localized: "Calendar"), "calendar"),
    ("battery", String(localized: "Battery"), "battery.100percent.bolt"),
    ("system", String(localized: "System"), "cpu"),
    ("continuity", String(localized: "iPhone"), "iphone.gen3"),
  ]

  static var defaultOrder: [String] { orderable.map(\.id) }

  /// Activities whose observer/server lifecycle follows their visibility toggle. AppDelegate uses
  /// the same ids when reconciling feature switches; publishing the classification here gives
  /// tests a way to catch a newly catalogued activity that nobody starts or deliberately exempts.
  static let lifecycleManagedIDs: Set<String> = [
    "pulse", "t3Code", "nowPlaying", "shelf", "clipboard", "ports", "calendar", "battery",
    "system", "continuity",
  ]

  /// Timer owns no background polling and must keep an already-running completion task when hidden.
  static let persistentLifecycleIDs: Set<String> = ["timer"]

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
