import AppKit
import QuickLookThumbnailing
import SwiftUI

struct ShelfItem: Identifiable, Equatable {
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

  @Published private(set) var items: [ShelfItem] = []
  /// True while a file drag is hovering the notch, so the UI can reveal the shelf.
  @Published var isDragActive = false

  private let dir: URL

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

  @discardableResult
  func add(_ source: URL) -> Bool {
    let dest = dir.appendingPathComponent(uniqueName(source.lastPathComponent))
    do {
      try FileManager.default.copyItem(at: source, to: dest)
      let item = ShelfItem(id: UUID(), url: dest, name: dest.lastPathComponent, thumbnail: nil)
      items.append(item)
      generateThumbnail(id: item.id, url: item.url)
      return true
    } catch {
      Log.app.error("Shelf copy failed: \(error.localizedDescription)")
      return false
    }
  }

  func remove(_ item: ShelfItem) {
    try? FileManager.default.removeItem(at: item.url)
    items.removeAll { $0.id == item.id }
  }

  func clear() {
    for item in items { try? FileManager.default.removeItem(at: item.url) }
    items = []
  }

  private func uniqueName(_ name: String) -> String {
    var candidate = name
    var i = 1
    let stem = (name as NSString).deletingPathExtension
    let ext = (name as NSString).pathExtension
    while FileManager.default.fileExists(atPath: dir.appendingPathComponent(candidate).path) {
      candidate = ext.isEmpty ? "\(stem) \(i)" : "\(stem) \(i).\(ext)"
      i += 1
    }
    return candidate
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
      await MainActor.run { ShelfModel.shared.setThumbnail(data, id: id) }
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
