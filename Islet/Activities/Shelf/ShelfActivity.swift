import Combine
import SwiftUI

/// Surfaces the file shelf in the island: a tray indicator in the compact view and a drop grid
/// (open, drag-out, and AirDrop) when expanded. Active while it holds files or a drop is underway.
@MainActor
final class ShelfActivity: NotchActivity, ObservableObject {
  let id = "shelf"
  let priority = ActivityPriority.ambient
  let tabIcon = "tray.full.fill"
  let isAvailableWhenInactive = true
  private(set) var activationDate: Date?

  private let model = ShelfModel.shared
  private var cancellables: Set<AnyCancellable> = []
  private var isMonitoring = false

  var isActive: Bool { !model.items.isEmpty || model.isDropPresentationActive }

  func start() {
    guard !isMonitoring else { return }
    isMonitoring = true
    model.objectWillChange
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in
        guard let self else { return }
        if self.isActive, self.activationDate == nil { self.activationDate = Date() }
        if !self.isActive { self.activationDate = nil }
        self.objectWillChange.send()
      }
      .store(in: &cancellables)
  }

  func stop() {
    guard isMonitoring else { return }
    isMonitoring = false
    cancellables.removeAll()
    activationDate = nil
    objectWillChange.send()
  }

  var compactLeading: AnyView {
    AnyView(Image(systemName: "tray.full.fill").appThemeForeground(.shelf).font(.caption2))
  }

  var compactTrailing: AnyView {
    AnyView(
      Text("\(model.items.count)")
        .font(.caption.weight(.semibold)).monospacedDigit().appThemeForeground(.shelf))
  }

  var expandedView: AnyView { AnyView(ShelfView(model: model)) }
}

struct ShelfView: View {
  @ObservedObject var model: ShelfModel
  @Environment(\.appTheme) private var appTheme

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Label("Shelf", systemImage: "tray.full.fill")
          .font(.caption.weight(.semibold)).appThemeForeground(.shelf)
        Spacer()
        if model.pendingImportCount > 0 {
          ProgressView()
            .controlSize(.small)
            .help(
              "Adding \(model.pendingImportCount) item\(model.pendingImportCount == 1 ? "" : "s")"
            )
            .accessibilityLabel("Adding files to Shelf")
            .accessibilityValue("\(model.pendingImportCount) remaining")
        }
        if !model.items.isEmpty {
          Button {
            airdropAll()
          } label: {
            Image(systemName: "square.and.arrow.up")
          }
          .buttonStyle(.plain)
          .help("Share all Shelf items with AirDrop")
          .accessibilityLabel("AirDrop all Shelf items")
          Button {
            Task { await model.clear() }
          } label: {
            Image(systemName: "trash")
          }
          .buttonStyle(.plain)
          .help("Remove all Shelf items")
          .accessibilityLabel("Clear Shelf")
        }
      }

      if let error = model.lastError {
        HStack(spacing: 5) {
          Image(systemName: "exclamationmark.triangle.fill")
          Text(error).lineLimit(1)
          Spacer(minLength: 0)
          Button("Dismiss") { model.dismissError() }.buttonStyle(.link)
        }
        .font(.caption2)
        .foregroundStyle(.orange)
        .accessibilityElement(children: .combine)
      }

      if model.items.isEmpty {
        RoundedRectangle(cornerRadius: 10)
          .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5]))
          .foregroundStyle(.secondary)
          .overlay {
            VStack(spacing: 4) {
              Image(systemName: "arrow.down.doc")
              Text("Drop files here").font(.caption)
            }
            .foregroundStyle(.secondary)
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 10) {
            ForEach(model.items) { item in
              ShelfItemView(item: item, model: model)
            }
          }
          .padding(.bottom, 2)
        }
      }
    }
    .foregroundStyle(.white)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .contentShape(Rectangle())
    .overlay {
      if model.isDragActive {
        RoundedRectangle(cornerRadius: 12)
          .strokeBorder(appTheme.color(for: .shelf), lineWidth: 2)
      }
    }
  }

  private func airdropAll() {
    guard let service = NSSharingService(named: .sendViaAirDrop) else { return }
    // The observer is what makes the "AirDrop sent" event source fire on completion.
    AirDropShareObserver.observe(service)
    service.perform(withItems: model.urls)
  }
}

struct ShelfItemView: View {
  let item: ShelfItem
  @ObservedObject var model: ShelfModel
  @State private var hovering = false
  @State private var thumbnailImage: NSImage?

  var body: some View {
    VStack(spacing: 3) {
      ZStack(alignment: .topTrailing) {
        Button {
          model.open(item)
        } label: {
          ZStack {
            RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.08))
            if let img = thumbnailImage {
              Image(nsImage: img).resizable().aspectRatio(contentMode: .fit).padding(4)
            } else {
              Image(systemName: "doc").font(.title2).foregroundStyle(.secondary)
            }
          }
        }
        .buttonStyle(.plain)
        .frame(width: 56, height: 56)
        .accessibilityLabel("Open \(item.name)")
        .accessibilityHint("Drag to copy it into another app")
        .help("Open \(item.name)")

        Button {
          Task { await model.remove(item) }
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.white, .black.opacity(0.6))
        }
        .buttonStyle(.plain)
        .opacity(hovering ? 1 : 0.6)
        .offset(x: 4, y: -4)
        .accessibilityLabel("Remove \(item.name) from Shelf")
      }
      Text(item.name).font(.system(size: 9)).lineLimit(1).frame(width: 60)
    }
    .onHover { hovering = $0 }
    .onAppear { updateThumbnail() }
    .onChange(of: item.thumbnail) { _, _ in updateThumbnail() }
    .accessibilityElement(children: .contain)
    .contextMenu {
      Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
      Button("Remove from Shelf", role: .destructive) {
        Task { await model.remove(item) }
      }
    }
    // Drag back out to Finder / other apps.
    .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
  }

  private func updateThumbnail() {
    thumbnailImage = item.thumbnail.flatMap(NSImage.init(data:))
  }
}
