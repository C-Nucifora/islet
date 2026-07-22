import AppKit

/// Heuristic fullscreen detection: a normal-layer window from another app that covers a screen.
enum FullscreenDetector {
  static func hasFullscreenWindow(on screen: NSScreen) -> Bool {
    let screenFrame = screen.frame
    guard
      let windows = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]]
    else { return false }

    let ownPID = NSRunningApplication.current.processIdentifier

    for window in windows {
      guard let layer = window[kCGWindowLayer as String] as? Int, layer == 0,
        let pid = window[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
        let boundsDict = window[kCGWindowBounds as String] as? [String: Any],
        let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
      else { continue }

      // CGWindow bounds are top-left origin; compare sizes and near-full coverage.
      if bounds.width >= screenFrame.width - 1, bounds.height >= screenFrame.height - 1 {
        return true
      }
    }
    return false
  }
}
