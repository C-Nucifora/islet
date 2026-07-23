import AppKit
import Combine
import Defaults
import SwiftUI

struct ClipboardItem: Identifiable, Equatable {
  enum Kind: Equatable {
    case text(String)
    case fileURL(URL)
    case image(Data)
  }
  let id = UUID()
  let kind: Kind
  let date: Date

  var icon: String {
    switch kind {
    case .text: "text.alignleft"
    case .fileURL: "doc"
    case .image: "photo"
    }
  }

  var preview: String {
    switch kind {
    case .text(let s): s.trimmingCharacters(in: .whitespacesAndNewlines)
    case .fileURL(let url): url.lastPathComponent
    case .image: "Image"
    }
  }
}

/// Session-only clipboard history: polls the pasteboard, keeps recent copies, and lets you re-copy.
/// Off by default (it would otherwise capture everything copied, including passwords).
@MainActor
final class ClipboardModel: ObservableObject {
  static let shared = ClipboardModel()

  @Published private(set) var items: [ClipboardItem] = []
  private let maxItems = 20
  private var lastChange = NSPasteboard.general.changeCount
  private var ownWriteChange = -1
  private var timer: AnyCancellable?
  private var cancellables: Set<AnyCancellable> = []

  func start() {
    if Defaults[.clipboardEnabled] { startPolling() }
    Defaults.publisher(.clipboardEnabled)
      .dropFirst()
      .sink { [weak self] change in
        if change.newValue { self?.startPolling() } else { self?.stopPolling() }
      }
      .store(in: &cancellables)
  }

  private func startPolling() {
    lastChange = NSPasteboard.general.changeCount
    timer = Timer.publish(every: 0.7, on: .main, in: .common).autoconnect()
      .sink { [weak self] _ in self?.poll() }
  }

  private func stopPolling() {
    timer = nil
    items = []
  }

  private func poll() {
    let pb = NSPasteboard.general
    guard pb.changeCount != lastChange else { return }
    lastChange = pb.changeCount
    guard pb.changeCount != ownWriteChange else { return }  // ignore our own re-copy
    capture(pb)
  }

  private func capture(_ pb: NSPasteboard) {
    let item: ClipboardItem?
    if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL],
      let url = urls.first, url.isFileURL
    {
      item = ClipboardItem(kind: .fileURL(url), date: Date())
    } else if let str = pb.string(forType: .string),
      !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      item = ClipboardItem(kind: .text(str), date: Date())
    } else if let data = pb.data(forType: .tiff) ?? pb.data(forType: .png) {
      item = ClipboardItem(kind: .image(data), date: Date())
    } else {
      item = nil
    }
    guard let item else { return }
    items.removeAll { $0.kind == item.kind }
    items.insert(item, at: 0)
    if items.count > maxItems { items = Array(items.prefix(maxItems)) }
  }

  func copyBack(_ item: ClipboardItem) {
    let pb = NSPasteboard.general
    pb.clearContents()
    switch item.kind {
    case .text(let s): pb.setString(s, forType: .string)
    case .fileURL(let url): pb.writeObjects([url as NSURL])
    case .image(let data): pb.setData(data, forType: .tiff)
    }
    ownWriteChange = pb.changeCount
    lastChange = pb.changeCount
    items.removeAll { $0.id == item.id }
    items.insert(item, at: 0)
  }

  func remove(_ item: ClipboardItem) { items.removeAll { $0.id == item.id } }
  func clear() { items = [] }
}

@MainActor
final class ClipboardActivity: NotchActivity, ObservableObject {
  let id = "clipboard"
  let priority = ActivityPriority.ambient
  let tabIcon = "doc.on.clipboard"
  private(set) var activationDate: Date?

  private let model = ClipboardModel.shared
  private var cancellables: Set<AnyCancellable> = []

  var isActive: Bool { Defaults[.clipboardEnabled] && !model.items.isEmpty }

  func start() {
    model.start()
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
    AnyView(Image(systemName: "doc.on.clipboard").foregroundStyle(.purple).font(.caption2))
  }
  var compactTrailing: AnyView {
    AnyView(
      Text("\(model.items.count)")
        .font(.caption.weight(.semibold)).monospacedDigit().foregroundStyle(.purple))
  }
  var expandedView: AnyView { AnyView(ClipboardView(model: model)) }
}

struct ClipboardView: View {
  @ObservedObject var model: ClipboardModel

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Label("Clipboard", systemImage: "doc.on.clipboard")
          .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        Spacer()
        if !model.items.isEmpty {
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
        Text("Nothing copied yet").font(.caption).foregroundStyle(.secondary)
      } else {
        ScrollView(.vertical, showsIndicators: false) {
          VStack(spacing: 4) {
            ForEach(model.items) { item in
              Button {
                Haptics.perform()
                model.copyBack(item)
              } label: {
                HStack(spacing: 8) {
                  Image(systemName: item.icon).font(.caption2).foregroundStyle(.purple)
                    .frame(width: 16)
                  Text(item.preview).font(.caption).lineLimit(1)
                  Spacer(minLength: 0)
                  Image(systemName: "doc.on.doc").font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.vertical, 3).padding(.horizontal, 6)
                .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.06)))
                .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
            }
          }
        }
      }
    }
    .foregroundStyle(.white)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}
