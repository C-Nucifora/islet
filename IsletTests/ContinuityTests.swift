import XCTest

@testable import Islet

private func item(_ identifier: String, name: String? = "Example", minX: CGFloat = 0)
  -> MenuBarLiveActivity
{
  MenuBarLiveActivity(axIdentifier: identifier, appName: name, minX: minX)
}

private final class LiveActivityAXFixtureNode {
  var attributes: [String: LiveActivityAXFixtureValue]

  init(_ attributes: [String: LiveActivityAXFixtureValue] = [:]) {
    self.attributes = attributes
  }
}

private enum LiveActivityAXFixtureValue {
  case element(LiveActivityAXFixtureNode)
  case children([LiveActivityAXFixtureNode])
  case string(String)
  case rect(CGRect)
}

private func fixtureHierarchyReader() -> LiveActivityAXHierarchyReader<LiveActivityAXFixtureNode> {
  LiveActivityAXHierarchyReader(
    element: {
      (node: LiveActivityAXFixtureNode, attribute: String)
        throws(LiveActivityAXCompatibilityError) -> LiveActivityAXFixtureNode in
      guard case .element(let value)? = node.attributes[attribute] else {
        throw LiveActivityAXCompatibilityError.missingAttribute(attribute: attribute)
      }
      return value
    },
    children: {
      (node: LiveActivityAXFixtureNode, attribute: String)
        throws(LiveActivityAXCompatibilityError) -> [LiveActivityAXFixtureNode] in
      guard case .children(let value)? = node.attributes[attribute] else {
        throw LiveActivityAXCompatibilityError.missingAttribute(attribute: attribute)
      }
      return value
    },
    optionalString: {
      (node: LiveActivityAXFixtureNode, attribute: String)
        throws(LiveActivityAXCompatibilityError) -> String? in
      guard let value = node.attributes[attribute] else { return nil }
      guard case .string(let value) = value else {
        throw LiveActivityAXCompatibilityError.unexpectedCFType(
          attribute: attribute, expected: CFStringGetTypeID(), actual: CFBooleanGetTypeID())
      }
      return value
    },
    rect: {
      (node: LiveActivityAXFixtureNode, attribute: String)
        throws(LiveActivityAXCompatibilityError) -> CGRect in
      guard case .rect(let value)? = node.attributes[attribute] else {
        throw LiveActivityAXCompatibilityError.missingAttribute(attribute: attribute)
      }
      return value
    })
}

final class LiveActivityIdentifierTests: XCTestCase {
  /// The identifier is the whole basis of detection: macOS names these items
  /// `<iOS bundle id>.liveActivity`, which both marks them and names the app.
  func testAppIdentifierYieldsTheBundleIdentifier() {
    XCTAssertEqual(
      LiveActivityIdentifier.parse("com.t3tools.t3code.liveActivity"),
      .app(bundleIdentifier: "com.t3tools.t3code"))
  }

  func testOrdinaryStatusItemsAreNotLiveActivities() {
    XCTAssertNil(LiveActivityIdentifier.parse("com.apple.menuextra.clock"))
    XCTAssertNil(LiveActivityIdentifier.parse("com.apple.menuextra.wifi"))
    XCTAssertNil(LiveActivityIdentifier.parse(""))
  }

  func testControlCentresOwnPlaceholdersAreRecognised() {
    XCTAssertEqual(
      LiveActivityIdentifier.parse("com.apple.ControlCenter.overflow.liveActivity"), .overflow)
    XCTAssertEqual(
      LiveActivityIdentifier.parse("com.apple.ControlCenter.empty.liveActivity"), .empty)
  }

  /// A bare suffix names no app; treating it as one would render a card with an empty title.
  func testSuffixWithoutABundleIdentifierIsRejected() {
    XCTAssertNil(LiveActivityIdentifier.parse(".liveActivity"))
  }

  func testSuffixMustBeAtTheEnd() {
    XCTAssertNil(LiveActivityIdentifier.parse("com.example.liveActivity.helper"))
  }
}

final class LiveActivityCatalogTests: XCTestCase {
  private func cards(
    _ items: [MenuBarLiveActivity], installed: Set<String> = []
  ) -> [LiveActivityCard] {
    LiveActivityCatalog.cards(from: items) { installed.contains($0) }
  }

  func testBuildsACardPerApp() {
    let out = cards([item("com.ubercab.UberClient.liveActivity", name: "Uber")])
    XCTAssertEqual(out.map(\.bundleIdentifier), ["com.ubercab.UberClient"])
    XCTAssertEqual(out.first?.appName, "Uber")
    XCTAssertEqual(out.first?.symbol, "car.fill")
  }

  /// ControlCenter's overflow and empty placeholders are its own bookkeeping, not activities, and
  /// rendering them would put "overflow" in the island as though it were an app.
  func testPlaceholdersAreDropped() {
    let out = cards([
      item("com.apple.ControlCenter.overflow.liveActivity"),
      item("com.apple.ControlCenter.empty.liveActivity"),
      item("com.apple.mobiletimer.liveActivity", name: "Clock"),
    ])
    XCTAssertEqual(out.map(\.bundleIdentifier), ["com.apple.mobiletimer"])
  }

  func testNonLiveActivityItemsAreDropped() {
    XCTAssertTrue(cards([item("com.apple.menuextra.clock", name: "Clock")]).isEmpty)
  }

  /// Ordered by position so the island lists activities the way the menu bar does.
  func testCardsFollowMenuBarOrder() {
    let out = cards([
      item("com.c.app.liveActivity", minX: 900),
      item("com.a.app.liveActivity", minX: 100),
      item("com.b.app.liveActivity", minX: 500),
    ])
    XCTAssertEqual(out.map(\.bundleIdentifier), ["com.a.app", "com.b.app", "com.c.app"])
  }

  /// Two items for one app would render twice under the same name with nothing to tell them apart.
  func testOneCardPerAppEvenIfTheMenuBarRepeatsIt() {
    let out = cards([
      item("com.a.app.liveActivity", name: "A", minX: 100),
      item("com.a.app.liveActivity", name: "A", minX: 300),
    ])
    XCTAssertEqual(out.count, 1)
    XCTAssertEqual(out.first?.id, "com.a.app.liveActivity")
  }

  func testUnknownAppsFallBackToThePhoneGlyph() {
    let out = cards([item("com.unknown.thing.liveActivity")])
    XCTAssertEqual(out.first?.symbol, LiveActivityAppStyle.fallbackSymbol)
  }

  func testMissingAccessibilityNameFallsBackToTheBundleLeaf() {
    XCTAssertEqual(
      cards([item("com.doordash.doordash.liveActivity", name: nil)]).first?.appName,
      "doordash")
    XCTAssertEqual(
      cards([item("com.doordash.doordash.liveActivity", name: "")]).first?.appName,
      "doordash")
  }

  /// An activity whose app is installed on this Mac probably originated here, and should not pass
  /// itself off as coming from the phone.
  func testLocallyInstalledAppsAreNotMarkedRemote() {
    let out = cards([item("com.local.app.liveActivity")], installed: ["com.local.app"])
    XCTAssertEqual(out.first?.isRemote, false)
    XCTAssertEqual(cards([item("com.phone.app.liveActivity")]).first?.isRemote, true)
  }

  func testNoItemsYieldNoCards() {
    XCTAssertTrue(cards([]).isEmpty)
  }
}

final class ContinuityAvailabilityTests: XCTestCase {
  func testPermissionDenialIsReported() {
    XCTAssertEqual(
      .needsAccessibility,
      ContinuityAvailability.resolve(
        readResult: .permissionDenied, systemEnabled: true, cardCount: 0))
  }

  func testMissingControlCentreIsDistinctFromASchemaChange() {
    XCTAssertEqual(
      .controlCenterUnavailable,
      ContinuityAvailability.resolve(
        readResult: .controlCenterUnavailable, systemEnabled: true, cardCount: 0))
    XCTAssertEqual(
      .incompatibleSchema,
      ContinuityAvailability.resolve(
        readResult: .schemaChanged(.missingAttribute(attribute: "AXExtrasMenuBar")),
        systemEnabled: true, cardCount: 0))
  }

  func testSystemSwitchedOffIsReported() {
    XCTAssertEqual(
      .systemDisabled,
      ContinuityAvailability.resolve(
        readResult: .success([]), systemEnabled: false, cardCount: 0))
  }

  func testEnabledButEmptyIsWaiting() {
    XCTAssertEqual(
      .waiting,
      ContinuityAvailability.resolve(
        readResult: .success([]), systemEnabled: true, cardCount: 0))
  }

  /// Cards in hand beat every settings signal — whatever the preferences claim, something is here.
  func testCardsInHandOutrankTheSettings() {
    XCTAssertEqual(
      .active,
      ContinuityAvailability.resolve(
        readResult: .success([item("com.example.app.liveActivity")]), systemEnabled: false,
        cardCount: 1))
  }

  func testEveryStateExplainsItself() {
    for state: ContinuityAvailability in [
      .needsAccessibility, .controlCenterUnavailable, .incompatibleSchema, .systemDisabled,
      .waiting, .active,
    ] {
      XCTAssertFalse(state.explanation.isEmpty)
    }
  }
}

final class ContinuityReadDiagnosticsTests: XCTestCase {
  func testOnlySuccessfulReadsAdvanceTheLastSuccess() {
    let firstSuccess = Date(timeIntervalSince1970: 100)
    let laterFailure = Date(timeIntervalSince1970: 200)
    var diagnostics = ContinuityReadDiagnostics()

    diagnostics.record(.success([]), at: firstSuccess)
    diagnostics.record(.controlCenterUnavailable, at: laterFailure)

    XCTAssertEqual(diagnostics.lastSuccessfulRead, firstSuccess)
  }

  func testCompatibilityFailureIsClearedByAKnownHierarchy() {
    var diagnostics = ContinuityReadDiagnostics()
    diagnostics.record(
      .schemaChanged(.missingAttribute(attribute: "AXExtrasMenuBar")), at: Date())
    XCTAssertEqual(
      diagnostics.compatibilityError, .missingAttribute(attribute: "AXExtrasMenuBar"))

    diagnostics.record(.success([]), at: Date())
    XCTAssertNil(diagnostics.compatibilityError)
  }
}

final class ContinuityEventBaselineTests: XCTestCase {
  func testFailureDoesNotTurnAnUnchangedRecoveryIntoANewActivity() {
    let card = LiveActivityCard(
      id: "com.example.delivery.liveActivity", bundleIdentifier: "com.example.delivery",
      appName: "Delivery", symbol: "shippingbox", isRemote: true)
    var baseline = ContinuityEventBaseline()

    XCTAssertEqual(baseline.reconcile(with: [card], readSucceeded: true).added, [card])
    XCTAssertTrue(baseline.reconcile(with: [], readSucceeded: false).removed.isEmpty)

    let recovery = baseline.reconcile(with: [card], readSucceeded: true)
    XCTAssertTrue(recovery.added.isEmpty)
    XCTAssertTrue(recovery.removed.isEmpty)
  }
}

final class ControlCenterSettingsTests: XCTestCase {
  func testReadsTheEnabledFlag() {
    XCTAssertTrue(
      ControlCenterLiveActivitySettings.parse(
        remoteEnabled: NSNumber(value: true), stateData: nil
      ).remoteEnabled)
    XCTAssertFalse(
      ControlCenterLiveActivitySettings.parse(
        remoteEnabled: NSNumber(value: false), stateData: nil
      ).remoteEnabled)
  }

  func testSettingDisabledInTheJSONBlobWins() {
    let s = ControlCenterLiveActivitySettings.parse(
      remoteEnabled: NSNumber(value: true),
      stateData: Data(#"{"CompanionPaired":true,"SettingEnabled":false}"#.utf8))
    XCTAssertFalse(s.remoteEnabled)
  }

  /// An absent key means the user has never touched the setting, which macOS treats as on.
  func testAbsentPreferenceDefaultsToEnabled() {
    XCTAssertTrue(
      ControlCenterLiveActivitySettings.parse(remoteEnabled: nil, stateData: nil).remoteEnabled)
  }

  func testGarbageBlobDoesNotCrashOrFlipTheFlag() {
    XCTAssertTrue(
      ControlCenterLiveActivitySettings.parse(
        remoteEnabled: NSNumber(value: true), stateData: Data([0xFF, 0x01])
      ).remoteEnabled)
  }
}

final class LiveActivityAXHierarchyReaderTests: XCTestCase {
  func testKnownHierarchyReturnsActivities() throws {
    let clock = LiveActivityAXFixtureNode([
      "AXIdentifier": .string("com.apple.menuextra.clock")
    ])
    let activity = LiveActivityAXFixtureNode([
      "AXIdentifier": .string("com.example.delivery.liveActivity"),
      "AXDescription": .string("Delivery"),
      "AXFrame": .rect(CGRect(x: 420, y: 0, width: 28, height: 24)),
    ])
    let extras = LiveActivityAXFixtureNode(["AXChildren": .children([clock, activity])])
    let application = LiveActivityAXFixtureNode(["AXExtrasMenuBar": .element(extras)])

    XCTAssertEqual(
      try fixtureHierarchyReader().read(from: application),
      [item("com.example.delivery.liveActivity", name: "Delivery", minX: 420)])
  }

  func testKnownHierarchyCanBeGenuinelyEmpty() throws {
    let clock = LiveActivityAXFixtureNode([
      "AXIdentifier": .string("com.apple.menuextra.clock")
    ])
    let extras = LiveActivityAXFixtureNode(["AXChildren": .children([clock])])
    let application = LiveActivityAXFixtureNode(["AXExtrasMenuBar": .element(extras)])

    XCTAssertEqual(try fixtureHierarchyReader().read(from: application), [])
  }

  func testRenamedExtrasMenuBarIsASchemaChange() {
    let renamed = LiveActivityAXFixtureNode()
    let application = LiveActivityAXFixtureNode(["AXMenuBarExtras": .element(renamed)])

    XCTAssertThrowsError(try fixtureHierarchyReader().read(from: application)) { error in
      XCTAssertEqual(
        error as? LiveActivityAXCompatibilityError,
        .missingAttribute(attribute: "AXExtrasMenuBar"))
    }
  }

  func testItemsWithoutIdentifiersAreASchemaChange() {
    let unidentifiableItem = LiveActivityAXFixtureNode()
    let extras = LiveActivityAXFixtureNode([
      "AXChildren": .children([unidentifiableItem])
    ])
    let application = LiveActivityAXFixtureNode(["AXExtrasMenuBar": .element(extras)])

    XCTAssertThrowsError(try fixtureHierarchyReader().read(from: application)) { error in
      XCTAssertEqual(
        error as? LiveActivityAXCompatibilityError, .noReadableIdentifiers(childCount: 1))
    }
  }
}

final class LiveActivityAXConversionTests: XCTestCase {
  func testConvertsAXUIElementAfterTypeCheck() throws {
    let input = AXUIElementCreateSystemWide()

    let output = try LiveActivityAXConversion.element(
      from: input, attribute: "AXExtrasMenuBar")

    XCTAssertTrue(CFEqual(input, output))
  }

  func testRejectsWrongCFTypeBeforeConvertingElement() {
    let value = NSString(string: "not an accessibility element")

    XCTAssertThrowsError(
      try LiveActivityAXConversion.element(from: value, attribute: "AXExtrasMenuBar")
    ) { error in
      XCTAssertEqual(
        error as? LiveActivityAXCompatibilityError,
        .unexpectedCFType(
          attribute: "AXExtrasMenuBar", expected: AXUIElementGetTypeID(),
          actual: CFGetTypeID(value)))
    }
  }

  func testRejectsWrongAXValueSubtypeBeforeReadingRect() throws {
    var point = CGPoint(x: 12, y: 34)
    let value = try XCTUnwrap(AXValueCreate(.cgPoint, &point))

    XCTAssertThrowsError(
      try LiveActivityAXConversion.rect(from: value, attribute: "AXFrame")
    ) { error in
      XCTAssertEqual(
        error as? LiveActivityAXCompatibilityError,
        .unexpectedAXValueType(
          attribute: "AXFrame", expected: AXValueType.cgRect.rawValue,
          actual: AXValueType.cgPoint.rawValue))
    }
  }

  func testRejectsWrongCFTypeBeforeConvertingAXValue() {
    let value = NSString(string: "not an accessibility value")

    XCTAssertThrowsError(
      try LiveActivityAXConversion.rect(from: value, attribute: "AXFrame")
    ) { error in
      XCTAssertEqual(
        error as? LiveActivityAXCompatibilityError,
        .unexpectedCFType(
          attribute: "AXFrame", expected: AXValueGetTypeID(), actual: CFGetTypeID(value)))
    }
  }

  func testReadsCGRectAXValue() throws {
    var input = CGRect(x: 10, y: 20, width: 300, height: 40)
    let value = try XCTUnwrap(AXValueCreate(.cgRect, &input))

    XCTAssertEqual(
      try LiveActivityAXConversion.rect(from: value, attribute: "AXFrame"), input)
  }

  func testConvertsAnArrayAfterCheckingEveryElement() throws {
    let first = AXUIElementCreateSystemWide()
    let second = AXUIElementCreateApplication(1)

    let output = try LiveActivityAXConversion.elements(
      from: [first, second] as NSArray, attribute: "AXChildren")

    XCTAssertEqual(output.count, 2)
    XCTAssertTrue(CFEqual(first, output[0]))
    XCTAssertTrue(CFEqual(second, output[1]))
  }

  func testRejectsANonElementInsideTheChildrenArray() {
    let values = [AXUIElementCreateSystemWide(), NSString(string: "wrong")] as NSArray

    XCTAssertThrowsError(
      try LiveActivityAXConversion.elements(from: values, attribute: "AXChildren")
    ) { error in
      guard
        case .unexpectedCFType(let attribute, _, _)? =
          error as? LiveActivityAXCompatibilityError
      else {
        return XCTFail("Unexpected error: \(error)")
      }
      XCTAssertEqual(attribute, "AXChildren[1]")
    }
  }

  func testRejectsNonStringIdentifier() {
    let value = NSNumber(value: true)

    XCTAssertThrowsError(
      try LiveActivityAXConversion.string(from: value, attribute: "AXIdentifier")
    ) { error in
      XCTAssertEqual(
        error as? LiveActivityAXCompatibilityError,
        .unexpectedCFType(
          attribute: "AXIdentifier", expected: CFStringGetTypeID(), actual: CFGetTypeID(value)))
    }
  }
}

/// Exercises the real accessibility read against the running ControlCenter.
///
/// Everything above is pure and would keep passing if macOS renamed `AXExtrasMenuBar`, changed the
/// identifier format, or stopped exposing status items — leaving a permanently empty iPhone tab
/// with nothing to say why. This is the one test that touches the live tree.
///
/// Skips without the Accessibility grant, which the test host will usually lack. That is a real
/// limitation of testing this at all, not something to assert around.
@MainActor
final class LiveActivityAXReaderIntegrationTests: XCTestCase {
  func testReadsTheLiveMenuBar() throws {
    guard AccessibilityPermission.isTrusted else {
      throw XCTSkip("Accessibility not granted to the test host")
    }
    let reachable: [MenuBarLiveActivity]
    switch LiveActivityAXReader.shared.read() {
    case .success(let items):
      reachable = items
    case .permissionDenied:
      return XCTFail("Accessibility was trusted before the read but denied during it")
    case .controlCenterUnavailable:
      return XCTFail("ControlCenter is not running")
    case .schemaChanged(let error):
      return XCTFail("ControlCenter's AX hierarchy changed: \(error.diagnosticSummary)")
    }

    // Whatever is running, every item the reader returns must parse; returning something the
    // catalogue then silently drops would mean the filter and the reader disagree.
    for item in reachable {
      XCTAssertNotNil(
        LiveActivityIdentifier.parse(item.axIdentifier),
        "reader returned \(item.axIdentifier), which the identifier parser rejects")
    }
    let cards = LiveActivityCatalog.cards(from: reachable) { _ in false }
    XCTAssertLessThanOrEqual(cards.count, reachable.count)
    print("AX read \(reachable.count) live activity item(s): \(reachable.map(\.axIdentifier))")
    print("  -> cards: \(cards.map { "\($0.appName) [\($0.bundleIdentifier)] \($0.symbol)" })")
  }
}
