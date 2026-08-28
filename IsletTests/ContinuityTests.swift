import XCTest

@testable import Islet

private func item(_ identifier: String, name: String? = "Example", minX: CGFloat = 0)
  -> MenuBarLiveActivity
{
  MenuBarLiveActivity(axIdentifier: identifier, appName: name, minX: minX)
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
  func testWithoutAccessibilityNothingElseMatters() {
    XCTAssertEqual(
      .needsAccessibility,
      ContinuityAvailability.resolve(
        isTrusted: false, controlCenterReachable: true, systemEnabled: true, cardCount: 3))
  }

  func testUnreachableControlCentreIsUnsupported() {
    XCTAssertEqual(
      .unsupported,
      ContinuityAvailability.resolve(
        isTrusted: true, controlCenterReachable: false, systemEnabled: true, cardCount: 0))
  }

  func testSystemSwitchedOffIsReported() {
    XCTAssertEqual(
      .systemDisabled,
      ContinuityAvailability.resolve(
        isTrusted: true, controlCenterReachable: true, systemEnabled: false, cardCount: 0))
  }

  func testEnabledButEmptyIsWaiting() {
    XCTAssertEqual(
      .waiting,
      ContinuityAvailability.resolve(
        isTrusted: true, controlCenterReachable: true, systemEnabled: true, cardCount: 0))
  }

  /// Cards in hand beat every settings signal — whatever the preferences claim, something is here.
  func testCardsInHandOutrankTheSettings() {
    XCTAssertEqual(
      .active,
      ContinuityAvailability.resolve(
        isTrusted: true, controlCenterReachable: false, systemEnabled: false, cardCount: 1))
  }

  func testEveryStateExplainsItself() {
    for state: ContinuityAvailability in [
      .needsAccessibility, .unsupported, .systemDisabled, .waiting, .active,
    ] {
      XCTAssertFalse(state.explanation.isEmpty)
    }
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
    let items = LiveActivityAXReader.shared.read()
    let reachable = try XCTUnwrap(
      items, "ControlCenter is running but exposed no AXExtrasMenuBar — the attribute has moved")

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
