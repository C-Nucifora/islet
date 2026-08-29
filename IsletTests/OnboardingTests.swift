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
        ["shared": "old", "first": 1, "onboardingVersion": 1],
        ["first": 2, "second": "imported"],
      ])

    XCTAssertEqual(merged["shared"] as? String, "current")
    XCTAssertEqual(merged["currentOnly"] as? Bool, true)
    XCTAssertEqual(merged["first"] as? Int, 1)
    XCTAssertEqual(merged["second"] as? String, "imported")
    XCTAssertNil(merged["onboardingVersion"])
  }

  @MainActor
  func testLegacyMigrationWritesEffectiveBundleDomainThroughLiveDefaults() throws {
    let suiteName = "dev.islet.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let imported = try LegacyInstallMigrator.migratePreferences(
      defaults: defaults, currentBundleIdentifier: suiteName,
      legacyDomains: [["showOnAllDisplays": true, "onboardingVersion": 1]])

    XCTAssertEqual(imported, 1)
    XCTAssertEqual(defaults.object(forKey: "showOnAllDisplays") as? Bool, true)
    XCTAssertNil(defaults.object(forKey: "onboardingVersion"))
    XCTAssertEqual(
      defaults.persistentDomain(forName: suiteName)?["showOnAllDisplays"] as? Bool, true)
  }

  @MainActor
  func testLegacyMigrationUsesTheEffectiveBundleIdentifier() {
    XCTAssertEqual(
      LegacyInstallMigrator.resolvedBundleIdentifier("dev.review.override"),
      "dev.review.override")
    XCTAssertEqual(LegacyInstallMigrator.resolvedBundleIdentifier(nil), "dev.islet")
  }
}
