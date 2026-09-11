import SwiftUI
import XCTest

@testable import Islet

final class MotionTests: XCTestCase {
  func testGatedPassesTheAnimationThroughWhenMotionIsAllowed() {
    XCTAssertEqual(Motion.gated(Motion.opening, reduceMotion: false), Motion.opening)
    XCTAssertEqual(Motion.gated(Motion.closing, reduceMotion: false), Motion.closing)
    XCTAssertEqual(Motion.gated(Motion.compact, reduceMotion: false), Motion.compact)
    XCTAssertEqual(Motion.gated(Motion.hudAppearing, reduceMotion: false), Motion.hudAppearing)
  }

  func testGatedCollapsesToNilUnderReduceMotion() {
    // nil is the "apply the change with no animation" argument for both withAnimation(_:_:)
    // and .animation(_:value:), so every call site gates by wrapping its animation.
    XCTAssertNil(Motion.gated(Motion.opening, reduceMotion: true))
    XCTAssertNil(Motion.gated(Motion.closing, reduceMotion: true))
    XCTAssertNil(Motion.gated(Motion.compact, reduceMotion: true))
    XCTAssertNil(Motion.gated(Motion.hudAppearing, reduceMotion: true))
  }

  func testHUDEntryIsShortAndExitUsesNormalCompactMotion() {
    XCTAssertEqual(Motion.compactChange(hudVisible: true), Motion.hudAppearing)
    XCTAssertEqual(Motion.compactChange(hudVisible: false), Motion.compact)
    XCTAssertNotEqual(Motion.hudAppearing, Motion.compact)
  }

  func testPanelShrinkDelayOutlastsTheClosingAnimation() {
    // The panel must stay oversized until the close has finished drawing, or the island is
    // clipped mid-collapse.
    XCTAssertGreaterThan(
      Motion.panelShrinkDelay,
      Duration.milliseconds(Int(Motion.closingDuration * 1000)))
  }

  func testMotionProfileNamesEverySourceAndRoundTrips() {
    XCTAssertEqual(MotionProfile.allCases.count, 15)
    for profile in MotionProfile.allCases {
      XCTAssertEqual(MotionProfile(rawValue: profile.rawValue), profile)
    }
    XCTAssertEqual(MotionProfile.volumeMount.rawValue, "volumeMount")
    XCTAssertEqual(MotionProfile.chargeComplete.rawValue, "chargeComplete")
  }
}

final class AccessibilityPolicyTests: XCTestCase {
  private final class FocusTestPanel: NotchPanel {
    private(set) var makeKeyCount = 0
    private(set) var resignKeyCount = 0
    private var reportsKeyWindow = false

    override var isKeyWindow: Bool { reportsKeyWindow }

    override func makeKey() {
      makeKeyCount += 1
      reportsKeyWindow = true
    }

    override func resignKey() {
      resignKeyCount += 1
      reportsKeyWindow = false
    }

    func simulateExternalFocus() {
      reportsKeyWindow = true
    }
  }

  @MainActor
  func testPanelInstanceTakesFocusOnlyAfterAnExplicitRequestAndReleasesItOnCollapse() {
    let panel = FocusTestPanel(frame: CGRect(x: 0, y: 0, width: 520, height: 190))
    defer { panel.close() }
    let geometry = NotchGeometry(
      screenFrame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
      safeAreaTop: 32, auxLeftWidth: 716, auxRightWidth: 716, menuBarHeight: 37)
    let viewModel = NotchViewModel(geometry: geometry, modeOverride: .clickToPin)
    let instance = PanelInstance(
      display: ManagedDisplay(id: "test", hardwareIdentity: .builtin), panel: panel,
      viewModel: viewModel)
    XCTAssertTrue(panel.canBecomeKey)
    XCTAssertFalse(panel.canBecomeMain)

    viewModel.apply(.clickedNotch)
    instance.updateKeyboardFocus(isExpanded: viewModel.state.isExpanded)
    XCTAssertFalse(panel.isKeyWindow)
    XCTAssertEqual(panel.makeKeyCount, 0)
    instance.requestKeyboardFocus()
    XCTAssertTrue(panel.isKeyWindow)
    XCTAssertEqual(panel.makeKeyCount, 1)
    viewModel.apply(.clickedNotch)
    instance.updateKeyboardFocus(isExpanded: viewModel.state.isExpanded)
    XCTAssertFalse(panel.isKeyWindow)
    XCTAssertEqual(panel.resignKeyCount, 1)
  }

  @MainActor
  func testPanelDoesNotReleaseFocusItDidNotAcquire() {
    let panel = FocusTestPanel(frame: CGRect(x: 0, y: 0, width: 520, height: 190))
    defer { panel.close() }

    panel.simulateExternalFocus()
    XCTAssertTrue(panel.isKeyWindow)
    panel.releaseKeyboardFocusIfAcquired()
    XCTAssertTrue(panel.isKeyWindow)
    XCTAssertEqual(panel.resignKeyCount, 0)
  }

  func testKeyboardCommandsUseStableShortcuts() {
    XCTAssertEqual(command("1", .command), .selectTab(0))
    XCTAssertEqual(command("9", .command), .selectTab(8))
    XCTAssertEqual(command("\t", .control), .cycleTab(1))
    XCTAssertEqual(command("\u{19}", [.control, .shift]), .cycleTab(-1))
    XCTAssertNil(command("\t", [.control, .shift]))
    XCTAssertEqual(command("\r", .command), .primaryAction)
    XCTAssertEqual(command("\u{1b}", []), .dismissTransient)
    XCTAssertEqual(command("W", .command), .close)
  }

  func testKeyboardPolicyPreservesUnrelatedKeysAndTypingFields() {
    XCTAssertNil(command("k", .command))
    XCTAssertNil(command("1", []))
    XCTAssertNil(command("\r", []))
    XCTAssertNil(command("\r", .command, isEditingText: true))
    XCTAssertNil(command("\u{1b}", [], isEditingText: true))
    XCTAssertNil(command("2", .command, isEditingText: true))
  }

  func testNumberSelectionAndCyclingReachOverflowActivities() {
    let ids = [ExpandedSelectionPolicy.homeID] + ActivityCatalog.defaultOrder
    XCTAssertEqual(
      IslandKeyboardPolicy.selectedID(
        for: .selectTab(0), tabIDs: ids, currentID: ExpandedSelectionPolicy.homeID),
      ExpandedSelectionPolicy.homeID)
    XCTAssertEqual(
      IslandKeyboardPolicy.selectedID(
        for: .selectTab(8), tabIDs: ids, currentID: ExpandedSelectionPolicy.homeID), ids[8])
    XCTAssertNil(
      IslandKeyboardPolicy.selectedID(
        for: .selectTab(12), tabIDs: ids, currentID: ExpandedSelectionPolicy.homeID))

    var selected = ExpandedSelectionPolicy.homeID
    for _ in 0..<ids.count {
      selected =
        IslandKeyboardPolicy.selectedID(
          for: .cycleTab(1), tabIDs: ids, currentID: selected) ?? selected
    }
    XCTAssertEqual(selected, ExpandedSelectionPolicy.homeID)
    XCTAssertEqual(
      IslandKeyboardPolicy.selectedID(
        for: .cycleTab(-1), tabIDs: ids, currentID: ExpandedSelectionPolicy.homeID), ids.last)
  }

  func testExpandedFocusOrderIncludesSwitcherUtilitiesAndEveryActivityContentGroup() {
    let visible = [ExpandedSelectionPolicy.homeID, "timer", "nowPlaying"]
    let overflow = ActivityCatalog.defaultOrder.filter { !visible.contains($0) }

    for selectedID in [ExpandedSelectionPolicy.homeID] + ActivityCatalog.defaultOrder {
      let order = ExpandedFocusOrder.targets(
        visibleTabIDs: visible, overflowTabIDs: overflow, selectedID: selectedID)
      XCTAssertEqual(Array(order.prefix(3)), visible.map(ExpandedFocusTarget.tab))
      XCTAssertEqual(order[3], .overflow)
      XCTAssertEqual(order[4], .quickActions)
      XCTAssertEqual(order[5], .settings)
      XCTAssertEqual(order.last, .content(selectedID))
    }
  }

  func testEffectiveSelectionUsesDropRequestStoredChoiceAndProminentActivityInOrder() {
    let ids = [ExpandedSelectionPolicy.homeID, "shelf", "timer", "nowPlaying"]
    XCTAssertEqual(
      ExpandedSelectionPolicy.effectiveSelection(
        tabIDs: ids, storedSelection: "timer", shelfPresentationActive: true,
        primaryActivityID: "nowPlaying"),
      "shelf")
    XCTAssertEqual(
      ExpandedSelectionPolicy.effectiveSelection(
        tabIDs: ids, storedSelection: "timer", shelfPresentationActive: false,
        primaryActivityID: "nowPlaying"),
      "timer")
    XCTAssertEqual(
      ExpandedSelectionPolicy.effectiveSelection(
        tabIDs: ids, storedSelection: nil, shelfPresentationActive: false,
        primaryActivityID: "nowPlaying"),
      "nowPlaying")
    XCTAssertEqual(
      ExpandedSelectionPolicy.effectiveSelection(
        tabIDs: ids, storedSelection: nil, shelfPresentationActive: false,
        primaryActivityID: "battery"),
      ExpandedSelectionPolicy.homeID)
  }

  func testActivityLabelsIncludeStateWithoutDependingOnColor() {
    XCTAssertEqual(
      ActivityAccessibilityText.clipboardItem(preview: "Report", detail: "2 files"),
      "Report, 2 files")
    XCTAssertEqual(
      ActivityAccessibilityText.portDevice(
        name: "Display", vendor: "Acme", speed: "10 Gb/s", port: "Port 2"),
      "Display, Acme, 10 Gb/s, Port 2")
    XCTAssertEqual(
      ActivityAccessibilityText.pulseItem(
        source: "Build", title: "Tests", state: "failed", subtitle: "One failure"),
      "Build, Tests, failed, One failure")
    XCTAssertEqual(
      ActivityAccessibilityText.reminder(title: "Submit", due: "9:00 am", overdue: true),
      "Submit, overdue, 9:00 am")
  }

  func testReduceMotionPolicyRemovesDecorativeEffects() {
    XCTAssertTrue(Motion.allowsDecorativeMotion(reduceMotion: false))
    XCTAssertFalse(Motion.allowsDecorativeMotion(reduceMotion: true))
    XCTAssertNil(Motion.gated(.bouncy, reduceMotion: true))
  }

  func testEveryThemeRoleMeetsTextContrastAgainstTheBlackIsland() throws {
    for theme in AppTheme.allCases {
      for role in AppThemeRole.allCases {
        let ratio = try XCTUnwrap(
          AppThemeContrast.ratio(foreground: theme.color(for: role)),
          "Could not resolve \(theme) \(role) in sRGB")
        XCTAssertGreaterThanOrEqual(
          ratio, AppThemeContrast.minimumTextRatio,
          "\(theme.title) \(role) contrast was \(ratio)")
      }
    }
  }

  func testBatteryGraphThemesAndMonochromeMeetGraphicalContrast() throws {
    for theme in AppTheme.allCases {
      for style in BatteryGraphStyle.allCases {
        for role in BatteryFlowRole.allCases {
          for opacity in BatteryFlowRendering.graphicalOpacities {
            let ratio = try XCTUnwrap(
              AppThemeContrast.ratio(
                foreground: theme.powerFlowColor(for: role, style: style), opacity: opacity),
              "Could not resolve \(theme) \(style) \(role) in sRGB")
            XCTAssertGreaterThanOrEqual(
              ratio, AppThemeContrast.minimumGraphicalRatio,
              "\(theme.title) \(style.title) \(role) at \(opacity) contrast was \(ratio)")
          }
        }
      }
    }
  }

  @MainActor
  func testDismissingCurrentSneakImmediatelyPresentsTheNextQueuedAlert() async throws {
    let queue = SneakQueue()
    queue.submit(
      Sneak(
        source: "first", duration: 4, leading: AnyView(EmptyView()),
        trailing: AnyView(EmptyView())))
    queue.submit(
      Sneak(
        source: "second", duration: 1, leading: AnyView(EmptyView()),
        trailing: AnyView(EmptyView())))
    await Task.yield()
    XCTAssertEqual(queue.current?.source, "first")

    XCTAssertTrue(queue.dismissCurrent())
    try await Task.sleep(for: .milliseconds(50))

    XCTAssertEqual(queue.current?.source, "second")
    XCTAssertTrue(queue.dismissCurrent())
  }

  private func command(
    _ key: String, _ modifiers: IslandKeyboardModifiers, isEditingText: Bool = false
  ) -> IslandKeyboardCommand? {
    IslandKeyboardPolicy.command(
      for: IslandKeyStroke(
        key: key, modifiers: modifiers, isEditingText: isEditingText))
  }
}
