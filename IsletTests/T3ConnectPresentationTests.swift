import XCTest

@testable import Islet

final class T3ConnectPresentationTests: XCTestCase {
  func testSignedOutPresentationOffersAccountLinking() {
    let presentation = T3ConnectAccountPresentation(
      state: .signedOut, lastLinkError: nil, lastCleanupError: nil)

    XCTAssertEqual(presentation.statusText, "Not linked")
    XCTAssertEqual(
      presentation.detailText,
      "Link an account to find T3 Code environments available through T3 Connect.")
    XCTAssertNil(presentation.identity)
    XCTAssertNil(presentation.lastSync)
    XCTAssertFalse(presentation.isBusy)
    XCTAssertEqual(
      presentation.actions,
      [.init(kind: .link, title: "Link T3 Connect account")])
    XCTAssertTrue(presentation.errorMessages.isEmpty)
  }

  func testLinkingPresentationCanBeCanceled() {
    let presentation = T3ConnectAccountPresentation(
      state: .linking(previous: nil), lastLinkError: nil, lastCleanupError: nil)

    XCTAssertEqual(presentation.statusText, "Linking account")
    XCTAssertEqual(presentation.detailText, "Waiting for browser…")
    XCTAssertTrue(presentation.isBusy)
    XCTAssertEqual(presentation.actions, [.init(kind: .cancel, title: "Cancel")])
  }

  func testRelinkingPresentationRetainsAndNormalizesPreviousIdentity() {
    let presentation = T3ConnectAccountPresentation(
      state: .linking(previous: account(identity: "  ada@example.com\n Work  ")),
      lastLinkError: nil,
      lastCleanupError: nil)

    XCTAssertEqual(presentation.statusText, "Relinking account")
    XCTAssertEqual(
      presentation.detailText,
      "Waiting for browser… Your current account stays linked unless this attempt succeeds."
    )
    XCTAssertEqual(presentation.identity, "ada@example.com Work")
    XCTAssertEqual(presentation.actions, [.init(kind: .cancel, title: "Cancel")])
  }

  func testLinkedPresentationShowsSyncAndSignOut() {
    let sync = Date(timeIntervalSince1970: 1_788_000_000)
    let presentation = T3ConnectAccountPresentation(
      state: .linked(account(identity: "ada@example.com"), lastSync: sync),
      lastLinkError: nil,
      lastCleanupError: nil)

    XCTAssertEqual(presentation.statusText, "Linked")
    XCTAssertEqual(presentation.detailText, "T3 Connect is monitoring your available environments.")
    XCTAssertEqual(presentation.identity, "ada@example.com")
    XCTAssertEqual(presentation.lastSync, sync)
    XCTAssertEqual(
      presentation.actions,
      [.init(kind: .signOut, title: "Sign out", isDestructive: true)])
  }

  func testLinkedPresentationExplainsPendingFirstSync() {
    let presentation = T3ConnectAccountPresentation(
      state: .linked(account(identity: nil), lastSync: nil),
      lastLinkError: nil,
      lastCleanupError: nil)

    XCTAssertEqual(presentation.detailText, "Waiting for the first environment sync.")
    XCTAssertNil(presentation.identity)
  }

  func testNeedsSignInWithoutAnAccountOffersRelinkingOnly() {
    let presentation = T3ConnectAccountPresentation(
      state: .needsSignIn(nil, "The refresh token expired."),
      lastLinkError: nil,
      lastCleanupError: nil)

    XCTAssertEqual(presentation.statusText, "Sign-in required")
    XCTAssertEqual(presentation.detailText, "Link the account again to restore T3 Connect access.")
    XCTAssertEqual(presentation.errorMessages, ["The refresh token expired."])
    XCTAssertEqual(presentation.actions, [.init(kind: .link, title: "Link again")])
  }

  func testNeedsSignInWithAnAccountCanRelinkOrSignOut() {
    let presentation = T3ConnectAccountPresentation(
      state: .needsSignIn(account(identity: "ada@example.com"), "Access was revoked."),
      lastLinkError: nil,
      lastCleanupError: nil)

    XCTAssertEqual(presentation.identity, "ada@example.com")
    XCTAssertEqual(
      presentation.actions,
      [
        .init(kind: .link, title: "Link again"),
        .init(kind: .signOut, title: "Sign out", isDestructive: true),
      ])
  }

  func testUnavailablePresentationRetainsIdentityAndOffersRetry() {
    let presentation = T3ConnectAccountPresentation(
      state: .unavailable(account(identity: "ada@example.com"), "Relay timed out."),
      lastLinkError: nil,
      lastCleanupError: nil)

    XCTAssertEqual(presentation.statusText, "T3 Connect unavailable")
    XCTAssertEqual(
      presentation.detailText,
      "Your last known environments stay visible while T3 Connect is unavailable.")
    XCTAssertEqual(presentation.errorMessages, ["Relay timed out."])
    XCTAssertEqual(
      presentation.actions,
      [
        .init(kind: .retry, title: "Retry"),
        .init(kind: .signOut, title: "Sign out", isDestructive: true),
      ])
  }

  func testLinkAndCleanupErrorsStayVisibleAndCleanupCanBeRetried() {
    let presentation = T3ConnectAccountPresentation(
      state: .signedOut,
      lastLinkError: "The browser callback expired.",
      lastCleanupError: "Keychain cleanup failed.")

    XCTAssertEqual(
      presentation.errorMessages,
      ["The browser callback expired.", "Keychain cleanup failed."])
    XCTAssertEqual(
      presentation.actions,
      [
        .init(kind: .link, title: "Link T3 Connect account"),
        .init(kind: .retryCleanup, title: "Retry cleanup"),
      ])
  }

  func testCleanupRetryIsNotExposedForANewlyLinkedAccount() {
    let presentation = T3ConnectAccountPresentation(
      state: .linked(account(identity: "ada@example.com"), lastSync: nil),
      lastLinkError: nil,
      lastCleanupError: "Old cleanup failed.")

    XCTAssertTrue(presentation.errorMessages.isEmpty)
    XCTAssertEqual(
      presentation.actions,
      [.init(kind: .signOut, title: "Sign out", isDestructive: true)])
  }

  func testLinkedAndUnavailableCopyDoesNotClaimMonitoringWhileDisabled() {
    let linked = T3ConnectAccountPresentation(
      state: .linked(account(identity: "ada@example.com"), lastSync: nil),
      lastLinkError: nil,
      lastCleanupError: nil,
      monitoringEnabled: false)
    let unavailable = T3ConnectAccountPresentation(
      state: .unavailable(account(identity: "ada@example.com"), "Relay timed out."),
      lastLinkError: nil,
      lastCleanupError: nil,
      monitoringEnabled: false)

    XCTAssertEqual(linked.detailText, "Monitoring is off. Your linked account remains saved.")
    XCTAssertEqual(unavailable.detailText, "Monitoring is off. Your linked account remains saved.")
  }

  func testRepeatedStateErrorIsShownOnce() {
    let presentation = T3ConnectAccountPresentation(
      state: .needsSignIn(nil, "Access was revoked."),
      lastLinkError: "Access was revoked.",
      lastCleanupError: nil)

    XCTAssertEqual(presentation.errorMessages, ["Access was revoked."])
  }

  func testIdentityIsCollapsedAndBoundedToEightyGraphemes() {
    let composedCharacter = "e\u{301}"
    let identity = "  " + String(repeating: composedCharacter, count: 81) + "\n"
    let presentation = T3ConnectAccountPresentation(
      state: .linked(account(identity: identity), lastSync: nil),
      lastLinkError: nil,
      lastCleanupError: nil)

    let rendered = try! XCTUnwrap(presentation.identity)
    XCTAssertEqual(rendered.count, 80)
    XCTAssertEqual(rendered.last, "…")
    XCTAssertEqual(rendered.dropLast().count, 79)
  }

  func testEmptyIdentityIsNotRendered() {
    let presentation = T3ConnectAccountPresentation(
      state: .linked(account(identity: " \n\t "), lastSync: nil),
      lastLinkError: nil,
      lastCleanupError: nil)

    XCTAssertNil(presentation.identity)
  }

  func testEnvironmentRowsExplainSourceStateAndAvailableControls() {
    let cases:
      [(
        source: T3EnvironmentSource, icon: String, sourceText: String,
        controls: [T3EnvironmentRowPresentation.Control]
      )] = [
        (.local, "laptopcomputer", "This Mac", []),
        (.connect, "cloud.fill", "T3 Connect", []),
        (.manual, "network", "Manually paired", [.enable, .remove]),
      ]

    for item in cases {
      let row = T3EnvironmentRowPresentation(
        snapshot: environment(source: item.source, state: .offline("Timed out")))

      XCTAssertEqual(row.label, "Studio")
      XCTAssertEqual(row.systemImage, item.icon)
      XCTAssertEqual(row.sourceText, item.sourceText)
      XCTAssertEqual(row.stateText, "Offline")
      XCTAssertEqual(row.controls, item.controls)
      XCTAssertEqual(row.accessibilityLabel, "Studio, \(item.sourceText), Offline")
    }
  }

  func testManualEnvironmentStatusRespectsTheGlobalMonitorToggle() {
    let globallyDisabled = T3EnvironmentRowPresentation(
      manualLabel: "Studio", profileEnabled: true, monitoringEnabled: false, state: nil)
    let profileDisabled = T3EnvironmentRowPresentation(
      manualLabel: "Studio", profileEnabled: false, monitoringEnabled: true,
      state: .connected)
    let connecting = T3EnvironmentRowPresentation(
      manualLabel: "Studio", profileEnabled: true, monitoringEnabled: true, state: nil)

    XCTAssertEqual(globallyDisabled.stateText, "Off")
    XCTAssertEqual(profileDisabled.stateText, "Off")
    XCTAssertEqual(connecting.stateText, "Connecting")
  }

  private func account(identity: String?) -> T3ConnectAccount {
    T3ConnectAccount(
      record: try! T3OAuthRecord(
        grantID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
        accessToken: "access", refreshToken: "refresh",
        expiresAt: Date(timeIntervalSince1970: 1_800_000_000), displayIdentity: identity))
  }

  private func environment(
    source: T3EnvironmentSource,
    state: T3ConnectionState
  ) -> T3EnvironmentSnapshot {
    T3EnvironmentSnapshot(
      id: "\(source.rawValue)|studio", logicalEnvironmentID: "studio", source: source,
      label: "Studio", baseURL: "https://studio.example/", platform: "macOS · arm64",
      serverVersion: "1", state: state, agents: [])
  }
}
