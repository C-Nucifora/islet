import AppKit

/// Heuristic fullscreen detection: a normal-layer window from another app that covers a screen.
enum FullscreenDetector {
  static func hasFullscreenWindow(on screen: NSScreen) -> Bool {
    guard let uuid = screen.displayUUID else { return false }
    return fullscreenDisplayUUIDs(on: [screen]).contains(uuid)
  }

  /// Resolves every fullscreen display from one window-server snapshot. `ScreenManager` calls this
  /// from a timer; querying CGWindowList once per display multiplied the most expensive part of the
  /// check on multi-monitor desks.
  static func fullscreenDisplayUUIDs(on screens: [NSScreen] = NSScreen.screens) -> Set<String> {
    guard
      let windows = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]]
    else { return [] }

    let ownPID = NSRunningApplication.current.processIdentifier
    let targets: [(uuid: String, bounds: CGRect)] = screens.compactMap { screen in
      guard let id = screen.displayID, let uuid = screen.displayUUID else { return nil }
      return (uuid, CGDisplayBounds(id))
    }
    var result: Set<String> = []

    for window in windows {
      guard let layer = window[kCGWindowLayer as String] as? Int, layer == 0,
        let pid = window[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
        let boundsDict = window[kCGWindowBounds as String] as? [String: Any],
        let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
      else { continue }

      // Size alone is insufficient: two same-sized displays are common, and it made a fullscreen
      // window on one display hide Islet on both. Both values here are Quartz coordinates, so
      // containment also handles displays above, below or to either side of the primary display.
      for target in targets where covers(window: bounds, display: target.bounds) {
        result.insert(target.uuid)
      }
    }
    return result
  }

  /// Pure geometry seam for offset-display and tolerance tests.
  nonisolated static func covers(
    window: CGRect, display: CGRect, tolerance: CGFloat = 1
  ) -> Bool {
    window.minX <= display.minX + tolerance
      && window.minY <= display.minY + tolerance
      && window.maxX >= display.maxX - tolerance
      && window.maxY >= display.maxY - tolerance
  }
}
