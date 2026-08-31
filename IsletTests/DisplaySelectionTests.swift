import XCTest

@testable import Islet

final class DisplaySelectionTests: XCTestCase {
  private let builtinID = "00000000-0000-0000-0000-000000000001"
  private let externalID = "00000000-0000-0000-0000-000000000002"
  private let secondExternalID = "00000000-0000-0000-0000-000000000003"

  func testAutomaticFallbackPrefersBuiltinBeforeMain() {
    let displays = [
      display(externalID, name: "Studio Display", isMain: true),
      display(builtinID, name: "Built-in Display", isBuiltin: true),
    ]

    XCTAssertEqual(
      DisplaySelection.targetIDs(
        showOnAllDisplays: false, storedPreference: "", displays: displays),
      [builtinID])
  }

  func testDesktopWithoutBuiltinFallsBackToMainDisplay() {
    let displays = [
      display(externalID, name: "Projector"),
      display(secondExternalID, name: "Studio Display", isMain: true),
    ]

    XCTAssertEqual(
      DisplaySelection.targetIDs(
        showOnAllDisplays: false, storedPreference: "", displays: displays),
      [secondExternalID])
  }

  func testFallbackUsesFirstDisplayWhenNoBuiltinOrMainExists() {
    let displays = [
      display(externalID, name: "Left"),
      display(secondExternalID, name: "Right"),
    ]

    XCTAssertEqual(
      DisplaySelection.targetIDs(
        showOnAllDisplays: false, storedPreference: "", displays: displays),
      [externalID])
  }

  func testDockUndockAndReconnectRestoresPreferenceWithoutRewritingIt() {
    let docked = [
      display(builtinID, name: "Built-in Display", isBuiltin: true, isMain: true),
      display(externalID, name: "Studio Display"),
    ]
    let undocked = [docked[0]]

    XCTAssertEqual(
      DisplaySelection.targetIDs(
        showOnAllDisplays: false, storedPreference: externalID, displays: docked),
      [externalID])
    XCTAssertEqual(
      DisplaySelection.targetIDs(
        showOnAllDisplays: false, storedPreference: externalID, displays: undocked),
      [builtinID])
    XCTAssertNil(
      DisplaySelection.migratedPreference(
        storedPreference: externalID, displays: undocked))
    XCTAssertEqual(
      DisplaySelection.targetIDs(
        showOnAllDisplays: false, storedPreference: externalID, displays: docked),
      [externalID])
  }

  func testClamshellFallbackUsesMainExternalUntilPreferenceReturns() {
    let closedLid = [display(secondExternalID, name: "Desk Display", isMain: true)]
    let preferredConnected = [
      display(secondExternalID, name: "Desk Display", isMain: true),
      display(externalID, name: "Studio Display"),
    ]

    XCTAssertEqual(
      DisplaySelection.targetIDs(
        showOnAllDisplays: false, storedPreference: externalID, displays: closedLid),
      [secondExternalID])
    XCTAssertEqual(
      DisplaySelection.targetIDs(
        showOnAllDisplays: false, storedPreference: externalID, displays: preferredConnected),
      [externalID])
  }

  func testQuickActionsAndShowIsletUseTheSameSingleDisplayTarget() {
    let displays = [
      display(builtinID, name: "Built-in Display", isBuiltin: true, isMain: true),
      display(externalID, name: "Studio Display"),
    ]
    let panelTargets = DisplaySelection.targetIDs(
      showOnAllDisplays: false, storedPreference: externalID, displays: displays)

    XCTAssertEqual(panelTargets, [externalID])
    XCTAssertEqual(
      DisplaySelection.actionTargetID(
        showOnAllDisplays: false,
        storedPreference: externalID,
        displays: displays,
        displayUnderPointerID: builtinID),
      panelTargets.first)
  }

  func testAllDisplaysUsesPointerTargetForActions() {
    let displays = [
      display(builtinID, name: "Built-in Display", isBuiltin: true, isMain: true),
      display(externalID, name: "Studio Display"),
    ]

    XCTAssertEqual(
      DisplaySelection.actionTargetID(
        showOnAllDisplays: true,
        storedPreference: externalID,
        displays: displays,
        displayUnderPointerID: externalID),
      externalID)
  }

  func testMirroredDisplaysProduceOnePanelPerMirrorGroup() {
    let displays = [
      display(builtinID, name: "Built-in Display", mirrorGroupID: builtinID),
      display(externalID, name: "Projector", mirrorGroupID: builtinID),
      display(secondExternalID, name: "Studio Display"),
    ]

    XCTAssertEqual(
      DisplaySelection.targetIDs(
        showOnAllDisplays: true, storedPreference: "", displays: displays),
      [builtinID, secondExternalID])
    XCTAssertEqual(
      DisplaySelection.targetIDs(
        showOnAllDisplays: false, storedPreference: externalID, displays: displays),
      [externalID])
  }

  func testDuplicateScreensAndDuplicateNamesDoNotCreateDuplicateChoices() {
    let displays = [
      display(externalID, name: "Studio Display"),
      display(secondExternalID, name: "Studio Display"),
      display(externalID, name: "Studio Display"),
    ]

    let choices = DisplaySelection.choices(from: displays)

    XCTAssertEqual(choices.map(\.id), [externalID, secondExternalID])
    XCTAssertEqual(choices.map(\.name), ["Studio Display 1", "Studio Display 2"])
  }

  func testLegacyRuntimeIdentifierMigratesOnlyWhenItsDisplayIsAvailable() {
    let displays = [
      display(externalID, legacyRuntimeID: "42", name: "Studio Display")
    ]

    XCTAssertEqual(
      DisplaySelection.migratedPreference(storedPreference: "42", displays: displays),
      externalID)
    XCTAssertEqual(
      DisplaySelection.migratedPreference(storedPreference: "display:42", displays: displays),
      externalID)
    XCTAssertNil(
      DisplaySelection.migratedPreference(storedPreference: "42", displays: []))
  }

  func testPrefixedAndLowercaseUUIDMigratesWithoutAConnectedDisplay() {
    XCTAssertEqual(
      DisplaySelection.migratedPreference(
        storedPreference: "display:\(externalID.lowercased())", displays: []),
      externalID)
  }

  func testUniqueLegacyNameMigratesButDuplicateNameDoesNotGuess() {
    let oneDisplay = [display(externalID, name: "Studio Display")]
    let duplicateNames = oneDisplay + [display(secondExternalID, name: "Studio Display")]

    XCTAssertEqual(
      DisplaySelection.migratedPreference(
        storedPreference: "studio display", displays: oneDisplay),
      externalID)
    XCTAssertNil(
      DisplaySelection.migratedPreference(
        storedPreference: "Studio Display", displays: duplicateNames))
  }

  func testNoDisplaysProducesNoPanelOrActionTarget() {
    XCTAssertEqual(
      DisplaySelection.targetIDs(
        showOnAllDisplays: false, storedPreference: externalID, displays: []),
      [])
    XCTAssertNil(
      DisplaySelection.actionTargetID(
        showOnAllDisplays: false,
        storedPreference: externalID,
        displays: [],
        displayUnderPointerID: nil))
  }

  private func display(
    _ id: String, legacyRuntimeID: String? = nil, name: String,
    isBuiltin: Bool = false, isMain: Bool = false, mirrorGroupID: String? = nil
  ) -> DisplaySnapshot {
    DisplaySnapshot(
      stableID: id,
      legacyRuntimeID: legacyRuntimeID,
      name: name,
      isBuiltin: isBuiltin,
      isMain: isMain,
      mirrorGroupID: mirrorGroupID ?? id)
  }
}

final class ScreenManagerDisplayLifecycleTests: XCTestCase {
  private let builtinID = "00000000-0000-0000-0000-000000000001"
  private let externalID = "00000000-0000-0000-0000-000000000002"

  func testDisconnectRepeatedNotificationAndReconnectKeepExactlyOnePanelTarget() {
    let builtin = display(builtinID, name: "Built-in Display", isBuiltin: true, isMain: true)
    let external = display(externalID, name: "Studio Display")
    var state = ScreenManagerDisplayState()

    let docked = state.reconcile(
      showOnAllDisplays: false,
      storedPreference: externalID,
      displays: [builtin, external])
    XCTAssertEqual(docked.panelIDs, [externalID])
    XCTAssertEqual(docked.addedIDs, [externalID])
    XCTAssertTrue(docked.removedIDs.isEmpty)

    let disconnected = state.reconcile(
      showOnAllDisplays: false,
      storedPreference: externalID,
      displays: [builtin])
    XCTAssertEqual(disconnected.panelIDs, [builtinID])
    XCTAssertEqual(disconnected.addedIDs, [builtinID])
    XCTAssertEqual(disconnected.removedIDs, [externalID])

    let repeated = state.reconcile(
      showOnAllDisplays: false,
      storedPreference: externalID,
      displays: [builtin, builtin])
    XCTAssertEqual(repeated.panelIDs, [builtinID])
    XCTAssertTrue(repeated.addedIDs.isEmpty)
    XCTAssertTrue(repeated.removedIDs.isEmpty)

    let reconnected = state.reconcile(
      showOnAllDisplays: false,
      storedPreference: externalID,
      displays: [builtin, external, external])
    XCTAssertEqual(reconnected.panelIDs, [externalID])
    XCTAssertEqual(reconnected.addedIDs, [externalID])
    XCTAssertEqual(reconnected.removedIDs, [builtinID])
  }

  private func display(
    _ id: String, name: String, isBuiltin: Bool = false, isMain: Bool = false
  ) -> DisplaySnapshot {
    DisplaySnapshot(
      stableID: id,
      legacyRuntimeID: nil,
      name: name,
      isBuiltin: isBuiltin,
      isMain: isMain,
      mirrorGroupID: id)
  }
}
