import Foundation

/// One observer of one kind of system event.
///
/// Sources are started and stopped by `SystemEventBus` as the user toggles them, so a disabled
/// source holds no notification registration, no run-loop source and no timer — it costs nothing.
@MainActor
protocol SystemEventSource: AnyObject {
  /// Stable identifier. Doubles as the coalescing key on every event this source emits, and as the
  /// Defaults key suffix for its toggle.
  var id: String { get }
  var displayName: String { get }
  var tier: SystemEventTier { get }
  /// Begin observing. Must be idempotent — the bus may call it again after a Defaults round trip.
  func start()
  /// Stop observing and release every registration. Must leave the source restartable.
  func stop()
}

/// The single list of every event source: its id, its user-facing name, its tier and its icon.
///
/// Settings renders from this, the Debug menu generates a "fire this event" button from it, and the
/// bus validates registrations against it. Adding a source means adding one row here and one file.
enum SourceCatalog {
  static let all: [(id: String, name: String, tier: SystemEventTier, icon: String)] = [
    // Tier 1 — public, callback-driven, no permission.
    ("usb", "USB devices", .core, "cable.connector"),
    ("volume", "Disks and volumes", .core, "externaldrive.fill"),
    ("display", "External displays", .core, "display"),
    ("power", "Low Power Mode", .core, "bolt.fill"),
    ("sleep", "Sleep and wake", .core, "moon.fill"),
    ("peripheral", "Peripheral batteries", .core, "magicmouse.fill"),
    ("audiodevice", "Audio output device", .core, "airpodspro"),
    ("battery", "Battery", .core, "battery.100percent.bolt"),
    ("timer", "Timer", .core, "timer"),
    ("nowPlaying", "Track changes", .core, "music.note"),
    // Tier 2 — public and reliable; Wi-Fi names cost one Location prompt.
    ("wifi", "Wi-Fi", .extended, "wifi"),
    ("bluetooth", "Bluetooth devices", .extended, "dot.radiowaves.right"),
    ("session", "Screen lock and Caps Lock", .extended, "lock.fill"),
    ("screenshot", "Screenshots", .extended, "camera.viewfinder"),
    // Tier 3 — inferred. Can be late, can be wrong.
    ("airdropOut", "AirDrop sent", .heuristic, "square.and.arrow.up"),
    ("airdropIn", "AirDrop received", .heuristic, "square.and.arrow.down"),
    ("focus", "Focus mode", .heuristic, "moon.circle.fill"),
    ("vpn", "Network tunnel", .heuristic, "lock.shield.fill"),
  ]

  static func name(for id: String) -> String {
    all.first { $0.id == id }?.name ?? id
  }

  static func tier(for id: String) -> SystemEventTier {
    all.first { $0.id == id }?.tier ?? .core
  }

  static func icon(for id: String) -> String {
    all.first { $0.id == id }?.icon ?? "circle"
  }

  static func ids(in tier: SystemEventTier) -> [String] {
    all.filter { $0.tier == tier }.map(\.id)
  }

  /// The motion a source's events normally use, so the Debug menu exercises the real choreography
  /// rather than showing every source with the generic settle.
  static func debugMotion(for id: String) -> MotionProfile {
    switch id {
    case "usb": .usb
    case "volume": .volumeMount
    case "display": .display
    case "power": .lowPower
    case "sleep": .sleepWake
    case "peripheral": .peripheralLow
    case "audiodevice", "bluetooth": .bluetooth
    case "battery": .chargeComplete
    case "wifi": .wifi
    case "session": .lock
    case "screenshot": .screenshot
    case "airdropOut", "airdropIn": .airdrop
    case "focus": .focus
    case "vpn": .vpn
    default: .generic
    }
  }
}
