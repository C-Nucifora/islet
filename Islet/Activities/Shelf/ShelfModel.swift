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
  var thumbnail: Data?  // PNG; Sendable-friendly so it can cross the QL callback boundary
}

enum ShelfStorageFailure: Equatable, Sendable {
  case initialization
  case listing

  var message: String {
    switch self {
    case .initialization:
      "Shelf storage couldn't be prepared."
    case .listing:
      "Shelf storage couldn't be read."
    }
  }

  fileprivate var logOperation: String {
    switch self {
    case .initialization: "initialization"
    case .listing: "listing"
    }
  }
}

/// A temporary file tray: dropped files are copied into app storage, thumbnailed, and can be
/// dragged back out or AirDropped. Persists across launches.
@MainActor
final class ShelfModel: ObservableObject {
  static let shared = ShelfModel()
  nonisolated static let maximumItemCount = 100

  private struct ImportBatch {
    let urls: [URL]
    let generation: UInt
  }

  private struct StorageReservation {
    var bytes: Int64
    var isStaged: Bool
  }

  typealias CopyItem = @Sendable (URL, URL) async -> Result<Void, Error>
  typealias MoveItem = @Sendable (URL, URL) async -> Result<Void, Error>
  typealias CreateDirectory = @Sendable (URL) -> Result<Void, Error>
  typealias ListDirectory = @Sendable (URL) -> Result<[URL], Error>
  typealias RemoveItem = @Sendable (URL) -> Result<Void, Error>
  typealias MeasureItem = @Sendable (URL) async -> Result<Int64, Error>
  typealias MeasureAvailableCapacity = @Sendable (URL) async -> Result<Int64, Error>

  @Published private(set) var items: [ShelfItem] = []
  @Published private(set) var lastError: String?
  /// `nil` means the Shelf storage is available. It must not be inferred from an empty item list.
  @Published private(set) var storageFailure: ShelfStorageFailure?
  @Published private var dropState = ShelfDropState()
  @Published private(set) var presentationRequest: UUID?
  @Published private(set) var currentUsageBytes: Int64?
  @Published private(set) var lastRejectedImportBytes: Int64?

  private let dir: URL
  let storagePolicy: ShelfStoragePolicy
  private let copyItem: CopyItem
  private let moveItem: MoveItem
  private let createDirectory: CreateDirectory
  private let listDirectory: ListDirectory
  private let removeItem: RemoveItem
  private let measureItem: MeasureItem
  private let measureAvailableCapacity: MeasureAvailableCapacity
  private var itemUsageBytes: [URL: Int64] = [:]
  private var reservedImports: [URL: StorageReservation] = [:]
  private var importQueue: [ImportBatch] = []
  private var importWorker: Task<Void, Never>?
  private var importGeneration: UInt = 0
  private var usageMutationGeneration: UInt = 0
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
    self.storagePolicy = storagePolicy
    dir = base
    refreshStorage()
  }

  var urls: [URL] { items.map(\.url) }
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

  func setDropTarget(_ id: UUID, active: Bool) {
    dropState.setTarget(id, active: active)
  }

  func requestPresentation() { presentationRequest = UUID() }

  func consumePresentationRequest(_ id: UUID) {
    guard presentationRequest == id else { return }
    presentationRequest = nil
  }

  func retryStorage() { refreshStorage() }

  func revealStorageLocation() {
    let location = isStorageAvailable ? dir : dir.deletingLastPathComponent()
    guard NSWorkspace.shared.open(location) else {
      lastError = "Couldn't open the Shelf storage location."
      return
    }
    lastError = nil
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
      storageFailure = nil
      lastError = nil
      setItems(from: found)
    case .failure(let error):
      setStorageFailure(.listing, error: error)
    }
  }

  private func setItems(from found: [URL]) {
    items = found.filter { !isStagingURL($0) }
      .sorted { modDate($0) < modDate($1) }
      .map { ShelfItem(id: UUID(), url: $0, name: $0.lastPathComponent, thumbnail: nil) }
    for item in items { generateThumbnail(id: item.id, url: item.url) }
    usageMutationGeneration &+= 1
    itemUsageBytes = [:]
    currentUsageBytes = nil
    scheduleUsageScan()
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

  private func setStorageFailure(_ failure: ShelfStorageFailure, error: Error) {
    items = []
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
    let result = await add(source, updatesLastError: true)
    return result.error == nil
  }

  private func add(
    _ source: URL, updatesLastError: Bool,
    expectedImportGeneration: UInt? = nil
  ) async -> (item: ShelfItem?, error: String?, rejectedBytes: Int64?) {
    if let expectedImportGeneration, expectedImportGeneration != importGeneration {
      return (nil, nil, nil)
    }
    guard isStorageAvailable else {
      let error = "Shelf storage is unavailable."
      setImportError(error, rejectedBytes: nil, updatesLastError: updatesLastError)
      return (nil, error, nil)
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
    guard source.isFileURL else {
      let error = "Only files and folders can be added."
      setImportError(error, rejectedBytes: nil, updatesLastError: updatesLastError)
      return (nil, error, nil)
    }
    guard FileManager.default.fileExists(atPath: source.path) else {
      let error = "That item is no longer available."
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
    guard await refreshUsageForImport(expectedImportGeneration: expectedImportGeneration) else {
      guard importIsCurrent(expectedImportGeneration) else { return (nil, nil, nil) }
      let error = "Couldn't calculate current Shelf storage usage."
      setImportError(error, rejectedBytes: estimatedBytes, updatesLastError: updatesLastError)
      return (nil, error, estimatedBytes)
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

    let dest = reserveDestination(named: source.lastPathComponent, bytes: estimatedBytes)
    defer { reservedImports.removeValue(forKey: dest) }
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
        return (nil, nil, nil)
      }
      switch moveResult {
      case .success:
        if updatesLastError {
          lastError = nil
          lastRejectedImportBytes = nil
        }
        let item = ShelfItem(id: UUID(), url: dest, name: dest.lastPathComponent, thumbnail: nil)
        items.append(item)
        usageMutationGeneration &+= 1
        itemUsageBytes[dest] = stagedBytes
        currentUsageBytes = ShelfLogic.totalBytes(itemUsageBytes.values)
        generateThumbnail(id: item.id, url: item.url)
        return (item, nil, nil)
      case .failure(let error):
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
    let result: Result<Void, Error> = await Task.detached(priority: .utility) {
      Result { try FileManager.default.removeItem(at: item.url) }
    }.value
    switch result {
    case .success:
      items.removeAll { $0.id == item.id }
      didRemoveStoredItem(at: item.url)
      lastError = nil
      lastRejectedImportBytes = nil
    case .failure(let error as CocoaError) where error.code == .fileNoSuchFile:
      // Finder or another process may already have removed the persistent copy. The requested
      // final state is still achieved, so do not strand a ghost tile on the Shelf.
      items.removeAll { $0.id == item.id }
      didRemoveStoredItem(at: item.url)
      lastError = nil
      lastRejectedImportBytes = nil
    case .failure(let error):
      lastError = "Couldn’t remove \(item.name)."
      Log.app.error("Shelf removal failed: \(error.localizedDescription)")
    }
  }

  func clear() async {
    guard !isClearing else { return }
    isClearing = true
    defer { isClearing = false }
    await cancelPendingImports()
    let current = items
    let originalIDs = Set(current.map(\.id))
    let removedIDs: Set<UUID> = await Task.detached(priority: .utility) {
      var removed: Set<UUID> = []
      for item in current {
        do {
          try FileManager.default.removeItem(at: item.url)
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
    items.removeAll { removedIDs.contains($0.id) }
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
  }

  func open(_ item: ShelfItem) {
    guard NSWorkspace.shared.open(item.url) else {
      lastError = "Couldn’t open \(item.name)."
      return
    }
    lastError = nil
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

  private func reserveDestination(named name: String, bytes: Int64) -> URL {
    var candidate = name
    var i = 1
    let stem = (name as NSString).deletingPathExtension
    let ext = (name as NSString).pathExtension
    while FileManager.default.fileExists(atPath: dir.appendingPathComponent(candidate).path)
      || reservedImports[dir.appendingPathComponent(candidate)] != nil
    {
      candidate = ext.isEmpty ? "\(stem) \(i)" : "\(stem) \(i).\(ext)"
      i += 1
    }
    let destination = dir.appendingPathComponent(candidate)
    reservedImports[destination] = StorageReservation(bytes: bytes, isStaged: false)
    return destination
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

  private func generateThumbnail(id: UUID, url: URL) {
    // Uses the async API so we never pass a non-Sendable QL representation across an actor hop.
    Task {
      let request = QLThumbnailGenerator.Request(
        fileAt: url, size: CGSize(width: 120, height: 120), scale: 2,
        representationTypes: .all)
      guard
        let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request),
        let data = Self.pngData(from: rep.cgImage)
      else { return }
      await MainActor.run { [weak self] in self?.setThumbnail(data, id: id) }
    }
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
    importQueue.append(ImportBatch(urls: fileURLs, generation: importGeneration))
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
          url, updatesLastError: false, expectedImportGeneration: generation)
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
