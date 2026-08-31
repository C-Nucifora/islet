import AppKit
import Darwin
import QuickLookThumbnailing
import SwiftUI

struct ShelfStoragePolicy: Equatable, Sendable {
  static let standard = ShelfStoragePolicy(
    maximumBytes: 2 * 1024 * 1024 * 1024,
    minimumFreeSpaceBytes: 1024 * 1024 * 1024)

  let maximumBytes: Int64
  let minimumFreeSpaceBytes: Int64

  init(maximumBytes: Int64, minimumFreeSpaceBytes: Int64) {
    precondition(maximumBytes > 0)
    precondition(minimumFreeSpaceBytes >= 0)
    self.maximumBytes = maximumBytes
    self.minimumFreeSpaceBytes = minimumFreeSpaceBytes
  }
}

enum ShelfFileMeasurements {
  private enum MeasurementError: LocalizedError {
    case arithmeticOverflow
    case unsupportedItem

    var errorDescription: String? {
      switch self {
      case .arithmeticOverflow: "The item is too large to measure."
      case .unsupportedItem: "The item contains an unsupported file type."
      }
    }
  }

  /// Estimates the most space a normal copy can occupy. Sparse files count at their logical size,
  /// and hard-linked paths count separately because a copy need not preserve their shared inode.
  static func estimatedCopyBytes(at root: URL) -> Result<Int64, Error> {
    Result {
      var pending = [root]
      var total: Int64 = 0
      while let url = pending.popLast() {
        var information = stat()
        guard lstat(url.path, &information) == 0 else {
          throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }

        let type = information.st_mode & mode_t(S_IFMT)
        let allocated = information.st_blocks.multipliedReportingOverflow(by: 512)
        guard !allocated.overflow else { throw MeasurementError.arithmeticOverflow }

        let bytes: Int64
        switch type {
        case mode_t(S_IFREG):
          bytes = max(information.st_size, allocated.partialValue)
        case mode_t(S_IFDIR):
          bytes = max(4_096, allocated.partialValue)
          pending.append(
            contentsOf: try FileManager.default.contentsOfDirectory(
              at: url, includingPropertiesForKeys: nil, options: []))
        case mode_t(S_IFLNK):
          bytes = max(4_096, information.st_size, allocated.partialValue)
        default:
          throw MeasurementError.unsupportedItem
        }

        let next = total.addingReportingOverflow(bytes)
        guard !next.overflow else { throw MeasurementError.arithmeticOverflow }
        total = next.partialValue
      }
      return total
    }
  }

  static func availableCapacity(at directory: URL) -> Result<Int64, Error> {
    Result {
      let values = try directory.resourceValues(
        forKeys: [.volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
      let capacities = [
        values.volumeAvailableCapacity.map(Int64.init),
        values.volumeAvailableCapacityForImportantUsage,
      ].compactMap { $0 }.filter { $0 >= 0 }
      guard let available = capacities.min() else {
        throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: directory.path])
      }
      return available
    }
  }
}

struct ShelfItem: Identifiable, Equatable, Sendable {
  let id: UUID
  let url: URL
  let name: String
  var stackID: UUID
  let importedAt: Date
  var expiresAt: Date?
  var thumbnail: Data?  // PNG; Sendable-friendly so it can cross the QL callback boundary
}

/// The metadata that invalidates a thumbnail when an item changes on disk.
struct ShelfThumbnailMetadata: Hashable, Sendable {
  let modificationDate: Date?
  let fileSize: Int?
}

enum ShelfStorageFailure: Equatable, Sendable {
  case initialization
  case listing
  case metadata

  var message: String {
    switch self {
    case .initialization:
      "Shelf storage couldn't be prepared."
    case .listing:
      "Shelf storage couldn't be read."
    case .metadata:
      "Shelf workspace data couldn't be read."
    }
  }

  fileprivate var logOperation: String {
    switch self {
    case .initialization: "initialization"
    case .listing: "listing"
    case .metadata: "metadata loading"
    }
  }
}

/// A temporary file tray: dropped files are copied into app storage, thumbnailed, and can be
/// dragged back out or AirDropped. Persists across launches.
@MainActor
final class ShelfModel: ObservableObject {
  static let shared = ShelfModel()
  nonisolated static let maximumItemCount = 100
  nonisolated static let maximumConcurrentThumbnailRequests = 2

  private struct ImportBatch {
    let urls: [URL]
    let stackID: UUID
    let generation: UInt
  }

  private struct StorageReservation {
    var bytes: Int64
    var isStaged: Bool
  }

  private enum PendingImportRecordResult {
    case recorded(ShelfPendingImport)
    case cancelled
    case saveFailed
  }

  private struct ThumbnailCacheKey: Hashable, Sendable {
    let url: URL
    let metadata: ShelfThumbnailMetadata
  }

  private struct ThumbnailWork: Sendable {
    let id: UUID
    let url: URL
    let cacheKey: ThumbnailCacheKey
    let token: UInt
  }

  typealias CopyItem = @Sendable (URL, URL) async -> Result<Void, Error>
  typealias MoveItem = @Sendable (URL, URL) async -> Result<Void, Error>
  typealias CreateDirectory = @Sendable (URL) -> Result<Void, Error>
  typealias ListDirectory = @Sendable (URL) -> Result<[URL], Error>
  typealias RemoveItem = @Sendable (URL) -> Result<Void, Error>
  typealias MeasureItem = @Sendable (URL) async -> Result<Int64, Error>
  typealias MeasureAvailableCapacity = @Sendable (URL) async -> Result<Int64, Error>
  typealias ThumbnailMetadata = @Sendable (URL) -> ShelfThumbnailMetadata?
  typealias GenerateThumbnail = @Sendable (URL) async -> Data?
  typealias LoadManifest = @Sendable (URL) -> Result<ShelfManifest?, Error>
  typealias SaveManifest = @Sendable (ShelfManifest, URL) async -> Result<Void, Error>
  typealias CurrentDate = @Sendable () -> Date

  @Published private(set) var items: [ShelfItem] = []
  @Published private(set) var lastError: String?
  /// `nil` means the Shelf storage is available. It must not be inferred from an empty item list.
  @Published private(set) var storageFailure: ShelfStorageFailure?
  @Published private var dropState = ShelfDropState()
  @Published private(set) var presentationRequest: UUID?
  @Published private(set) var currentUsageBytes: Int64?
  @Published private(set) var lastRejectedImportBytes: Int64?
  @Published private(set) var stacks: [ShelfStack]
  @Published var selectedStackID: UUID
  @Published var sameFileDuplicatePolicy: ShelfSameFileDuplicatePolicy
  @Published var sameNameDuplicatePolicy: ShelfSameNameDuplicatePolicy

  private let dir: URL
  let storagePolicy: ShelfStoragePolicy
  private let copyItem: CopyItem
  private let moveItem: MoveItem
  private let createDirectory: CreateDirectory
  private let listDirectory: ListDirectory
  private let removeItem: RemoveItem
  private let measureItem: MeasureItem
  private let measureAvailableCapacity: MeasureAvailableCapacity
  private let thumbnailMetadata: ThumbnailMetadata
  private let generateThumbnailData: GenerateThumbnail
  private let loadManifest: LoadManifest
  private let saveManifest: SaveManifest
  private let currentDate: CurrentDate
  private var manifest: ShelfManifest
  private let manifestURL: URL
  private let quickLookController = ShelfQuickLookController()
  private var useCounts: [UUID: Int] = [:]
  private var removalReservations: Set<UUID> = []
  private var expiryTask: Task<Void, Never>?
  private var expiryRuleMutationCounts: [UUID: Int] = [:]
  private var reservedOrigins: [ShelfOriginIdentity: URL] = [:]
  private var originWaiters: [ShelfOriginIdentity: [CheckedContinuation<ShelfItem?, Never>]] = [:]
  private var reservedNames: [String: URL] = [:]
  private var nameWaiters: [String: [CheckedContinuation<ShelfItem?, Never>]] = [:]
  private var manifestSaveTail: Task<Result<Void, Error>, Never>?
  private var manifestMutationInProgress = false
  private var manifestMutationWaiters: [CheckedContinuation<Void, Never>] = []
  private var itemUsageBytes: [URL: Int64] = [:]
  private var reservedImports: [URL: StorageReservation] = [:]
  private var importQueue: [ImportBatch] = []
  private var importWorker: Task<Void, Never>?
  private var importGeneration: UInt = 0
  private var usageMutationGeneration: UInt = 0
  private var visibleThumbnailIDs: Set<UUID> = []
  private var queuedThumbnailWork: [ThumbnailWork] = []
  private var activeThumbnailWork: [UUID: ThumbnailWork] = [:]
  private var thumbnailTasks: [UUID: Task<Void, Never>] = [:]
  private var thumbnailCache: [ThumbnailCacheKey: Data] = [:]
  private var cancelledThumbnailTokens: Set<UInt> = []
  private var thumbnailWorkToken: UInt = 0
  private(set) var isClearing = false

  init(
    directory: URL? = nil,
    copyItem: CopyItem? = nil,
    moveItem: MoveItem? = nil,
    createDirectory: CreateDirectory? = nil,
    listDirectory: ListDirectory? = nil,
    removeItem: RemoveItem? = nil,
    measureItem: MeasureItem? = nil,
    measureAvailableCapacity: MeasureAvailableCapacity? = nil,
    thumbnailMetadata: ThumbnailMetadata? = nil,
    generateThumbnailData: GenerateThumbnail? = nil,
    loadManifest: LoadManifest? = nil,
    saveManifest: SaveManifest? = nil,
    currentDate: @escaping CurrentDate = { .now },
    storagePolicy: ShelfStoragePolicy = .standard
  ) {
    let base =
      directory
      ?? FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
      )[0].appendingPathComponent("Islet/Shelf", isDirectory: true)
    self.copyItem =
      copyItem
      ?? { source, destination in
        await Task.detached(priority: .utility) {
          Result { try FileManager.default.copyItem(at: source, to: destination) }
        }.value
      }
    self.moveItem =
      moveItem
      ?? { source, destination in
        await Task.detached(priority: .utility) {
          // Both URLs are direct children of `dir`, so this is a same-filesystem rename.
          Result { try FileManager.default.moveItem(at: source, to: destination) }
        }.value
      }
    self.createDirectory =
      createDirectory
      ?? { directory in
        Result {
          try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        }
      }
    self.listDirectory =
      listDirectory
      ?? { directory in
        Result {
          try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
        }
      }
    self.removeItem =
      removeItem
      ?? { item in
        Result { try FileManager.default.removeItem(at: item) }
      }
    self.measureItem =
      measureItem
      ?? { item in
        await Task.detached(priority: .utility) {
          ShelfFileMeasurements.estimatedCopyBytes(at: item)
        }.value
      }
    self.measureAvailableCapacity =
      measureAvailableCapacity
      ?? { directory in
        await Task.detached(priority: .utility) {
          ShelfFileMeasurements.availableCapacity(at: directory)
        }.value
      }
    self.thumbnailMetadata =
      thumbnailMetadata
      ?? { url in
        guard
          let values = try? url.resourceValues(
            forKeys: [.contentModificationDateKey, .fileSizeKey])
        else { return nil }
        return ShelfThumbnailMetadata(
          modificationDate: values.contentModificationDate, fileSize: values.fileSize)
      }
    self.generateThumbnailData = generateThumbnailData ?? Self.thumbnailData(for:)
    self.loadManifest = loadManifest ?? ShelfManifestStore.load
    self.saveManifest = saveManifest ?? ShelfManifestStore.save
    self.currentDate = currentDate
    self.storagePolicy = storagePolicy
    dir = base
    manifestURL = base.appendingPathExtension("json")
    let defaultStack = ShelfStack(id: UUID(), name: "Shelf", expiryRule: .never)
    let initialManifest = ShelfManifest.empty(defaultStack: defaultStack)
    manifest = initialManifest
    stacks = initialManifest.stacks
    selectedStackID = defaultStack.id
    sameFileDuplicatePolicy = initialManifest.sameFilePolicy
    sameNameDuplicatePolicy = initialManifest.sameNamePolicy
    refreshStorage()
  }

  var urls: [URL] { items.map(\.url) }
  var selectedItems: [ShelfItem] { items.filter { $0.stackID == selectedStackID } }
  var selectedStack: ShelfStack? { stacks.first { $0.id == selectedStackID } }
  /// True while at least one notch window is under the current file drag.
  var isDragActive: Bool { dropState.isTargeted }
  /// Keeps the Shelf selected until every provider resolves and every copy finishes.
  var isDropPresentationActive: Bool { dropState.isActive }
  var pendingImportCount: Int { dropState.pendingImportCount }
  var isStorageAvailable: Bool { storageFailure == nil }
  var canRevealStorageLocation: Bool { dir.isFileURL }
  var storageUsageText: String {
    guard let currentUsageBytes else { return "Calculating Shelf storage…" }
    return
      "\(Self.formattedByteCount(currentUsageBytes)) of \(Self.formattedByteCount(storagePolicy.maximumBytes))"
  }

  var storageUsageAccessibilityText: String {
    guard let currentUsageBytes else { return "Calculating Shelf storage usage" }
    return
      "Shelf storage: \(Self.formattedByteCount(currentUsageBytes)) used of "
      + "\(Self.formattedByteCount(storagePolicy.maximumBytes)). Keeps at least "
      + "\(Self.formattedByteCount(storagePolicy.minimumFreeSpaceBytes)) free for other apps."
  }

  func shareAllItems(using airDrop: AirDropShareController) {
    let leasedItems = items.filter { beginUsing($0) }
    guard !leasedItems.isEmpty else { return }
    airDrop.share(leasedItems.map(\.url)) { [weak self] in
      guard let self else { return }
      for item in leasedItems { self.endUsing(item) }
    }
  }

  func setDropTarget(_ id: UUID, active: Bool) {
    dropState.setTarget(id, active: active)
  }

  func requestPresentation() { presentationRequest = UUID() }

  func consumePresentationRequest(_ id: UUID) {
    guard presentationRequest == id else { return }
    presentationRequest = nil
  }

  func retryStorage() {
    guard manifestMutationInProgress else {
      refreshStorage()
      return
    }
    Task { [weak self] in
      guard let self else { return }
      await self.withManifestMutation { self.refreshStorage() }
    }
  }

  func revealStorageLocation() {
    let location = isStorageAvailable ? dir : dir.deletingLastPathComponent()
    guard NSWorkspace.shared.open(location) else {
      lastError = "Couldn't open the Shelf storage location."
      return
    }
    lastError = nil
  }

  @discardableResult
  func createStack(named rawName: String) async -> ShelfStack? {
    let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
    return await withManifestMutation {
      guard !name.isEmpty else {
        lastError = "Workspace names can't be empty."
        return nil
      }
      guard
        !manifest.stacks.contains(where: {
          $0.name.caseInsensitiveCompare(name) == .orderedSame
        })
      else {
        lastError = "A workspace named \(name) already exists."
        return nil
      }
      let stack = ShelfStack(id: UUID(), name: name, expiryRule: .never)
      let previous = manifest
      manifest.stacks.append(stack)
      guard await persistManifest(reportingError: true) else {
        manifest = previous
        return nil
      }
      stacks = manifest.stacks
      selectedStackID = stack.id
      lastError = nil
      return stack
    }
  }

  func renameStack(_ stack: ShelfStack, to rawName: String) async -> Bool {
    let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
    return await withManifestMutation {
      guard !name.isEmpty,
        !manifest.stacks.contains(where: {
          $0.id != stack.id && $0.name.caseInsensitiveCompare(name) == .orderedSame
        }),
        let index = manifest.stacks.firstIndex(where: { $0.id == stack.id })
      else {
        lastError = "Workspace names must be unique and non-empty."
        return false
      }
      let previous = manifest
      manifest.stacks[index].name = name
      guard await persistManifest(reportingError: true) else {
        manifest = previous
        return false
      }
      stacks = manifest.stacks
      lastError = nil
      return true
    }
  }

  func setExpiryRule(_ rule: ShelfExpiryRule, for stack: ShelfStack) async -> Bool {
    beginExpiryRuleMutation(for: stack.id)
    let saved = await withManifestMutation {
      guard let index = manifest.stacks.firstIndex(where: { $0.id == stack.id }) else {
        return false
      }
      let previous = manifest
      manifest.stacks[index].expiryRule = rule
      for itemIndex in manifest.items.indices where manifest.items[itemIndex].stackID == stack.id {
        manifest.items[itemIndex].expiresAt = rule.interval.map {
          manifest.items[itemIndex].importedAt.addingTimeInterval($0)
        }
      }
      for pendingIndex in manifest.pendingImports.indices
      where manifest.pendingImports[pendingIndex].stackID == stack.id {
        manifest.pendingImports[pendingIndex].expiresAt = rule.interval.map {
          manifest.pendingImports[pendingIndex].importedAt.addingTimeInterval($0)
        }
      }
      guard await persistManifest(reportingError: true) else {
        manifest = previous
        return false
      }
      stacks = manifest.stacks
      applyManifestItems()
      return true
    }
    endExpiryRuleMutation(for: stack.id)
    scheduleExpiry()
    await cleanupExpired()
    return saved
  }

  func setSameFileDuplicatePolicy(_ policy: ShelfSameFileDuplicatePolicy) async {
    await withManifestMutation {
      let previous = manifest
      manifest.sameFilePolicy = policy
      guard await persistManifest(reportingError: true) else {
        manifest = previous
        return
      }
      sameFileDuplicatePolicy = policy
    }
  }

  func setSameNameDuplicatePolicy(_ policy: ShelfSameNameDuplicatePolicy) async {
    await withManifestMutation {
      let previous = manifest
      manifest.sameNamePolicy = policy
      guard await persistManifest(reportingError: true) else {
        manifest = previous
        return
      }
      sameNameDuplicatePolicy = policy
    }
  }

  func move(_ item: ShelfItem, to stack: ShelfStack) async -> Bool {
    let saved = await withManifestMutation {
      guard let destinationStack = manifest.stacks.first(where: { $0.id == stack.id }),
        let index = manifest.items.firstIndex(where: { $0.id == item.id })
      else { return false }
      let previous = manifest
      manifest.items[index].stackID = destinationStack.id
      manifest.items[index].expiresAt = destinationStack.expiryRule.interval.map {
        manifest.items[index].importedAt.addingTimeInterval($0)
      }
      guard await persistManifest(reportingError: true) else {
        manifest = previous
        return false
      }
      return true
    }
    guard saved else { return false }
    applyManifestItems()
    scheduleExpiry()
    await cleanupExpired()
    return true
  }

  private func withManifestMutation<Value>(_ mutation: () async -> Value) async -> Value {
    await beginManifestMutation()
    defer { endManifestMutation() }
    return await mutation()
  }

  private func beginManifestMutation() async {
    guard manifestMutationInProgress else {
      manifestMutationInProgress = true
      return
    }
    await withCheckedContinuation { manifestMutationWaiters.append($0) }
  }

  private func endManifestMutation() {
    guard !manifestMutationWaiters.isEmpty else {
      manifestMutationInProgress = false
      return
    }
    manifestMutationWaiters.removeFirst().resume()
  }

  private func persistManifest(reportingError: Bool) async -> Bool {
    let task = enqueueManifestSave()
    switch await task.value {
    case .success:
      return true
    case .failure(let error):
      if reportingError { lastError = "Couldn't save Shelf workspace data." }
      Log.app.error("Shelf metadata save failed: \(error.localizedDescription)")
      return false
    }
  }

  private func enqueueManifestSave() -> Task<Result<Void, Error>, Never> {
    let previous = manifestSaveTail
    let snapshot = manifest
    let destination = manifestURL
    let save = saveManifest
    let task = Task {
      if let previous { _ = await previous.value }
      return await save(snapshot, destination)
    }
    manifestSaveTail = task
    return task
  }

  private func refreshStorage() {
    switch createDirectory(dir) {
    case .success:
      break
    case .failure(let error):
      setStorageFailure(.initialization, error: error)
      return
    }

    switch listDirectory(dir) {
    case .success(let found):
      cleanAbandonedStagingEntries(in: found)
      let loadedManifest: ShelfManifest
      switch loadManifest(manifestURL) {
      case .success(let stored):
        loadedManifest = stored ?? manifest
      case .failure(let error):
        setStorageFailure(.metadata, error: error)
        return
      }
      storageFailure = nil
      lastError = nil
      setItems(from: found, loadedManifest: loadedManifest)
    case .failure(let error):
      setStorageFailure(.listing, error: error)
    }
  }

  private func setItems(from found: [URL], loadedManifest: ShelfManifest) {
    cancelAllThumbnailWork()
    var recovered = repairedManifest(loadedManifest, found: found)
    let storedURLs = found.filter { !isInternalURL($0) }
    let urlsByName = Dictionary(uniqueKeysWithValues: storedURLs.map { ($0.lastPathComponent, $0) })
    let recordedNames = Set(recovered.items.map(\.fileName))
    let defaultStackID = recovered.stacks[0].id
    for url in storedURLs where !recordedNames.contains(url.lastPathComponent) {
      recovered.items.append(
        ShelfItemRecord(
          id: UUID(), fileName: url.lastPathComponent, stackID: defaultStackID,
          importedAt: modDate(url), expiresAt: nil, origin: nil))
    }
    recovered.items.removeAll { urlsByName[$0.fileName] == nil }
    manifest = recovered
    stacks = recovered.stacks
    sameFileDuplicatePolicy = recovered.sameFilePolicy
    sameNameDuplicatePolicy = recovered.sameNamePolicy
    if !stacks.contains(where: { $0.id == selectedStackID }) {
      selectedStackID = stacks[0].id
    }
    items = recovered.items.compactMap { record in
      guard let url = urlsByName[record.fileName] else { return nil }
      return ShelfItem(
        id: record.id, url: url, name: record.fileName, stackID: record.stackID,
        importedAt: record.importedAt, expiresAt: record.expiresAt, thumbnail: nil)
    }.sorted { $0.importedAt < $1.importedAt }
    let retainedURLs = Set(items.map(\.url))
    thumbnailCache = thumbnailCache.filter { retainedURLs.contains($0.key.url) }
    usageMutationGeneration &+= 1
    itemUsageBytes = [:]
    currentUsageBytes = nil
    scheduleUsageScan()
    scheduleExpiry()
    if recovered != loadedManifest { _ = enqueueManifestSave() }
    if items.contains(where: { $0.expiresAt.map { $0 <= currentDate() } == true }) {
      Task { [weak self] in await self?.cleanupExpired() }
    }
  }

  private func repairedManifest(_ loaded: ShelfManifest, found: [URL]) -> ShelfManifest {
    var repaired = loaded
    if repaired.stacks.isEmpty {
      repaired.stacks = [ShelfStack(id: UUID(), name: "Shelf", expiryRule: .never)]
    }
    let validStackIDs = Set(repaired.stacks.map(\.id))
    let defaultStackID = repaired.stacks[0].id
    for index in repaired.items.indices where !validStackIDs.contains(repaired.items[index].stackID)
    {
      repaired.items[index].stackID = defaultStackID
    }
    let foundNames = Set(found.filter { !isInternalURL($0) }.map(\.lastPathComponent))
    for pending in repaired.pendingImports where foundNames.contains(pending.fileName) {
      if !repaired.items.contains(where: { $0.id == pending.id }) {
        repaired.items.append(
          ShelfItemRecord(
            id: pending.id, fileName: pending.fileName,
            stackID: validStackIDs.contains(pending.stackID) ? pending.stackID : defaultStackID,
            importedAt: pending.importedAt, expiresAt: pending.expiresAt,
            origin: pending.origin))
      }
    }
    repaired.pendingImports.removeAll()
    repaired.items.removeAll { !foundNames.contains($0.fileName) }
    return repaired
  }

  private func scheduleUsageScan() {
    let urls = items.map(\.url)
    let generation = usageMutationGeneration
    Task { [weak self] in
      guard let self else { return }
      let result = await self.measureUsage(of: urls)
      guard generation == self.usageMutationGeneration else { return }
      self.applyUsageMeasurement(result)
    }
  }

  private func measureUsage(of urls: [URL]) async -> Result<[URL: Int64], Error> {
    var measurements: [URL: Int64] = [:]
    for url in urls {
      switch await measureItem(url) {
      case .success(let bytes):
        guard bytes >= 0 else {
          return .failure(CocoaError(.fileReadUnknown))
        }
        measurements[url] = bytes
      case .failure(let error):
        return .failure(error)
      }
    }
    return .success(measurements)
  }

  private func applyUsageMeasurement(_ result: Result<[URL: Int64], Error>) {
    switch result {
    case .success(let measurements):
      guard let total = ShelfLogic.totalBytes(measurements.values) else {
        currentUsageBytes = nil
        return
      }
      itemUsageBytes = measurements
      currentUsageBytes = total
    case .failure(let error):
      currentUsageBytes = nil
      Log.app.error("Shelf usage measurement failed: \(error.localizedDescription)")
    }
  }

  private func cleanAbandonedStagingEntries(in found: [URL]) {
    for item in found where isStagingURL(item) {
      if case .failure(let error) = removeItem(item) {
        Log.app.error("Shelf staging cleanup failed: \(error.localizedDescription)")
      }
    }
  }

  private func isInternalURL(_ url: URL) -> Bool {
    isStagingURL(url) || url.lastPathComponent == ShelfManifestStore.fileName
  }

  private func setStorageFailure(_ failure: ShelfStorageFailure, error: Error) {
    cancelAllThumbnailWork()
    items = []
    thumbnailCache.removeAll()
    usageMutationGeneration &+= 1
    itemUsageBytes = [:]
    currentUsageBytes = nil
    storageFailure = failure
    lastError = nil

    let nsError = error as NSError
    Log.app.error(
      "Shelf storage \(failure.logOperation, privacy: .public) failed [\(nsError.domain, privacy: .public):\(nsError.code, privacy: .public)]: \(nsError.localizedDescription, privacy: .private)"
    )
  }

  private func modDate(_ url: URL) -> Date {
    (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
      ?? .distantPast
  }

  /// Copies a dropped item away from the main actor. Large files should never freeze the notch's
  /// hover/click animation while FileManager performs disk I/O.
  @discardableResult
  func add(_ source: URL) async -> Bool {
    let result = await add(source, to: selectedStackID, updatesLastError: true)
    return result.error == nil
  }

  @discardableResult
  func add(_ source: URL, to stackID: UUID) async -> Bool {
    let result = await add(source, to: stackID, updatesLastError: true)
    return result.error == nil
  }

  private func add(
    _ source: URL, to stackID: UUID, updatesLastError: Bool,
    expectedImportGeneration: UInt? = nil
  ) async -> (item: ShelfItem?, error: String?, rejectedBytes: Int64?) {
    guard !isClearing else { return (nil, "Shelf is being cleared.", nil) }
    if let expectedImportGeneration, expectedImportGeneration != importGeneration {
      return (nil, nil, nil)
    }
    guard isStorageAvailable else {
      let error = "Shelf storage is unavailable."
      setImportError(error, rejectedBytes: nil, updatesLastError: updatesLastError)
      return (nil, error, nil)
    }
    guard source.isFileURL else {
      let error = "Only files and folders can be added."
      setImportError(error, rejectedBytes: nil, updatesLastError: updatesLastError)
      return (nil, error, nil)
    }
    guard let targetStack = stacks.first(where: { $0.id == stackID }) else {
      let error = "That Shelf workspace no longer exists."
      setImportError(error, rejectedBytes: nil, updatesLastError: updatesLastError)
      return (nil, error, nil)
    }
    guard FileManager.default.fileExists(atPath: source.path) else {
      let error = "That item is no longer available."
      setImportError(error, rejectedBytes: nil, updatesLastError: updatesLastError)
      return (nil, error, nil)
    }
    let origin = ShelfOriginIdentity.read(from: source)
    if let duplicate = duplicateItem(for: origin, sourceName: source.lastPathComponent) {
      if updatesLastError {
        lastError = nil
        lastRejectedImportBytes = nil
      }
      return (duplicate, nil, nil)
    }
    if sameFileDuplicatePolicy == .reuseExisting, reservedOrigins[origin] != nil {
      if let item = await waitForImport(of: origin) { return (item, nil, nil) }
      return await add(
        source, to: stackID, updatesLastError: updatesLastError,
        expectedImportGeneration: expectedImportGeneration)
    }
    let nameKey = duplicateNameKey(source.lastPathComponent)
    if sameNameDuplicatePolicy == .reuseExisting, reservedNames[nameKey] != nil {
      if let item = await waitForImport(named: nameKey) { return (item, nil, nil) }
      return await add(
        source, to: stackID, updatesLastError: updatesLastError,
        expectedImportGeneration: expectedImportGeneration)
    }
    guard
      ShelfLogic.hasCapacity(
        currentCount: items.count, pendingCount: reservedImports.count,
        maximum: Self.maximumItemCount)
    else {
      let error = "Shelf is full (\(Self.maximumItemCount) items)."
      setImportError(error, rejectedBytes: nil, updatesLastError: updatesLastError)
      return (nil, error, nil)
    }

    let estimatedBytes: Int64
    switch await measureItem(source) {
    case .success(let bytes) where bytes >= 0:
      estimatedBytes = bytes
    case .success, .failure:
      let error = "Couldn't calculate the size of \(source.lastPathComponent)."
      setImportError(error, rejectedBytes: nil, updatesLastError: updatesLastError)
      return (nil, error, nil)
    }
    guard importIsCurrent(expectedImportGeneration) else { return (nil, nil, nil) }
    if let duplicate = duplicateItem(for: origin, sourceName: source.lastPathComponent) {
      return (duplicate, nil, nil)
    }
    guard await refreshUsageForImport(expectedImportGeneration: expectedImportGeneration) else {
      guard importIsCurrent(expectedImportGeneration) else { return (nil, nil, nil) }
      let error = "Couldn't calculate current Shelf storage usage."
      setImportError(error, rejectedBytes: estimatedBytes, updatesLastError: updatesLastError)
      return (nil, error, estimatedBytes)
    }
    if sameFileDuplicatePolicy == .reuseExisting, reservedOrigins[origin] != nil {
      if let item = await waitForImport(of: origin) { return (item, nil, nil) }
      return await add(
        source, to: stackID, updatesLastError: updatesLastError,
        expectedImportGeneration: expectedImportGeneration)
    }
    if sameNameDuplicatePolicy == .reuseExisting, reservedNames[nameKey] != nil {
      if let item = await waitForImport(named: nameKey) { return (item, nil, nil) }
      return await add(
        source, to: stackID, updatesLastError: updatesLastError,
        expectedImportGeneration: expectedImportGeneration)
    }
    guard
      ShelfLogic.hasCapacity(
        currentCount: items.count, pendingCount: reservedImports.count,
        maximum: Self.maximumItemCount)
    else {
      let error = "Shelf is full (\(Self.maximumItemCount) items)."
      setImportError(error, rejectedBytes: nil, updatesLastError: updatesLastError)
      return (nil, error, nil)
    }
    let dest = reserveDestination(
      named: source.lastPathComponent, bytes: estimatedBytes, origin: origin)
    var committedItem: ShelfItem?
    defer {
      reservedImports.removeValue(forKey: dest)
      if reservedOrigins[origin] == dest { reservedOrigins.removeValue(forKey: origin) }
      if reservedNames[nameKey] == dest { reservedNames.removeValue(forKey: nameKey) }
      resolveImportWaiters(for: origin, item: committedItem)
      resolveImportWaiters(named: nameKey, item: committedItem)
    }
    if let error = await reservationError(
      destination: dest, sourceName: source.lastPathComponent,
      rejectedBytes: estimatedBytes)
    {
      guard importIsCurrent(expectedImportGeneration) else { return (nil, nil, nil) }
      setImportError(error, rejectedBytes: estimatedBytes, updatesLastError: updatesLastError)
      return (nil, error, estimatedBytes)
    }
    guard importIsCurrent(expectedImportGeneration) else { return (nil, nil, nil) }

    let staging = stagingDestination()
    let result = await copyItem(source, staging)

    if !importIsCurrent(expectedImportGeneration) {
      // A cancelled copy may finish after Clear. It only ever wrote to staging, so it was never
      // visible as a Shelf item.
      removeStagingItem(staging)
      return (nil, nil, nil)
    }

    switch result {
    case .success:
      let stagedBytes: Int64
      switch await measureItem(staging) {
      case .success(let bytes) where bytes >= 0:
        stagedBytes = bytes
      case .success, .failure:
        removeStagingItem(staging)
        let error = "Couldn't verify the size of \(source.lastPathComponent)."
        setImportError(error, rejectedBytes: nil, updatesLastError: updatesLastError)
        return (nil, error, nil)
      }
      guard importIsCurrent(expectedImportGeneration) else {
        removeStagingItem(staging)
        return (nil, nil, nil)
      }
      reservedImports[dest] = StorageReservation(bytes: stagedBytes, isStaged: true)
      guard await refreshUsageForImport(expectedImportGeneration: expectedImportGeneration) else {
        removeStagingItem(staging)
        guard importIsCurrent(expectedImportGeneration) else { return (nil, nil, nil) }
        let error = "Couldn't calculate current Shelf storage usage."
        setImportError(error, rejectedBytes: stagedBytes, updatesLastError: updatesLastError)
        return (nil, error, stagedBytes)
      }
      if let error = await reservationError(
        destination: dest, sourceName: source.lastPathComponent,
        rejectedBytes: stagedBytes)
      {
        removeStagingItem(staging)
        guard importIsCurrent(expectedImportGeneration) else { return (nil, nil, nil) }
        setImportError(error, rejectedBytes: stagedBytes, updatesLastError: updatesLastError)
        return (nil, error, stagedBytes)
      }
      guard importIsCurrent(expectedImportGeneration) else {
        removeStagingItem(staging)
        return (nil, nil, nil)
      }

      let importedAt = currentDate()
      let pendingDraft = ShelfPendingImport(
        id: UUID(), fileName: dest.lastPathComponent, stackID: targetStack.id,
        importedAt: importedAt,
        expiresAt: targetStack.expiryRule.interval.map { importedAt.addingTimeInterval($0) },
        origin: origin)
      let pending: ShelfPendingImport
      switch await recordPendingImport(
        pendingDraft, expectedImportGeneration: expectedImportGeneration)
      {
      case .recorded(let recorded):
        pending = recorded
      case .cancelled:
        removeStagingItem(staging)
        return (nil, nil, nil)
      case .saveFailed:
        removeStagingItem(staging)
        let error = "Couldn't save Shelf workspace data."
        setImportError(error, rejectedBytes: nil, updatesLastError: updatesLastError)
        return (nil, error, nil)
      }
      guard importIsCurrent(expectedImportGeneration) else {
        removeStagingItem(staging)
        await discardPendingImport(pending.id)
        return (nil, nil, nil)
      }

      let moveResult = await moveItem(staging, dest)
      if !importIsCurrent(expectedImportGeneration) {
        switch moveResult {
        case .success:
          // Clear may run while the rename is in flight. If the rename won that race, remove the
          // completed destination because it was never present in Clear's item snapshot.
          removeImportedItem(dest)
        case .failure:
          removeStagingItem(staging)
        }
        await discardPendingImport(pending.id)
        return (nil, nil, nil)
      }
      switch moveResult {
      case .success:
        let (committedPending, metadataSaved) = await commitPendingImport(pending)
        if updatesLastError {
          lastError = metadataSaved ? nil : "Couldn't finish saving Shelf workspace data."
          lastRejectedImportBytes = nil
        }
        let item = ShelfItem(
          id: committedPending.id, url: dest, name: dest.lastPathComponent,
          stackID: committedPending.stackID, importedAt: committedPending.importedAt,
          expiresAt: committedPending.expiresAt, thumbnail: nil)
        items.append(item)
        committedItem = item
        usageMutationGeneration &+= 1
        itemUsageBytes[dest] = stagedBytes
        currentUsageBytes = ShelfLogic.totalBytes(itemUsageBytes.values)
        scheduleExpiry()
        return (item, nil, nil)
      case .failure(let error):
        await discardPendingImport(pending.id)
        removeStagingItem(staging)
        let message = "Couldn’t add \(source.lastPathComponent)."
        setImportError(message, rejectedBytes: nil, updatesLastError: updatesLastError)
        Log.app.error("Shelf staged rename failed: \(error.localizedDescription)")
        return (nil, message, nil)
      }
    case .failure(let error):
      // A failed copy can leave a partial file or directory. It is in staging, rather than the
      // visible destination, and cleanup makes the next launch safe even after a process crash.
      removeStagingItem(staging)
      // A file can disappear between Finder producing its drag payload and the async copy. Give a
      // useful, non-technical error while retaining the detailed failure in the log.
      let message = "Couldn’t add \(source.lastPathComponent)."
      setImportError(message, rejectedBytes: nil, updatesLastError: updatesLastError)
      Log.app.error("Shelf copy failed: \(error.localizedDescription)")
      return (nil, message, nil)
    }
  }

  private func recordPendingImport(
    _ pending: ShelfPendingImport, expectedImportGeneration: UInt?
  ) async -> PendingImportRecordResult {
    await withManifestMutation {
      guard importIsCurrent(expectedImportGeneration),
        let stack = manifest.stacks.first(where: { $0.id == pending.stackID })
      else { return .cancelled }
      var recorded = pending
      recorded.expiresAt = stack.expiryRule.interval.map {
        recorded.importedAt.addingTimeInterval($0)
      }
      manifest.pendingImports.append(recorded)
      guard await persistManifest(reportingError: false) else {
        manifest.pendingImports.removeAll { $0.id == recorded.id }
        return .saveFailed
      }
      return .recorded(recorded)
    }
  }

  private func discardPendingImport(_ id: UUID) async {
    await withManifestMutation {
      manifest.pendingImports.removeAll { $0.id == id }
      _ = await persistManifest(reportingError: false)
    }
  }

  private func commitPendingImport(
    _ pending: ShelfPendingImport
  ) async -> (ShelfPendingImport, Bool) {
    await withManifestMutation {
      let committed = manifest.pendingImports.first(where: { $0.id == pending.id }) ?? pending
      manifest.pendingImports.removeAll { $0.id == pending.id }
      manifest.items.append(
        ShelfItemRecord(
          id: committed.id, fileName: committed.fileName, stackID: committed.stackID,
          importedAt: committed.importedAt, expiresAt: committed.expiresAt,
          origin: committed.origin))
      return (committed, await persistManifest(reportingError: false))
    }
  }

  private func importIsCurrent(_ expectedImportGeneration: UInt?) -> Bool {
    !Task.isCancelled
      && expectedImportGeneration.map { $0 == importGeneration } != false
  }

  private func refreshUsageForImport(expectedImportGeneration: UInt?) async -> Bool {
    while importIsCurrent(expectedImportGeneration) {
      let generation = usageMutationGeneration
      let urls = items.map(\.url)
      let result = await measureUsage(of: urls)
      guard importIsCurrent(expectedImportGeneration) else { return false }
      guard generation == usageMutationGeneration else { continue }
      applyUsageMeasurement(result)
      return currentUsageBytes != nil
    }
    return false
  }

  private func reservationError(
    destination: URL, sourceName: String, rejectedBytes: Int64
  ) async -> String? {
    let available: Int64
    switch await measureAvailableCapacity(dir) {
    case .success(let bytes) where bytes >= 0:
      available = bytes
    case .success, .failure:
      return "Couldn't check free disk space."
    }

    guard let currentUsageBytes, reservedImports[destination] != nil else {
      return "Couldn't calculate current Shelf storage usage."
    }
    let reservations = Array(reservedImports.values)
    let decision = ShelfLogic.storageDecision(
      currentBytes: currentUsageBytes,
      reservedBytes: reservations.map(\.bytes),
      unstagedBytes: reservations.filter { !$0.isStaged }.map(\.bytes),
      availableBytes: available,
      policy: storagePolicy)
    guard decision == .accepted else {
      return storageLimitError(
        sourceName: sourceName, rejectedBytes: rejectedBytes, decision: decision)
    }
    return nil
  }

  private func storageLimitError(
    sourceName: String, rejectedBytes: Int64,
    decision: ShelfStorageDecision = .overBudget
  ) -> String {
    let size = Self.formattedByteCount(rejectedBytes)
    switch decision {
    case .accepted, .overBudget:
      return
        "Can't add \(sourceName) (\(size)). The Shelf limit is \(Self.formattedByteCount(storagePolicy.maximumBytes))."
    case .lowFreeSpace:
      return
        "Can't add \(sourceName) (\(size)). Islet keeps \(Self.formattedByteCount(storagePolicy.minimumFreeSpaceBytes)) free for other apps."
    case .invalidMeasurement:
      return "Can't add \(sourceName) (\(size)) because its storage size is invalid."
    }
  }

  private func setImportError(
    _ error: String, rejectedBytes: Int64?, updatesLastError: Bool
  ) {
    guard updatesLastError else { return }
    lastError = error
    lastRejectedImportBytes = rejectedBytes
  }

  nonisolated private static func formattedByteCount(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
  }

  func remove(_ item: ShelfItem) async {
    await remove(item, respectingUseLease: false)
  }

  private func remove(_ item: ShelfItem, respectingUseLease: Bool) async {
    guard items.contains(where: { $0.id == item.id }),
      !removalReservations.contains(item.id),
      !respectingUseLease || useCounts[item.id] == nil
    else { return }
    removalReservations.insert(item.id)
    defer { removalReservations.remove(item.id) }
    let removeStoredItem = removeItem
    let result: Result<Void, Error> = await Task.detached(priority: .utility) {
      removeStoredItem(item.url)
    }.value
    switch result {
    case .success:
      await completeRemoval(of: item)
    case .failure(let error as CocoaError) where error.code == .fileNoSuchFile:
      // Finder or another process may already have removed the persistent copy. The requested
      // final state is still achieved, so do not strand a ghost tile on the Shelf.
      await completeRemoval(of: item)
    case .failure(let error):
      lastError = "Couldn’t remove \(item.name)."
      Log.app.error("Shelf removal failed: \(error.localizedDescription)")
    }
  }

  private func completeRemoval(of item: ShelfItem) async {
    await withManifestMutation {
      quickLookController.close(itemID: item.id)
      cancelThumbnailWork(for: item.id, removingCachedThumbnailFor: item.url)
      items.removeAll { $0.id == item.id }
      manifest.items.removeAll { $0.id == item.id }
      useCounts.removeValue(forKey: item.id)
      didRemoveStoredItem(at: item.url)
      let saved = await persistManifest(reportingError: true)
      if saved { lastError = nil }
      lastRejectedImportBytes = nil
    }
  }

  func clear() async {
    guard !isClearing else { return }
    isClearing = true
    defer { isClearing = false }
    await cancelPendingImports()
    let current = items
    let previouslyVisibleThumbnailIDs = visibleThumbnailIDs
    for item in current {
      cancelThumbnailWork(for: item.id, removingCachedThumbnailFor: item.url)
    }
    let originalIDs = Set(current.map(\.id))
    let removeStoredItem = removeItem
    let removedIDs: Set<UUID> = await Task.detached(priority: .utility) {
      var removed: Set<UUID> = []
      for item in current {
        do {
          try removeStoredItem(item.url).get()
          removed.insert(item.id)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
          // Finder or a concurrent single-item removal already achieved Clear's requested state.
          removed.insert(item.id)
        } catch {
          Log.app.error("Shelf clear failed for \(item.name): \(error.localizedDescription)")
        }
      }
      return removed
    }.value
    await withManifestMutation {
      items.removeAll { removedIDs.contains($0.id) }
      manifest.items.removeAll { removedIDs.contains($0.id) }
      // A failed deletion leaves its tile in place. Restore any visible request that Clear
      // cancelled; SwiftUI does not call `onAppear` again for a view whose identity never changed.
      for item in items where previouslyVisibleThumbnailIDs.contains(item.id) {
        visibleThumbnailIDs.insert(item.id)
        requestThumbnail(for: item)
      }
      usageMutationGeneration &+= 1
      for item in current where removedIDs.contains(item.id) {
        itemUsageBytes.removeValue(forKey: item.url)
      }
      if itemUsageBytes.count == items.count {
        currentUsageBytes = ShelfLogic.totalBytes(itemUsageBytes.values)
      } else {
        currentUsageBytes = nil
        scheduleUsageScan()
      }
      lastError =
        originalIDs.subtracting(removedIDs).isEmpty
        ? nil : "Some Shelf items couldn’t be removed."
      if lastError == nil { lastRejectedImportBytes = nil }
      _ = await persistManifest(reportingError: lastError == nil)
      scheduleExpiry()
    }
  }

  func open(_ item: ShelfItem) {
    guard beginUsing(item) else {
      lastError = "\(item.name) is no longer available."
      return
    }
    guard NSWorkspace.shared.open(item.url) else {
      endUsing(item)
      lastError = "Couldn’t open \(item.name)."
      return
    }
    // Keep the path stable while LaunchServices hands it to the destination app. Once that app has
    // opened the file, removing the Shelf directory entry cannot invalidate its open descriptor.
    Task { [weak self] in
      try? await Task.sleep(for: .seconds(10))
      self?.endUsing(item)
    }
    lastError = nil
  }

  func quickLook(_ item: ShelfItem) {
    guard beginUsing(item) else {
      lastError = "\(item.name) is no longer available."
      return
    }
    guard quickLookController.present(item, onClose: { [weak self] in self?.endUsing(item) }) else {
      endUsing(item)
      lastError =
        FileManager.default.fileExists(atPath: item.url.path)
        ? "Quick Look isn't available for \(item.name)."
        : "\(item.name) is no longer available."
      return
    }
    lastError = nil
  }

  @discardableResult
  func beginUsing(_ item: ShelfItem) -> Bool {
    guard items.contains(where: { $0.id == item.id }), !removalReservations.contains(item.id)
    else { return false }
    useCounts[item.id, default: 0] += 1
    return true
  }

  func endUsing(_ item: ShelfItem) {
    guard let count = useCounts[item.id] else { return }
    if count <= 1 {
      useCounts.removeValue(forKey: item.id)
    } else {
      useCounts[item.id] = count - 1
    }
    if items.first(where: { $0.id == item.id })?.expiresAt.map({ $0 <= currentDate() }) == true {
      Task { [weak self] in await self?.cleanupExpired() }
    }
  }

  func itemProvider(for item: ShelfItem) -> NSItemProvider {
    guard beginUsing(item) else { return NSItemProvider() }
    return ShelfDragItemProvider(item: item) { [weak self] in
      self?.endUsing(item)
    }
  }

  func expirationText(for item: ShelfItem, now: Date = .now) -> String? {
    guard let expiry = item.expiresAt else { return nil }
    if expiry <= now { return useCounts[item.id] == nil ? "Expired" : "Expires after use" }
    return "Expires \(expiry.formatted(.relative(presentation: .named)))"
  }

  func cleanupStorage() async {
    await cleanupItems(at: currentDate(), includeMissing: true)
  }

  func cleanupExpired(at date: Date? = nil) async {
    await cleanupItems(at: date ?? currentDate(), includeMissing: false)
  }

  private func cleanupItems(at date: Date, includeMissing: Bool) async {
    let candidates = items.filter { item in
      guard useCounts[item.id] == nil else { return false }
      let expiryUpdateInFlight = expiryRuleMutationCounts[item.stackID] != nil
      let expired = !expiryUpdateInFlight && item.expiresAt.map { $0 <= date } == true
      let missing = includeMissing && !FileManager.default.fileExists(atPath: item.url.path)
      return expired || missing
    }
    for item in candidates { await remove(item, respectingUseLease: true) }
    scheduleExpiry()
  }

  private func scheduleExpiry() {
    expiryTask?.cancel()
    let now = currentDate()
    guard
      let next = items.lazy.filter({ self.expiryRuleMutationCounts[$0.stackID] == nil })
        .compactMap(\.expiresAt).filter({ $0 > now }).min()
    else { return }
    expiryTask = Task { [weak self] in
      let interval = max(0, next.timeIntervalSince(now))
      try? await Task.sleep(for: .seconds(interval))
      guard !Task.isCancelled else { return }
      await self?.cleanupExpired()
    }
  }

  private func applyManifestItems() {
    let records = Dictionary(uniqueKeysWithValues: manifest.items.map { ($0.id, $0) })
    for index in items.indices {
      guard let record = records[items[index].id] else { continue }
      items[index].stackID = record.stackID
      items[index].expiresAt = record.expiresAt
    }
  }

  private func beginExpiryRuleMutation(for stackID: UUID) {
    expiryRuleMutationCounts[stackID, default: 0] += 1
    expiryTask?.cancel()
  }

  private func endExpiryRuleMutation(for stackID: UUID) {
    guard let count = expiryRuleMutationCounts[stackID] else { return }
    if count <= 1 {
      expiryRuleMutationCounts.removeValue(forKey: stackID)
    } else {
      expiryRuleMutationCounts[stackID] = count - 1
    }
  }

  func dismissError() {
    lastError = nil
    lastRejectedImportBytes = nil
  }

  private func didRemoveStoredItem(at url: URL) {
    usageMutationGeneration &+= 1
    itemUsageBytes.removeValue(forKey: url)
    if itemUsageBytes.count == items.count {
      currentUsageBytes = ShelfLogic.totalBytes(itemUsageBytes.values)
    } else {
      currentUsageBytes = nil
      scheduleUsageScan()
    }
  }

  private func duplicateItem(for origin: ShelfOriginIdentity, sourceName: String) -> ShelfItem? {
    if sameFileDuplicatePolicy == .reuseExisting,
      let record = manifest.items.first(where: { $0.origin == origin })
    {
      return items.first { $0.id == record.id }
    }
    if sameNameDuplicatePolicy == .reuseExisting {
      return items.first { $0.name.caseInsensitiveCompare(sourceName) == .orderedSame }
    }
    return nil
  }

  private func waitForImport(of origin: ShelfOriginIdentity) async -> ShelfItem? {
    await withCheckedContinuation { continuation in
      originWaiters[origin, default: []].append(continuation)
    }
  }

  private func resolveImportWaiters(for origin: ShelfOriginIdentity, item: ShelfItem?) {
    let waiters = originWaiters.removeValue(forKey: origin) ?? []
    for waiter in waiters { waiter.resume(returning: item) }
  }

  private func waitForImport(named nameKey: String) async -> ShelfItem? {
    await withCheckedContinuation { continuation in
      nameWaiters[nameKey, default: []].append(continuation)
    }
  }

  private func resolveImportWaiters(named nameKey: String, item: ShelfItem?) {
    let waiters = nameWaiters.removeValue(forKey: nameKey) ?? []
    for waiter in waiters { waiter.resume(returning: item) }
  }

  private func duplicateNameKey(_ name: String) -> String {
    name.lowercased()
  }

  private func reserveDestination(
    named name: String, bytes: Int64, origin: ShelfOriginIdentity
  ) -> URL {
    var candidate = name
    var i = 1
    let stem = (name as NSString).deletingPathExtension
    let ext = (name as NSString).pathExtension
    while isReservedInternalName(candidate)
      || FileManager.default.fileExists(atPath: dir.appendingPathComponent(candidate).path)
      || reservedImports[dir.appendingPathComponent(candidate)] != nil
    {
      candidate = ext.isEmpty ? "\(stem) \(i)" : "\(stem) \(i).\(ext)"
      i += 1
    }
    let destination = dir.appendingPathComponent(candidate)
    reservedImports[destination] = StorageReservation(bytes: bytes, isStaged: false)
    reservedOrigins[origin] = destination
    reservedNames[duplicateNameKey(name)] = destination
    return destination
  }

  private func isReservedInternalName(_ name: String) -> Bool {
    name == ShelfManifestStore.fileName
      || isStagingURL(dir.appendingPathComponent(name))
  }

  private func stagingDestination() -> URL {
    dir.appendingPathComponent(".islet-shelf-staging-\(UUID().uuidString)")
  }

  private func isStagingURL(_ url: URL) -> Bool {
    let prefix = ".islet-shelf-staging-"
    let name = url.lastPathComponent
    guard name.hasPrefix(prefix) else { return false }
    return UUID(uuidString: String(name.dropFirst(prefix.count))) != nil
  }

  private func removeStagingItem(_ staging: URL) {
    _ = removeItem(staging)
  }

  private func removeImportedItem(_ destination: URL) {
    if case .failure(let error) = removeItem(destination) {
      Log.app.error("Shelf cancelled import cleanup failed: \(error.localizedDescription)")
    }
  }

  private func setThumbnail(_ data: Data, id: UUID) {
    guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
    items[idx].thumbnail = data
  }

  /// Called by an item tile as it enters or leaves the horizontal viewport. There is deliberately
  /// no eager work on Shelf launch: `LazyHStack` asks for the visible tiles first.
  func setThumbnailVisibility(for item: ShelfItem, isVisible: Bool) {
    if !isVisible {
      visibleThumbnailIDs.remove(item.id)
      cancelThumbnailWork(for: item.id)
      return
    }
    guard let currentItem = items.first(where: { $0.id == item.id && $0.url == item.url }) else {
      return
    }
    visibleThumbnailIDs.insert(item.id)
    requestThumbnail(for: currentItem)
  }

  private func requestThumbnail(for item: ShelfItem) {
    guard visibleThumbnailIDs.contains(item.id), let metadata = thumbnailMetadata(item.url) else {
      return
    }
    let cacheKey = ThumbnailCacheKey(url: item.url, metadata: metadata)
    if let data = thumbnailCache[cacheKey] {
      setThumbnail(data, id: item.id)
      return
    }
    if queuedThumbnailWork.contains(where: { $0.id == item.id && $0.cacheKey == cacheKey }) {
      return
    }
    if let activeWork = activeThumbnailWork[item.id], activeWork.cacheKey == cacheKey,
      !cancelledThumbnailTokens.contains(activeWork.token)
    {
      return
    }

    // A fresh request supersedes a queued or in-flight result for the same tile. The cancelled
    // task remains counted until Quick Look returns, so cancellation cannot exceed the cap.
    cancelThumbnailWork(for: item.id)
    thumbnailWorkToken &+= 1
    queuedThumbnailWork.append(
      ThumbnailWork(id: item.id, url: item.url, cacheKey: cacheKey, token: thumbnailWorkToken))
    startThumbnailWorkIfPossible()
  }

  private func startThumbnailWorkIfPossible() {
    while activeThumbnailWork.count < Self.maximumConcurrentThumbnailRequests,
      let nextIndex = queuedThumbnailWork.firstIndex(where: { activeThumbnailWork[$0.id] == nil })
    {
      let work = queuedThumbnailWork.remove(at: nextIndex)
      guard visibleThumbnailIDs.contains(work.id),
        items.contains(where: { $0.id == work.id && $0.url == work.url })
      else { continue }
      activeThumbnailWork[work.id] = work
      thumbnailTasks[work.id] = Task { [weak self] in
        guard let self else { return }
        let data = await self.generateThumbnailData(work.url)
        guard !Task.isCancelled else {
          self.finishThumbnailWork(work, data: nil)
          return
        }
        self.finishThumbnailWork(work, data: data)
      }
    }
  }

  private func finishThumbnailWork(_ work: ThumbnailWork, data: Data?) {
    guard activeThumbnailWork[work.id]?.token == work.token else { return }
    let wasCancelled = cancelledThumbnailTokens.remove(work.token) != nil
    activeThumbnailWork.removeValue(forKey: work.id)
    thumbnailTasks.removeValue(forKey: work.id)
    defer { startThumbnailWorkIfPossible() }
    guard !wasCancelled,
      visibleThumbnailIDs.contains(work.id),
      items.contains(where: { $0.id == work.id && $0.url == work.url }),
      thumbnailMetadata(work.url) == work.cacheKey.metadata,
      let data
    else { return }

    // Keep one version per URL. This bounds the in-memory cache to the Shelf item limit while
    // invalidating an entry as soon as modification metadata changes.
    thumbnailCache = thumbnailCache.filter { $0.key.url != work.url || $0.key == work.cacheKey }
    thumbnailCache[work.cacheKey] = data
    setThumbnail(data, id: work.id)
  }

  private func cancelThumbnailWork(
    for id: UUID, removingCachedThumbnailFor url: URL? = nil
  ) {
    queuedThumbnailWork.removeAll { $0.id == id }
    if let work = activeThumbnailWork[id] { cancelledThumbnailTokens.insert(work.token) }
    thumbnailTasks[id]?.cancel()
    if let url {
      visibleThumbnailIDs.remove(id)
      thumbnailCache = thumbnailCache.filter { $0.key.url != url }
    }
  }

  private func cancelAllThumbnailWork() {
    visibleThumbnailIDs.removeAll()
    queuedThumbnailWork.removeAll()
    for (id, task) in thumbnailTasks {
      if let work = activeThumbnailWork[id] { cancelledThumbnailTokens.insert(work.token) }
      task.cancel()
    }
  }

  private static func thumbnailData(for url: URL) async -> Data? {
    // Uses the async API so we never pass a non-Sendable QL representation across an actor hop.
    let request = QLThumbnailGenerator.Request(
      fileAt: url, size: CGSize(width: 120, height: 120), scale: 2,
      representationTypes: .all)
    guard
      let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request),
      !Task.isCancelled
    else { return nil }
    return pngData(from: rep.cgImage)
  }

  private static func pngData(from cgImage: CGImage) -> Data? {
    NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
  }

  /// AppKit window destinations already resolve Finder's pasteboard to file URLs, so imports can
  /// begin without waiting for an item-provider callback.
  @discardableResult
  func importDroppedURLs(_ urls: [URL]) -> Bool {
    guard !isClearing else { return false }
    let fileURLs = urls.filter(\.isFileURL)
    guard !fileURLs.isEmpty else { return false }

    dropState.beginImports(fileURLs.count)
    importQueue.append(
      ImportBatch(urls: fileURLs, stackID: selectedStackID, generation: importGeneration))
    startImportWorkerIfNeeded()
    return true
  }

  private func startImportWorkerIfNeeded() {
    guard importWorker == nil, !importQueue.isEmpty else { return }
    let generation = importGeneration
    importWorker = Task { [weak self] in
      await self?.drainImportQueue(generation: generation)
    }
  }

  private func drainImportQueue(generation: UInt) async {
    var firstError: String?
    var firstRejectedBytes: Int64?
    while generation == importGeneration, !Task.isCancelled, !importQueue.isEmpty {
      let batch = importQueue.removeFirst()
      guard batch.generation == generation else { continue }
      for url in batch.urls {
        guard generation == importGeneration, !Task.isCancelled else { return }
        let result = await add(
          url, to: batch.stackID, updatesLastError: false,
          expectedImportGeneration: generation)
        guard generation == importGeneration, !Task.isCancelled else { return }
        if firstError == nil, let error = result.error {
          firstError = error
          firstRejectedBytes = result.rejectedBytes
          lastError = error
          lastRejectedImportBytes = result.rejectedBytes
        }
        dropState.finishImport()
      }
    }
    guard generation == importGeneration else { return }
    lastError = firstError
    lastRejectedImportBytes = firstRejectedBytes
    importWorker = nil
    startImportWorkerIfNeeded()
  }

  private func cancelPendingImports() async {
    importGeneration &+= 1
    importQueue.removeAll()
    let activeWorker = importWorker
    activeWorker?.cancel()
    // Clear only the generation being invalidated. New drops are rejected while Clear awaits the
    // old worker, so no fresh progress state can be erased by this reset.
    dropState.cancelImports()
    await activeWorker?.value
    importWorker = nil
    startImportWorkerIfNeeded()
  }
}

struct ShelfDropState: Equatable {
  private(set) var targetedDropZones: Set<UUID> = []
  private(set) var pendingImportCount = 0

  var isTargeted: Bool { !targetedDropZones.isEmpty }
  var isActive: Bool { isTargeted || pendingImportCount > 0 }

  mutating func setTarget(_ id: UUID, active: Bool) {
    if active {
      targetedDropZones.insert(id)
    } else {
      targetedDropZones.remove(id)
    }
  }

  mutating func beginImports(_ count: Int) {
    guard count > 0 else { return }
    pendingImportCount += count
  }

  mutating func finishImport() {
    guard pendingImportCount > 0 else { return }
    pendingImportCount -= 1
  }

  mutating func cancelImports() {
    pendingImportCount = 0
  }
}

enum ShelfStorageDecision: Equatable {
  case accepted
  case overBudget
  case lowFreeSpace
  case invalidMeasurement
}

enum ShelfLogic {
  static func hasCapacity(currentCount: Int, pendingCount: Int, maximum: Int) -> Bool {
    guard currentCount >= 0, pendingCount >= 0, maximum > 0 else { return false }
    return currentCount + pendingCount < maximum
  }

  static func totalBytes<S: Sequence>(_ values: S) -> Int64? where S.Element == Int64 {
    var total: Int64 = 0
    for value in values {
      guard value >= 0 else { return nil }
      let next = total.addingReportingOverflow(value)
      guard !next.overflow else { return nil }
      total = next.partialValue
    }
    return total
  }

  static func storageDecision(
    currentBytes: Int64, reservedBytes: [Int64], unstagedBytes: [Int64],
    availableBytes: Int64, policy: ShelfStoragePolicy
  ) -> ShelfStorageDecision {
    guard currentBytes >= 0, availableBytes >= 0,
      let reserved = totalBytes(reservedBytes),
      let unstaged = totalBytes(unstagedBytes)
    else { return .invalidMeasurement }

    let plannedUsage = currentBytes.addingReportingOverflow(reserved)
    guard !plannedUsage.overflow else { return .invalidMeasurement }
    guard plannedUsage.partialValue <= policy.maximumBytes else { return .overBudget }

    let requiredFreeSpace = policy.minimumFreeSpaceBytes.addingReportingOverflow(unstaged)
    guard !requiredFreeSpace.overflow else { return .invalidMeasurement }
    guard availableBytes >= requiredFreeSpace.partialValue else { return .lowFreeSpace }
    return .accepted
  }
}
