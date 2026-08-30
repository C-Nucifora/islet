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

  func testActionPolicyUsesPointerThenActiveAppThenPreferenceThenMain() {
    let fourthID = "00000000-0000-0000-0000-000000000004"
    let displays = [
      display(builtinID, name: "Main", isMain: true),
      display(externalID, name: "Preferred"),
      display(secondExternalID, name: "Active app"),
      display(fourthID, name: "Pointer"),
    ]

    XCTAssertEqual(
      DisplaySelection.actionTargetID(
        showOnAllDisplays: true, storedPreference: externalID, displays: displays,
        displayUnderPointerID: fourthID, activeApplicationDisplayID: secondExternalID),
      fourthID)
    XCTAssertEqual(
      DisplaySelection.actionTargetID(
        showOnAllDisplays: true, storedPreference: externalID, displays: displays,
        displayUnderPointerID: nil, activeApplicationDisplayID: secondExternalID),
      secondExternalID)
    XCTAssertEqual(
      DisplaySelection.actionTargetID(
        showOnAllDisplays: true, storedPreference: externalID, displays: displays,
        displayUnderPointerID: nil, activeApplicationDisplayID: nil),
      externalID)
    XCTAssertEqual(
      DisplaySelection.actionTargetID(
        showOnAllDisplays: true, storedPreference: "", displays: displays,
        displayUnderPointerID: nil, activeApplicationDisplayID: nil),
      builtinID)
  }

  func testActionPolicyMapsMirrorMembersToTheHostedRepresentative() {
    let displays = [
      display(builtinID, name: "Built-in", isMain: true, mirrorGroupID: builtinID),
      display(externalID, name: "Projector", mirrorGroupID: builtinID),
      display(secondExternalID, name: "Desk"),
    ]

    XCTAssertEqual(
      DisplaySelection.actionTargetID(
        showOnAllDisplays: true, storedPreference: "", displays: displays,
        displayUnderPointerID: externalID, activeApplicationDisplayID: secondExternalID),
      builtinID)
  }

  func testSingleDisplayModeAlwaysAddressesItsOnlyHostedPanel() {
    let displays = [
      display(builtinID, name: "Built-in", isBuiltin: true, isMain: true),
      display(externalID, name: "Preferred"),
      display(secondExternalID, name: "Pointer"),
    ]

    XCTAssertEqual(
      DisplaySelection.actionTargetID(
        showOnAllDisplays: false, storedPreference: externalID, displays: displays,
        displayUnderPointerID: secondExternalID, activeApplicationDisplayID: builtinID),
      externalID)
  }

  func testSleepingAndDisconnectedPreferencesFallThroughToMain() {
    let sleeping = [
      display(builtinID, name: "Main", isMain: true),
      display(externalID, name: "Sleeping preference", isUsable: false),
    ]
    let disconnected = [display(builtinID, name: "Main", isMain: true)]

    for displays in [sleeping, disconnected] {
      XCTAssertEqual(
        DisplaySelection.actionTargetID(
          showOnAllDisplays: true, storedPreference: externalID, displays: displays,
          displayUnderPointerID: externalID, activeApplicationDisplayID: externalID),
        builtinID)
    }
  }

  func testStalePanelSetDoesNotReceiveActionDuringTopologyRace() {
    let displays = [
      display(builtinID, name: "Main", isMain: true),
      display(externalID, name: "Preferred"),
    ]

    XCTAssertNil(
      DisplaySelection.actionTargetID(
        showOnAllDisplays: false, storedPreference: externalID, displays: displays,
        displayUnderPointerID: externalID, hostedPanelIDs: [builtinID]))
    XCTAssertEqual(
      DisplaySelection.actionTargetID(
        showOnAllDisplays: false, storedPreference: externalID, displays: displays,
        displayUnderPointerID: externalID, hostedPanelIDs: [externalID]),
      externalID)
  }

  func testIncompleteAllDisplayPanelSetForcesTopologyRebuild() {
    let displays = [
      display(builtinID, name: "Main", isMain: true),
      display(externalID, name: "New display"),
    ]

    XCTAssertNil(
      DisplaySelection.actionTargetID(
        showOnAllDisplays: true, storedPreference: "", displays: displays,
        displayUnderPointerID: externalID, hostedPanelIDs: [builtinID]))
  }

  func testMultiplePanelsWithoutAnyPolicyCandidateDoNotUseCollectionOrder() {
    let displays = [
      display(externalID, name: "Left"),
      display(secondExternalID, name: "Right"),
    ]

    for hosted in [Set([externalID, secondExternalID]), Set([secondExternalID, externalID])] {
      XCTAssertNil(
        DisplaySelection.actionTargetID(
          showOnAllDisplays: true, storedPreference: "", displays: displays,
          displayUnderPointerID: nil, activeApplicationDisplayID: nil,
          hostedPanelIDs: hosted))
    }
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
    isBuiltin: Bool = false, isMain: Bool = false, mirrorGroupID: String? = nil,
    isUsable: Bool = true
  ) -> DisplaySnapshot {
    DisplaySnapshot(
      stableID: id,
      legacyRuntimeID: legacyRuntimeID,
      name: name,
      isBuiltin: isBuiltin,
      isMain: isMain,
      mirrorGroupID: mirrorGroupID ?? id,
      isUsable: isUsable)
  }
}

final class ActiveApplicationDisplayResolverTests: XCTestCase {
  private let leftID = "00000000-0000-0000-0000-000000000001"
  private let rightID = "00000000-0000-0000-0000-000000000002"

  func testUsesFrontmostNormalWindowOwnedByActiveApplication() {
    let displays = sideBySideDisplays()
    let windows = [
      window(pid: 22, layer: 0, bounds: CGRect(x: 0, y: 0, width: 100, height: 100)),
      window(pid: 11, layer: 3, bounds: CGRect(x: 100, y: 0, width: 100, height: 100)),
      window(pid: 11, layer: 0, bounds: CGRect(x: 120, y: 10, width: 60, height: 80)),
      window(pid: 11, layer: 0, bounds: CGRect(x: 10, y: 10, width: 60, height: 80)),
    ]

    XCTAssertEqual(
      ActiveApplicationDisplayResolver.targetID(
        processIdentifier: 11, windows: windows, displays: displays),
      rightID)
  }

  func testSpanningWindowUsesLargestIntersection() {
    XCTAssertEqual(
      ActiveApplicationDisplayResolver.targetID(
        processIdentifier: 11,
        windows: [window(pid: 11, bounds: CGRect(x: 80, y: 0, width: 100, height: 100))],
        displays: sideBySideDisplays()),
      rightID)
  }

  func testEqualIntersectionPrefersMainThenStableIdentifier() {
    let spanning = [window(pid: 11, bounds: CGRect(x: 50, y: 0, width: 100, height: 100))]
    XCTAssertEqual(
      ActiveApplicationDisplayResolver.targetID(
        processIdentifier: 11, windows: spanning, displays: sideBySideDisplays()),
      leftID)

    let noMain = [
      ActionDisplayGeometry(
        stableID: rightID, bounds: CGRect(x: 100, y: 0, width: 100, height: 100),
        isMain: false),
      ActionDisplayGeometry(
        stableID: leftID, bounds: CGRect(x: 0, y: 0, width: 100, height: 100),
        isMain: false),
    ]
    XCTAssertEqual(
      ActiveApplicationDisplayResolver.targetID(
        processIdentifier: 11, windows: spanning, displays: noMain),
      leftID)
  }

  func testMissingWindowsAndOffscreenWindowsReturnNoDisplay() {
    XCTAssertNil(
      ActiveApplicationDisplayResolver.targetID(
        processIdentifier: 11, windows: [], displays: sideBySideDisplays()))
    XCTAssertNil(
      ActiveApplicationDisplayResolver.targetID(
        processIdentifier: 11,
        windows: [window(pid: 11, bounds: CGRect(x: 500, y: 500, width: 50, height: 50))],
        displays: sideBySideDisplays()))
  }

  private func sideBySideDisplays() -> [ActionDisplayGeometry] {
    [
      ActionDisplayGeometry(
        stableID: leftID, bounds: CGRect(x: 0, y: 0, width: 100, height: 100), isMain: true),
      ActionDisplayGeometry(
        stableID: rightID, bounds: CGRect(x: 100, y: 0, width: 100, height: 100),
        isMain: false),
    ]
  }

  private func window(
    pid: pid_t, layer: Int = 0, bounds: CGRect
  ) -> ActiveApplicationWindowSnapshot {
    ActiveApplicationWindowSnapshot(
      ownerProcessIdentifier: pid, layer: layer, bounds: bounds)
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
