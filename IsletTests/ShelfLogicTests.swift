import AppKit
import XCTest

@testable import Islet

final class ShelfLogicTests: XCTestCase {
  func testShelfHasBoundedCapacity() {
    XCTAssertEqual(ShelfModel.maximumItemCount, 100)
    XCTAssertTrue(ShelfLogic.hasCapacity(currentCount: 99, pendingCount: 0, maximum: 100))
    XCTAssertFalse(ShelfLogic.hasCapacity(currentCount: 99, pendingCount: 1, maximum: 100))
    XCTAssertFalse(ShelfLogic.hasCapacity(currentCount: 100, pendingCount: 0, maximum: 100))
  }

  func testInvalidCapacityInputsFailClosed() {
    XCTAssertFalse(ShelfLogic.hasCapacity(currentCount: -1, pendingCount: 0, maximum: 100))
    XCTAssertFalse(ShelfLogic.hasCapacity(currentCount: 0, pendingCount: -1, maximum: 100))
    XCTAssertFalse(ShelfLogic.hasCapacity(currentCount: 0, pendingCount: 0, maximum: 0))
  }

  func testDropTargetCanLeaveAndReenter() {
    let zone = UUID()
    var state = ShelfDropState()

    state.setTarget(zone, active: true)
    XCTAssertTrue(state.isTargeted)
    XCTAssertTrue(state.isActive)

    state.setTarget(zone, active: false)
    XCTAssertFalse(state.isTargeted)
    XCTAssertFalse(state.isActive)

    state.setTarget(zone, active: true)
    XCTAssertTrue(state.isTargeted)
    XCTAssertTrue(state.isActive)
  }

  func testOneWindowLeavingDoesNotClearAnotherWindowsTarget() {
    let first = UUID()
    let second = UUID()
    var state = ShelfDropState()

    state.setTarget(first, active: true)
    state.setTarget(second, active: true)
    state.setTarget(first, active: false)

    XCTAssertTrue(state.isTargeted)
    XCTAssertEqual(state.targetedDropZones, [second])
  }

  func testPendingImportsKeepShelfActiveAfterDragExits() {
    let zone = UUID()
    var state = ShelfDropState()
    state.setTarget(zone, active: true)
    state.beginImports(2)
    state.setTarget(zone, active: false)

    XCTAssertFalse(state.isTargeted)
    XCTAssertTrue(state.isActive)
    XCTAssertEqual(state.pendingImportCount, 2)

    state.finishImport()
    XCTAssertTrue(state.isActive)
    state.finishImport()
    XCTAssertFalse(state.isActive)
  }

  @MainActor
  func testDroppedProviderStaysPendingUntilItsFileIsCopied() async throws {
    let temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    let shelfDirectory = temporaryRoot.appendingPathComponent("Shelf", isDirectory: true)
    let source = temporaryRoot.appendingPathComponent("drop-test.txt")
    try FileManager.default.createDirectory(
      at: temporaryRoot, withIntermediateDirectories: true)
    try Data("notch drop".utf8).write(to: source)
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }

    let model = ShelfModel(directory: shelfDirectory)
    let provider = try XCTUnwrap(NSItemProvider(contentsOf: source))

    XCTAssertTrue(model.importDroppedItems(from: [provider]))
    XCTAssertEqual(model.pendingImportCount, 1)
    XCTAssertTrue(model.isDropPresentationActive)

    for _ in 0..<100 where model.pendingImportCount > 0 {
      try await Task.sleep(for: .milliseconds(10))
    }

    XCTAssertEqual(model.pendingImportCount, 0)
    XCTAssertFalse(model.isDropPresentationActive)
    XCTAssertEqual(model.items.map(\.name), ["drop-test.txt"])
    XCTAssertEqual(try String(contentsOf: model.items[0].url, encoding: .utf8), "notch drop")
  }
}
