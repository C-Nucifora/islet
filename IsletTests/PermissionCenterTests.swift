import EventKit
import XCTest

@testable import Islet

final class PermissionCenterTests: XCTestCase {
  func testEventKitPermissionStatesPreserveRecoveryMeaning() {
    XCTAssertEqual(EventKitPermissionState(.notDetermined), .notDetermined)
    XCTAssertEqual(EventKitPermissionState(.denied), .denied)
    XCTAssertEqual(EventKitPermissionState(.restricted), .restricted)
    XCTAssertEqual(EventKitPermissionState(.writeOnly), .writeOnly)
    XCTAssertEqual(EventKitPermissionState(.fullAccess), .fullAccess)

    XCTAssertFalse(EventKitPermissionState.denied.canRead)
    XCTAssertTrue(EventKitPermissionState.denied.requiresSettingsRecovery)
    XCTAssertFalse(EventKitPermissionState.restricted.requiresSettingsRecovery)
    XCTAssertTrue(EventKitPermissionState.fullAccess.canRead)
    XCTAssertFalse(EventKitPermissionState.notDetermined.requiresSettingsRecovery)
  }

  func testPrivacyPaneURLsTargetExpectedSystemSettingsAnchors() {
    XCTAssertEqual(
      SystemSettingsPrivacyPane.calendars.url.absoluteString,
      "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")
    XCTAssertEqual(
      SystemSettingsPrivacyPane.accessibility.url.absoluteString,
      "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
  }

  func testDiagnosticsTextIncludesIdentityAndDistinctPermissionStates() {
    let snapshot = PermissionDiagnosticsSnapshot(
      capturedAt: Date(timeIntervalSince1970: 0),
      appPath: "/Applications/Islet.app",
      executablePath: "/Applications/Islet.app/Contents/MacOS/Islet",
      bundleIdentifier: "dev.islet",
      appVersion: "1.2.3",
      buildVersion: "45",
      signingIdentifier: "dev.islet",
      teamIdentifier: "TEAM123",
      signingIdentity: "Apple Development: Example",
      codeDirectoryHash: "abcdef",
      accessibilityGranted: true,
      calendar: .denied,
      reminders: .fullAccess,
      location: .granted,
      bluetooth: .notDetermined)

    XCTAssertTrue(snapshot.text.contains("App path: /Applications/Islet.app"))
    XCTAssertTrue(snapshot.text.contains("Team identifier: TEAM123"))
    XCTAssertTrue(snapshot.text.contains("Calendars: Denied"))
    XCTAssertTrue(snapshot.text.contains("Reminders: Full access"))
    XCTAssertTrue(snapshot.text.contains("Location: Allowed"))
    XCTAssertTrue(snapshot.text.contains("Bluetooth: Not requested"))
  }
}
