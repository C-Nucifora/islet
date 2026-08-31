import AppKit
import Quartz
import UniformTypeIdentifiers

@MainActor
final class ShelfDragItemProvider: NSItemProvider, @unchecked Sendable {
  private let releaseLease: @MainActor @Sendable () -> Void

  init(item: ShelfItem, releaseLease: @escaping @MainActor @Sendable () -> Void) {
    self.releaseLease = releaseLease
    super.init(item: item.url as NSURL, typeIdentifier: UTType.fileURL.identifier)
    let contentType =
      (try? item.url.resourceValues(forKeys: [.contentTypeKey]).contentType) ?? .data
    registerFileRepresentation(
      forTypeIdentifier: contentType.identifier, fileOptions: [.openInPlace], visibility: .all
    ) { completion in
      completion(item.url, true, nil)
      return nil
    }
  }

  required init?(coder _: NSCoder) {
    nil
  }

  deinit {
    let releaseLease = releaseLease
    Task { @MainActor in releaseLease() }
  }
}

@MainActor
final class ShelfQuickLookController: NSObject, @preconcurrency QLPreviewPanelDataSource,
  QLPreviewPanelDelegate
{
  private var item: ShelfItem?
  private var onClose: (() -> Void)?

  func present(_ item: ShelfItem, onClose: @escaping () -> Void) -> Bool {
    guard FileManager.default.fileExists(atPath: item.url.path),
      let panel = QLPreviewPanel.shared()
    else { return false }
    finishPreview()
    self.item = item
    self.onClose = onClose
    panel.dataSource = self
    panel.delegate = self
    panel.currentPreviewItemIndex = 0
    panel.reloadData()
    panel.makeKeyAndOrderFront(nil)
    return true
  }

  func numberOfPreviewItems(in _: QLPreviewPanel!) -> Int {
    item == nil ? 0 : 1
  }

  func previewPanel(_: QLPreviewPanel!, previewItemAt _: Int) -> any QLPreviewItem {
    (item?.url ?? URL(fileURLWithPath: "/")) as NSURL
  }

  func previewPanelWillClose(_: QLPreviewPanel!) {
    finishPreview()
  }

  func close(itemID: UUID) {
    guard item?.id == itemID else { return }
    QLPreviewPanel.shared()?.orderOut(nil)
    finishPreview()
  }

  private func finishPreview() {
    guard item != nil || onClose != nil else { return }
    item = nil
    let completion = onClose
    onClose = nil
    completion?()
  }
}
