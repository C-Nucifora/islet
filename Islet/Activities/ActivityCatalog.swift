import Foundation

/// The activities the user can reorder in the expanded switcher (Home is always pinned first).
enum ActivityCatalog {
  static let orderable: [(id: String, name: String, icon: String)] = [
    ("timer", "Timer", "timer"),
    ("nowPlaying", "Now Playing", "music.note"),
    ("shelf", "File Shelf", "tray.full.fill"),
    ("clipboard", "Clipboard", "doc.on.clipboard"),
    ("calendar", "Calendar", "calendar"),
    ("battery", "Battery", "battery.100percent.bolt"),
  ]

  static var defaultOrder: [String] { orderable.map(\.id) }

  static func name(for id: String) -> String {
    orderable.first { $0.id == id }?.name ?? id
  }

  static func icon(for id: String) -> String {
    orderable.first { $0.id == id }?.icon ?? "app.dashed"
  }
}
