import Foundation

/// How reliably a source can observe what it claims to observe.
///
/// This is surfaced to the user in Settings, because it is the difference between "Islet will tell
/// you when a USB device is plugged in" and "Islet will probably notice a file that probably arrived
/// by AirDrop, shortly after it finished arriving".
enum SystemEventTier: Int, CaseIterable, Codable, Sendable {
  /// Public, callback-driven, no permission, no ambiguity.
  case core = 1
  /// Public and reliable; may cost one permission prompt.
  case extended = 2
  /// Inferred. Can be late, can be wrong, cannot always name what it saw.
  case heuristic = 3

  var label: String {
    switch self {
    case .core: String(localized: "Devices and power")
    case .extended: String(localized: "Network and session")
    case .heuristic: String(localized: "Inferred (may be late or wrong)")
    }
  }
}

/// Scheduling priority for queued compact-island events.
///
/// `SneakLogic` dequeues higher urgency before lower urgency while preserving FIFO order within an
/// urgency level. It gives an ambient event one turn after three consecutive alerts so alert storms
/// cannot leave ambient updates queued forever. A displayed sneak is never interrupted.
enum SystemEventUrgency: Int, Comparable, Sendable {
  case ambient = 0
  case normal = 1
  case alert = 2

  static func < (l: Self, r: Self) -> Bool { l.rawValue < r.rawValue }
}

/// The accent palette, as `#RRGGBB` strings so `SystemEvent` stays `Equatable` and `Sendable`
/// without dragging SwiftUI's `Color` (which is neither, usefully) into the model.
enum EventAccent {
  static let neutral = "#EBEBF5"
  static let positive = "#32D74B"
  static let warning = "#FFD60A"
  static let danger = "#FF453A"
  static let info = "#0A84FF"
}

/// One thing that happened, described completely enough that nothing downstream needs to know which
/// source produced it.
///
/// `Equatable` deliberately ignores `id`: the coalescer and the queue need to ask "is this the same
/// event as that one?", and a per-instance UUID would make the answer always no.
struct SystemEvent: Identifiable, Equatable, Sendable {
  let id: UUID
  /// Coalescing key. Matches the emitting source's `id`, so a second event from the same source
  /// replaces a queued one rather than stacking behind it — the semantics `SneakLogic.enqueue`
  /// already implements.
  let sourceID: String
  let icon: String
  let title: String
  var subtitle: String?
  var accentHex: String
  var motion: MotionProfile
  var urgency: SystemEventUrgency
  var duration: TimeInterval
  /// Explicit VoiceOver text. Leave nil and `spokenAnnouncement` composes one.
  var announcement: String?

  init(
    id: UUID = UUID(),
    sourceID: String,
    icon: String,
    title: String,
    subtitle: String? = nil,
    accentHex: String = EventAccent.neutral,
    motion: MotionProfile = .generic,
    urgency: SystemEventUrgency = .normal,
    duration: TimeInterval = 2,
    announcement: String? = nil
  ) {
    self.id = id
    self.sourceID = sourceID
    self.icon = icon
    self.title = title
    self.subtitle = subtitle
    self.accentHex = accentHex
    self.motion = motion
    self.urgency = urgency
    self.duration = duration
    self.announcement = announcement
  }

  /// What VoiceOver says. A source that sets no announcement is still announced.
  var spokenAnnouncement: String {
    if let announcement { return announcement }
    guard let subtitle, !subtitle.isEmpty else { return title }
    return String(localized: "\(title), \(subtitle)", comment: "VoiceOver event announcement")
  }

  static func == (l: Self, r: Self) -> Bool {
    l.sourceID == r.sourceID && l.icon == r.icon && l.title == r.title
      && l.subtitle == r.subtitle && l.accentHex == r.accentHex && l.motion == r.motion
      && l.urgency == r.urgency && l.duration == r.duration && l.announcement == r.announcement
  }
}
