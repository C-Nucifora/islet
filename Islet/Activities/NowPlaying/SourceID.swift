import AppKit
import Foundation

/// Identity of one media source.
///
/// The bundle identifier alone is not unique — three distinct `com.apple.WebKit.GPU` processes
/// coexist on a normal machine, one per media-hosting web view — so the pid is part of the key.
/// The display identity is what the user sees: the parent app, never the helper.
struct SourceID: Hashable, Sendable {
  /// The process actually holding the session.
  let bundleIdentifier: String
  let pid: Int32
  /// Display identity: parentApplicationBundleIdentifier when present, else bundleIdentifier.
  let displayBundleIdentifier: String

  /// Designated. Use when the display identity has already been resolved.
  init(bundleIdentifier: String, pid: Int32, displayBundleIdentifier: String) {
    self.bundleIdentifier = bundleIdentifier
    self.pid = pid
    self.displayBundleIdentifier = displayBundleIdentifier
  }

  /// Resolves display identity from the adapter's parent-app field: the parent when non-empty,
  /// otherwise the bundle identifier itself. Mirrors `PlaybackState.sourceBundleIdentifier`.
  init(bundleIdentifier: String, pid: Int32, parentBundleIdentifier: String) {
    self.init(
      bundleIdentifier: bundleIdentifier,
      pid: pid,
      displayBundleIdentifier: parentBundleIdentifier.isEmpty
        ? bundleIdentifier : parentBundleIdentifier)
  }

  init(state: PlaybackState) {
    self.init(
      bundleIdentifier: state.bundleIdentifier,
      pid: state.processIdentifier,
      parentBundleIdentifier: state.parentBundleIdentifier)
  }
}

/// Collapses helper processes onto the app that owns them.
///
/// CoreAudio reports raw process objects with no parent-app field, so Safari appears as one to
/// three `com.apple.WebKit.GPU` rows and Chromium apps as N `<parent>.helper` rows. Verified by
/// probe on this machine: pids 1172, 1469 and 17670 all reported `com.apple.WebKit.GPU`.
enum AudioSourceResolver {
  /// Helpers whose bundle identifier gives no hint of the parent app.
  static let helperParents: [String: String] = [
    "com.apple.WebKit.GPU": "com.apple.Safari",
    "com.apple.WebKit.WebContent": "com.apple.Safari",
  ]

  /// The app a process should be displayed as.
  ///
  /// `runningAppBundleID` maps a pid to the bundle identifier of the owning `NSRunningApplication`.
  /// Tests pass a stub; production passes `AudioSourceResolver.runningAppBundleID`.
  static func displayBundleID(
    bundleID: String, pid: Int32, runningAppBundleID: (Int32) -> String?
  ) -> String {
    let inferred = inferredDisplayBundleID(for: bundleID)
    if inferred != bundleID.trimmingCharacters(in: .whitespacesAndNewlines) { return inferred }
    if let app = runningAppBundleID(pid)?.trimmingCharacters(in: .whitespacesAndNewlines),
      !app.isEmpty
    {
      return app
    }
    return inferred
  }

  /// Resolves the stable parent identity that can be inferred from a process bundle identifier
  /// alone. Preference migration uses this path because old persisted exclusions have no PID to
  /// look up in the current process table.
  static func inferredDisplayBundleID(for bundleID: String) -> String {
    let bundleID = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
    if let mapped = helperParents[bundleID] { return mapped }
    // Chromium-family helpers are "<parent>.helper", "<parent>.helper.Renderer", and so on.
    if let range = bundleID.range(of: ".helper", options: [.caseInsensitive]) {
      let parent = String(bundleID[bundleID.startIndex..<range.lowerBound])
      if !parent.isEmpty { return parent }
    }
    return bundleID
  }

  /// Production pid → owning-application lookup. Returns nil for daemons and XPC services, which
  /// are not applications.
  static func runningAppBundleID(_ pid: Int32) -> String? {
    NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
  }
}
