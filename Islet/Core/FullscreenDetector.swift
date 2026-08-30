import AppKit

/// Resolves the displays whose current macOS Space is a native fullscreen Space.
enum FullscreenDetector {
  struct ManagedSpaceState: Equatable {
    let displayUUIDs: Set<String>
    let fullscreenDisplayUUIDs: Set<String>
  }

  private typealias MainConnectionFn = @convention(c) () -> UInt32
  private typealias CopyManagedDisplaySpacesFn =
    @convention(c) (UInt32) -> Unmanaged<CFArray>?

  static func hasFullscreenWindow(on screen: NSScreen) -> Bool {
    guard let uuid = screen.displayUUID else { return false }
    return fullscreenDisplayUUIDs(on: [screen]).contains(uuid)
  }

  /// Uses the active Space for each display when WindowServer exposes that information. Unlike a
  /// window-size heuristic, this does not mistake a borderless window for native fullscreen. The
  /// old window-list check remains as a compatibility fallback if the private symbols or snapshot
  /// shape change on a later macOS release.
  static func fullscreenDisplayUUIDs(on screens: [NSScreen] = NSScreen.screens) -> Set<String> {
    let targets: [(uuid: String, bounds: CGRect)] = screens.compactMap { screen in
      guard let id = screen.displayID, let uuid = screen.displayUUID else { return nil }
      return (uuid, CGDisplayBounds(id))
    }
    let requestedUUIDs = Set(targets.map(\.uuid))

    return resolvedDisplayUUIDs(
      managedSpaces: copyManagedSpaceState(), requestedDisplayUUIDs: requestedUUIDs
    ) {
      windowListFullscreenDisplayUUIDs(targets: targets)
    }
  }

  /// Converts the WindowServer dictionary into a stable, testable per-display state. A normal
  /// desktop Space has type 0. Native fullscreen Spaces have type 4.
  nonisolated static func managedSpaceState(
    from displays: [[String: Any]]
  ) -> ManagedSpaceState? {
    guard !displays.isEmpty else { return nil }

    var displayUUIDs: Set<String> = []
    var fullscreenDisplayUUIDs: Set<String> = []
    for display in displays {
      guard
        let displayUUID = display["Display Identifier"] as? String,
        let currentSpace = display["Current Space"] as? [String: Any],
        let type = currentSpace["type"] as? NSNumber
      else { return nil }

      displayUUIDs.insert(displayUUID)
      if type.intValue == 4 { fullscreenDisplayUUIDs.insert(displayUUID) }
    }
    return ManagedSpaceState(
      displayUUIDs: displayUUIDs, fullscreenDisplayUUIDs: fullscreenDisplayUUIDs)
  }

  /// Prefers a valid Space snapshot even when the older window list still describes the Space
  /// that was active before a transition.
  nonisolated static func resolvedDisplayUUIDs(
    managedSpaces: ManagedSpaceState?, requestedDisplayUUIDs: Set<String>,
    windowListFallback: () -> Set<String>
  ) -> Set<String> {
    guard let managedSpaces,
      requestedDisplayUUIDs.isSubset(of: managedSpaces.displayUUIDs)
    else {
      return windowListFallback().intersection(requestedDisplayUUIDs)
    }
    return managedSpaces.fullscreenDisplayUUIDs.intersection(requestedDisplayUUIDs)
  }

  /// Pure geometry seam for offset-display and fallback tests.
  nonisolated static func covers(
    window: CGRect, display: CGRect, tolerance: CGFloat = 1
  ) -> Bool {
    window.minX <= display.minX + tolerance
      && window.minY <= display.minY + tolerance
      && window.maxX >= display.maxX - tolerance
      && window.maxY >= display.maxY - tolerance
  }

  private static func copyManagedSpaceState() -> ManagedSpaceState? {
    guard
      let handle = dlopen(
        "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY | RTLD_LOCAL)
    else { return nil }
    defer { dlclose(handle) }

    guard
      let connectionSymbol = dlsym(handle, "CGSMainConnectionID"),
      let spacesSymbol = dlsym(handle, "CGSCopyManagedDisplaySpaces")
    else { return nil }

    let mainConnection = unsafeBitCast(connectionSymbol, to: MainConnectionFn.self)
    let copySpaces = unsafeBitCast(spacesSymbol, to: CopyManagedDisplaySpacesFn.self)
    guard
      let rawSpaces = copySpaces(mainConnection())?.takeRetainedValue(),
      let displays = rawSpaces as? [[String: Any]]
    else { return nil }
    return managedSpaceState(from: displays)
  }

  private static func windowListFullscreenDisplayUUIDs(
    targets: [(uuid: String, bounds: CGRect)]
  ) -> Set<String> {
    guard
      let windows = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]]
    else { return [] }

    let ownPID = NSRunningApplication.current.processIdentifier
    var result: Set<String> = []
    for window in windows {
      guard let layer = window[kCGWindowLayer as String] as? Int, layer == 0,
        let pid = window[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
        let boundsDictionary = window[kCGWindowBounds as String] as? [String: Any],
        let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary)
      else { continue }

      for target in targets where covers(window: bounds, display: target.bounds) {
        result.insert(target.uuid)
      }
    }
    return result
  }
}
