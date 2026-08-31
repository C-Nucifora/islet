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

  private actor MoveCallProbe {
    private var callCountValue = 0

    func move(source _: URL, to _: URL) -> Result<Void, Error> {
      callCountValue += 1
      return .failure(CopyFailure.expected)
    }

    func callCount() -> Int { callCountValue }
  }

  private actor FailingSecondManifestSave {
    private var callCount = 0

    func save(_ manifest: ShelfManifest, to url: URL) async -> Result<Void, Error> {
      callCount += 1
      if callCount == 2 { return .failure(CopyFailure.expected) }
      return await ShelfManifestStore.save(manifest, to: url)
    }
  }

  private actor ManifestSaveGate {
    enum Outcome {
      case success
      case failure
    }

    private let outcomes: [Outcome]
    private var callCountValue = 0
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var callCountWaiters:
      [(expected: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(outcomes: [Outcome]) {
      self.outcomes = outcomes
    }

    func save(_ manifest: ShelfManifest, to url: URL) async -> Result<Void, Error> {
      let callIndex = callCountValue
      callCountValue += 1
      let readyWaiters = callCountWaiters.filter { $0.expected <= callCountValue }
      callCountWaiters.removeAll { $0.expected <= callCountValue }
      for waiter in readyWaiters { waiter.continuation.resume() }
      await withCheckedContinuation { continuations.append($0) }
      guard callIndex < outcomes.count else { return .failure(CopyFailure.expected) }
      switch outcomes[callIndex] {
      case .success:
        return await ShelfManifestStore.save(manifest, to: url)
      case .failure:
        return .failure(CopyFailure.expected)
      }
    }

    func callCount() -> Int { callCountValue }

    func waitUntilCallCount(_ expected: Int) async {
      guard callCountValue < expected else { return }
      await withCheckedContinuation {
        callCountWaiters.append((expected: expected, continuation: $0))
      }
    }

    func releaseNext() {
      guard !continuations.isEmpty else { return }
      continuations.removeFirst().resume()
    }
  }

  private actor FirstManifestSaveGate {
    private var firstCallStarted = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func save(_ manifest: ShelfManifest, to url: URL) async -> Result<Void, Error> {
      if !firstCallStarted {
        firstCallStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { continuation = $0 }
      }
      return await ShelfManifestStore.save(manifest, to: url)
    }

    func hasStarted() -> Bool { firstCallStarted }

    func waitUntilStarted() async {
      guard !firstCallStarted else { return }
      await withCheckedContinuation { startWaiters.append($0) }
    }

    func release() {
      continuation?.resume()
      continuation = nil
    }
  }

  private final class RemovalGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var started = false
    private var released = false

    func remove(_ url: URL) -> Result<Void, Error> {
      condition.lock()
      started = true
      condition.broadcast()
      while !released { condition.wait() }
      condition.unlock()
      return Result { try FileManager.default.removeItem(at: url) }
    }

    func hasStarted() -> Bool {
      condition.lock()
      defer { condition.unlock() }
      return started
    }

    func release() {
      condition.lock()
      released = true
      condition.broadcast()
      condition.unlock()
    }
  }

  private final class MutableDateProvider: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) {
      self.value = value
    }

    func current() -> Date {
      lock.lock()
      defer { lock.unlock() }
      return value
    }

    func set(_ value: Date) {
      lock.lock()
      self.value = value
      lock.unlock()
    }
  }

  private actor ThumbnailGeneratorProbe {
    private var requestedURLs: [URL] = []
    private var activeCount = 0
    private var maximumActiveCount = 0
    private var cancellationURLs: [URL] = []
    private var continuations: [CheckedContinuation<Data?, Never>] = []

    func generate(_ url: URL) async -> Data? {
      requestedURLs.append(url)
      activeCount += 1
      maximumActiveCount = max(maximumActiveCount, activeCount)
      let data = await withTaskCancellationHandler(
        operation: {
          await withCheckedContinuation { continuation in
            continuations.append(continuation)
          }
        },
        onCancel: {
          Task { await self.recordCancellation(of: url) }
        })
      activeCount -= 1
      return data
    }

    func requestCount() -> Int { requestedURLs.count }
    func requests() -> [URL] { requestedURLs }
    func maximumActiveRequests() -> Int { maximumActiveCount }
    func cancellationCount() -> Int { cancellationURLs.count }

    func releaseNext(with data: Data? = Data([1])) {
      guard !continuations.isEmpty else { return }
      continuations.removeFirst().resume(returning: data)
    }

    func releaseAll() {
      let waiting = continuations
      continuations.removeAll()
      for continuation in waiting { continuation.resume(returning: Data([1])) }
    }

    private func recordCancellation(of url: URL) {
      cancellationURLs.append(url)
    }
  }

  private final class ThumbnailMetadataStore: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [URL: ShelfThumbnailMetadata]

    init(_ values: [URL: ShelfThumbnailMetadata]) {
      self.values = values
    }

    func metadata(for url: URL) -> ShelfThumbnailMetadata? {
      lock.lock()
      defer { lock.unlock() }
      return values[url]
    }

    func set(_ metadata: ShelfThumbnailMetadata, for url: URL) {
      lock.lock()
      values[url] = metadata
      lock.unlock()
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

  @MainActor
  func testVisibleShelfItemsLoadFirstWithBoundedThumbnailConcurrency() async {
    let shelf = URL(fileURLWithPath: "/Shelf")
    let first = shelf.appendingPathComponent("first.pdf")
    let second = shelf.appendingPathComponent("second.pdf")
    let third = shelf.appendingPathComponent("third.pdf")
    let metadata = ThumbnailMetadataStore(
      [first, second, third].reduce(into: [:]) { values, url in
        values[url] = ShelfThumbnailMetadata(modificationDate: .now, fileSize: 1)
      })
    let renderer = ThumbnailGeneratorProbe()
    let model = ShelfModel(
      directory: shelf,
      createDirectory: { _ in .success(()) },
      listDirectory: { _ in .success([first, second, third]) },
      measureItem: { _ in .success(0) },
      thumbnailMetadata: metadata.metadata,
      generateThumbnailData: renderer.generate)

    let itemsByURL = Dictionary(uniqueKeysWithValues: model.items.map { ($0.url, $0) })
    model.setThumbnailVisibility(for: itemsByURL[first]!, isVisible: true)
    model.setThumbnailVisibility(for: itemsByURL[second]!, isVisible: true)
    model.setThumbnailVisibility(for: itemsByURL[third]!, isVisible: true)
    for _ in 0..<100 where await renderer.requestCount() < 2 { await Task.yield() }

    let initialRequests = await renderer.requests()
    let initialMaximum = await renderer.maximumActiveRequests()
    XCTAssertEqual(initialRequests, [first, second])
    XCTAssertEqual(initialMaximum, 2)
    await renderer.releaseNext()
    for _ in 0..<100 where await renderer.requestCount() < 3 { await Task.yield() }
    let allRequests = await renderer.requests()
    let maximum = await renderer.maximumActiveRequests()
    XCTAssertEqual(allRequests, [first, second, third])
    XCTAssertEqual(maximum, ShelfModel.maximumConcurrentThumbnailRequests)
    await renderer.releaseAll()
  }

  @MainActor
  func testThumbnailCacheUsesModificationMetadataAsItsVersion() async {
    let shelf = URL(fileURLWithPath: "/Shelf")
    let stored = shelf.appendingPathComponent("cached.pdf")
    let originalDate = Date.now
    let originalMetadata = ShelfThumbnailMetadata(modificationDate: originalDate, fileSize: 1)
    let metadata = ThumbnailMetadataStore([stored: originalMetadata])
    let renderer = ThumbnailGeneratorProbe()
    let model = ShelfModel(
      directory: shelf,
      createDirectory: { _ in .success(()) },
      listDirectory: { _ in .success([stored]) },
      measureItem: { _ in .success(0) },
      thumbnailMetadata: metadata.metadata,
      generateThumbnailData: renderer.generate)
    guard let item = model.items.first else {
      XCTFail("Expected the stored Shelf item")
      return
    }

    model.setThumbnailVisibility(for: item, isVisible: true)
    for _ in 0..<100 where await renderer.requestCount() < 1 { await Task.yield() }
    await renderer.releaseNext()
    for _ in 0..<100 where model.items.first?.thumbnail == nil { await Task.yield() }
    XCTAssertNotNil(model.items.first?.thumbnail)

    model.setThumbnailVisibility(for: item, isVisible: false)
    model.setThumbnailVisibility(for: item, isVisible: true)
    for _ in 0..<10 { await Task.yield() }
    let cachedRequestCount = await renderer.requestCount()
    XCTAssertEqual(cachedRequestCount, 1)

    model.setThumbnailVisibility(for: item, isVisible: false)
    metadata.set(
      ShelfThumbnailMetadata(
        modificationDate: originalDate.addingTimeInterval(1), fileSize: 1),
      for: stored)
    model.setThumbnailVisibility(for: item, isVisible: true)
    for _ in 0..<100 where await renderer.requestCount() < 2 { await Task.yield() }
    let refreshedRequestCount = await renderer.requestCount()
    XCTAssertEqual(refreshedRequestCount, 2)
    await renderer.releaseAll()
  }

  @MainActor
  func testThumbnailResultIsDiscardedWhenItsFileMetadataBecomesStale() async {
    let shelf = URL(fileURLWithPath: "/Shelf")
    let stored = shelf.appendingPathComponent("changing.pdf")
    let originalDate = Date.now
    let metadata = ThumbnailMetadataStore(
      [stored: ShelfThumbnailMetadata(modificationDate: originalDate, fileSize: 1)])
    let renderer = ThumbnailGeneratorProbe()
    let model = ShelfModel(
      directory: shelf,
      createDirectory: { _ in .success(()) },
      listDirectory: { _ in .success([stored]) },
      measureItem: { _ in .success(0) },
      thumbnailMetadata: metadata.metadata,
      generateThumbnailData: renderer.generate)
    guard let item = model.items.first else {
      XCTFail("Expected the stored Shelf item")
      return
    }

    model.setThumbnailVisibility(for: item, isVisible: true)
    for _ in 0..<100 where await renderer.requestCount() < 1 { await Task.yield() }
    metadata.set(
      ShelfThumbnailMetadata(modificationDate: originalDate.addingTimeInterval(1), fileSize: 1),
      for: stored)
    await renderer.releaseNext()
    for _ in 0..<100 { await Task.yield() }
    XCTAssertNil(model.items.first?.thumbnail)

    model.setThumbnailVisibility(for: item, isVisible: false)
    model.setThumbnailVisibility(for: item, isVisible: true)
    for _ in 0..<100 where await renderer.requestCount() < 2 { await Task.yield() }
    let requestCount = await renderer.requestCount()
    XCTAssertEqual(requestCount, 2)
    await renderer.releaseAll()
  }

  @MainActor
  func testOffscreenThumbnailCancellationDoesNotStrandAReappearingItem() async {
    let shelf = URL(fileURLWithPath: "/Shelf")
    let stored = shelf.appendingPathComponent("reappearing.pdf")
    let metadata = ThumbnailMetadataStore(
      [stored: ShelfThumbnailMetadata(modificationDate: .now, fileSize: 1)])
    let renderer = ThumbnailGeneratorProbe()
    let model = ShelfModel(
      directory: shelf,
      createDirectory: { _ in .success(()) },
      listDirectory: { _ in .success([stored]) },
      measureItem: { _ in .success(0) },
      thumbnailMetadata: metadata.metadata,
      generateThumbnailData: renderer.generate)
    guard let item = model.items.first else {
      XCTFail("Expected the stored Shelf item")
      return
    }

    model.setThumbnailVisibility(for: item, isVisible: true)
    for _ in 0..<100 where await renderer.requestCount() < 1 { await Task.yield() }
    model.setThumbnailVisibility(for: item, isVisible: false)
    model.setThumbnailVisibility(for: item, isVisible: true)
    await renderer.releaseNext()
    for _ in 0..<100 where await renderer.requestCount() < 2 { await Task.yield() }
    await renderer.releaseNext()
    for _ in 0..<100 where model.items.first?.thumbnail == nil { await Task.yield() }

    XCTAssertNotNil(model.items.first?.thumbnail)
  }

  @MainActor
  func testRemovingOrClearingVisibleItemsCancelsTheirThumbnailRequests() async {
    let shelf = URL(fileURLWithPath: "/Shelf")
    let first = shelf.appendingPathComponent("remove.pdf")
    let second = shelf.appendingPathComponent("clear.pdf")
    let metadata = ThumbnailMetadataStore(
      [first, second].reduce(into: [:]) { values, url in
        values[url] = ShelfThumbnailMetadata(modificationDate: .now, fileSize: 1)
      })
    let renderer = ThumbnailGeneratorProbe()
    let model = ShelfModel(
      directory: shelf,
      createDirectory: { _ in .success(()) },
      listDirectory: { _ in .success([first, second]) },
      measureItem: { _ in .success(0) },
      thumbnailMetadata: metadata.metadata,
      generateThumbnailData: renderer.generate)
    let itemsByURL = Dictionary(uniqueKeysWithValues: model.items.map { ($0.url, $0) })
    model.setThumbnailVisibility(for: itemsByURL[first]!, isVisible: true)
    model.setThumbnailVisibility(for: itemsByURL[second]!, isVisible: true)
    for _ in 0..<100 where await renderer.requestCount() < 2 { await Task.yield() }

    await model.remove(itemsByURL[first]!)
    await model.clear()
    for _ in 0..<100 where await renderer.cancellationCount() < 2 { await Task.yield() }

    let cancellationCount = await renderer.cancellationCount()
    XCTAssertEqual(cancellationCount, 2)
    XCTAssertTrue(model.items.isEmpty)
    await renderer.releaseAll()
  }

  @MainActor
  func testFailedClearRestartsThumbnailWorkForTheVisibleRetainedItem() async {
    let shelf = URL(fileURLWithPath: "/Shelf")
    let retained = shelf.appendingPathComponent("retained.pdf")
    let metadata = ThumbnailMetadataStore(
      [retained: ShelfThumbnailMetadata(modificationDate: .now, fileSize: 1)])
    let renderer = ThumbnailGeneratorProbe()
    let model = ShelfModel(
      directory: shelf,
      createDirectory: { _ in .success(()) },
      listDirectory: { _ in .success([retained]) },
      removeItem: { _ in .failure(CopyFailure.expected) },
      measureItem: { _ in .success(0) },
      thumbnailMetadata: metadata.metadata,
      generateThumbnailData: renderer.generate)
    guard let item = model.items.first else {
      XCTFail("Expected the stored Shelf item")
      return
    }

    model.setThumbnailVisibility(for: item, isVisible: true)
    for _ in 0..<100 where await renderer.requestCount() < 1 { await Task.yield() }
    await model.clear()
    for _ in 0..<100 where await renderer.cancellationCount() < 1 { await Task.yield() }

    await renderer.releaseNext()
    for _ in 0..<100 where await renderer.requestCount() < 2 { await Task.yield() }
    await renderer.releaseNext(with: Data([9]))
    for _ in 0..<100 where model.items.first?.thumbnail == nil { await Task.yield() }

    XCTAssertEqual(model.items.map(\.id), [item.id])
    XCTAssertEqual(model.items.first?.thumbnail, Data([9]))
    XCTAssertEqual(model.lastError, "Some Shelf items couldn’t be removed.")
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

  @MainActor
  func testConcurrentSameFileImportsReuseOneShelfCopy() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    let shelf = root.appendingPathComponent("Shelf", isDirectory: true)
    let source = root.appendingPathComponent("same.txt")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("one source".utf8).write(to: source)
    defer { try? FileManager.default.removeItem(at: root) }
    let gate = StagedCopyGate()
    let model = ShelfModel(
      directory: shelf,
      copyItem: { source, destination in await gate.copy(source: source, to: destination) })

    let first = Task { await model.add(source) }
    for _ in 0..<100 where !(await gate.hasStarted()) {
      try await Task.sleep(for: .milliseconds(5))
    }
    let second = Task { await model.add(source) }
    await gate.release()
    let firstAdded = await first.value
    let secondAdded = await second.value

    XCTAssertTrue(secondAdded)
    XCTAssertTrue(firstAdded)
    XCTAssertEqual(model.items.map(\.name), ["same.txt"])
  }

  @MainActor
  func testConcurrentSameNameImportsHonorReusePolicy() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    let shelf = root.appendingPathComponent("Shelf", isDirectory: true)
    let firstFolder = root.appendingPathComponent("first", isDirectory: true)
    let secondFolder = root.appendingPathComponent("second", isDirectory: true)
    try FileManager.default.createDirectory(at: firstFolder, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: secondFolder, withIntermediateDirectories: true)
    let firstSource = firstFolder.appendingPathComponent("report.txt")
    let secondSource = secondFolder.appendingPathComponent("report.txt")
    try Data("first".utf8).write(to: firstSource)
    try Data("second".utf8).write(to: secondSource)
    defer { try? FileManager.default.removeItem(at: root) }
    let gate = StagedCopyGate()
    let model = ShelfModel(
      directory: shelf,
      copyItem: { source, destination in await gate.copy(source: source, to: destination) })
    await model.setSameNameDuplicatePolicy(.reuseExisting)

    let first = Task { await model.add(firstSource) }
    for _ in 0..<100 where !(await gate.hasStarted()) {
      try await Task.sleep(for: .milliseconds(5))
    }
    let second = Task { await model.add(secondSource) }
    await Task.yield()
    await gate.release()

    let firstAdded = await first.value
    let secondAdded = await second.value
    XCTAssertTrue(firstAdded)
    XCTAssertTrue(secondAdded)
    XCTAssertEqual(model.items.map(\.name), ["report.txt"])
    XCTAssertEqual(try String(contentsOf: model.items[0].url, encoding: .utf8), "first")
  }

  @MainActor
  func testDuplicateReuseStillWorksWhenShelfIsFull() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    let shelf = root.appendingPathComponent("Shelf", isDirectory: true)
    let sourceFolder = root.appendingPathComponent("source", isDirectory: true)
    try FileManager.default.createDirectory(at: shelf, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
    for index in 0..<ShelfModel.maximumItemCount {
      try Data([UInt8(index % 255)]).write(
        to: shelf.appendingPathComponent("item-\(index).txt"))
    }
    let duplicate = sourceFolder.appendingPathComponent("item-0.txt")
    try Data("replacement must not be copied".utf8).write(to: duplicate)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = ShelfModel(directory: shelf)
    await model.setSameNameDuplicatePolicy(.reuseExisting)

    let duplicateReused = await model.add(duplicate)
    XCTAssertTrue(duplicateReused)
    XCTAssertEqual(model.items.count, ShelfModel.maximumItemCount)
    XCTAssertEqual(
      try Data(contentsOf: shelf.appendingPathComponent("item-0.txt")), Data([0]))
  }

  @MainActor
  func testDifferentFilesWithTheSameNameGetPredictableNumberedNames() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    let shelf = root.appendingPathComponent("Shelf", isDirectory: true)
    let firstFolder = root.appendingPathComponent("first", isDirectory: true)
    let secondFolder = root.appendingPathComponent("second", isDirectory: true)
    try FileManager.default.createDirectory(at: firstFolder, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: secondFolder, withIntermediateDirectories: true)
    let first = firstFolder.appendingPathComponent("report.txt")
    let second = secondFolder.appendingPathComponent("report.txt")
    try Data("first".utf8).write(to: first)
    try Data("second".utf8).write(to: second)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = ShelfModel(directory: shelf)

    let firstAdded = await model.add(first)
    let secondAdded = await model.add(second)

    XCTAssertTrue(firstAdded)
    XCTAssertTrue(secondAdded)
    XCTAssertEqual(model.items.map(\.name), ["report.txt", "report 1.txt"])
    XCTAssertEqual(try String(contentsOf: model.items[1].url, encoding: .utf8), "second")
  }

  @MainActor
  func testSameNameReusePolicyKeepsTheExistingContents() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    let shelf = root.appendingPathComponent("Shelf", isDirectory: true)
    let firstFolder = root.appendingPathComponent("first", isDirectory: true)
    let secondFolder = root.appendingPathComponent("second", isDirectory: true)
    try FileManager.default.createDirectory(at: firstFolder, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: secondFolder, withIntermediateDirectories: true)
    let first = firstFolder.appendingPathComponent("report.txt")
    let second = secondFolder.appendingPathComponent("report.txt")
    try Data("retained".utf8).write(to: first)
    try Data("ignored".utf8).write(to: second)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = ShelfModel(directory: shelf)
    await model.setSameNameDuplicatePolicy(.reuseExisting)

    let firstAdded = await model.add(first)
    let secondAdded = await model.add(second)

    XCTAssertTrue(firstAdded)
    XCTAssertTrue(secondAdded)
    XCTAssertEqual(model.items.map(\.name), ["report.txt"])
    XCTAssertEqual(try String(contentsOf: model.items[0].url, encoding: .utf8), "retained")
  }

  @MainActor
  func testWorkspaceMutationsSerializeFailureRollbackBeforeLaterSuccess() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    let shelf = root.appendingPathComponent("Shelf", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let saver = ManifestSaveGate(outcomes: [.failure, .success])
    let model = ShelfModel(directory: shelf, saveManifest: saver.save)

    let failed = Task { await model.createStack(named: "Failed") }
    for _ in 0..<100 where await saver.callCount() < 1 { await Task.yield() }
    let saved = Task { await model.createStack(named: "Saved") }
    await Task.yield()

    await saver.releaseNext()
    let failedStack = await failed.value
    XCTAssertNil(failedStack)
    for _ in 0..<100 where await saver.callCount() < 2 { await Task.yield() }
    await saver.releaseNext()
    let savedValue = await saved.value
    let savedStack = try XCTUnwrap(savedValue)

    XCTAssertEqual(model.stacks.filter { $0.name != "Shelf" }.map(\.name), ["Saved"])
    XCTAssertEqual(model.selectedStackID, savedStack.id)
    let relaunched = ShelfModel(directory: shelf)
    XCTAssertEqual(relaunched.stacks.filter { $0.name != "Shelf" }.map(\.name), ["Saved"])
    XCTAssertTrue(relaunched.stacks.contains { $0.id == relaunched.selectedStackID })
  }

  @MainActor
  func testConcurrentWorkspaceCreationRejectsCaseInsensitiveDuplicate() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    let shelf = root.appendingPathComponent("Shelf", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let saver = ManifestSaveGate(outcomes: [.success, .success])
    let model = ShelfModel(directory: shelf, saveManifest: saver.save)

    let first = Task { await model.createStack(named: "Project") }
    for _ in 0..<100 where await saver.callCount() < 1 { await Task.yield() }
    let duplicate = Task { await model.createStack(named: "project") }
    await Task.yield()

    await saver.releaseNext()
    let firstStack = await first.value
    for _ in 0..<100 where await saver.callCount() < 2 { await Task.yield() }
    await saver.releaseNext()
    let duplicateStack = await duplicate.value

    XCTAssertNotNil(firstStack)
    XCTAssertNil(duplicateStack)
    XCTAssertEqual(
      model.stacks.filter { $0.name.caseInsensitiveCompare("project") == .orderedSame }.count,
      1)
    let relaunched = ShelfModel(directory: shelf)
    XCTAssertEqual(
      relaunched.stacks.filter { $0.name.caseInsensitiveCompare("project") == .orderedSame }.count,
      1)
  }

  @MainActor
  func testExpiryWaitsForUseAndNeverDeletesTheOriginal() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    let shelf = root.appendingPathComponent("Shelf", isDirectory: true)
    let source = root.appendingPathComponent("expiring.txt")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("original".utf8).write(to: source)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = ShelfModel(directory: shelf)
    let createdWorkspace = await model.createStack(named: "Scratch")
    let workspace = try XCTUnwrap(createdWorkspace)
    let expirySaved = await model.setExpiryRule(.oneHour, for: workspace)
    let added = await model.add(source, to: workspace.id)
    XCTAssertTrue(expirySaved)
    XCTAssertTrue(added)
    let item = try XCTUnwrap(model.items.first)
    let afterExpiry = try XCTUnwrap(item.expiresAt).addingTimeInterval(1)

    model.beginUsing(item)
    await model.cleanupExpired(at: afterExpiry)
    XCTAssertEqual(model.items.map(\.id), [item.id])
    XCTAssertTrue(FileManager.default.fileExists(atPath: item.url.path))

    model.endUsing(item)
    await model.cleanupExpired(at: afterExpiry)
    XCTAssertTrue(model.items.isEmpty)
    XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "original")
  }

  @MainActor
  func testImportUsesWorkspaceExpiryRuleCurrentWhenPendingMetadataIsRecorded() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    let shelf = root.appendingPathComponent("Shelf", isDirectory: true)
    let source = root.appendingPathComponent("large-import.txt")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("source".utf8).write(to: source)
    defer { try? FileManager.default.removeItem(at: root) }
    let copyGate = StagedCopyGate()
    let model = ShelfModel(
      directory: shelf,
      copyItem: { source, destination in
        await copyGate.copy(source: source, to: destination)
      })
    let createdWorkspace = await model.createStack(named: "Scratch")
    let workspace = try XCTUnwrap(createdWorkspace)
    let initialRuleSaved = await model.setExpiryRule(.oneHour, for: workspace)
    XCTAssertTrue(initialRuleSaved)

    let importTask = Task { await model.add(source, to: workspace.id) }
    for _ in 0..<200 where !(await copyGate.hasStarted()) {
      try await Task.sleep(for: .milliseconds(5))
    }
    let copyStarted = await copyGate.hasStarted()
    XCTAssertTrue(copyStarted)
    let newRuleSaved = await model.setExpiryRule(.never, for: workspace)
    XCTAssertTrue(newRuleSaved)
    await copyGate.release()

    let imported = await importTask.value
    XCTAssertTrue(imported)
    XCTAssertNil(try XCTUnwrap(model.items.first).expiresAt)
    XCTAssertNil(try XCTUnwrap(ShelfModel(directory: shelf).items.first).expiresAt)
  }

  @MainActor
  func testExpiryRuleChangeUpdatesAnImportWaitingToCommit() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    let shelf = root.appendingPathComponent("Shelf", isDirectory: true)
    let source = root.appendingPathComponent("pending-import.txt")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("source".utf8).write(to: source)
    defer { try? FileManager.default.removeItem(at: root) }
    let moveGate = CompletedMoveGate()
    let model = ShelfModel(
      directory: shelf,
      moveItem: { source, destination in
        await moveGate.move(source: source, to: destination)
      })
    let createdWorkspace = await model.createStack(named: "Scratch")
    let workspace = try XCTUnwrap(createdWorkspace)
    let initialRuleSaved = await model.setExpiryRule(.oneHour, for: workspace)
    XCTAssertTrue(initialRuleSaved)

    let importTask = Task { await model.add(source, to: workspace.id) }
    for _ in 0..<200 where !(await moveGate.hasStarted()) {
      try await Task.sleep(for: .milliseconds(5))
    }
    let moveStarted = await moveGate.hasStarted()
    XCTAssertTrue(moveStarted)
    let newRuleSaved = await model.setExpiryRule(.never, for: workspace)
    XCTAssertTrue(newRuleSaved)
    await moveGate.release()

    let imported = await importTask.value
    XCTAssertTrue(imported)
    XCTAssertNil(try XCTUnwrap(model.items.first).expiresAt)
    XCTAssertNil(try XCTUnwrap(ShelfModel(directory: shelf).items.first).expiresAt)
  }

  @MainActor
  func testMoveUsesCurrentDestinationExpiryInsteadOfCapturedStackValue() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    let shelf = root.appendingPathComponent("Shelf", isDirectory: true)
    let source = root.appendingPathComponent("move-me.txt")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("source".utf8).write(to: source)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = ShelfModel(directory: shelf)
    let added = await model.add(source)
    XCTAssertTrue(added)
    let item = try XCTUnwrap(model.items.first)
    let createdWorkspace = await model.createStack(named: "Scratch")
    let workspace = try XCTUnwrap(createdWorkspace)
    let initialRuleSaved = await model.setExpiryRule(.oneHour, for: workspace)
    XCTAssertTrue(initialRuleSaved)
    let capturedWorkspace = try XCTUnwrap(model.stacks.first { $0.id == workspace.id })
    let newRuleSaved = await model.setExpiryRule(.never, for: capturedWorkspace)
    XCTAssertTrue(newRuleSaved)

    let movedSuccessfully = await model.move(item, to: capturedWorkspace)
    XCTAssertTrue(movedSuccessfully)

    let moved = try XCTUnwrap(model.items.first)
    XCTAssertEqual(moved.stackID, workspace.id)
    XCTAssertNil(moved.expiresAt)
    XCTAssertNil(try XCTUnwrap(ShelfModel(directory: shelf).items.first).expiresAt)
  }

  @MainActor
  func testExpiryCrossedDuringManifestSaveIsRemovedAfterPersistence() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    let shelf = root.appendingPathComponent("Shelf", isDirectory: true)
    try FileManager.default.createDirectory(at: shelf, withIntermediateDirectories: true)
    let stored = shelf.appendingPathComponent("crosses-deadline.txt")
    try Data("stored".utf8).write(to: stored)
    defer { try? FileManager.default.removeItem(at: root) }
    let initialDate = Date(timeIntervalSince1970: 2_000_000_000)
    let deadline = initialDate.addingTimeInterval(10)
    let stack = ShelfStack(id: UUID(), name: "Scratch", expiryRule: .never)
    let record = ShelfItemRecord(
      id: UUID(), fileName: stored.lastPathComponent, stackID: stack.id,
      importedAt: deadline.addingTimeInterval(-3_600), expiresAt: nil, origin: nil)
    let manifest = ShelfManifest(
      stacks: [stack], items: [record], pendingImports: [],
      sameFilePolicy: .reuseExisting, sameNamePolicy: .keepBoth)
    try await ShelfManifestStore.save(manifest, to: shelf.appendingPathExtension("json")).get()
    let saveGate = FirstManifestSaveGate()
    let dateProvider = MutableDateProvider(initialDate)
    let model = ShelfModel(
      directory: shelf, saveManifest: saveGate.save, currentDate: dateProvider.current)

    let ruleChange = Task { await model.setExpiryRule(.oneHour, for: stack) }
    await saveGate.waitUntilStarted()
    let firstSaveStarted = await saveGate.hasStarted()
    XCTAssertTrue(firstSaveStarted)
    dateProvider.set(deadline.addingTimeInterval(1))
    await saveGate.release()

    let ruleSaved = await ruleChange.value
    XCTAssertTrue(ruleSaved)
    XCTAssertTrue(model.items.isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: stored.path))
    XCTAssertTrue(ShelfModel(directory: shelf).items.isEmpty)
  }

  @MainActor
  func testExpiryCleanupSkipsAWorkspaceWhileItsRuleChangeIsSaving() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    let shelf = root.appendingPathComponent("Shelf", isDirectory: true)
    try FileManager.default.createDirectory(at: shelf, withIntermediateDirectories: true)
    let stored = shelf.appendingPathComponent("extended-before-expiry.txt")
    try Data("stored".utf8).write(to: stored)
    defer { try? FileManager.default.removeItem(at: root) }
    let expiry = Date(timeIntervalSince1970: 2_000_000_000)
    let stack = ShelfStack(id: UUID(), name: "Scratch", expiryRule: .oneHour)
    let record = ShelfItemRecord(
      id: UUID(), fileName: stored.lastPathComponent, stackID: stack.id,
      importedAt: expiry.addingTimeInterval(-3_600), expiresAt: expiry, origin: nil)
    let manifest = ShelfManifest(
      stacks: [stack], items: [record], pendingImports: [],
      sameFilePolicy: .reuseExisting, sameNamePolicy: .keepBoth)
    try await ShelfManifestStore.save(manifest, to: shelf.appendingPathExtension("json")).get()
    let saveGate = FirstManifestSaveGate()
    let model = ShelfModel(
      directory: shelf,
      removeItem: { url in
        let result = Result { try FileManager.default.removeItem(at: url) }
        Task { await saveGate.release() }
        return result
      },
      saveManifest: saveGate.save)

    let ruleChange = Task { await model.setExpiryRule(.never, for: stack) }
    await saveGate.waitUntilStarted()
    let saveStarted = await saveGate.hasStarted()
    XCTAssertTrue(saveStarted)

    await model.cleanupExpired(at: expiry.addingTimeInterval(1))
    await saveGate.release()
    let ruleSaved = await ruleChange.value
    XCTAssertTrue(ruleSaved)
    XCTAssertEqual(model.items.map(\.id), [record.id])
    XCTAssertNil(try XCTUnwrap(model.items.first).expiresAt)
    XCTAssertTrue(FileManager.default.fileExists(atPath: stored.path))
  }

  @MainActor
  func testFailedExpiryRuleSaveRestoresAndCleansTheOldElapsedRule() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    let shelf = root.appendingPathComponent("Shelf", isDirectory: true)
    try FileManager.default.createDirectory(at: shelf, withIntermediateDirectories: true)
    let stored = shelf.appendingPathComponent("expires-while-save-fails.txt")
    try Data("stored".utf8).write(to: stored)
    defer { try? FileManager.default.removeItem(at: root) }
    let initialDate = Date(timeIntervalSince1970: 2_000_000_000)
    let expiry = initialDate.addingTimeInterval(10)
    let stack = ShelfStack(id: UUID(), name: "Scratch", expiryRule: .oneHour)
    let record = ShelfItemRecord(
      id: UUID(), fileName: stored.lastPathComponent, stackID: stack.id,
      importedAt: expiry.addingTimeInterval(-3_600), expiresAt: expiry, origin: nil)
    let manifest = ShelfManifest(
      stacks: [stack], items: [record], pendingImports: [],
      sameFilePolicy: .reuseExisting, sameNamePolicy: .keepBoth)
    try await ShelfManifestStore.save(manifest, to: shelf.appendingPathExtension("json")).get()
    let dateProvider = MutableDateProvider(initialDate)
    let model = ShelfModel(
      directory: shelf,
      saveManifest: { _, _ in
        dateProvider.set(expiry.addingTimeInterval(1))
        return .failure(CopyFailure.expected)
      },
      currentDate: dateProvider.current)

    let saved = await model.setExpiryRule(.never, for: stack)

    XCTAssertFalse(saved)
    XCTAssertEqual(model.stacks.first?.expiryRule, .oneHour)
    XCTAssertTrue(model.items.isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: stored.path))
    XCTAssertTrue(ShelfModel(directory: shelf).items.isEmpty)
  }

  @MainActor
  func testOverlappingExpiryRuleSavesPublishOnlyCommittedMetadata() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    let shelf = root.appendingPathComponent("Shelf", isDirectory: true)
    try FileManager.default.createDirectory(at: shelf, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let stack = ShelfStack(id: UUID(), name: "Scratch", expiryRule: .never)
    let manifest = ShelfManifest(
      stacks: [stack], items: [], pendingImports: [],
      sameFilePolicy: .reuseExisting, sameNamePolicy: .keepBoth)
    try await ShelfManifestStore.save(manifest, to: shelf.appendingPathExtension("json")).get()
    let saveGate = ManifestSaveGate(outcomes: [.success, .success])
    let model = ShelfModel(directory: shelf, saveManifest: saveGate.save)

    let firstChange = Task { await model.setExpiryRule(.oneHour, for: stack) }
    await saveGate.waitUntilCallCount(1)
    let secondChange = Task { await model.setExpiryRule(.oneDay, for: stack) }
    await saveGate.releaseNext()
    await saveGate.waitUntilCallCount(2)

    XCTAssertEqual(model.stacks.first?.expiryRule, .oneHour)

    await saveGate.releaseNext()
    let firstSaved = await firstChange.value
    let secondSaved = await secondChange.value
    XCTAssertTrue(firstSaved)
    XCTAssertTrue(secondSaved)
    XCTAssertEqual(model.stacks.first?.expiryRule, .oneDay)
    XCTAssertEqual(ShelfModel(directory: shelf).stacks.first?.expiryRule, .oneDay)
  }

  @MainActor
  func testMissingItemCleanupContinuesWhileAnExpiryRuleSaveIsInFlight() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    let shelf = root.appendingPathComponent("Shelf", isDirectory: true)
    try FileManager.default.createDirectory(at: shelf, withIntermediateDirectories: true)
    let stored = shelf.appendingPathComponent("missing-during-rule-save.txt")
    try Data("stored".utf8).write(to: stored)
    defer { try? FileManager.default.removeItem(at: root) }
    let stack = ShelfStack(id: UUID(), name: "Scratch", expiryRule: .oneHour)
    let importedAt = Date(timeIntervalSince1970: 2_000_000_000)
    let record = ShelfItemRecord(
      id: UUID(), fileName: stored.lastPathComponent, stackID: stack.id,
      importedAt: importedAt, expiresAt: importedAt.addingTimeInterval(3_600), origin: nil)
    let manifest = ShelfManifest(
      stacks: [stack], items: [record], pendingImports: [],
      sameFilePolicy: .reuseExisting, sameNamePolicy: .keepBoth)
    try await ShelfManifestStore.save(manifest, to: shelf.appendingPathExtension("json")).get()
    let saveGate = FirstManifestSaveGate()
    let model = ShelfModel(
      directory: shelf,
      removeItem: { _ in
        Task { await saveGate.release() }
        return .failure(CocoaError(.fileNoSuchFile))
      },
      saveManifest: saveGate.save)

    let ruleChange = Task { await model.setExpiryRule(.never, for: stack) }
    await saveGate.waitUntilStarted()
    try FileManager.default.removeItem(at: stored)

    await model.cleanupStorage()
    await saveGate.release()
    let ruleSaved = await ruleChange.value

    XCTAssertTrue(ruleSaved)
    XCTAssertTrue(model.items.isEmpty)
    XCTAssertTrue(ShelfModel(directory: shelf).items.isEmpty)
  }

  @MainActor
  func testClearDuringPendingMetadataSaveDoesNotStartTheRename() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    let shelf = root.appendingPathComponent("Shelf", isDirectory: true)
    let source = root.appendingPathComponent("cancel-before-rename.txt")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("source".utf8).write(to: source)
    defer { try? FileManager.default.removeItem(at: root) }
    let saveGate = FirstManifestSaveGate()
    let moveProbe = MoveCallProbe()
    let model = ShelfModel(
      directory: shelf,
      moveItem: { source, destination in
        await moveProbe.move(source: source, to: destination)
      },
      saveManifest: saveGate.save)

    XCTAssertTrue(model.importDroppedURLs([source]))
    await saveGate.waitUntilStarted()
    let saveStarted = await saveGate.hasStarted()
    XCTAssertTrue(saveStarted)

    let clear = Task { await model.clear() }
    for _ in 0..<200 where !model.isClearing { await Task.yield() }
    XCTAssertTrue(model.isClearing)
    await saveGate.release()
    await clear.value

    let moveCallCount = await moveProbe.callCount()
    XCTAssertEqual(moveCallCount, 0)
    XCTAssertTrue(model.items.isEmpty)
    let remaining = try FileManager.default.contentsOfDirectory(
      at: shelf, includingPropertiesForKeys: nil)
    XCTAssertTrue(remaining.isEmpty)
  }

  @MainActor
  func testAirDropLeasesExpiringItemsUntilEveryTerminalOutcome() async throws {
    let outcomes: [AirDropShareOutcome] = [
      .shared,
      .cancelled,
      .failed("The receiving device disconnected."),
    ]
    var roots: [URL] = []
    defer {
      for root in roots { try? FileManager.default.removeItem(at: root) }
    }

    for (index, outcome) in outcomes.enumerated() {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString, isDirectory: true)
      roots.append(root)
      let shelf = root.appendingPathComponent("Shelf", isDirectory: true)
      try FileManager.default.createDirectory(at: shelf, withIntermediateDirectories: true)
      let stored = shelf.appendingPathComponent("share-\(index).txt")
      try Data("stored".utf8).write(to: stored)
      let expiry = Date.now.addingTimeInterval(3_600)
      let stack = ShelfStack(id: UUID(), name: "Scratch", expiryRule: .oneHour)
      let record = ShelfItemRecord(
        id: UUID(), fileName: stored.lastPathComponent, stackID: stack.id,
        importedAt: expiry.addingTimeInterval(-3_600), expiresAt: expiry, origin: nil)
      let manifest = ShelfManifest(
        stacks: [stack], items: [record], pendingImports: [],
        sameFilePolicy: .reuseExisting, sameNamePolicy: .keepBoth)
      try await ShelfManifestStore.save(manifest, to: shelf.appendingPathExtension("json")).get()
      let model = ShelfModel(directory: shelf)
      var finish: ((AirDropShareOutcome) -> Void)?
      let controller = AirDropShareController(
        serviceAvailable: { true },
        startShare: { _, completion in
          finish = completion
          return .started
        })

      model.shareAllItems(using: controller)
      await model.cleanupExpired(at: expiry.addingTimeInterval(1))
      XCTAssertEqual(model.items.map(\.id), [record.id])
      XCTAssertTrue(FileManager.default.fileExists(atPath: stored.path))

      finish?(outcome)
      await model.cleanupExpired(at: expiry.addingTimeInterval(1))
      XCTAssertTrue(model.items.isEmpty)
      XCTAssertFalse(FileManager.default.fileExists(atPath: stored.path))
    }
  }

  @MainActor
  func testExpiryRemovalRejectsANewLeaseAfterDeletionIsReserved() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    let shelf = root.appendingPathComponent("Shelf", isDirectory: true)
    try FileManager.default.createDirectory(at: shelf, withIntermediateDirectories: true)
    let stored = shelf.appendingPathComponent("expiring.txt")
    try Data("stored".utf8).write(to: stored)
    defer { try? FileManager.default.removeItem(at: root) }
    let expiry = Date.now.addingTimeInterval(3_600)
    let stack = ShelfStack(id: UUID(), name: "Scratch", expiryRule: .oneHour)
    let record = ShelfItemRecord(
      id: UUID(), fileName: stored.lastPathComponent, stackID: stack.id,
      importedAt: expiry.addingTimeInterval(-3_600), expiresAt: expiry, origin: nil)
    let manifest = ShelfManifest(
      stacks: [stack], items: [record], pendingImports: [],
      sameFilePolicy: .reuseExisting, sameNamePolicy: .keepBoth)
    try await ShelfManifestStore.save(manifest, to: shelf.appendingPathExtension("json")).get()
    let removal = RemovalGate()
    let model = ShelfModel(directory: shelf, removeItem: removal.remove)
    let item = try XCTUnwrap(model.items.first)

    let cleanup = Task { await model.cleanupExpired(at: expiry.addingTimeInterval(1)) }
    for _ in 0..<200 where !removal.hasStarted() {
      try await Task.sleep(for: .milliseconds(5))
    }

    XCTAssertFalse(model.beginUsing(item))
    removal.release()
    await cleanup.value
    XCTAssertTrue(model.items.isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: stored.path))
  }

  @MainActor
  func testExpiryChangedDuringUseCleansUpWhenTheLeaseEnds() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    let shelf = root.appendingPathComponent("Shelf", isDirectory: true)
    try FileManager.default.createDirectory(at: shelf, withIntermediateDirectories: true)
    let stored = shelf.appendingPathComponent("old.txt")
    try Data("old".utf8).write(to: stored)
    defer { try? FileManager.default.removeItem(at: root) }
    let stack = ShelfStack(id: UUID(), name: "Scratch", expiryRule: .never)
    let record = ShelfItemRecord(
      id: UUID(), fileName: stored.lastPathComponent, stackID: stack.id,
      importedAt: Date.now.addingTimeInterval(-7_200), expiresAt: nil, origin: nil)
    let manifest = ShelfManifest(
      stacks: [stack], items: [record], pendingImports: [],
      sameFilePolicy: .reuseExisting, sameNamePolicy: .keepBoth)
    try await ShelfManifestStore.save(manifest, to: shelf.appendingPathExtension("json")).get()
    let model = ShelfModel(directory: shelf)
    let itemBeforeRuleChange = try XCTUnwrap(model.items.first)

    model.beginUsing(itemBeforeRuleChange)
    let ruleChanged = await model.setExpiryRule(.oneHour, for: stack)
    XCTAssertTrue(ruleChanged)
    XCTAssertEqual(model.items.map(\.id), [record.id])
    model.endUsing(itemBeforeRuleChange)
    for _ in 0..<200 where !model.items.isEmpty {
      try await Task.sleep(for: .milliseconds(5))
    }

    XCTAssertTrue(model.items.isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: stored.path))
  }

  @MainActor
  func testMovingAnOldItemIntoAnExpiringWorkspaceCleansItUpImmediately() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    let shelf = root.appendingPathComponent("Shelf", isDirectory: true)
    try FileManager.default.createDirectory(at: shelf, withIntermediateDirectories: true)
    let stored = shelf.appendingPathComponent("old.txt")
    try Data("old".utf8).write(to: stored)
    defer { try? FileManager.default.removeItem(at: root) }
    let permanent = ShelfStack(id: UUID(), name: "Permanent", expiryRule: .never)
    let scratch = ShelfStack(id: UUID(), name: "Scratch", expiryRule: .oneHour)
    let record = ShelfItemRecord(
      id: UUID(), fileName: stored.lastPathComponent, stackID: permanent.id,
      importedAt: Date.now.addingTimeInterval(-7_200), expiresAt: nil, origin: nil)
    let manifest = ShelfManifest(
      stacks: [permanent, scratch], items: [record], pendingImports: [],
      sameFilePolicy: .reuseExisting, sameNamePolicy: .keepBoth)
    try await ShelfManifestStore.save(manifest, to: shelf.appendingPathExtension("json")).get()
    let model = ShelfModel(directory: shelf)

    let moved = await model.move(try XCTUnwrap(model.items.first), to: scratch)
    XCTAssertTrue(moved)
    XCTAssertTrue(model.items.isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: stored.path))
  }

  @MainActor
  func testCleanupRemovesMissingItemMetadata() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    let shelf = root.appendingPathComponent("Shelf", isDirectory: true)
    let source = root.appendingPathComponent("missing.txt")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("source".utf8).write(to: source)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = ShelfModel(directory: shelf)
    let added = await model.add(source)
    XCTAssertTrue(added)
    try FileManager.default.removeItem(at: try XCTUnwrap(model.items.first?.url))

    await model.cleanupStorage()

    XCTAssertTrue(model.items.isEmpty)
    let relaunched = ShelfModel(directory: shelf)
    XCTAssertTrue(relaunched.items.isEmpty)
  }

  @MainActor
  func testStacksItemsAndPoliciesPersistAcrossRelaunch() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    let shelf = root.appendingPathComponent("Shelf", isDirectory: true)
    let source = root.appendingPathComponent("persisted.txt")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("persisted".utf8).write(to: source)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = ShelfModel(directory: shelf)
    let createdWorkspace = await model.createStack(named: "Project Alpha")
    let workspace = try XCTUnwrap(createdWorkspace)
    let expirySaved = await model.setExpiryRule(.oneWeek, for: workspace)
    await model.setSameFileDuplicatePolicy(.keepBoth)
    let added = await model.add(source, to: workspace.id)
    XCTAssertTrue(expirySaved)
    XCTAssertTrue(added)

    let relaunched = ShelfModel(directory: shelf)

    XCTAssertEqual(relaunched.stacks.first(where: { $0.id == workspace.id })?.name, "Project Alpha")
    XCTAssertEqual(relaunched.stacks.first(where: { $0.id == workspace.id })?.expiryRule, .oneWeek)
    XCTAssertEqual(relaunched.items.first?.stackID, workspace.id)
    XCTAssertNotNil(relaunched.items.first?.expiresAt)
    XCTAssertEqual(relaunched.sameFileDuplicatePolicy, .keepBoth)
  }

  @MainActor
  func testMetadataFailureBeforeCommitLeavesNoPartialItem() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    let shelf = root.appendingPathComponent("Shelf", isDirectory: true)
    let source = root.appendingPathComponent("metadata-fails.txt")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("source".utf8).write(to: source)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = ShelfModel(
      directory: shelf,
      saveManifest: { _, _ in .failure(CopyFailure.expected) })

    let added = await model.add(source)
    XCTAssertFalse(added)
    XCTAssertTrue(model.items.isEmpty)
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(at: shelf, includingPropertiesForKeys: nil), [])
  }

  @MainActor
  func testRelaunchRecoversDestinationCommittedWithPendingMetadata() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    let shelf = root.appendingPathComponent("Shelf", isDirectory: true)
    try FileManager.default.createDirectory(at: shelf, withIntermediateDirectories: true)
    let destination = shelf.appendingPathComponent("recovered.txt")
    try Data("complete".utf8).write(to: destination)
    defer { try? FileManager.default.removeItem(at: root) }
    let stack = ShelfStack(id: UUID(), name: "Recovered Workspace", expiryRule: .oneDay)
    let importedAt = Date.now
    let pending = ShelfPendingImport(
      id: UUID(), fileName: destination.lastPathComponent, stackID: stack.id,
      importedAt: importedAt, expiresAt: importedAt.addingTimeInterval(86_400),
      origin: ShelfOriginIdentity(
        standardizedPath: "/original/recovered.txt", resourceIdentifier: nil))
    let manifest = ShelfManifest(
      stacks: [stack], items: [], pendingImports: [pending],
      sameFilePolicy: .reuseExisting, sameNamePolicy: .keepBoth)
    try await ShelfManifestStore.save(manifest, to: shelf.appendingPathExtension("json")).get()

    let relaunched = ShelfModel(directory: shelf)

    XCTAssertEqual(relaunched.items.first?.id, pending.id)
    XCTAssertEqual(relaunched.items.first?.stackID, stack.id)
    XCTAssertEqual(
      try XCTUnwrap(relaunched.items.first?.expiresAt).timeIntervalSince1970,
      try XCTUnwrap(pending.expiresAt).timeIntervalSince1970, accuracy: 1)
  }

  @MainActor
  func testRelaunchRecoversAfterFinalMetadataSaveFails() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    let shelf = root.appendingPathComponent("Shelf", isDirectory: true)
    let source = root.appendingPathComponent("committed.txt")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("complete".utf8).write(to: source)
    defer { try? FileManager.default.removeItem(at: root) }
    let saver = FailingSecondManifestSave()
    let model = ShelfModel(directory: shelf, saveManifest: saver.save)

    let added = await model.add(source)
    XCTAssertTrue(added)
    XCTAssertEqual(model.lastError, "Couldn't finish saving Shelf workspace data.")
    let committedID = try XCTUnwrap(model.items.first?.id)
    let committedStackID = try XCTUnwrap(model.items.first?.stackID)

    let relaunched = ShelfModel(directory: shelf)
    XCTAssertEqual(relaunched.items.first?.id, committedID)
    XCTAssertEqual(relaunched.items.first?.stackID, committedStackID)
    XCTAssertEqual(
      try String(contentsOf: try XCTUnwrap(relaunched.items.first?.url), encoding: .utf8),
      "complete")
  }
}
