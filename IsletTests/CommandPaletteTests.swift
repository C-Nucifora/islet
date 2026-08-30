import Carbon.HIToolbox
import XCTest

@testable import Islet

@MainActor
final class CommandPaletteTests: XCTestCase {
  func testRankingPrefersExactAndTitleMatches() {
    let results = [
      result(id: "detail", title: "Open Calendar", detail: "Start a focus timer"),
      result(id: "prefix", title: "Focus Pulse", detail: "Provider profile"),
      result(id: "exact", title: "Focus", detail: "Open focus settings"),
    ]

    XCTAssertEqual(
      CommandPaletteSearch.ranked(results, query: "focus").map(\.id),
      ["exact", "prefix", "detail"])
  }

  func testSearchUsesSettingsNormalization() {
    let candidate = result(
      id: "wifi", title: "Configure résumé source", detail: "Settings",
      searchableContent: ["Wi-Fi"])

    XCTAssertEqual(
      CommandPaletteSearch.ranked([candidate], query: "RESUME wifi").map(\.id), ["wifi"])
  }

  func testUnavailableResultsAreNotShown() {
    let available = result(id: "available", title: "Available", detail: "", isAvailable: true)
    let unavailable = result(
      id: "unavailable", title: "Unavailable", detail: "", isAvailable: false)

    XCTAssertEqual(
      CommandPaletteCatalog.availableResults(from: [unavailable, available]).map(\.id),
      ["available"])
  }

  func testKeyboardSelectionWrapsAndClampsWhenResultsChange() {
    var selection = CommandPaletteSelection()
    selection.move(1, resultCount: 3)
    XCTAssertEqual(selection.index, 1)
    selection.move(-1, resultCount: 3)
    XCTAssertEqual(selection.index, 0)
    selection.move(-1, resultCount: 3)
    XCTAssertEqual(selection.index, 2)
    selection.updateResultCount(1)
    XCTAssertEqual(selection.index, 0)
    selection.move(1, resultCount: 0)
    XCTAssertEqual(selection.index, 0)
  }

  func testPerformRecordsAtMostFiveRecentResults() {
    var stored = ["old-1", "old-2", "old-3", "old-4", "old-5"]
    let performed = expectation(description: "performed")
    let candidate = result(id: "new", title: "New", detail: "", perform: { performed.fulfill() })
    let model = CommandPaletteModel(
      candidates: { [candidate] }, recentIDs: { stored }, saveRecentIDs: { stored = $0 })

    model.perform(candidate)

    wait(for: [performed], timeout: 0.1)
    XCTAssertEqual(stored, ["new", "old-1", "old-2", "old-3", "old-4"])
  }

  func testReturnPerformsKeyboardSelection() {
    var performedID: String?
    let first = result(id: "first", title: "A", detail: "", perform: { performedID = "first" })
    let second = result(id: "second", title: "B", detail: "", perform: { performedID = "second" })
    let model = CommandPaletteModel(
      candidates: { [first, second] }, recentIDs: { [] }, saveRecentIDs: { _ in })

    model.moveSelection(1)
    model.performSelected()

    XCTAssertEqual(performedID, "second")
  }

  func testPerformRestoresPreviousAppUnlessResultOpensAnIsletWindow() {
    var restoreDecisions: [Bool] = []
    let background = result(id: "background", title: "Background", detail: "")
    let foreground = result(
      id: "foreground", title: "Foreground", detail: "", opensIsletWindow: true)
    let model = CommandPaletteModel(
      candidates: { [background, foreground] }, recentIDs: { [] }, saveRecentIDs: { _ in },
      dismiss: { restoreDecisions.append($0) })

    model.perform(background)
    model.perform(foreground)

    XCTAssertEqual(restoreDecisions, [true, false])
  }

  func testEverySettingsPageExposesAnIndividualControl() {
    for page in SettingsDetailPage.allCases {
      XCTAssertFalse(page.paletteControls.isEmpty, "\(page) has no palette controls")
    }
  }

  private func result(
    id: String, title: String, detail: String, searchableContent: [String] = [],
    opensIsletWindow: Bool = false, isAvailable: Bool = true,
    perform: @escaping () -> Void = {}
  ) -> CommandPaletteResult {
    CommandPaletteResult(
      id: id, title: title, detail: detail, symbol: "bolt", kind: .action,
      searchableContent: searchableContent, opensIsletWindow: opensIsletWindow,
      isAvailable: { isAvailable }, perform: perform)
  }
}

@MainActor
final class GlobalShortcutTests: XCTestCase {
  func testDefaultShortcutIsValid() {
    XCTAssertNil(GlobalShortcutValidator.validate(.default))
    XCTAssertEqual(GlobalShortcut.default.displayName, "⌥Space")
  }

  func testShortcutRequiresPrimaryModifier() {
    let noModifiers = GlobalShortcut(keyCode: 0, key: "A", modifiers: [])
    let shiftOnly = GlobalShortcut(keyCode: 0, key: "A", modifiers: .shift)

    XCTAssertEqual(GlobalShortcutValidator.validate(noModifiers), .modifierKeyRequired)
    XCTAssertEqual(GlobalShortcutValidator.validate(shiftOnly), .modifierKeyRequired)
  }

  func testShortcutRejectsNavigationKeys() {
    let escape = GlobalShortcut(
      keyCode: UInt32(kVK_Escape), key: "Escape", modifiers: .command)
    let returnKey = GlobalShortcut(
      keyCode: UInt32(kVK_Return), key: "Return", modifiers: .option)

    XCTAssertEqual(GlobalShortcutValidator.validate(escape), .unsupportedKey)
    XCTAssertEqual(GlobalShortcutValidator.validate(returnKey), .unsupportedKey)
  }

  func testShortcutRejectsKeysOutsideTheDocumentedSet() {
    let help = GlobalShortcut(keyCode: UInt32(kVK_Help), key: "Help", modifiers: .command)
    let unknown = GlobalShortcut(keyCode: 255, key: "Unknown", modifiers: .control)

    XCTAssertEqual(GlobalShortcutValidator.validate(help), .unsupportedKey)
    XCTAssertEqual(GlobalShortcutValidator.validate(unknown), .unsupportedKey)
  }

  func testShortcutAcceptsArrowAndFunctionKeys() {
    let arrow = GlobalShortcut(keyCode: UInt32(kVK_LeftArrow), key: "←", modifiers: .option)
    let function = GlobalShortcut(keyCode: UInt32(kVK_F12), key: "F12", modifiers: .control)

    XCTAssertNil(GlobalShortcutValidator.validate(arrow))
    XCTAssertNil(GlobalShortcutValidator.validate(function))
  }

  func testManagerReportsRegistrationConflictAndUnregistersOnDisable() {
    let registrar = FakeShortcutRegistrar(status: OSStatus(eventHotKeyExistsErr))
    let manager = GlobalShortcutManager(registrar: registrar)

    manager.register(.default)
    XCTAssertEqual(manager.status, .conflict)
    XCTAssertEqual(registrar.registeredShortcuts, [.default])

    manager.register(nil)
    XCTAssertEqual(manager.status, .disabled)
    XCTAssertEqual(registrar.unregisterCount, 2)
  }
}

private final class FakeShortcutRegistrar: GlobalShortcutRegistering {
  let status: OSStatus
  private(set) var registeredShortcuts: [GlobalShortcut] = []
  private(set) var unregisterCount = 0

  init(status: OSStatus) { self.status = status }

  func register(_ shortcut: GlobalShortcut, handler: @escaping @MainActor () -> Void) -> OSStatus {
    registeredShortcuts.append(shortcut)
    return status
  }

  func unregister() { unregisterCount += 1 }
}
