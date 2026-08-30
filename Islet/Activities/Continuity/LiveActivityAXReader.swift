import AppKit
import ApplicationServices

enum LiveActivityAXCompatibilityError: Error, Equatable {
  case missingAttribute(attribute: String)
  case noReadableIdentifiers(childCount: Int)
  case unexpectedCFType(attribute: String, expected: CFTypeID, actual: CFTypeID)
  case unexpectedAXValueType(attribute: String, expected: UInt32, actual: UInt32)
  case unreadableAXValue(attribute: String, type: UInt32)

  var diagnosticSummary: String {
    switch self {
    case .missingAttribute(let attribute):
      "Missing \(attribute)"
    case .noReadableIdentifiers(let childCount):
      "No AXIdentifier on \(childCount) menu bar item(s)"
    case .unexpectedCFType(let attribute, _, _):
      "Unexpected value type for \(attribute)"
    case .unexpectedAXValueType(let attribute, _, _):
      "Unexpected AX value type for \(attribute)"
    case .unreadableAXValue(let attribute, _):
      "Unreadable \(attribute)"
    }
  }
}

enum LiveActivityAXConversion {
  static func element(from value: AnyObject, attribute: String)
    throws(LiveActivityAXCompatibilityError) -> AXUIElement
  {
    let actualType = CFGetTypeID(value)
    guard actualType == AXUIElementGetTypeID() else {
      throw LiveActivityAXCompatibilityError.unexpectedCFType(
        attribute: attribute, expected: AXUIElementGetTypeID(), actual: actualType)
    }

    // Swift rejects `as? AXUIElement` because Core Foundation references appear castable from any
    // object. The type-ID check above is the runtime check that makes this downcast valid.
    return unsafeDowncast(value, to: AXUIElement.self)
  }

  static func rect(from value: AnyObject, attribute: String)
    throws(LiveActivityAXCompatibilityError) -> CGRect
  {
    let actualType = CFGetTypeID(value)
    guard actualType == AXValueGetTypeID() else {
      throw LiveActivityAXCompatibilityError.unexpectedCFType(
        attribute: attribute, expected: AXValueGetTypeID(), actual: actualType)
    }

    // As with AXUIElement above, Swift cannot express this Core Foundation check as `as?`.
    let axValue = unsafeDowncast(value, to: AXValue.self)
    let valueType = AXValueGetType(axValue)
    guard valueType == .cgRect else {
      throw LiveActivityAXCompatibilityError.unexpectedAXValueType(
        attribute: attribute, expected: AXValueType.cgRect.rawValue,
        actual: valueType.rawValue)
    }

    var rect = CGRect.zero
    guard AXValueGetValue(axValue, .cgRect, &rect) else {
      throw LiveActivityAXCompatibilityError.unreadableAXValue(
        attribute: attribute, type: valueType.rawValue)
    }
    return rect
  }

  static func elements(from value: AnyObject, attribute: String)
    throws(LiveActivityAXCompatibilityError) -> [AXUIElement]
  {
    let actualType = CFGetTypeID(value)
    guard actualType == CFArrayGetTypeID() else {
      throw LiveActivityAXCompatibilityError.unexpectedCFType(
        attribute: attribute, expected: CFArrayGetTypeID(), actual: actualType)
    }

    let values = unsafeDowncast(value, to: NSArray.self)
    var elements: [AXUIElement] = []
    for (index, value) in values.enumerated() {
      elements.append(
        try element(from: value as AnyObject, attribute: "\(attribute)[\(index)]"))
    }
    return elements
  }

  static func string(from value: AnyObject, attribute: String)
    throws(LiveActivityAXCompatibilityError) -> String
  {
    let actualType = CFGetTypeID(value)
    guard actualType == CFStringGetTypeID(), let string = value as? String else {
      throw LiveActivityAXCompatibilityError.unexpectedCFType(
        attribute: attribute, expected: CFStringGetTypeID(), actual: actualType)
    }
    return string
  }
}

/// The private ControlCenter hierarchy Islet knows how to read.
///
/// Keeping the attribute names in this generic walker makes the schema assumption testable with
/// fixtures. The production adapter supplies `AXUIElement` values; tests supply in-memory nodes.
/// Required attributes throw instead of turning a changed hierarchy into a false empty result.
struct LiveActivityAXHierarchyReader<Element> {
  let element: (Element, String) throws(LiveActivityAXCompatibilityError) -> Element
  let children: (Element, String) throws(LiveActivityAXCompatibilityError) -> [Element]
  let optionalString: (Element, String) throws(LiveActivityAXCompatibilityError) -> String?
  let rect: (Element, String) throws(LiveActivityAXCompatibilityError) -> CGRect

  func read(from application: Element) throws(LiveActivityAXCompatibilityError)
    -> [MenuBarLiveActivity]
  {
    let extras = try element(application, "AXExtrasMenuBar")
    let items = try children(extras, kAXChildrenAttribute as String)
    var readableIdentifierCount = 0
    var activities: [MenuBarLiveActivity] = []

    for item in items {
      guard let identifier = try optionalString(item, kAXIdentifierAttribute as String) else {
        continue
      }
      readableIdentifierCount += 1
      guard LiveActivityIdentifier.parse(identifier) != nil else { continue }
      activities.append(
        MenuBarLiveActivity(
          axIdentifier: identifier,
          appName: try optionalString(item, kAXDescriptionAttribute as String),
          minX: try rect(item, "AXFrame").minX))
    }

    // An empty children array is a valid empty menu bar. A populated menu bar whose items no
    // longer expose identifiers is a schema change, because identifiers are the detection key.
    guard items.isEmpty || readableIdentifierCount > 0 else {
      throw LiveActivityAXCompatibilityError.noReadableIdentifiers(childCount: items.count)
    }
    return activities
  }
}

enum LiveActivityAXReadResult: Equatable {
  case permissionDenied
  case controlCenterUnavailable
  case schemaChanged(LiveActivityAXCompatibilityError)
  case success([MenuBarLiveActivity])
}

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

  /// Whether Islet has been granted Accessibility.
  var isTrusted: Bool { AccessibilityPermission.isTrusted }

  private var controlCenter: NSRunningApplication? {
    NSWorkspace.shared.runningApplications.first {
      $0.bundleIdentifier == "com.apple.controlcenter"
    }
  }

  /// Reads the known private hierarchy. Only `.success` means the reader reached that hierarchy;
  /// the catalogue can then treat a filtered-empty result as genuinely empty.
  func read() -> LiveActivityAXReadResult {
    guard isTrusted else { return .permissionDenied }
    guard let pid = controlCenter?.processIdentifier else { return .controlCenterUnavailable }
    let app = AXUIElementCreateApplication(pid)
    let hierarchy = LiveActivityAXHierarchyReader<AXUIElement>(
      element: {
        [weak self] (element: AXUIElement, attribute: String)
          throws(LiveActivityAXCompatibilityError) -> AXUIElement in
        guard let value = self?.copy(element, attribute) else {
          throw LiveActivityAXCompatibilityError.missingAttribute(attribute: attribute)
        }
        return try LiveActivityAXConversion.element(from: value, attribute: attribute)
      },
      children: {
        [weak self] (element: AXUIElement, attribute: String)
          throws(LiveActivityAXCompatibilityError) -> [AXUIElement] in
        guard let value = self?.copy(element, attribute) else {
          throw LiveActivityAXCompatibilityError.missingAttribute(attribute: attribute)
        }
        return try LiveActivityAXConversion.elements(from: value, attribute: attribute)
      },
      optionalString: {
        [weak self] (element: AXUIElement, attribute: String)
          throws(LiveActivityAXCompatibilityError) -> String? in
        guard let value = self?.copy(element, attribute) else { return nil }
        return try LiveActivityAXConversion.string(from: value, attribute: attribute)
      },
      rect: {
        [weak self] (element: AXUIElement, attribute: String)
          throws(LiveActivityAXCompatibilityError) -> CGRect in
        guard let value = self?.copy(element, attribute) else {
          throw LiveActivityAXCompatibilityError.missingAttribute(attribute: attribute)
        }
        return try LiveActivityAXConversion.rect(from: value, attribute: attribute)
      })
    do {
      return .success(try hierarchy.read(from: app))
    } catch {
      return .schemaChanged(error)
    }
  }

  /// Re-attaches after a permission grant or a transient ControlCenter restart, then lets the
  /// monitor perform a synchronous retry.
  func retryObservation() { attach() }

  /// Starts watching for changes. `onChange` fires on the main actor, already coalesced.
  func startObserving(_ onChange: @escaping () -> Void) {
    stopObserving()
    self.onChange = onChange
    attach()
    // ControlCenter is restartable — it is a launch agent, and restarting it is even the known fix
    // for its pairing state going stale. A dead observer would leave the tab frozen on whatever it
    // last saw, so re-attach whenever it comes back.
    let center = NSWorkspace.shared.notificationCenter
    for name in [
      NSWorkspace.didLaunchApplicationNotification,
      NSWorkspace.didTerminateApplicationNotification,
    ] {
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
    for observer in workspaceObservers { center.removeObserver(observer) }
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
    Log.app.notice(
      "Continuity: observing ControlCenter accessibility (pid \(pid, privacy: .public))")
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
}
