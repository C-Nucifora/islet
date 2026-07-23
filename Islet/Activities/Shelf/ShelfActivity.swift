import Combine
import SwiftUI
import UniformTypeIdentifiers

/// Surfaces the file shelf in the island: a tray indicator in the compact view and a drop grid
/// (drag-out + AirDrop) when expanded. Active while it holds files or a drag is hovering the notch.
@MainActor
final class ShelfActivity: NotchActivity, ObservableObject {
  let id = "shelf"
  let priority = ActivityPriority.ambient
  let tabIcon = "tray.full.fill"
  private(set) var activationDate: Date?

  private let model = ShelfModel.shared
  private var cancellables: Set<AnyCancellable> = []

  var isActive: Bool { !model.items.isEmpty || model.isDragActive }

  func start() {
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

  var compactLeading: AnyView {
    AnyView(Image(systemName: "tray.full.fill").foregroundStyle(.blue).font(.caption2))
  }

  var compactTrailing: AnyView {
    AnyView(
      Text("\(model.items.count)")
        .font(.caption.weight(.semibold)).monospacedDigit().foregroundStyle(.blue))
  }

  var expandedView: AnyView { AnyView(ShelfView(model: model)) }
}

struct ShelfView: View {
  @ObservedObject var model: ShelfModel
  @State private var targeted = false

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Label("Shelf", systemImage: "tray.full.fill")
          .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        Spacer()
        if !model.items.isEmpty {
          Button {
            Haptics.perform()
            airdropAll()
          } label: {
            Image(systemName: "square.and.arrow.up")
          }
          .buttonStyle(.plain)
          Button {
            Haptics.perform(.levelChange)
            model.clear()
          } label: {
            Image(systemName: "trash")
          }
          .buttonStyle(.plain)
        }
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
    .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
      ShelfModel.loadURLs(from: providers) { url in
        Task { @MainActor in model.add(url) }
      }
      return true
    }
    .overlay {
      if targeted {
        RoundedRectangle(cornerRadius: 12).strokeBorder(.blue, lineWidth: 2)
      }
    }
  }

  private func airdropAll() {
    NSSharingService(named: .sendViaAirDrop)?.perform(withItems: model.urls)
  }
}

struct ShelfItemView: View {
  let item: ShelfItem
  @ObservedObject var model: ShelfModel
  @State private var hovering = false

  var body: some View {
    VStack(spacing: 3) {
      ZStack {
        RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.08))
        if let data = item.thumbnail, let img = NSImage(data: data) {
          Image(nsImage: img).resizable().aspectRatio(contentMode: .fit).padding(4)
        } else {
          Image(systemName: "doc").font(.title2).foregroundStyle(.secondary)
        }
      }
      .frame(width: 56, height: 56)
      .overlay(alignment: .topTrailing) {
        if hovering {
          Button {
            Haptics.perform()
            model.remove(item)
          } label: {
            Image(systemName: "xmark.circle.fill")
              .foregroundStyle(.white, .black.opacity(0.6))
          }
          .buttonStyle(.plain)
          .offset(x: 4, y: -4)
        }
      }
      Text(item.name).font(.system(size: 9)).lineLimit(1).frame(width: 60)
    }
    .onHover { hovering = $0 }
    // Drag back out to Finder / other apps.
    .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
  }
}
