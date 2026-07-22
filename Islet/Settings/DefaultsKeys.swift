import Defaults
import Foundation

extension InteractionMode: Defaults.Serializable {}
extension MediaSourceMode: Defaults.Serializable {}

extension Defaults.Keys {
  static let mediaSourceMode = Key<MediaSourceMode>("mediaSourceMode", default: .auto)
  static let mediaPriorityList = Key<[String]>(
    "mediaPriorityList",
    default: ["com.spotify.client", "com.apple.Music"])
  static let interactionMode = Key<InteractionMode>("interactionMode", default: .hover)
  static let hoverExpandDelay = Key<Double>("hoverExpandDelay", default: 0.3)
  static let hoverCollapseTimeout = Key<Double>("hoverCollapseTimeout", default: 0.5)
  static let hapticsEnabled = Key<Bool>("hapticsEnabled", default: true)
  static let hideFromScreenRecording = Key<Bool>("hideFromScreenRecording", default: false)
  static let batteryEnabled = Key<Bool>("batteryEnabled", default: true)
  static let hudEnabled = Key<Bool>("hudEnabled", default: false)
  static let calendarEnabled = Key<Bool>("calendarEnabled", default: false)
  static let calendarLeadMinutes = Key<Int>("calendarLeadMinutes", default: 10)
  static let airpodsEnabled = Key<Bool>("airpodsEnabled", default: false)
}
