import Foundation
import XCTest

@testable import Islet

final class SettingsTransferTests: XCTestCase {
  func testExportRoundTripsEveryPortableSetting() throws {
    let exported = sampleSnapshot
    let data = try SettingsTransfer.exportData(
      snapshot: exported, exportedAt: Date(timeIntervalSince1970: 0))
    let preview = try SettingsTransfer.preview(data: data, current: defaultSnapshot)

    XCTAssertEqual(preview.sourceVersion, SettingsTransfer.currentVersion)
    XCTAssertEqual(preview.result, exported)
    XCTAssertEqual(preview.importedSettingCount, SettingsTransfer.portableKeys.count)
    XCTAssertTrue(preview.ignoredKeys.isEmpty)
  }

  func testPartialImportKeepsSettingsThatAreNotInTheFile() throws {
    let data = try document(settings: ["appTheme": "ocean"])
    let preview = try SettingsTransfer.preview(data: data, current: defaultSnapshot)

    var expected = defaultSnapshot
    expected.appTheme = .ocean
    XCTAssertEqual(preview.result, expected)
    XCTAssertEqual(preview.importedSettingCount, 1)
    XCTAssertEqual(preview.changes.map(\.key), ["appTheme"])
  }

  func testCorruptAndTypeInvalidFilesFailBeforeProducingAPreview() throws {
    XCTAssertThrowsError(
      try SettingsTransfer.preview(data: Data("not json".utf8), current: defaultSnapshot))

    let invalid = try document(settings: ["hapticsEnabled": "yes"])
    XCTAssertThrowsError(try SettingsTransfer.preview(data: invalid, current: defaultSnapshot)) {
      XCTAssertEqual(
        $0.localizedDescription, "hapticsEnabled has the wrong value. Expected true or false.")
    }
  }

  func testOversizedDocumentsAndListsFailBeforeProducingAPreview() throws {
    let oversized = Data(repeating: 0x20, count: SettingsTransfer.maximumDocumentBytes + 1)
    XCTAssertThrowsError(
      try SettingsTransfer.preview(data: oversized, current: defaultSnapshot)
    ) {
      XCTAssertEqual($0.localizedDescription, "The settings file is larger than 1 MB.")
    }

    let tooManyActivities = (0...SettingsTransfer.maximumListItems).map { "activity-\($0)" }
    let invalidList = try document(settings: ["disabledActivities": tooManyActivities])
    XCTAssertThrowsError(
      try SettingsTransfer.preview(data: invalidList, current: defaultSnapshot))
  }

  func testAudioOnlyExclusionsNormalizeAndEnforceTheirSmallerBound() throws {
    let normalized = try document(
      settings: [
        "excludedAudioOnlySourceBundleIdentifiers": [
          "com.google.Chrome.helper.Renderer", "com.google.Chrome", "com.apple.PowerChime",
        ]
      ])
    let preview = try SettingsTransfer.preview(data: normalized, current: defaultSnapshot)
    XCTAssertEqual(
      preview.result.excludedAudioOnlySourceBundleIdentifiers, ["com.google.Chrome"])

    let tooMany = (0...SourceFilter.maximumAudioOnlyExclusions).map { "com.example.app\($0)" }
    let invalid = try document(
      settings: ["excludedAudioOnlySourceBundleIdentifiers": tooMany])
    XCTAssertThrowsError(try SettingsTransfer.preview(data: invalid, current: defaultSnapshot))
  }

  func testVersionOneAliasesMigrate() throws {
    let object: [String: Any] = [
      "version": 1,
      "preferences": [
        "theme": "forest",
        "interaction": "clickToPin",
        "hiddenActivities": ["pulse"],
        "disabledEvents": ["wifi"],
      ],
    ]
    let data = try JSONSerialization.data(withJSONObject: object)
    let preview = try SettingsTransfer.preview(data: data, current: defaultSnapshot)

    XCTAssertEqual(preview.sourceVersion, 1)
    XCTAssertEqual(preview.result.appTheme, .forest)
    XCTAssertEqual(preview.result.interactionMode, .clickToPin)
    XCTAssertEqual(preview.result.disabledActivities, ["pulse"])
    XCTAssertEqual(preview.result.disabledEventSources, ["wifi"])
    XCTAssertTrue(preview.ignoredKeys.isEmpty)
  }

  func testUnknownKeysAreReportedAndIgnored() throws {
    let data = try document(settings: ["appTheme": "violet", "futureSetting": 42])
    let preview = try SettingsTransfer.preview(data: data, current: defaultSnapshot)

    XCTAssertEqual(preview.ignoredKeys, ["futureSetting"])
    XCTAssertEqual(preview.result.appTheme, .violet)
  }

  func testPreviewDescribesChangesWithoutMutatingCurrentSettings() throws {
    let current = defaultSnapshot
    let data = try document(
      settings: ["energyMode": "live", "disabledActivities": ["clipboard", "pulse"]])
    let preview = try SettingsTransfer.preview(data: data, current: current)

    XCTAssertEqual(current, defaultSnapshot)
    XCTAssertEqual(preview.changes.map(\.key), ["disabledActivities", "energyMode"])
    XCTAssertEqual(preview.changes.first?.oldValue, "None")
    XCTAssertEqual(preview.changes.first?.newValue, "clipboard, pulse")
  }

  func testApplyUsesOneValidatedPatch() throws {
    let data = try document(settings: ["appTheme": "sunset", "hudEnabled": true])
    let preview = try SettingsTransfer.preview(data: data, current: defaultSnapshot)
    var applyCount = 0
    var applied = defaultSnapshot

    SettingsTransfer.apply(preview) { patch in
      applyCount += 1
      applied = patch.applying(to: applied)
    }

    XCTAssertEqual(applyCount, 1)
    XCTAssertEqual(applied, preview.result)
  }

  func testExportAllowlistCannotContainSensitiveOrInstallationSpecificPreferences() throws {
    XCTAssertTrue(
      Set(SettingsTransfer.portableKeys).isDisjoint(with: SettingsTransfer.excludedPreferenceKeys))

    let data = try SettingsTransfer.exportData(snapshot: sampleSnapshot)
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: data) as? [String: Any])
    let settings = try XCTUnwrap(object["settings"] as? [String: Any])

    XCTAssertEqual(Set(settings.keys), Set(SettingsTransfer.portableKeys))
    for forbidden in SettingsTransfer.excludedPreferenceKeys {
      XCTAssertNil(settings[forbidden], "Export included \(forbidden)")
    }
    let text = try XCTUnwrap(String(data: data, encoding: .utf8))
    XCTAssertFalse(text.localizedCaseInsensitiveContains("keychain"))
    XCTAssertFalse(text.localizedCaseInsensitiveContains("token"))
    XCTAssertFalse(text.contains("t3RemoteEnvironments"))
    XCTAssertFalse(text.contains("hiddenCalendarIDs"))
  }

  private func document(settings: [String: Any]) throws -> Data {
    try JSONSerialization.data(
      withJSONObject: [
        "format": SettingsTransfer.formatIdentifier,
        "version": SettingsTransfer.currentVersion,
        "settings": settings,
      ])
  }

  private var defaultSnapshot: SettingsTransferSnapshot {
    SettingsTransferSnapshot(
      appTheme: .classic, batteryGraphStyle: .coloured, mediaSourceMode: .auto,
      mediaPriorityList: ["com.spotify.client", "com.apple.Music"],
      excludedAudioOnlySourceBundleIdentifiers: [], interactionMode: .hover,
      hoverCollapseTimeout: 0.5, hapticsEnabled: true, hapticStrength: .medium,
      barrierPushDistance: 120, energyMode: .automatic, hideFromScreenRecording: false,
      hudEnabled: false, hudStyle: .bar, calendarEnabled: true, calendarLeadMinutes: 10,
      remindersEnabled: true, showOnAllDisplays: false, hideInFullscreen: false,
      launchAtLogin: false, activityOrder: ActivityCatalog.defaultOrder, disabledActivities: [],
      disabledEventSources: [], systemAlwaysVisible: false, metricStyles: [:],
      continuityAlwaysVisible: false, continuitySneaks: true)
  }

  private var sampleSnapshot: SettingsTransferSnapshot {
    SettingsTransferSnapshot(
      appTheme: .catppuccin, batteryGraphStyle: .monochrome, mediaSourceMode: .prioritized,
      mediaPriorityList: ["com.apple.Music", "com.spotify.client"],
      excludedAudioOnlySourceBundleIdentifiers: ["com.example.CallApp"],
      interactionMode: .clickToPin, hoverCollapseTimeout: 2.4, hapticsEnabled: false,
      hapticStrength: .strong, barrierPushDistance: 640, energyMode: .lowEnergy,
      hideFromScreenRecording: true, hudEnabled: true, hudStyle: .gauge,
      calendarEnabled: false, calendarLeadMinutes: 30, remindersEnabled: false,
      showOnAllDisplays: true, hideInFullscreen: true, launchAtLogin: true,
      activityOrder: ActivityCatalog.defaultOrder.reversed(),
      disabledActivities: ["pulse", "clipboard"], disabledEventSources: ["wifi", "focus"],
      systemAlwaysVisible: true, metricStyles: ["cpu": "combined", "thermal": "number"],
      continuityAlwaysVisible: true, continuitySneaks: false)
  }
}
