import AppKit
import Combine

/// External displays connecting and disconnecting.
///
/// `didChangeScreenParametersNotification` fires for resolution changes and menu-bar changes too, so
/// the notification alone means nothing — the screen set has to be diffed. Keyed by display UUID,
/// which survives reconfiguration where `NSScreen` identity does not.
@MainActor
final class DisplayEventSource: SystemEventSource {
  let id = "display"
  let displayName = String(localized: "External displays")
  let tier = SystemEventTier.core

  private var cancellable: AnyCancellable?
  private var known: [String] = []

  func start() {
    guard cancellable == nil else { return }
    known = Self.currentUUIDs()  // baseline; the displays already attached are not news
    cancellable = NotificationCenter.default
      .publisher(for: NSApplication.didChangeScreenParametersNotification)
      .debounce(for: .milliseconds(600), scheduler: DispatchQueue.main)
      .sink { [weak self] _ in self?.report() }
  }

  func stop() {
    cancellable = nil
    known = []
  }

  private static func currentUUIDs() -> [String] {
    NSScreen.screens.compactMap(\.displayUUID)
  }

  private static func name(forUUID uuid: String) -> String {
    guard let screen = NSScreen.screens.first(where: { $0.displayUUID == uuid })
    else { return String(localized: "Display") }
    return screen.localizedName
  }

  private func report() {
    let now = Self.currentUUIDs()
    let diff = SetDiff.changes(from: known, to: now)
    known = now
    for uuid in diff.added {
      let name = Self.name(forUUID: uuid)
      SystemEventBus.shared.emit(
        SystemEvent(
          sourceID: id, icon: "display", title: name, subtitle: String(localized: "Connected"),
          accentHex: EventAccent.info, motion: .display,
          announcement: String(localized: "\(name) connected")))
    }
    for _ in diff.removed {
      // The screen is already gone, so its name is no longer resolvable — say so plainly rather
      // than caching names purely to produce a nicer string for the disconnect case.
      SystemEventBus.shared.emit(
        SystemEvent(
          sourceID: id, icon: "display.trianglebadge.exclamationmark",
          title: String(localized: "Display disconnected"),
          accentHex: EventAccent.neutral, motion: .display, urgency: .ambient,
          announcement: String(localized: "Display disconnected")))
    }
  }
}
