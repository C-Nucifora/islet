import AppKit
import ApplicationServices

/// Reads iPhone Live Activities out of ControlCenter's menu bar over the Accessibility API.
///
/// This is the second design for this feature. The first read the activities directly from
/// `ACActivityCenter`, ActivityKit's private Objective-C half — the same API ControlCenter uses.
/// Registration succeeded from an unentitled process, but delivery never did: with a Live Activity
/// visibly in the menu bar, a freshly registered listener was called back with zero activities.
/// The gate is on delivery, not registration, and `com.apple.private.sessionkit.listener` is not
/// obtainable. Accessibility is what is left.
///
/// What that costs: accessibility exposes the app behind an activity and nothing it says. The
/// deepest element is an `AXUnknown` whose only text is the app name, because the content is a
/// scene replicated from the phone. `AXPress` is unsupported, so the expanded platter cannot be
/// opened either. Presence and identity are the whole of what is available.
@MainActor
final class LiveActivityAXReader {
  static let shared = LiveActivityAXReader()

  private var observer: AXObserver?
  private var observedPID: pid_t?
  private var onChange: (() -> Void)?
  private var coalesce: Task<Void, Never>?
  private var workspaceObservers: [NSObjectProtocol] = []

  private init() {}

  /// Whether Islet has been granted Accessibility. Everything here returns empty without it.
  var isTrusted: Bool { AccessibilityPermission.isTrusted }

  private var controlCenter: NSRunningApplication? {
    NSWorkspace.shared.runningApplications.first {
      $0.bundleIdentifier == "com.apple.controlcenter"
    }
  }

  /// Current Live Activities, or `nil` when ControlCenter could not be reached at all — which is a
  /// different state from "reached it, found none" and gets a different sentence in the UI.
  func read() -> [MenuBarLiveActivity]? {
    guard isTrusted, let pid = controlCenter?.processIdentifier else { return nil }
    let app = AXUIElementCreateApplication(pid)
    guard let extrasValue = copy(app, "AXExtrasMenuBar"),
      CFGetTypeID(extrasValue) == AXUIElementGetTypeID()
    else { return nil }
    let extras = extrasValue as! AXUIElement
    let items = (copy(extras, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
    return items.compactMap { item -> MenuBarLiveActivity? in
      guard let identifier = copy(item, kAXIdentifierAttribute as String) as? String,
        LiveActivityIdentifier.parse(identifier) != nil
      else { return nil }
      return MenuBarLiveActivity(
        axIdentifier: identifier,
        appName: copy(item, kAXDescriptionAttribute as String) as? String,
        minX: frame(item).minX)
    }
  }

  /// Starts watching for changes. `onChange` fires on the main actor, already coalesced.
  func startObserving(_ onChange: @escaping () -> Void) {
    stopObserving()
    self.onChange = onChange
    attach()
    // ControlCenter is restartable — it is a launch agent, and restarting it is even the known fix
    // for its pairing state going stale. A dead observer would leave the tab frozen on whatever it
    // last saw, so re-attach whenever it comes back.
    let center = NSWorkspace.shared.notificationCenter
    for name in [NSWorkspace.didLaunchApplicationNotification,
                 NSWorkspace.didTerminateApplicationNotification] {
      let token = center.addObserver(forName: name, object: nil, queue: .main) { note in
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        guard app?.bundleIdentifier == "com.apple.controlcenter" else { return }
        MainActor.assumeIsolated {
          LiveActivityAXReader.shared.attach()
          LiveActivityAXReader.shared.notifyChanged()
        }
      }
      workspaceObservers.append(token)
    }
  }

  func stopObserving() {
    coalesce?.cancel()
    coalesce = nil
    detach()
    let center = NSWorkspace.shared.notificationCenter
    workspaceObservers.forEach { center.removeObserver($0) }
    workspaceObservers.removeAll()
    onChange = nil
  }

  private func attach() {
    guard isTrusted, let pid = controlCenter?.processIdentifier else { return }
    guard pid != observedPID || observer == nil else { return }
    detach()

    var created: AXObserver?
    let callback: AXObserverCallback = { _, _, _, _ in
      MainActor.assumeIsolated { LiveActivityAXReader.shared.notifyChanged() }
    }
    guard AXObserverCreate(pid, callback, &created) == .success, let created else { return }
    observer = created
    observedPID = pid
    CFRunLoopAddSource(
      CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
    let app = AXUIElementCreateApplication(pid)
    for name in [
      kAXCreatedNotification, kAXUIElementDestroyedNotification,
      kAXLayoutChangedNotification, kAXValueChangedNotification,
    ] as [String] {
      AXObserverAddNotification(created, app, name as CFString, nil)
    }
    Log.app.notice("Continuity: observing ControlCenter accessibility (pid \(pid, privacy: .public))")
  }

  private func detach() {
    if let observer {
      CFRunLoopRemoveSource(
        CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
    }
    observer = nil
    observedPID = nil
  }

  /// The menu bar is noisy — the clock alone fires `AXValueChanged` — and each wake re-walks the
  /// item list, so changes are coalesced rather than acted on one for one.
  private func notifyChanged() {
    coalesce?.cancel()
    coalesce = Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(250))
      guard !Task.isCancelled else { return }
      onChange?()
    }
  }

  // MARK: - Accessibility plumbing

  private func copy(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
    else { return nil }
    return value as AnyObject?
  }

  private func frame(_ element: AXUIElement) -> CGRect {
    guard let value = copy(element, "AXFrame"), CFGetTypeID(value) == AXValueGetTypeID()
    else { return .zero }
    var rect = CGRect.zero
    AXValueGetValue(value as! AXValue, .cgRect, &rect)
    return rect
  }
}
