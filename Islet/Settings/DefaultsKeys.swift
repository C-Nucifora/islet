import Defaults
import Foundation

extension InteractionMode: Defaults.Serializable {}

extension Defaults.Keys {
  static let interactionMode = Key<InteractionMode>("interactionMode", default: .hover)
  static let hoverExpandDelay = Key<Double>("hoverExpandDelay", default: 0.3)
  static let hoverCollapseTimeout = Key<Double>("hoverCollapseTimeout", default: 0.5)
  static let hapticsEnabled = Key<Bool>("hapticsEnabled", default: true)
  static let hideFromScreenRecording = Key<Bool>("hideFromScreenRecording", default: false)
}
