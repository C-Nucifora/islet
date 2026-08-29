import AppKit
import Darwin
import XCTest

@testable import Islet

final class ShelfLogicTests: XCTestCase {
  private enum CopyFailure: Error { case expected }

  private actor CopyProbe {
    private var started = false

    func markStarted() { started = true }
    func hasStarted() -> Bool { started }
  }

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
  func testDroppedFileURLsCopyThroughAppKitImportPath() async throws {
    let temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    let shelfDirectory = temporaryRoot.appendingPathComponent("Shelf", isDirectory: true)
    let source = temporaryRoot.appendingPathComponent("appkit-drop.txt")
    try FileManager.default.createDirectory(
      at: temporaryRoot, withIntermediateDirectories: true)
    try Data("appkit drop".utf8).write(to: source)
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }

    let model = ShelfModel(directory: shelfDirectory)
    XCTAssertTrue(model.importDroppedURLs([source]))
    XCTAssertEqual(model.pendingImportCount, 1)
    XCTAssertTrue(model.isDropPresentationActive)

    for _ in 0..<100 where model.pendingImportCount > 0 {
      try await Task.sleep(for: .milliseconds(10))
    }

    XCTAssertEqual(model.pendingImportCount, 0)
    XCTAssertFalse(model.isDropPresentationActive)
    XCTAssertEqual(model.items.map(\.name), ["appkit-drop.txt"])
    XCTAssertEqual(try String(contentsOf: model.items[0].url, encoding: .utf8), "appkit drop")
  }

  @MainActor
  func testBatchDropPreservesCapacityFailureAfterAnotherFileSucceeds() async throws {
    let temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    let shelfDirectory = temporaryRoot.appendingPathComponent("Shelf", isDirectory: true)
    try FileManager.default.createDirectory(
      at: shelfDirectory, withIntermediateDirectories: true)
    for index in 0..<(ShelfModel.maximumItemCount - 1) {
      FileManager.default.createFile(
        atPath: shelfDirectory.appendingPathComponent("existing-\(index).txt").path,
        contents: Data())
    }
    let first = temporaryRoot.appendingPathComponent("first.txt")
    let second = temporaryRoot.appendingPathComponent("second.txt")
    try Data("first".utf8).write(to: first)
    try Data("second".utf8).write(to: second)
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }

    let model = ShelfModel(directory: shelfDirectory)
    XCTAssertTrue(model.importDroppedURLs([first, second]))
    for _ in 0..<200 where model.pendingImportCount > 0 {
      try await Task.sleep(for: .milliseconds(10))
    }

    XCTAssertEqual(model.pendingImportCount, 0)
    XCTAssertEqual(model.items.count, ShelfModel.maximumItemCount)
    XCTAssertEqual(model.lastError, "Shelf is full (\(ShelfModel.maximumItemCount) items).")
    XCTAssertEqual(model.items.filter { $0.name == "first.txt" }.count, 1)
    XCTAssertFalse(model.items.contains { $0.name == "second.txt" })
  }

  @MainActor
  func testOverlappingDropBatchesShareOneErrorResult() async throws {
    let temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    let shelfDirectory = temporaryRoot.appendingPathComponent("Shelf", isDirectory: true)
    let failing = temporaryRoot.appendingPathComponent("failing.txt")
    let succeeding = temporaryRoot.appendingPathComponent("succeeding.txt")
    try FileManager.default.createDirectory(
      at: temporaryRoot, withIntermediateDirectories: true)
    try Data("fail".utf8).write(to: failing)
    try Data("succeed".utf8).write(to: succeeding)
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }

    let model = ShelfModel(
      directory: shelfDirectory,
      copyItem: { source, destination in
        if source.lastPathComponent == "failing.txt" { return .failure(CopyFailure.expected) }
        return await Task.detached(priority: .utility) {
          Result { try FileManager.default.copyItem(at: source, to: destination) }
        }.value
      })
    XCTAssertTrue(model.importDroppedURLs([failing]))
    XCTAssertTrue(model.importDroppedURLs([succeeding]))

    for _ in 0..<200 where model.pendingImportCount > 0 {
      try await Task.sleep(for: .milliseconds(10))
    }

    XCTAssertEqual(model.pendingImportCount, 0)
    XCTAssertEqual(model.items.map(\.name), ["succeeding.txt"])
    XCTAssertEqual(model.lastError, "Couldn’t add failing.txt.")
  }

  @MainActor
  func testClearInvalidatesAnImportAlreadyCopying() async throws {
    let temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    let shelfDirectory = temporaryRoot.appendingPathComponent("Shelf", isDirectory: true)
    let source = temporaryRoot.appendingPathComponent("pending.txt")
    try FileManager.default.createDirectory(
      at: temporaryRoot, withIntermediateDirectories: true)
    try Data("pending".utf8).write(to: source)
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }
    let probe = CopyProbe()

    let model = ShelfModel(
      directory: shelfDirectory,
      copyItem: { source, destination in
        await probe.markStarted()
        return await Task.detached(priority: .utility) { () -> Result<Void, Error> in
          usleep(150_000)
          return Result { try FileManager.default.copyItem(at: source, to: destination) }
        }.value
      })
    XCTAssertTrue(model.importDroppedURLs([source]))
    for _ in 0..<100 {
      if await probe.hasStarted() { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    let copyStarted = await probe.hasStarted()
    XCTAssertTrue(copyStarted)

    await model.clear()
    XCTAssertEqual(model.pendingImportCount, 0)
    XCTAssertTrue(model.items.isEmpty)
    try await Task.sleep(for: .milliseconds(250))

    XCTAssertTrue(model.items.isEmpty)
    let remaining =
      (try? FileManager.default.contentsOfDirectory(
        at: shelfDirectory, includingPropertiesForKeys: nil)) ?? []
    XCTAssertTrue(remaining.isEmpty)
  }

  @MainActor
  func testClearRemovesPartialDestinationLeftByFailedCopy() async throws {
    let temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    let shelfDirectory = temporaryRoot.appendingPathComponent("Shelf", isDirectory: true)
    let source = temporaryRoot.appendingPathComponent("partial.txt")
    try FileManager.default.createDirectory(
      at: temporaryRoot, withIntermediateDirectories: true)
    try Data("source".utf8).write(to: source)
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }
    let probe = CopyProbe()

    let model = ShelfModel(
      directory: shelfDirectory,
      copyItem: { _, destination in
        await Task.detached(priority: .utility) {
          try? Data("partial".utf8).write(to: destination)
        }.value
        await probe.markStarted()
        return await Task.detached(priority: .utility) { () -> Result<Void, Error> in
          usleep(150_000)
          return .failure(CopyFailure.expected)
        }.value
      })
    XCTAssertTrue(model.importDroppedURLs([source]))
    for _ in 0..<100 {
      if await probe.hasStarted() { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    let copyStarted = await probe.hasStarted()
    XCTAssertTrue(copyStarted)

    await model.clear()

    XCTAssertTrue(model.items.isEmpty)
    let remaining =
      (try? FileManager.default.contentsOfDirectory(
        at: shelfDirectory, includingPropertiesForKeys: nil)) ?? []
    XCTAssertTrue(remaining.isEmpty)
  }

  @MainActor
  func testDropIsRejectedWhileClearAwaitsInvalidatedCopy() async throws {
    let temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    let shelfDirectory = temporaryRoot.appendingPathComponent("Shelf", isDirectory: true)
    let pending = temporaryRoot.appendingPathComponent("pending.txt")
    let fresh = temporaryRoot.appendingPathComponent("fresh.txt")
    try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    try Data("pending".utf8).write(to: pending)
    try Data("fresh".utf8).write(to: fresh)
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }
    let probe = CopyProbe()

    let model = ShelfModel(
      directory: shelfDirectory,
      copyItem: { source, destination in
        await probe.markStarted()
        return await Task.detached(priority: .utility) {
          usleep(150_000)
          return Result { try FileManager.default.copyItem(at: source, to: destination) }
        }.value
      })
    XCTAssertTrue(model.importDroppedURLs([pending]))
    for _ in 0..<100 {
      if await probe.hasStarted() { break }
      try await Task.sleep(for: .milliseconds(5))
    }

    let clearTask = Task { await model.clear() }
    for _ in 0..<100 where !model.isClearing {
      await Task.yield()
    }
    XCTAssertTrue(model.isClearing)
    XCTAssertFalse(model.importDroppedURLs([fresh]))
    XCTAssertEqual(model.pendingImportCount, 0)

    await clearTask.value
    XCTAssertFalse(model.isClearing)
    XCTAssertTrue(model.items.isEmpty)
  }

  @MainActor
  func testOrdinaryCopyFailureRemovesPartialDestination() async throws {
    let temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    let shelfDirectory = temporaryRoot.appendingPathComponent("Shelf", isDirectory: true)
    let source = temporaryRoot.appendingPathComponent("partial.txt")
    try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    try Data("source".utf8).write(to: source)
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }

    let model = ShelfModel(
      directory: shelfDirectory,
      copyItem: { _, destination in
        await Task.detached(priority: .utility) {
          try? Data("partial".utf8).write(to: destination)
        }.value
        return .failure(CopyFailure.expected)
      })

    let added = await model.add(source)
    XCTAssertFalse(added)
    let remaining =
      (try? FileManager.default.contentsOfDirectory(
        at: shelfDirectory, includingPropertiesForKeys: nil)) ?? []
    XCTAssertTrue(remaining.isEmpty)
  }

  @MainActor
  func testClearTreatsAnAlreadyMissingFileAsRemoved() async throws {
    let temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    let shelfDirectory = temporaryRoot.appendingPathComponent("Shelf", isDirectory: true)
    try FileManager.default.createDirectory(at: shelfDirectory, withIntermediateDirectories: true)
    let stored = shelfDirectory.appendingPathComponent("removed-in-finder.txt")
    try Data("gone".utf8).write(to: stored)
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }

    let model = ShelfModel(directory: shelfDirectory)
    XCTAssertEqual(model.items.count, 1)
    try FileManager.default.removeItem(at: stored)

    await model.clear()

    XCTAssertTrue(model.items.isEmpty)
    XCTAssertNil(model.lastError)
  }
}
