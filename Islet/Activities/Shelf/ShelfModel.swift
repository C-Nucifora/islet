import AppKit
import QuickLookThumbnailing
import SwiftUI

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

  typealias CopyItem = @Sendable (URL, URL) async -> Result<Void, Error>
  typealias MoveItem = @Sendable (URL, URL) async -> Result<Void, Error>
  typealias CreateDirectory = @Sendable (URL) -> Result<Void, Error>
  typealias ListDirectory = @Sendable (URL) -> Result<[URL], Error>
  typealias RemoveItem = @Sendable (URL) -> Result<Void, Error>

  @Published private(set) var items: [ShelfItem] = []
  @Published private(set) var lastError: String?
  /// `nil` means the Shelf storage is available. It must not be inferred from an empty item list.
  @Published private(set) var storageFailure: ShelfStorageFailure?
  @Published private var dropState = ShelfDropState()
  @Published private(set) var presentationRequest: UUID?

  private let dir: URL
  private let copyItem: CopyItem
  private let moveItem: MoveItem
  private let createDirectory: CreateDirectory
  private let listDirectory: ListDirectory
  private let removeItem: RemoveItem
  private var reservedDestinations: Set<URL> = []
  private var importQueue: [ImportBatch] = []
  private var importWorker: Task<Void, Never>?
  private var importGeneration: UInt = 0
  private(set) var isClearing = false

  init(
    directory: URL? = nil,
    copyItem: CopyItem? = nil,
    moveItem: MoveItem? = nil,
    createDirectory: CreateDirectory? = nil,
    listDirectory: ListDirectory? = nil,
    removeItem: RemoveItem? = nil
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
  ) async -> (item: ShelfItem?, error: String?) {
    if let expectedImportGeneration, expectedImportGeneration != importGeneration {
      return (nil, nil)
    }
    guard isStorageAvailable else {
      let error = "Shelf storage is unavailable."
      if updatesLastError { lastError = error }
      return (nil, error)
    }
    guard
      ShelfLogic.hasCapacity(
        currentCount: items.count, pendingCount: reservedDestinations.count,
        maximum: Self.maximumItemCount)
    else {
      let error = "Shelf is full (\(Self.maximumItemCount) items)."
      if updatesLastError { lastError = error }
      return (nil, error)
    }
    guard source.isFileURL else {
      let error = "Only files and folders can be added."
      if updatesLastError { lastError = error }
      return (nil, error)
    }
    guard FileManager.default.fileExists(atPath: source.path) else {
      let error = "That item is no longer available."
      if updatesLastError { lastError = error }
      return (nil, error)
    }

    let dest = reserveDestination(named: source.lastPathComponent)
    defer { reservedDestinations.remove(dest) }
    let staging = stagingDestination()
    let result = await copyItem(source, staging)

    if let expectedImportGeneration, expectedImportGeneration != importGeneration {
      // A cancelled copy may finish after Clear. It only ever wrote to staging, so it was never
      // visible as a Shelf item.
      removeStagingItem(staging)
      return (nil, nil)
    }

    switch result {
    case .success:
      let moveResult = await moveItem(staging, dest)
      if let expectedImportGeneration, expectedImportGeneration != importGeneration {
        switch moveResult {
        case .success:
          // Clear may run while the rename is in flight. If the rename won that race, remove the
          // completed destination because it was never present in Clear's item snapshot.
          removeImportedItem(dest)
        case .failure:
          removeStagingItem(staging)
        }
        return (nil, nil)
      }
      switch moveResult {
      case .success:
        if updatesLastError { lastError = nil }
        let item = ShelfItem(id: UUID(), url: dest, name: dest.lastPathComponent, thumbnail: nil)
        items.append(item)
        generateThumbnail(id: item.id, url: item.url)
        return (item, nil)
      case .failure(let error):
        removeStagingItem(staging)
        let message = "Couldn’t add \(source.lastPathComponent)."
        if updatesLastError { lastError = message }
        Log.app.error("Shelf staged rename failed: \(error.localizedDescription)")
        return (nil, message)
      }
    case .failure(let error):
      // A failed copy can leave a partial file or directory. It is in staging, rather than the
      // visible destination, and cleanup makes the next launch safe even after a process crash.
      removeStagingItem(staging)
      // A file can disappear between Finder producing its drag payload and the async copy. Give a
      // useful, non-technical error while retaining the detailed failure in the log.
      let message = "Couldn’t add \(source.lastPathComponent)."
      if updatesLastError { lastError = message }
      Log.app.error("Shelf copy failed: \(error.localizedDescription)")
      return (nil, message)
    }
  }

  func remove(_ item: ShelfItem) async {
    let result: Result<Void, Error> = await Task.detached(priority: .utility) {
      Result { try FileManager.default.removeItem(at: item.url) }
    }.value
    switch result {
    case .success:
      items.removeAll { $0.id == item.id }
      lastError = nil
    case .failure(let error as CocoaError) where error.code == .fileNoSuchFile:
      // Finder or another process may already have removed the persistent copy. The requested
      // final state is still achieved, so do not strand a ghost tile on the Shelf.
      items.removeAll { $0.id == item.id }
      lastError = nil
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
    lastError =
      originalIDs.subtracting(removedIDs).isEmpty
      ? nil : "Some Shelf items couldn’t be removed."
  }

  func open(_ item: ShelfItem) {
    guard NSWorkspace.shared.open(item.url) else {
      lastError = "Couldn’t open \(item.name)."
      return
    }
    lastError = nil
  }

  func dismissError() { lastError = nil }

  private func reserveDestination(named name: String) -> URL {
    var candidate = name
    var i = 1
    let stem = (name as NSString).deletingPathExtension
    let ext = (name as NSString).pathExtension
    while FileManager.default.fileExists(atPath: dir.appendingPathComponent(candidate).path)
      || reservedDestinations.contains(dir.appendingPathComponent(candidate))
    {
      candidate = ext.isEmpty ? "\(stem) \(i)" : "\(stem) \(i).\(ext)"
      i += 1
    }
    let destination = dir.appendingPathComponent(candidate)
    reservedDestinations.insert(destination)
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
          lastError = error
        }
        dropState.finishImport()
      }
    }
    guard generation == importGeneration else { return }
    lastError = firstError
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

enum ShelfLogic {
  static func hasCapacity(currentCount: Int, pendingCount: Int, maximum: Int) -> Bool {
    guard currentCount >= 0, pendingCount >= 0, maximum > 0 else { return false }
    return currentCount + pendingCount < maximum
  }
}
