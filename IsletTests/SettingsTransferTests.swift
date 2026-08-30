import Defaults
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

  @MainActor
  func testSystemPresenceControlsRoundTripThroughDefaults() throws {
    let saved = systemPresenceControlValues
    let savedHoverCollapseTimeout = Defaults[.hoverCollapseTimeout]
    defer {
      setSystemPresenceControls(saved)
      Defaults[.hoverCollapseTimeout] = savedHoverCollapseTimeout
    }
    let keys = [
      "systemAutoPresentCPU", "systemAutoPresentThermal", "systemAutoPresentMemoryPressure",
      "systemAutoPresentLowDiskSpace", "systemAutoPresentDiskThroughput",
      "systemAutoPresentNetworkThroughput",
    ]

    Defaults[.hoverCollapseTimeout] = 0.5
    setSystemPresenceControls(Array(repeating: false, count: keys.count))
    let data = try SettingsTransfer.exportData(snapshot: SettingsTransferDefaults.snapshot())
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let settings = try XCTUnwrap(object["settings"] as? [String: Any])
    for key in keys {
      XCTAssertEqual(settings[key] as? Bool, false, "Export omitted \(key)")
    }

    setSystemPresenceControls(Array(repeating: true, count: keys.count))
    let preview = try SettingsTransfer.preview(
      data: data, current: SettingsTransferDefaults.snapshot())
    XCTAssertTrue(preview.ignoredKeys.isEmpty)
    XCTAssertEqual(Set(preview.changes.map(\.key)).intersection(keys), Set(keys))
    SettingsTransfer.apply(preview) { SettingsTransferDefaults.apply($0) }
    XCTAssertEqual(systemPresenceControlValues, Array(repeating: false, count: keys.count))
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

  @MainActor
  private var systemPresenceControlValues: [Bool] {
    [
      Defaults[.systemAutoPresentCPU], Defaults[.systemAutoPresentThermal],
      Defaults[.systemAutoPresentMemoryPressure], Defaults[.systemAutoPresentLowDiskSpace],
      Defaults[.systemAutoPresentDiskThroughput], Defaults[.systemAutoPresentNetworkThroughput],
    ]
  }

  @MainActor
  private func setSystemPresenceControls(_ values: [Bool]) {
    Defaults[.systemAutoPresentCPU] = values[0]
    Defaults[.systemAutoPresentThermal] = values[1]
    Defaults[.systemAutoPresentMemoryPressure] = values[2]
    Defaults[.systemAutoPresentLowDiskSpace] = values[3]
    Defaults[.systemAutoPresentDiskThroughput] = values[4]
    Defaults[.systemAutoPresentNetworkThroughput] = values[5]
  }

  private var defaultSnapshot: SettingsTransferSnapshot {
    SettingsTransferSnapshot(
      appTheme: .classic, batteryGraphStyle: .coloured, mediaSourceMode: .auto,
      mediaPriorityList: ["com.spotify.client", "com.apple.Music"], interactionMode: .hover,
      hoverCollapseTimeout: 0.5, hapticsEnabled: true, hapticStrength: .medium,
      barrierPushDistance: 120, energyMode: .automatic, hideFromScreenRecording: false,
      hudEnabled: false, hudStyle: .bar, calendarEnabled: true, calendarLeadMinutes: 10,
      remindersEnabled: true, showOnAllDisplays: false, hideInFullscreen: false,
      launchAtLogin: false, activityOrder: ActivityCatalog.defaultOrder, disabledActivities: [],
      disabledEventSources: [], systemAlwaysVisible: false,
      systemAutoPresentCPU: true, systemAutoPresentThermal: true,
      systemAutoPresentMemoryPressure: true, systemAutoPresentLowDiskSpace: true,
      systemAutoPresentDiskThroughput: true, systemAutoPresentNetworkThroughput: true,
      metricStyles: [:],
      continuityAlwaysVisible: false, continuitySneaks: true)
  }

  private var sampleSnapshot: SettingsTransferSnapshot {
    SettingsTransferSnapshot(
      appTheme: .catppuccin, batteryGraphStyle: .monochrome, mediaSourceMode: .prioritized,
      mediaPriorityList: ["com.apple.Music", "com.spotify.client"],
      interactionMode: .clickToPin, hoverCollapseTimeout: 2.4, hapticsEnabled: false,
      hapticStrength: .strong, barrierPushDistance: 640, energyMode: .lowEnergy,
      hideFromScreenRecording: true, hudEnabled: true, hudStyle: .gauge,
      calendarEnabled: false, calendarLeadMinutes: 30, remindersEnabled: false,
      showOnAllDisplays: true, hideInFullscreen: true, launchAtLogin: true,
      activityOrder: ActivityCatalog.defaultOrder.reversed(),
      disabledActivities: ["pulse", "clipboard"], disabledEventSources: ["wifi", "focus"],
      systemAlwaysVisible: true,
      systemAutoPresentCPU: false, systemAutoPresentThermal: true,
      systemAutoPresentMemoryPressure: false, systemAutoPresentLowDiskSpace: true,
      systemAutoPresentDiskThroughput: false, systemAutoPresentNetworkThroughput: true,
      metricStyles: ["cpu": "combined", "thermal": "number"],
      continuityAlwaysVisible: true, continuitySneaks: false)
  }
}
