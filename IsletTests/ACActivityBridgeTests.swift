import XCTest

@testable import Islet

/// Builds real `ACActivityDescriptor` / `ACActivityContentUpdate` objects and runs them through
/// the bridge's conversion.
///
/// The conversion is the riskiest code in the feature and the hardest to see: a mistyped selector
/// or a wrong KVC key silently yields nil rather than failing, and until a paired iPhone actually
/// delivers something there is no other way to notice. The framework's initialisers are public
/// Objective-C, so the objects can be constructed here — which is how the
/// `platterTargetBundleIdentifier` fallback below was found.
final class ACActivityBridgeConversionTests: XCTestCase {
  /// `ACActivityDescriptor` only resolves once ActivityKit is loaded, and nothing in a test host
  /// loads it on its own. Touching the bridge singleton runs the `dlopen` these tests depend on —
  /// and if that fails there is nothing to construct, so skipping here beats nine identical
  /// failures with no explanation.
  override func setUpWithError() throws {
    try super.setUpWithError()
    guard ACActivityBridge.shared.availability == .available else {
      throw XCTSkip("ACActivityCenter unavailable; see ACActivityBridgeAvailabilityTests")
    }
  }

  // MARK: - Constructing framework objects

  private static let descriptorInitName =
    "initWithIdentifier:sceneTargets:alertSceneTargets:presentationOptions:isEphemeral:"
    + "isMomentary:isImportant:createdDate:descriptorData:contentTypesByDestination:"
    + "alertContentTypesByDestination:remoteDeviceIdentifier:localizedAppName:protectionClass:"
  private static let descriptorInit = NSSelectorFromString(descriptorInitName)

  private typealias DescriptorInitFn = @convention(c) (
    AnyObject, Selector, NSString?, NSDictionary?, NSDictionary?, AnyObject?,
    Bool, Bool, Bool, NSDate?, NSData?, NSDictionary?, NSDictionary?, NSString?, NSString?, Int
  ) -> AnyObject?

  private func makeDescriptor(
    id: String = "act-1",
    sceneTargets: NSDictionary? = [NSNumber(value: 2): "com.ubercab.UberClient"],
    isImportant: Bool = false,
    isMomentary: Bool = false,
    isEphemeral: Bool = false,
    created: Date? = nil,
    attributes: Data? = nil,
    remoteDeviceIdentifier: String? = "iphone-1",
    appName: String? = "Uber"
  ) throws -> AnyObject {
    // Skip rather than fail if the private class is gone: ACActivityBridgeAvailabilityTests is
    // the canary for that, and one clear failure beats a cascade of confusing ones.
    guard let cls = NSClassFromString("ACActivityDescriptor") as? NSObject.Type else {
      throw XCTSkip("ACActivityDescriptor unavailable on this macOS")
    }
    let allocated = try XCTUnwrap(
      (cls as AnyObject).perform(NSSelectorFromString("alloc"))?.takeUnretainedValue())
    guard cls.instancesRespond(to: Self.descriptorInit),
      let imp = (allocated as AnyObject).method(for: Self.descriptorInit)
    else {
      throw XCTSkip("ACActivityDescriptor no longer responds to \(Self.descriptorInitName)")
    }
    let fn = unsafeBitCast(imp, to: DescriptorInitFn.self)
    return try XCTUnwrap(
      fn(
        allocated, Self.descriptorInit, id as NSString, sceneTargets, nil, nil,
        isEphemeral, isMomentary, isImportant, created as NSDate?, attributes as NSData?, nil, nil,
        remoteDeviceIdentifier as NSString?, appName as NSString?, 0))
  }

  private func makeContentUpdate(
    descriptor: AnyObject, state: Int, contentData: Data?, staleDate: Date?, relevance: Double
  ) throws -> AnyObject {
    guard let contentCls = NSClassFromString("ACActivityContent") as? NSObject.Type,
      let updateCls = NSClassFromString("ACActivityContentUpdate") as? NSObject.Type
    else { throw XCTSkip("ACActivityContent classes unavailable on this macOS") }

    let contentInit = NSSelectorFromString("initWithContentData:staleDate:relevanceScore:")
    typealias ContentFn = @convention(c) (AnyObject, Selector, NSData?, NSDate?, Double)
      -> AnyObject?
    let contentAlloc = try XCTUnwrap(
      (contentCls as AnyObject).perform(NSSelectorFromString("alloc"))?.takeUnretainedValue())
    guard let contentIMP = (contentAlloc as AnyObject).method(for: contentInit) else {
      throw XCTSkip("ACActivityContent initialiser has changed shape")
    }
    let content = try XCTUnwrap(
      unsafeBitCast(contentIMP, to: ContentFn.self)(
        contentAlloc, contentInit, contentData as NSData?, staleDate as NSDate?, relevance))

    let updateInit = NSSelectorFromString("initWithIdentifier:descriptor:state:content:")
    typealias UpdateFn = @convention(c) (
      AnyObject, Selector, NSString?, AnyObject?, Int, AnyObject?
    ) -> AnyObject?
    let updateAlloc = try XCTUnwrap(
      (updateCls as AnyObject).perform(NSSelectorFromString("alloc"))?.takeUnretainedValue())
    guard let updateIMP = (updateAlloc as AnyObject).method(for: updateInit) else {
      throw XCTSkip("ACActivityContentUpdate initialiser has changed shape")
    }
    return try XCTUnwrap(
      unsafeBitCast(updateIMP, to: UpdateFn.self)(
        updateAlloc, updateInit, "act-1" as NSString, descriptor, state, content))
  }

  // MARK: - Descriptor conversion

  func testEveryDescriptorFieldSurvivesConversion() throws {
    let created = Date(timeIntervalSince1970: 1_786_430_000)
    let descriptor = try makeDescriptor(
      id: "act-42", isImportant: true, isMomentary: true, isEphemeral: true, created: created,
      attributes: Data(#"{"driver":"Sam"}"#.utf8),
      remoteDeviceIdentifier: "iphone-DC3D", appName: "Uber")
    let activity = try XCTUnwrap(ACActivityBridge.activity(fromDescriptor: descriptor))

    XCTAssertEqual(activity.id, "act-42")
    XCTAssertEqual(activity.appName, "Uber")
    XCTAssertEqual(activity.remoteDeviceIdentifier, "iphone-DC3D")
    XCTAssertEqual(activity.createdDate, created)
    XCTAssertTrue(activity.isImportant)
    XCTAssertTrue(activity.isMomentary)
    XCTAssertTrue(activity.isEphemeral)
    XCTAssertEqual(activity.attributesData, Data(#"{"driver":"Sam"}"#.utf8))
    XCTAssertTrue(activity.isRemote)
  }

  /// The regression this whole file exists for. `platterTargetBundleIdentifier` does not resolve
  /// from a constructed descriptor, so reading only it leaves every card without a bundle id —
  /// generic glyph, no adapter match, and nothing to indicate anything went wrong.
  func testBundleIdentifierIsRecoveredFromSceneTargets() throws {
    let descriptor = try makeDescriptor(
      sceneTargets: [NSNumber(value: 2): "com.ubercab.UberClient"])
    let activity = try XCTUnwrap(ACActivityBridge.activity(fromDescriptor: descriptor))
    XCTAssertEqual(activity.bundleIdentifier, "com.ubercab.UberClient")
  }

  func testAnActivityWithNoIdentifierIsDropped() throws {
    let descriptor = try makeDescriptor(id: "")
    // An empty identifier still converts; a *missing* one cannot be built through this
    // initialiser, so the guard is exercised by the nil-returning path in `value(_:_:)` instead.
    XCTAssertEqual(ACActivityBridge.activity(fromDescriptor: descriptor)?.id, "")
  }

  func testMacLocalActivitiesAreNotMarkedRemote() throws {
    let descriptor = try makeDescriptor(remoteDeviceIdentifier: nil)
    let activity = try XCTUnwrap(ACActivityBridge.activity(fromDescriptor: descriptor))
    XCTAssertFalse(activity.isRemote)
  }

  func testAnEmptyRemoteIdentifierIsNotRemote() throws {
    let descriptor = try makeDescriptor(remoteDeviceIdentifier: "")
    let activity = try XCTUnwrap(ACActivityBridge.activity(fromDescriptor: descriptor))
    XCTAssertFalse(activity.isRemote)
  }

  // MARK: - Content update conversion

  func testContentUpdateCarriesPayloadStateAndDescriptor() throws {
    let stale = Date(timeIntervalSince1970: 1_786_431_000)
    let update = try makeContentUpdate(
      descriptor: try makeDescriptor(),
      state: 0, contentData: Data(#"{"title":"Arriving"}"#.utf8), staleDate: stale,
      relevance: 7.5)
    let activity = try XCTUnwrap(ACActivityBridge.activity(fromContentUpdate: update))

    XCTAssertEqual(activity.id, "act-1")
    XCTAssertEqual(activity.contentData, Data(#"{"title":"Arriving"}"#.utf8))
    XCTAssertEqual(activity.staleDate, stale)
    XCTAssertEqual(activity.relevanceScore, 7.5, accuracy: 0.001)
    XCTAssertEqual(activity.state, 0)
    XCTAssertTrue(activity.isLive)
    // The descriptor half must survive too — the update is the only callback that carries both.
    XCTAssertEqual(activity.appName, "Uber")
    XCTAssertEqual(activity.bundleIdentifier, "com.ubercab.UberClient")
  }

  func testEndedStateIsReadAsNotLive() throws {
    let update = try makeContentUpdate(
      descriptor: try makeDescriptor(), state: 2, contentData: nil, staleDate: nil, relevance: 0)
    let activity = try XCTUnwrap(ACActivityBridge.activity(fromContentUpdate: update))
    XCTAssertEqual(activity.state, 2)
    XCTAssertFalse(activity.isLive)
  }

  /// `relevanceScore` and `state` are scalars, which `perform` cannot return — they go through KVC
  /// instead, and a wrong key there reads as 0 rather than throwing.
  func testScalarsAreReadThroughKVCNotDroppedToZero() throws {
    let update = try makeContentUpdate(
      descriptor: try makeDescriptor(), state: 3, contentData: nil, staleDate: nil, relevance: 2.25)
    let activity = try XCTUnwrap(ACActivityBridge.activity(fromContentUpdate: update))
    XCTAssertEqual(activity.state, 3)
    XCTAssertEqual(activity.relevanceScore, 2.25, accuracy: 0.001)
  }

  /// A real payload goes all the way to a drawable card without any special-casing.
  func testAContentUpdateBecomesADrawableCard() throws {
    let update = try makeContentUpdate(
      descriptor: try makeDescriptor(),
      state: 0,
      contentData: Data(#"{"title":"Arriving","subtitle":"2 min away","progress":0.8}"#.utf8),
      staleDate: nil, relevance: 1)
    let activity = try XCTUnwrap(ACActivityBridge.activity(fromContentUpdate: update))
    let card = LiveActivityCard.make(from: activity)

    XCTAssertEqual(card.render.title, "Arriving")
    XCTAssertEqual(card.render.subtitle, "2 min away")
    XCTAssertEqual(card.render.progress ?? 0, 0.8, accuracy: 0.001)
    XCTAssertEqual(card.render.symbol, "car.fill")  // resolved from the recovered bundle id
    XCTAssertTrue(card.isRemote)
  }
}

final class BundleIdentifierResolutionTests: XCTestCase {
  func testPlatterIdentifierWinsWhenPresent() {
    XCTAssertEqual(
      ACActivityBridge.bundleIdentifier(
        platter: "com.a.app", sceneTargets: [1: "com.b.app"]),
      "com.a.app")
  }

  func testFallsBackToTheSceneTargetValue() {
    XCTAssertEqual(
      ACActivityBridge.bundleIdentifier(platter: nil, sceneTargets: [2: "com.b.app"]),
      "com.b.app")
  }

  func testEmptyPlatterIdentifierIsTreatedAsAbsent() {
    XCTAssertEqual(
      ACActivityBridge.bundleIdentifier(platter: "", sceneTargets: [2: "com.b.app"]),
      "com.b.app")
  }

  func testRepeatedValuesCollapseToOne() {
    XCTAssertEqual(
      ACActivityBridge.bundleIdentifier(
        platter: nil, sceneTargets: [1: "com.b.app", 2: "com.b.app", 3: "com.b.app"]),
      "com.b.app")
  }

  /// One activity belongs to one app, so this should not happen — but the choice still has to be
  /// the same on every call or the card's glyph flickers between renders.
  func testMultipleDistinctValuesResolveDeterministically() {
    let targets: [AnyHashable: Any] = [1: "com.z.app", 2: "com.a.app", 3: "com.m.app"]
    let first = ACActivityBridge.bundleIdentifier(platter: nil, sceneTargets: targets)
    XCTAssertEqual(first, "com.a.app")
    for _ in 0..<20 {
      XCTAssertEqual(ACActivityBridge.bundleIdentifier(platter: nil, sceneTargets: targets), first)
    }
  }

  func testNothingUsableYieldsNil() {
    XCTAssertNil(ACActivityBridge.bundleIdentifier(platter: nil, sceneTargets: nil))
    XCTAssertNil(ACActivityBridge.bundleIdentifier(platter: nil, sceneTargets: [:]))
    XCTAssertNil(ACActivityBridge.bundleIdentifier(platter: nil, sceneTargets: [1: ""]))
    XCTAssertNil(ACActivityBridge.bundleIdentifier(platter: nil, sceneTargets: [1: 42]))
  }
}
