import XCTest

@testable import Islet

final class OnboardingTests: XCTestCase {
  func testDisabledActivitiesFollowTheSetupSelection() {
    let selected: Set<String> = ["timer", "battery", "calendar"]

    let disabled = OnboardingPreferences.disabledActivities(
      preserving: [], selected: selected)

    XCTAssertFalse(disabled.contains("timer"))
    XCTAssertFalse(disabled.contains("battery"))
    XCTAssertFalse(disabled.contains("calendar"))
    XCTAssertTrue(disabled.contains("clipboard"))
    XCTAssertTrue(disabled.contains("pulse"))
  }

  func testUnknownActivityPreferencesSurviveSetup() {
    let disabled = OnboardingPreferences.disabledActivities(
      preserving: ["futureActivity", "timer"], selected: ["timer"])

    XCTAssertTrue(disabled.contains("futureActivity"))
    XCTAssertFalse(disabled.contains("timer"))
    XCTAssertEqual(disabled.filter { $0 == "futureActivity" }.count, 1)
  }

  @MainActor
  func testLegacyMigrationPreservesCanonicalSettingsAndImportsMissingValues() {
    let merged = LegacyInstallMigrator.merging(
      current: ["shared": "current", "currentOnly": true],
      legacy: [
        ["shared": "old", "first": 1],
        ["first": 2, "second": "imported"],
      ])

    XCTAssertEqual(merged["shared"] as? String, "current")
    XCTAssertEqual(merged["currentOnly"] as? Bool, true)
    XCTAssertEqual(merged["first"] as? Int, 1)
    XCTAssertEqual(merged["second"] as? String, "imported")
  }
}
