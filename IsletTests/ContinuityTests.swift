import XCTest

@testable import Islet

/// Builds a raw activity without needing a paired iPhone or the private framework.
private func raw(
  _ id: String,
  bundle: String? = "com.example.app",
  app: String? = "Example",
  remote: String? = "iphone-1",
  created: Date? = nil,
  content: String? = nil,
  attributes: String? = nil,
  stale: Date? = nil,
  relevance: Double = 0,
  state: Int = 0
) -> RawLiveActivity {
  RawLiveActivity(
    id: id,
    bundleIdentifier: bundle,
    appName: app,
    remoteDeviceIdentifier: remote,
    createdDate: created,
    attributesData: attributes.map { Data($0.utf8) },
    contentData: content.map { Data($0.utf8) },
    staleDate: stale,
    relevanceScore: relevance,
    state: state)
}

final class LiveActivityStoreTests: XCTestCase {
  let now = Date(timeIntervalSince1970: 1_786_430_090)

  func testDescriptorAddsAnActivity() {
    var store = LiveActivityStore()
    let change = store.apply(descriptors: [raw("a")], now: now)
    XCTAssertEqual(change.added.map(\.id), ["a"])
    XCTAssertEqual(store.ordered(now: now).map(\.id), ["a"])
  }

  /// The descriptor stream re-sends the whole set and carries no payload. Overwriting wholesale
  /// would blank every card each time any one activity ticked.
  func testDescriptorRefreshKeepsContentAlreadyReceived() {
    var store = LiveActivityStore()
    _ = store.apply(descriptors: [raw("a")], now: now)
    _ = store.apply(content: raw("a", content: #"{"title":"Cooking"}"#), now: now)
    _ = store.apply(descriptors: [raw("a")], now: now)
    XCTAssertEqual(store.ordered(now: now).first?.render.title, "Cooking")
  }

  func testActivityMissingFromDescriptorsIsRemoved() {
    var store = LiveActivityStore()
    _ = store.apply(descriptors: [raw("a"), raw("b")], now: now)
    let change = store.apply(descriptors: [raw("b")], now: now)
    XCTAssertEqual(change.removed.map(\.id), ["a"])
    XCTAssertEqual(store.ordered(now: now).map(\.id), ["b"])
  }

  /// The content stream is allowed to be the first thing we hear about an activity.
  func testContentWithoutAPriorDescriptorStillCreatesACard() {
    var store = LiveActivityStore()
    let change = store.apply(content: raw("a", content: #"{"title":"Ride"}"#), now: now)
    XCTAssertEqual(change.added.map(\.id), ["a"])
    XCTAssertEqual(store.ordered(now: now).first?.render.title, "Ride")
  }

  func testEndedActivitiesLeaveTheList() {
    var store = LiveActivityStore()
    _ = store.apply(descriptors: [raw("a")], now: now)
    let change = store.apply(content: raw("a", state: 2), now: now)
    XCTAssertEqual(change.removed.map(\.id), ["a"])
    XCTAssertTrue(store.ordered(now: now).isEmpty)
  }

  func testHigherRelevanceIsPromoted() {
    var store = LiveActivityStore()
    _ = store.apply(descriptors: [raw("a"), raw("b")], now: now)
    _ = store.apply(content: raw("a", relevance: 1), now: now)
    _ = store.apply(content: raw("b", relevance: 9), now: now)
    XCTAssertEqual(store.ordered(now: now).map(\.id), ["b", "a"])
  }

  func testNewerActivityWinsWhenRelevanceTies() {
    var store = LiveActivityStore()
    _ = store.apply(
      descriptors: [
        raw("old", created: now.addingTimeInterval(-600)),
        raw("new", created: now.addingTimeInterval(-60)),
      ], now: now)
    XCTAssertEqual(store.ordered(now: now).map(\.id), ["new", "old"])
  }

  func testRemoteActivitiesOutrankMacOnes() {
    var store = LiveActivityStore()
    _ = store.apply(descriptors: [raw("mac", remote: nil), raw("phone")], now: now)
    XCTAssertEqual(store.ordered(now: now).map(\.id), ["phone", "mac"])
    XCTAssertEqual(store.ordered(now: now).map(\.isRemote), [true, false])
  }

  /// Equal-scoring activities must not swap places between renders, or the promoted card flickers.
  func testOrderIsTotalAndStable() {
    var store = LiveActivityStore()
    _ = store.apply(descriptors: [raw("c"), raw("a"), raw("b")], now: now)
    let first = store.ordered(now: now).map(\.id)
    for _ in 0..<20 { XCTAssertEqual(store.ordered(now: now).map(\.id), first) }
    XCTAssertEqual(first, ["a", "b", "c"])
  }

  func testNoChangeProducesNoSneaks() {
    var store = LiveActivityStore()
    _ = store.apply(descriptors: [raw("a")], now: now)
    XCTAssertTrue(store.apply(descriptors: [raw("a")], now: now).isEmpty)
  }
}

final class LiveActivityCardTests: XCTestCase {
  let now = Date(timeIntervalSince1970: 1_786_430_090)

  /// `staleDate` is the daemon's own expiry and is schema-independent, so it is a safe countdown
  /// when the app's payload did not yield one.
  func testStaleDateBecomesTheCountdownWhenThePayloadHasNone() {
    let end = now.addingTimeInterval(300)
    let card = LiveActivityCard.make(
      from: raw("a", content: #"{"title":"Order"}"#, stale: end), now: now)
    XCTAssertEqual(card.render.endDate, end)
  }

  func testAPayloadCountdownBeatsStaleDate() throws {
    let payloadEnd = now.addingTimeInterval(60)
    let card = LiveActivityCard.make(
      from: raw(
        "a",
        content: #"{"title":"Order","endDate":\#(payloadEnd.timeIntervalSinceReferenceDate)}"#,
        stale: now.addingTimeInterval(9000)),
      now: now)
    XCTAssertEqual(
      try XCTUnwrap(card.render.endDate).timeIntervalSince1970, payloadEnd.timeIntervalSince1970,
      accuracy: 1)
  }

  func testAlreadyExpiredStaleDateIsNotACountdown() {
    let card = LiveActivityCard.make(
      from: raw("a", content: #"{"title":"Order"}"#, stale: now.addingTimeInterval(-10)), now: now)
    XCTAssertNil(card.render.endDate)
  }

  func testKnownAppsGetTheirOwnGlyph() {
    let card = LiveActivityCard.make(from: raw("a", bundle: "com.apple.mobiletimer"), now: now)
    XCTAssertEqual(card.render.symbol, "timer")
  }

  func testUnknownAppsFallBackToThePhoneGlyph() {
    let card = LiveActivityCard.make(from: raw("a", bundle: "com.unknown.thing"), now: now)
    XCTAssertEqual(card.render.symbol, LiveActivityAppStyle.fallbackSymbol)
  }

  /// An unreadable payload should still say which app it belongs to rather than render blank.
  func testUndecodablePayloadStillNamesTheApp() {
    var activity = raw("a", app: "Uber", content: nil)
    activity.contentData = Data([0xFF, 0x00, 0x01])
    let card = LiveActivityCard.make(from: activity, now: now)
    XCTAssertEqual(card.compactText, "Uber")
  }

  func testMissingAppNameFallsBackToTheBundleLeaf() {
    let card = LiveActivityCard.make(
      from: raw("a", bundle: "com.doordash.doordash", app: nil), now: now)
    XCTAssertEqual(card.appName, "doordash")
  }
}

final class ContinuityAvailabilityTests: XCTestCase {
  func testUnresolvedBridgeIsUnsupported() {
    XCTAssertEqual(
      .unsupported,
      ContinuityAvailability.resolve(
        bridgeAvailable: false, systemEnabled: true, companionPaired: true, cardCount: 3))
  }

  func testSystemSwitchedOffIsReported() {
    XCTAssertEqual(
      .systemDisabled,
      ContinuityAvailability.resolve(
        bridgeAvailable: true, systemEnabled: false, companionPaired: false, cardCount: 0))
  }

  func testEnabledButNoPhoneIsWaiting() {
    XCTAssertEqual(
      .waiting,
      ContinuityAvailability.resolve(
        bridgeAvailable: true, systemEnabled: true, companionPaired: false, cardCount: 0))
  }

  /// ControlCenter's pairing flag is a cache it only rewrites when it notices a change, so it can
  /// read stale. An activity in hand proves the pipe is open whatever the cache says.
  func testCardsInHandOutrankAStalePairingFlag() {
    XCTAssertEqual(
      .active,
      ContinuityAvailability.resolve(
        bridgeAvailable: true, systemEnabled: false, companionPaired: false, cardCount: 1))
  }

  func testEveryStateExplainsItself() {
    for state: ContinuityAvailability in [.unsupported, .systemDisabled, .waiting, .active] {
      XCTAssertFalse(state.explanation.isEmpty)
    }
  }
}

final class ControlCenterSettingsTests: XCTestCase {
  private func state(_ json: String) -> Data { Data(json.utf8) }

  func testReadsPairingFromTheJSONBlob() {
    let s = ControlCenterLiveActivitySettings.parse(
      remoteEnabled: NSNumber(value: true),
      stateData: state(#"{"CompanionPaired":true,"SettingEnabled":true}"#))
    XCTAssertTrue(s.remoteEnabled)
    XCTAssertTrue(s.companionPaired)
  }

  func testSettingDisabledInTheBlobWins() {
    let s = ControlCenterLiveActivitySettings.parse(
      remoteEnabled: NSNumber(value: true),
      stateData: state(#"{"CompanionPaired":false,"SettingEnabled":false}"#))
    XCTAssertFalse(s.remoteEnabled)
  }

  /// An absent key means the user has never touched the setting, which macOS treats as on.
  func testAbsentPreferenceDefaultsToEnabled() {
    let s = ControlCenterLiveActivitySettings.parse(remoteEnabled: nil, stateData: nil)
    XCTAssertTrue(s.remoteEnabled)
    XCTAssertFalse(s.companionPaired)
  }

  func testGarbageBlobDoesNotCrashOrClaimPairing() {
    let s = ControlCenterLiveActivitySettings.parse(
      remoteEnabled: NSNumber(value: false), stateData: Data([0xFF, 0x01]))
    XCTAssertFalse(s.remoteEnabled)
    XCTAssertFalse(s.companionPaired)
  }
}

final class LiveActivityCountdownTests: XCTestCase {
  let now = Date(timeIntervalSince1970: 1_786_430_090)

  /// A Live Activity is very often a running timer, and a timer that reads "1m" for a whole minute
  /// looks broken — which is why this does not reuse `CalendarLogic.countdownText`.
  func testSecondsAreShownUnderAnHour() {
    XCTAssertEqual(LiveActivityCountdown.text(to: now.addingTimeInterval(65), now: now), "1:05")
    XCTAssertEqual(LiveActivityCountdown.text(to: now.addingTimeInterval(9), now: now), "0:09")
  }

  func testHoursAndMinutesPastAnHour() {
    XCTAssertEqual(LiveActivityCountdown.text(to: now.addingTimeInterval(3665), now: now), "1:01")
  }

  func testExpiredCountdownsClampToZero() {
    XCTAssertEqual(LiveActivityCountdown.text(to: now.addingTimeInterval(-5), now: now), "0:00")
    XCTAssertEqual(LiveActivityCountdown.text(to: now, now: now), "0:00")
  }
}

final class ContinuityCaptureTests: XCTestCase {
  /// A capture is only useful if it round-trips through the real decode path, so the raw blobs
  /// have to survive as blobs rather than as someone's pre-parsed convenience shape.
  func testRecordKeepsBlobsRecoverable() throws {
    let activity = raw("a", content: #"{"title":"Ride"}"#, attributes: #"{"driver":"Sam"}"#)
    let record = ContinuityCapture.record(kind: "content", activity: activity)
    let contentBase64 = try XCTUnwrap(record["contentData"] as? String)
    let restored = try XCTUnwrap(Data(base64Encoded: contentBase64))
    XCTAssertEqual(PayloadValue.decode(restored), .object(["title": .string("Ride")]))
    XCTAssertEqual(record["kind"] as? String, "content")
    XCTAssertEqual(record["id"] as? String, "a")
    XCTAssertEqual(record["isRemote"] as? Bool, true)
  }

  func testRecordIsJSONSerialisable() throws {
    let record = ContinuityCapture.record(kind: "descriptor", activity: raw("a"))
    XCTAssertTrue(JSONSerialization.isValidJSONObject(record))
    XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: record))
  }
}

/// The canary for the private-API path.
///
/// Everything else in this file is pure and would keep passing long after macOS moved
/// `ACActivityCenter` out from under us — the app would degrade to a permanently empty iPhone tab
/// and nothing would say why. This is the one test that touches the real framework, and a failure
/// here means exactly one thing: the private path this feature rests on has changed.
///
/// Safe to run in a test host. Resolving the class and instantiating it starts no listeners,
/// prompts for no permission and touches no hardware, which is why it does not need the monitor
/// guard `AppDelegate` applies to everything else.
final class ACActivityBridgeAvailabilityTests: XCTestCase {
  func testTheLiveActivityPrivateAPIStillResolves() {
    XCTAssertEqual(
      ACActivityBridge.shared.availability, .available,
      """
      ACActivityCenter no longer resolves. iPhone Live Activities are now dark in Islet — the app \
      degrades on its own, but the bridge in ACActivityBridge.swift needs re-checking against this \
      macOS version.
      """)
  }
}
