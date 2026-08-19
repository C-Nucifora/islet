import Foundation

/// The private-API edge: subscribes to the Live Activity stream that `liveactivitiesd` replicates
/// from a paired iPhone, and hands out plain values.
///
/// There is no public API for this. macOS 26 does ship `ActivityKit.framework`, but every Swift
/// symbol in it is `@available(macOS, unavailable)`, so the module cannot even be imported. What
/// *is* reachable is the framework's Objective-C half — `ACActivityCenter` — which is what
/// ControlCenter itself uses to draw iPhone Live Activities in the menu bar.
///
/// ControlCenter holds `com.apple.private.sessionkit.listener` for this, an entitlement no
/// third-party app can carry. Registering the listener turns out not to require it, but that is an
/// observation about today's macOS, not a guarantee — so nothing here is linked, imported or
/// assumed. Every class and selector is resolved by name at runtime and every failure collapses to
/// `.unsupported`, which hides the feature rather than breaking the app. This mirrors how
/// `BrightnessController` reaches DisplayServices and `MediaRemoteCommands` reaches MediaRemote.
final class ACActivityBridge: @unchecked Sendable {
  enum Availability: Equatable, Sendable {
    /// The class or a selector did not resolve — almost certainly a macOS update moved them.
    case unsupported
    case available
  }

  static let shared = ACActivityBridge()

  private static let frameworkPath =
    "/System/Library/Frameworks/ActivityKit.framework/Versions/A/ActivityKit"

  private let center: NSObject?
  /// The daemon keeps a subscription alive only while its assertion is retained; dropping these
  /// silently unsubscribes and the stream goes quiet with no error anywhere.
  private var assertions: [AnyObject] = []
  private let lock = NSLock()

  private init() {
    guard dlopen(Self.frameworkPath, RTLD_LAZY) != nil,
      let cls = NSClassFromString("ACActivityCenter") as? NSObject.Type
    else {
      center = nil
      Log.app.notice("ACActivityCenter unavailable; Continuity activities disabled")
      return
    }
    let instance = cls.init()
    // Registering a listener we cannot read back from is worse than not registering: it would
    // leave the tab visible and permanently empty.
    guard instance.responds(to: Self.descriptorsSelector),
      instance.responds(to: Self.contentUpdatesSelector)
    else {
      center = nil
      Log.app.notice("ACActivityCenter is missing its observe selectors; Continuity disabled")
      return
    }
    center = instance
  }

  private static let descriptorsSelector = NSSelectorFromString("observeDescriptorsWithHandler:")
  private static let contentUpdatesSelector = NSSelectorFromString(
    "observeContentUpdatesWithHandler:")

  var availability: Availability { center == nil ? .unsupported : .available }

  /// Whether the system has Live Activities switched on at all. Distinct from availability: the
  /// API can be present and working while the user has the feature off.
  var areActivitiesEnabled: Bool {
    guard let center else { return false }
    let sel = NSSelectorFromString("areActivitiesEnabled")
    guard center.responds(to: sel) else { return true }
    typealias Fn = @convention(c) (AnyObject, Selector) -> Bool
    return unsafeBitCast(center.method(for: sel), to: Fn.self)(center, sel)
  }

  /// Starts both streams. `onDescriptors` receives the complete current set on every change;
  /// `onContent` receives one activity's live payload. Both are called on an arbitrary queue.
  ///
  /// Calling twice is a no-op — the assertions are held for the process lifetime, matching the
  /// other monitors in the app, which start once at launch and never stop.
  func start(
    onDescriptors: @escaping @Sendable ([RawLiveActivity]) -> Void,
    onContent: @escaping @Sendable (RawLiveActivity) -> Void
  ) {
    guard let center else { return }
    lock.lock()
    defer { lock.unlock() }
    guard assertions.isEmpty else { return }

    typealias ObserveFn = @convention(c) (
      AnyObject, Selector, @escaping @convention(block) @Sendable (AnyObject?) -> Void
    ) -> AnyObject?

    let observeDescriptors = unsafeBitCast(
      center.method(for: Self.descriptorsSelector), to: ObserveFn.self)
    if let token = observeDescriptors(center, Self.descriptorsSelector, { object in
      let list = (object as? [AnyObject]) ?? []
      onDescriptors(list.compactMap(Self.activity(fromDescriptor:)))
    }) {
      assertions.append(token)
    }

    let observeContent = unsafeBitCast(
      center.method(for: Self.contentUpdatesSelector), to: ObserveFn.self)
    if let token = observeContent(center, Self.contentUpdatesSelector, { object in
      guard let object, let update = Self.activity(fromContentUpdate: object) else { return }
      onContent(update)
    }) {
      assertions.append(token)
    }

    // `notice` rather than `info`: this is the one line that says whether the private-API path
    // resolved on this machine, and info-level messages are not persisted, so a report of "the
    // iPhone tab is empty" would arrive with no way to tell a dead bridge from a quiet phone.
    Log.app.notice(
      "Continuity: \(self.assertions.count, privacy: .public) activity listeners active")
  }

  // MARK: - Objective-C to value

  private static func value(_ object: AnyObject, _ selectorName: String) -> AnyObject? {
    let sel = NSSelectorFromString(selectorName)
    guard object.responds(to: sel) else { return nil }
    return object.perform(sel)?.takeUnretainedValue() as AnyObject?
  }

  private static func flag(_ object: AnyObject, _ selectorName: String) -> Bool {
    let sel = NSSelectorFromString(selectorName)
    guard object.responds(to: sel) else { return false }
    typealias Fn = @convention(c) (AnyObject, Selector) -> Bool
    guard let method = (object as? NSObject)?.method(for: sel) else { return false }
    return unsafeBitCast(method, to: Fn.self)(object, sel)
  }

  /// Reads a scalar property through KVC rather than `perform`, which cannot return a non-object.
  private static func scalar(_ object: AnyObject, _ key: String) -> NSNumber? {
    (object as? NSObject)?.value(forKey: key) as? NSNumber
  }

  static func activity(fromDescriptor descriptor: AnyObject) -> RawLiveActivity? {
    guard let id = value(descriptor, "activityIdentifier") as? String else { return nil }
    return RawLiveActivity(
      id: id,
      bundleIdentifier: value(descriptor, "platterTargetBundleIdentifier") as? String,
      appName: value(descriptor, "localizedAppName") as? String,
      remoteDeviceIdentifier: value(descriptor, "remoteDeviceIdentifier") as? String,
      createdDate: value(descriptor, "createdDate") as? Date,
      isImportant: flag(descriptor, "isImportant"),
      isMomentary: flag(descriptor, "isMomentary"),
      isEphemeral: flag(descriptor, "isEphemeral"),
      attributesData: value(descriptor, "descriptorData") as? Data)
  }

  static func activity(fromContentUpdate update: AnyObject) -> RawLiveActivity? {
    // The update carries its own descriptor, so one callback is enough to build the whole record;
    // the identifier is read from the descriptor when the update omits it.
    guard let descriptor = value(update, "descriptor"),
      var activity = activity(fromDescriptor: descriptor)
    else { return nil }
    activity.state = scalar(update, "state")?.intValue ?? 0
    if let content = value(update, "content") {
      activity.contentData = value(content, "contentData") as? Data
      activity.staleDate = value(content, "staleDate") as? Date
      activity.relevanceScore = scalar(content, "relevanceScore")?.doubleValue ?? 0
    }
    return activity
  }
}
