import AppKit
import QuickLookThumbnailing
import SwiftUI

struct ShelfItem: Identifiable, Equatable, Sendable {
  let id: UUID
  let url: URL
  let name: String
  var thumbnail: Data?  // PNG; Sendable-friendly so it can cross the QL callback boundary
}

/// A temporary file tray: dropped files are copied into app storage, thumbnailed, and can be
/// dragged back out or AirDropped. Persists across launches.
@MainActor
final class ShelfModel: ObservableObject {
  static let shared = ShelfModel()
  nonisolated static let maximumItemCount = 100

  @Published private(set) var items: [ShelfItem] = []
  @Published private(set) var lastError: String?
  @Published private var dropState = ShelfDropState()
  @Published private(set) var presentationRequest: UUID?

  private let dir: URL
  private var reservedDestinations: Set<URL> = []

  init(directory: URL? = nil) {
    let base =
      directory
      ?? FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
      )[0].appendingPathComponent("Islet/Shelf", isDirectory: true)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    dir = base
    load()
  }

  var urls: [URL] { items.map(\.url) }
  /// True while at least one notch window is under the current file drag.
  var isDragActive: Bool { dropState.isTargeted }
  /// Keeps the Shelf selected until every provider resolves and every copy finishes.
  var isDropPresentationActive: Bool { dropState.isActive }
  var pendingImportCount: Int { dropState.pendingImportCount }

  func setDropTarget(_ id: UUID, active: Bool) {
    dropState.setTarget(id, active: active)
  }

  func requestPresentation() { presentationRequest = UUID() }

  func consumePresentationRequest(_ id: UUID) {
    guard presentationRequest == id else { return }
    presentationRequest = nil
  }

  private func load() {
    let found =
      (try? FileManager.default.contentsOfDirectory(
        at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
    items = found.sorted { modDate($0) < modDate($1) }
      .map { ShelfItem(id: UUID(), url: $0, name: $0.lastPathComponent, thumbnail: nil) }
    for item in items { generateThumbnail(id: item.id, url: item.url) }
  }

  private func modDate(_ url: URL) -> Date {
    (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
      ?? .distantPast
  }

  /// Copies a dropped item away from the main actor. Large files should never freeze the notch's
  /// hover/click animation while FileManager performs disk I/O.
  @discardableResult
  func add(_ source: URL) async -> Bool {
    guard
      ShelfLogic.hasCapacity(
        currentCount: items.count, pendingCount: reservedDestinations.count,
        maximum: Self.maximumItemCount)
    else {
      lastError = "Shelf is full (\(Self.maximumItemCount) items)."
      return false
    }
    guard source.isFileURL else {
      lastError = "Only files and folders can be added."
      return false
    }
    guard FileManager.default.fileExists(atPath: source.path) else {
      lastError = "That item is no longer available."
      return false
    }

    let dest = reserveDestination(named: source.lastPathComponent)
    let result: Result<Void, Error> = await Task.detached(priority: .utility) {
      Result { try FileManager.default.copyItem(at: source, to: dest) }
    }.value
    reservedDestinations.remove(dest)

    switch result {
    case .success:
      lastError = nil
      let item = ShelfItem(id: UUID(), url: dest, name: dest.lastPathComponent, thumbnail: nil)
      items.append(item)
      generateThumbnail(id: item.id, url: item.url)
      return true
    case .failure(let error):
      // A file can disappear between Finder producing its drag payload and the async copy. Give a
      // useful, non-technical error while retaining the detailed failure in the log.
      lastError = "Couldn’t add \(source.lastPathComponent)."
      Log.app.error("Shelf copy failed: \(error.localizedDescription)")
      return false
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
    let current = items
    let removedIDs: Set<UUID> = await Task.detached(priority: .utility) {
      var removed: Set<UUID> = []
      for item in current {
        do {
          try FileManager.default.removeItem(at: item.url)
          removed.insert(item.id)
        } catch {
          Log.app.error("Shelf clear failed for \(item.name): \(error.localizedDescription)")
        }
      }
      return removed
    }.value
    items.removeAll { removedIDs.contains($0.id) }
    lastError = items.isEmpty ? nil : "Some Shelf items couldn’t be removed."
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
    let fileURLs = urls.filter(\.isFileURL)
    guard !fileURLs.isEmpty else { return false }

    dropState.beginImports(fileURLs.count)
    for url in fileURLs {
      Task { @MainActor [weak self] in
        guard let self else { return }
        defer { self.dropState.finishImport() }
        await self.add(url)
      }
    }
    return true
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
}

enum ShelfLogic {
  static func hasCapacity(currentCount: Int, pendingCount: Int, maximum: Int) -> Bool {
    guard currentCount >= 0, pendingCount >= 0, maximum > 0 else { return false }
    return currentCount + pendingCount < maximum
  }
}
