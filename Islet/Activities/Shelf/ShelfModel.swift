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
  static let maximumItemCount = 100

  @Published private(set) var items: [ShelfItem] = []
  @Published private(set) var lastError: String?
  /// True while a file drag is hovering the notch, so the UI can reveal the shelf.
  @Published var isDragActive = false

  private let dir: URL
  private var reservedDestinations: Set<URL> = []

  init() {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Islet/Shelf", isDirectory: true)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    dir = base
    load()
  }

  var urls: [URL] { items.map(\.url) }

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

  /// Extracts file URLs from dropped item providers; `add` is called per URL (off-main).
  nonisolated static func loadURLs(
    from providers: [NSItemProvider], add: @escaping @Sendable (URL) -> Void
  ) {
    for provider in providers {
      _ = provider.loadObject(ofClass: URL.self) { url, _ in
        if let url { add(url) }
      }
    }
  }
}

enum ShelfLogic {
  static func hasCapacity(currentCount: Int, pendingCount: Int, maximum: Int) -> Bool {
    guard currentCount >= 0, pendingCount >= 0, maximum > 0 else { return false }
    return currentCount + pendingCount < maximum
  }
}
