import AppKit
import Darwin
import XCTest

@testable import Islet

final class ShelfLogicTests: XCTestCase {
  private enum CopyFailure: Error { case expected }

  private final class RetryableStorage: @unchecked Sendable {
    private let lock = NSLock()
    private var available = false

    func setAvailable(_ available: Bool) {
      lock.lock()
      self.available = available
      lock.unlock()
    }

    func createDirectory(at _: URL) -> Result<Void, Error> {
      lock.lock()
      defer { lock.unlock() }
      return available ? .success(()) : .failure(CopyFailure.expected)
    }

    func listDirectory(at _: URL) -> Result<[URL], Error> {
      lock.lock()
      defer { lock.unlock() }
      return available ? .success([]) : .failure(CopyFailure.expected)
    }
  }

  private actor CopyProbe {
    private var started = false

    func markStarted() { started = true }
    func hasStarted() -> Bool { started }
  }

  private actor StagedCopyGate {
    private var started = false
    private var continuation: CheckedContinuation<Void, Never>?

    func copy(source: URL, to staging: URL) async -> Result<Void, Error> {
      let result = Result { try FileManager.default.copyItem(at: source, to: staging) }
      started = true
      await withCheckedContinuation { continuation = $0 }
      return result
    }

    func hasStarted() -> Bool { started }

    func release() {
      continuation?.resume()
      continuation = nil
    }
  }

  private actor CompletedMoveGate {
    private var started = false
    private var continuation: CheckedContinuation<Void, Never>?

    func move(source: URL, to destination: URL) async -> Result<Void, Error> {
      let result = Result { try FileManager.default.moveItem(at: source, to: destination) }
      started = true
      await withCheckedContinuation { continuation = $0 }
      return result
    }

    func hasStarted() -> Bool { started }

    func release() {
      continuation?.resume()
      continuation = nil
    }
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

  func testStorageBudgetAcceptsExactByteAndFreeSpaceBoundaries() {
    let policy = ShelfStoragePolicy(maximumBytes: 100, minimumFreeSpaceBytes: 25)

    XCTAssertEqual(
      ShelfLogic.storageDecision(
        currentBytes: 40, reservedBytes: [60], unstagedBytes: [60],
        availableBytes: 85, policy: policy),
      .accepted)
  }

  func testStorageBudgetRejectsOneByteOverEitherLimit() {
    let policy = ShelfStoragePolicy(maximumBytes: 100, minimumFreeSpaceBytes: 25)

    XCTAssertEqual(
      ShelfLogic.storageDecision(
        currentBytes: 41, reservedBytes: [60], unstagedBytes: [60],
        availableBytes: 1_000, policy: policy),
      .overBudget)
    XCTAssertEqual(
      ShelfLogic.storageDecision(
        currentBytes: 40, reservedBytes: [60], unstagedBytes: [60],
        availableBytes: 84, policy: policy),
      .lowFreeSpace)
  }

  func testStorageBudgetFailsClosedForOverflowAndNegativeMeasurements() {
    let policy = ShelfStoragePolicy(maximumBytes: .max, minimumFreeSpaceBytes: 0)

    XCTAssertEqual(
      ShelfLogic.storageDecision(
        currentBytes: .max, reservedBytes: [1], unstagedBytes: [],
        availableBytes: .max, policy: policy),
      .invalidMeasurement)
    XCTAssertEqual(
      ShelfLogic.storageDecision(
        currentBytes: 0, reservedBytes: [-1], unstagedBytes: [],
        availableBytes: .max, policy: policy),
      .invalidMeasurement)
  }

  @MainActor
  func testStorageInitializationFailureIsNotAnEmptyShelf() {
    let model = ShelfModel(
      directory: URL(fileURLWithPath: "/unavailable-shelf"),
      createDirectory: { _ in .failure(CopyFailure.expected) },
      listDirectory: { _ in .success([]) })

    XCTAssertEqual(model.storageFailure, .initialization)
    XCTAssertFalse(model.isStorageAvailable)
    XCTAssertTrue(model.items.isEmpty)
    XCTAssertTrue(model.canRevealStorageLocation)
  }

  @MainActor
  func testStorageListingFailureIsNotAnEmptyShelf() {
    let model = ShelfModel(
      directory: URL(fileURLWithPath: "/unreadable-shelf"),
      createDirectory: { _ in .success(()) },
      listDirectory: { _ in .failure(CopyFailure.expected) })

    XCTAssertEqual(model.storageFailure, .listing)
    XCTAssertFalse(model.isStorageAvailable)
    XCTAssertTrue(model.items.isEmpty)
  }

  @MainActor
  func testRetryClearsStorageFailureAfterStorageRecovers() {
    let storage = RetryableStorage()
    let model = ShelfModel(
      directory: URL(fileURLWithPath: "/recoverable-shelf"),
      createDirectory: storage.createDirectory,
      listDirectory: storage.listDirectory)
    XCTAssertEqual(model.storageFailure, .initialization)

    storage.setAvailable(true)
    model.retryStorage()

    XCTAssertNil(model.storageFailure)
    XCTAssertTrue(model.isStorageAvailable)
    XCTAssertTrue(model.items.isEmpty)
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
  func testSuccessfulImportPublishesOnlyAfterStagingRename() async throws {
    let temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    let shelfDirectory = temporaryRoot.appendingPathComponent("Shelf", isDirectory: true)
    let source = temporaryRoot.appendingPathComponent("atomic.txt")
    try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    try Data("complete contents".utf8).write(to: source)
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }
    let gate = StagedCopyGate()
    let model = ShelfModel(
      directory: shelfDirectory,
      copyItem: { source, staging in await gate.copy(source: source, to: staging) })

    let importTask = Task { await model.add(source) }
    for _ in 0..<100 {
      if await gate.hasStarted() { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    let copyStarted = await gate.hasStarted()
    XCTAssertTrue(copyStarted)

    let beforeRename = try FileManager.default.contentsOfDirectory(
      at: shelfDirectory, includingPropertiesForKeys: nil)
    XCTAssertTrue(model.items.isEmpty)
    let finalURL = shelfDirectory.appendingPathComponent("atomic.txt")
    XCTAssertFalse(FileManager.default.fileExists(atPath: finalURL.path))
    XCTAssertEqual(beforeRename.count, 1)
    XCTAssertTrue(beforeRename[0].lastPathComponent.hasPrefix(".islet-shelf-staging-"))

    await gate.release()
    let added = await importTask.value
    XCTAssertTrue(added)
    XCTAssertEqual(model.items.map(\.name), ["atomic.txt"])
    XCTAssertEqual(try String(contentsOf: model.items[0].url, encoding: .utf8), "complete contents")
    XCTAssertFalse(FileManager.default.fileExists(atPath: beforeRename[0].path))
  }

  @MainActor
  func testLaunchCleansStagingFromAnInterruptedImportWithoutLoadingIt() throws {
    let temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    let shelfDirectory = temporaryRoot.appendingPathComponent("Shelf", isDirectory: true)
    let interrupted = shelfDirectory.appendingPathComponent(
      ".islet-shelf-staging-\(UUID().uuidString)")
    let retained = shelfDirectory.appendingPathComponent("retained.txt")
    try FileManager.default.createDirectory(at: shelfDirectory, withIntermediateDirectories: true)
    try Data("partial".utf8).write(to: interrupted)
    try Data("complete".utf8).write(to: retained)
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }

    let model = ShelfModel(directory: shelfDirectory)

    XCTAssertEqual(model.items.map(\.name), ["retained.txt"])
    XCTAssertFalse(FileManager.default.fileExists(atPath: interrupted.path))
  }

  @MainActor
  func testUnremovableStagingEntryNeverLoadsAsAShelfItem() throws {
    let shelfDirectory = URL(fileURLWithPath: "/Shelf")
    let staging = shelfDirectory.appendingPathComponent(
      ".islet-shelf-staging-\(UUID().uuidString)")
    let retained = shelfDirectory.appendingPathComponent("retained.txt")
    let model = ShelfModel(
      directory: shelfDirectory,
      createDirectory: { _ in .success(()) },
      listDirectory: { _ in .success([staging, retained]) },
      removeItem: { _ in .failure(CopyFailure.expected) })

    XCTAssertTrue(model.isStorageAvailable)
    XCTAssertEqual(model.items.map(\.name), ["retained.txt"])
  }

  @MainActor
  func testOrdinaryFileWithStagingPrefixRemainsVisible() {
    let shelfDirectory = URL(fileURLWithPath: "/Shelf")
    let prefixed = shelfDirectory.appendingPathComponent(".islet-shelf-staging-not-internal.txt")
    let model = ShelfModel(
      directory: shelfDirectory,
      createDirectory: { _ in .success(()) },
      listDirectory: { _ in .success([prefixed]) })

    XCTAssertEqual(model.items.map(\.name), [".islet-shelf-staging-not-internal.txt"])
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
  func testClearRemovesDestinationRenamedWhileClearWasRunning() async throws {
    let temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    let shelfDirectory = temporaryRoot.appendingPathComponent("Shelf", isDirectory: true)
    let source = temporaryRoot.appendingPathComponent("renamed-during-clear.txt")
    try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    try Data("complete".utf8).write(to: source)
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }
    let gate = CompletedMoveGate()
    let model = ShelfModel(
      directory: shelfDirectory,
      moveItem: { source, destination in
        await gate.move(source: source, to: destination)
      })

    XCTAssertTrue(model.importDroppedURLs([source]))
    for _ in 0..<100 {
      if await gate.hasStarted() { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    let moveStarted = await gate.hasStarted()
    XCTAssertTrue(moveStarted)

    let clearTask = Task { await model.clear() }
    for _ in 0..<100 where !model.isClearing {
      await Task.yield()
    }
    XCTAssertTrue(model.isClearing)
    await gate.release()
    await clearTask.value

    XCTAssertTrue(model.items.isEmpty)
    let remaining = try FileManager.default.contentsOfDirectory(
      at: shelfDirectory, includingPropertiesForKeys: nil)
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
  func testStagedRenameFailureRemovesTheCompletedStagingCopy() async throws {
    let temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    let shelfDirectory = temporaryRoot.appendingPathComponent("Shelf", isDirectory: true)
    let source = temporaryRoot.appendingPathComponent("rename-fails.txt")
    try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    try Data("source".utf8).write(to: source)
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }

    let model = ShelfModel(
      directory: shelfDirectory,
      moveItem: { _, _ in .failure(CopyFailure.expected) })

    let added = await model.add(source)
    XCTAssertFalse(added)
    XCTAssertTrue(model.items.isEmpty)
    let remaining = try FileManager.default.contentsOfDirectory(
      at: shelfDirectory, includingPropertiesForKeys: nil)
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

  @MainActor
  func testExactBudgetBoundaryCommitsAndPublishesUsage() async throws {
    let temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    let shelfDirectory = temporaryRoot.appendingPathComponent("Shelf", isDirectory: true)
    let source = temporaryRoot.appendingPathComponent("boundary.bin")
    try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    try Data([0]).write(to: source)
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }

    let model = ShelfModel(
      directory: shelfDirectory,
      measureItem: { _ in .success(100) },
      measureAvailableCapacity: { _ in .success(125) },
      storagePolicy: ShelfStoragePolicy(maximumBytes: 100, minimumFreeSpaceBytes: 25))

    let added = await model.add(source)
    XCTAssertTrue(added)
    XCTAssertEqual(model.currentUsageBytes, 100)
    XCTAssertEqual(model.items.map(\.name), ["boundary.bin"])
  }

  @MainActor
  func testOverBudgetImportReportsRejectedSizeWithoutCopying() async throws {
    let temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    let shelfDirectory = temporaryRoot.appendingPathComponent("Shelf", isDirectory: true)
    let source = temporaryRoot.appendingPathComponent("too-large.bin")
    try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    try Data([0]).write(to: source)
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }

    let model = ShelfModel(
      directory: shelfDirectory,
      measureItem: { _ in .success(101) },
      measureAvailableCapacity: { _ in .success(10_000) },
      storagePolicy: ShelfStoragePolicy(maximumBytes: 100, minimumFreeSpaceBytes: 25))

    let added = await model.add(source)
    XCTAssertFalse(added)
    XCTAssertEqual(model.lastRejectedImportBytes, 101)
    XCTAssertEqual(
      model.lastError,
      "Can't add too-large.bin (101 bytes). The Shelf limit is 100 bytes.")
    XCTAssertTrue(model.items.isEmpty)
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(
        at: shelfDirectory, includingPropertiesForKeys: nil),
      [])
  }

  @MainActor
  func testLowDiskImportReportsSizeAndPreservesFreeSpaceReserve() async throws {
    let temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    let shelfDirectory = temporaryRoot.appendingPathComponent("Shelf", isDirectory: true)
    let source = temporaryRoot.appendingPathComponent("low-disk.bin")
    try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    try Data([0]).write(to: source)
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }

    let model = ShelfModel(
      directory: shelfDirectory,
      measureItem: { _ in .success(60) },
      measureAvailableCapacity: { _ in .success(84) },
      storagePolicy: ShelfStoragePolicy(maximumBytes: 100, minimumFreeSpaceBytes: 25))

    let added = await model.add(source)
    XCTAssertFalse(added)
    XCTAssertEqual(model.lastRejectedImportBytes, 60)
    XCTAssertEqual(
      model.lastError,
      "Can't add low-disk.bin (60 bytes). Islet keeps 25 bytes free for other apps.")
    XCTAssertTrue(model.items.isEmpty)
  }

  @MainActor
  func testStagedCopyIsRemeasuredBeforeCommitWhenTheSourceEstimateChanges() async throws {
    let temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    let shelfDirectory = temporaryRoot.appendingPathComponent("Shelf", isDirectory: true)
    let source = temporaryRoot.appendingPathComponent("growing.bin")
    try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    try Data([0]).write(to: source)
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }

    let model = ShelfModel(
      directory: shelfDirectory,
      measureItem: { url in
        .success(url.lastPathComponent.hasPrefix(".islet-shelf-staging-") ? 101 : 40)
      },
      measureAvailableCapacity: { _ in .success(10_000) },
      storagePolicy: ShelfStoragePolicy(maximumBytes: 100, minimumFreeSpaceBytes: 0))

    let added = await model.add(source)

    XCTAssertFalse(added)
    XCTAssertEqual(model.lastRejectedImportBytes, 101)
    XCTAssertTrue(model.items.isEmpty)
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(
        at: shelfDirectory, includingPropertiesForKeys: nil),
      [])
  }

  @MainActor
  func testConcurrentImportsCannotSpendTheSameBudgetTwice() async throws {
    let temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    let shelfDirectory = temporaryRoot.appendingPathComponent("Shelf", isDirectory: true)
    let first = temporaryRoot.appendingPathComponent("first.bin")
    let second = temporaryRoot.appendingPathComponent("second.bin")
    try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    try Data([1]).write(to: first)
    try Data([2]).write(to: second)
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }
    let gate = StagedCopyGate()
    let model = ShelfModel(
      directory: shelfDirectory,
      copyItem: { source, staging in await gate.copy(source: source, to: staging) },
      measureItem: { _ in .success(60) },
      measureAvailableCapacity: { _ in .success(10_000) },
      storagePolicy: ShelfStoragePolicy(maximumBytes: 100, minimumFreeSpaceBytes: 0))

    let firstTask = Task { await model.add(first) }
    for _ in 0..<100 {
      if await gate.hasStarted() { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    let copyStarted = await gate.hasStarted()
    XCTAssertTrue(copyStarted)

    let secondAdded = await model.add(second)
    XCTAssertFalse(secondAdded)
    XCTAssertEqual(model.lastRejectedImportBytes, 60)
    await gate.release()
    let firstAdded = await firstTask.value
    XCTAssertTrue(firstAdded)
    XCTAssertEqual(model.items.map(\.name), ["first.bin"])
    XCTAssertEqual(model.currentUsageBytes, 60)
  }

  @MainActor
  func testClearReleasesAStorageReservationForTheNextImport() async throws {
    let temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    let shelfDirectory = temporaryRoot.appendingPathComponent("Shelf", isDirectory: true)
    let pending = temporaryRoot.appendingPathComponent("pending.bin")
    let next = temporaryRoot.appendingPathComponent("next.bin")
    try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    try Data([1]).write(to: pending)
    try Data([2]).write(to: next)
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }
    let gate = StagedCopyGate()
    let model = ShelfModel(
      directory: shelfDirectory,
      copyItem: { source, staging in
        if source.lastPathComponent == "pending.bin" {
          return await gate.copy(source: source, to: staging)
        }
        return Result { try FileManager.default.copyItem(at: source, to: staging) }
      },
      measureItem: { _ in .success(100) },
      measureAvailableCapacity: { _ in .success(10_000) },
      storagePolicy: ShelfStoragePolicy(maximumBytes: 100, minimumFreeSpaceBytes: 0))

    XCTAssertTrue(model.importDroppedURLs([pending]))
    for _ in 0..<100 {
      if await gate.hasStarted() { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    let clearTask = Task { await model.clear() }
    for _ in 0..<100 where !model.isClearing { await Task.yield() }
    await gate.release()
    await clearTask.value

    let nextAdded = await model.add(next)
    XCTAssertTrue(nextAdded)
    XCTAssertEqual(model.items.map(\.name), ["next.bin"])
    XCTAssertEqual(model.currentUsageBytes, 100)
  }

  @MainActor
  func testStorageUsageTextIncludesCurrentLimitAndAccessibleFreeSpacePolicy() async throws {
    let shelf = URL(fileURLWithPath: "/Shelf")
    let stored = shelf.appendingPathComponent("stored.bin")
    let model = ShelfModel(
      directory: shelf,
      createDirectory: { _ in .success(()) },
      listDirectory: { _ in .success([stored]) },
      measureItem: { _ in .success(12) },
      storagePolicy: ShelfStoragePolicy(maximumBytes: 100, minimumFreeSpaceBytes: 25))
    for _ in 0..<100 where model.currentUsageBytes == nil { await Task.yield() }

    XCTAssertEqual(model.currentUsageBytes, 12)
    XCTAssertEqual(model.storageUsageText, "12 bytes of 100 bytes")
    XCTAssertEqual(
      model.storageUsageAccessibilityText,
      "Shelf storage: 12 bytes used of 100 bytes. Keeps at least 25 bytes free for other apps."
    )
  }

  func testFolderAndPackageMeasurementsIncludeTheirDescendants() throws {
    let temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    let package = temporaryRoot.appendingPathComponent("Example.app", isDirectory: true)
    let contents = package.appendingPathComponent("Contents", isDirectory: true)
    let payload = contents.appendingPathComponent("payload.bin")
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    try Data(repeating: 1, count: 16_384).write(to: payload)
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }

    let packageBytes = try ShelfFileMeasurements.estimatedCopyBytes(at: package).get()
    let payloadBytes = try ShelfFileMeasurements.estimatedCopyBytes(at: payload).get()

    XCTAssertGreaterThan(packageBytes, payloadBytes)
    XCTAssertGreaterThanOrEqual(packageBytes, payloadBytes + 8_192)
  }

  func testSparseFileUsesLogicalSizeRatherThanAllocatedBlocks() throws {
    let temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    let sparse = temporaryRoot.appendingPathComponent("sparse.bin")
    let descriptor = open(sparse.path, O_WRONLY | O_CREAT, S_IRUSR | S_IWUSR)
    XCTAssertGreaterThanOrEqual(descriptor, 0)
    defer {
      if descriptor >= 0 { close(descriptor) }
      try? FileManager.default.removeItem(at: temporaryRoot)
    }
    XCTAssertEqual(ftruncate(descriptor, 8 * 1024 * 1024), 0)

    let bytes = try ShelfFileMeasurements.estimatedCopyBytes(at: sparse).get()

    XCTAssertEqual(bytes, 8 * 1024 * 1024)
  }

  func testSymlinkMeasurementDoesNotFollowItsTarget() throws {
    let temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    let folder = temporaryRoot.appendingPathComponent("links", isDirectory: true)
    let target = temporaryRoot.appendingPathComponent("large-target.bin")
    let symlink = folder.appendingPathComponent("shortcut")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data(repeating: 1, count: 1024 * 1024).write(to: target)
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }

    let folderBytes = try ShelfFileMeasurements.estimatedCopyBytes(at: folder).get()
    let targetBytes = try ShelfFileMeasurements.estimatedCopyBytes(at: target).get()

    XCTAssertEqual(folderBytes, 8_192)
    XCTAssertLessThan(folderBytes, targetBytes)
  }

  func testHardLinkedPathsEachReserveTheirFullCopySize() throws {
    let temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    let folder = temporaryRoot.appendingPathComponent("hard-links", isDirectory: true)
    let first = folder.appendingPathComponent("first.bin")
    let second = folder.appendingPathComponent("second.bin")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data(repeating: 1, count: 16_384).write(to: first)
    XCTAssertEqual(link(first.path, second.path), 0)
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }

    let fileBytes = try ShelfFileMeasurements.estimatedCopyBytes(at: first).get()
    let folderBytes = try ShelfFileMeasurements.estimatedCopyBytes(at: folder).get()

    XCTAssertEqual(folderBytes, 4_096 + fileBytes * 2)
  }
}
