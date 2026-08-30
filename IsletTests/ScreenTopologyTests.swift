import Defaults
import XCTest

@testable import Islet

@MainActor
final class ScreenTopologyTests: XCTestCase {
  private let builtinID = "00000000-0000-0000-0000-000000000001"
  private let externalID = "00000000-0000-0000-0000-000000000002"

  func testSyntheticProviderCoversToggleConnectIdempotenceRearrangeAndDisconnect() {
    let builtin = descriptor(
      builtinID, name: "Built-in Display", isBuiltin: true, isMain: true,
      frame: CGRect(x: 0, y: 0, width: 1728, height: 1117))
    let external = descriptor(
      externalID, name: "Studio Display",
      frame: CGRect(x: 1728, y: 0, width: 2560, height: 1440))
    let provider = SyntheticScreenDescriptorProvider([builtin])
    var controller = ScreenTopologyController(provider: provider)

    let initial = controller.reconcile(showOnAllDisplays: false, storedPreference: "")
    XCTAssertEqual(initial.panelIDs, [builtinID])
    XCTAssertEqual(initial.addedIDs, [builtinID])
    XCTAssertTrue(initial.removedIDs.isEmpty)

    provider.descriptors = [builtin, external]
    let disabledConnect = controller.reconcile(showOnAllDisplays: false, storedPreference: "")
    XCTAssertEqual(disabledConnect.panelIDs, [builtinID])
    XCTAssertTrue(disabledConnect.addedIDs.isEmpty)
    XCTAssertTrue(disabledConnect.removedIDs.isEmpty)
    XCTAssertTrue(disabledConnect.reconfiguredIDs.isEmpty)

    let enabled = controller.reconcile(showOnAllDisplays: true, storedPreference: "")
    XCTAssertEqual(enabled.panelIDs, [builtinID, externalID])
    XCTAssertEqual(enabled.addedIDs, [externalID])

    let disabled = controller.reconcile(showOnAllDisplays: false, storedPreference: "")
    XCTAssertEqual(disabled.panelIDs, [builtinID])
    XCTAssertEqual(disabled.removedIDs, [externalID])

    let reenabled = controller.reconcile(showOnAllDisplays: true, storedPreference: "")
    XCTAssertEqual(reenabled.panelIDs, [builtinID, externalID])
    XCTAssertEqual(reenabled.addedIDs, [externalID])

    let repeated = controller.reconcile(showOnAllDisplays: true, storedPreference: "")
    XCTAssertTrue(repeated.addedIDs.isEmpty)
    XCTAssertTrue(repeated.removedIDs.isEmpty)
    XCTAssertTrue(repeated.reconfiguredIDs.isEmpty)

    let rearrangedExternal = descriptor(
      externalID, name: "Studio Display",
      frame: CGRect(x: -2560, y: 180, width: 2560, height: 1440))
    provider.descriptors = [rearrangedExternal, builtin]
    let rearranged = controller.reconcile(showOnAllDisplays: true, storedPreference: "")
    XCTAssertEqual(rearranged.panelIDs, [externalID, builtinID])
    XCTAssertEqual(rearranged.reconfiguredIDs, [externalID])
    XCTAssertTrue(rearranged.addedIDs.isEmpty)
    XCTAssertTrue(rearranged.removedIDs.isEmpty)

    provider.descriptors = [builtin]
    let disconnected = controller.reconcile(showOnAllDisplays: true, storedPreference: "")
    XCTAssertEqual(disconnected.panelIDs, [builtinID])
    XCTAssertEqual(disconnected.removedIDs, [externalID])

    let repeatedDisconnect = controller.reconcile(
      showOnAllDisplays: true, storedPreference: "")
    XCTAssertTrue(repeatedDisconnect.addedIDs.isEmpty)
    XCTAssertTrue(repeatedDisconnect.removedIDs.isEmpty)
    XCTAssertTrue(repeatedDisconnect.reconfiguredIDs.isEmpty)
  }

  func testDuplicateStableIdentityCreatesOnePanelTarget() {
    let first = descriptor(
      externalID, name: "Studio Display",
      frame: CGRect(x: 0, y: 0, width: 2560, height: 1440))
    let duplicate = descriptor(
      externalID, name: "Duplicate AppKit entry",
      frame: CGRect(x: 5000, y: 0, width: 1920, height: 1080))
    let provider = SyntheticScreenDescriptorProvider([first, duplicate])
    var controller = ScreenTopologyController(provider: provider)

    let transition = controller.reconcile(showOnAllDisplays: true, storedPreference: "")

    XCTAssertEqual(transition.panelIDs, [externalID])
    XCTAssertEqual(transition.descriptors.first?.geometry, first.geometry)
  }

  func testPreferredSingleDisplayFallsBackAndReturnsAcrossDisconnect() {
    let builtin = descriptor(
      builtinID, name: "Built-in Display", isBuiltin: true, isMain: true,
      frame: CGRect(x: 0, y: 0, width: 1728, height: 1117))
    let external = descriptor(
      externalID, name: "Studio Display",
      frame: CGRect(x: 1728, y: 0, width: 2560, height: 1440))
    let provider = SyntheticScreenDescriptorProvider([builtin, external])
    var controller = ScreenTopologyController(provider: provider)

    XCTAssertEqual(
      controller.reconcile(showOnAllDisplays: false, storedPreference: externalID).panelIDs,
      [externalID])

    provider.descriptors = [builtin, builtin]
    let disconnected = controller.reconcile(
      showOnAllDisplays: false, storedPreference: externalID)
    XCTAssertEqual(disconnected.panelIDs, [builtinID])
    XCTAssertEqual(disconnected.addedIDs, [builtinID])
    XCTAssertEqual(disconnected.removedIDs, [externalID])

    provider.descriptors = [builtin, external, external]
    let reconnected = controller.reconcile(
      showOnAllDisplays: false, storedPreference: externalID)
    XCTAssertEqual(reconnected.panelIDs, [externalID])
    XCTAssertEqual(reconnected.addedIDs, [externalID])
    XCTAssertEqual(reconnected.removedIDs, [builtinID])
  }

  func testExternalGeometryAlwaysUsesACentredSyntheticNotch() {
    let frame = CGRect(x: 2560, y: 180, width: 1920, height: 1080)
    let geometry = DisplayGeometryPolicy.geometry(
      screenFrame: frame,
      visibleFrame: CGRect(x: 2560, y: 180, width: 1920, height: 1052),
      isBuiltin: false,
      notchReading: .init(safeAreaTop: 40, auxLeftWidth: 700, auxRightWidth: 700))

    XCTAssertFalse(geometry.hasHardwareNotch)
    XCTAssertEqual(geometry.notchSize, CGSize(width: Metrics.fallbackNotchWidth, height: 28))
    XCTAssertEqual(geometry.notchRect.midX, frame.midX, accuracy: 0.01)
    XCTAssertEqual(geometry.notchRect.maxY, frame.maxY, accuracy: 0.01)
  }

  func testBuiltinGeometryRetainsPhysicalNotchMeasurements() {
    let frame = CGRect(x: 0, y: 0, width: 1728, height: 1117)
    let geometry = DisplayGeometryPolicy.geometry(
      screenFrame: frame,
      visibleFrame: CGRect(x: 0, y: 0, width: 1728, height: 1080),
      isBuiltin: true,
      notchReading: .init(safeAreaTop: 32, auxLeftWidth: 716, auxRightWidth: 708))

    XCTAssertTrue(geometry.hasHardwareNotch)
    XCTAssertEqual(geometry.notchRect.minX, 716, accuracy: 0.01)
    XCTAssertEqual(geometry.notchRect.maxX, 1020, accuracy: 0.01)
    XCTAssertEqual(geometry.notchRect.maxY, frame.maxY, accuracy: 0.01)
  }

  func testAllDisplaysPreferenceIsPersistedAndRestored() {
    XCTAssertFalse(DisplayPlacementDefaults.showOnAllDisplays)
    let saved = Defaults[.showOnAllDisplays]
    defer { Defaults[.showOnAllDisplays] = saved }

    Defaults[.showOnAllDisplays] = true
    XCTAssertTrue(Defaults[.showOnAllDisplays])
    Defaults[.showOnAllDisplays] = false
    XCTAssertFalse(Defaults[.showOnAllDisplays])
  }

  private func descriptor(
    _ id: String, name: String, isBuiltin: Bool = false, isMain: Bool = false,
    frame: CGRect
  ) -> ScreenDescriptor {
    let reading =
      isBuiltin
      ? NotchStickiness.Reading(safeAreaTop: 32, auxLeftWidth: 716, auxRightWidth: 708)
      : NotchStickiness.Reading(safeAreaTop: 0, auxLeftWidth: 0, auxRightWidth: 0)
    return ScreenDescriptor(
      snapshot: DisplaySnapshot(
        stableID: id, legacyRuntimeID: nil, name: name, isBuiltin: isBuiltin,
        isMain: isMain, mirrorGroupID: id),
      hardwareIdentity: isBuiltin ? .builtin : nil,
      geometry: DisplayGeometryPolicy.geometry(
        screenFrame: frame,
        visibleFrame: CGRect(
          x: frame.minX, y: frame.minY, width: frame.width, height: frame.height - 28),
        isBuiltin: isBuiltin, notchReading: reading))
  }
}

@MainActor
private final class SyntheticScreenDescriptorProvider: ScreenDescriptorProviding {
  var descriptors: [ScreenDescriptor]

  init(_ descriptors: [ScreenDescriptor]) {
    self.descriptors = descriptors
  }

  func currentDescriptors() -> [ScreenDescriptor] { descriptors }
}
