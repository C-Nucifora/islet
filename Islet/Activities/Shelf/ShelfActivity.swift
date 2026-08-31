import Combine
import SwiftUI

private struct ShelfDropTargetedEnvironmentKey: EnvironmentKey {
  static let defaultValue = false
}

extension EnvironmentValues {
  var shelfDropTargeted: Bool {
    get { self[ShelfDropTargetedEnvironmentKey.self] }
    set { self[ShelfDropTargetedEnvironmentKey.self] = newValue }
  }
}

/// Surfaces the file shelf in the island: a tray indicator in the compact view and a drop grid
/// (open, drag-out, and AirDrop) when expanded. Active while it holds files or a drop is underway.
@MainActor
final class ShelfActivity: NotchActivity, ObservableObject {
  let id = "shelf"
  let priority = ActivityPriority.ambient
  let tabIcon = "tray.full.fill"
  let isAvailableWhenInactive = true
  private(set) var activationDate: Date?

  private let model: ShelfModel
  let airDrop: AirDropShareController
  private var cancellables: Set<AnyCancellable> = []
  private var isMonitoring = false

  init(
    model: ShelfModel = .shared,
    airDrop: AirDropShareController = AirDropShareController()
  ) {
    self.model = model
    self.airDrop = airDrop
  }

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

  var shelfView: ShelfView { ShelfView(model: model, airDrop: airDrop) }
  var expandedView: AnyView { AnyView(shelfView) }
}

struct ShelfView: View {
  @ObservedObject var model: ShelfModel
  @ObservedObject var airDrop: AirDropShareController
  @Environment(\.appTheme) private var appTheme
  @Environment(\.shelfDropTargeted) private var shelfDropTargeted
  @State private var isCreatingStack = false
  @State private var newStackName = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Label("Shelf", systemImage: "tray.full.fill")
          .font(.caption.weight(.semibold)).appThemeForeground(.shelf)
        Menu {
          ForEach(model.stacks) { stack in
            Button {
              model.selectedStackID = stack.id
            } label: {
              if model.selectedStackID == stack.id {
                Label(stack.name, systemImage: "checkmark")
              } else {
                Text(stack.name)
              }
            }
          }
          Divider()
          Button("New Workspace…") { isCreatingStack = true }
        } label: {
          Text(model.selectedStack?.name ?? "Workspace")
            .font(.caption2.weight(.medium))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
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
            model.shareAllItems(using: airDrop)
          } label: {
            if airDrop.isSharing {
              ProgressView().controlSize(.small)
            } else {
              Image(systemName: "square.and.arrow.up")
            }
          }
          .buttonStyle(.plain)
          .disabled(!airDrop.isActionEnabled)
          .help(airDropHelp)
          .accessibilityLabel("AirDrop all Shelf items")
          .accessibilityHint(airDropHint)
          Button {
            Task { await model.cleanupStorage() }
          } label: {
            Image(systemName: "sparkles")
          }
          .buttonStyle(.plain)
          .help("Remove expired and missing Shelf items")
          .accessibilityLabel("Clean up Shelf storage")
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

      if isCreatingStack {
        HStack(spacing: 5) {
          TextField("Workspace name", text: $newStackName)
            .textFieldStyle(.roundedBorder)
            .font(.caption)
            .onSubmit { createStack() }
          Button("Add") { createStack() }.buttonStyle(.bordered)
          Button("Cancel") {
            newStackName = ""
            isCreatingStack = false
          }.buttonStyle(.plain)
        }
      }

      if model.isStorageAvailable {
        HStack(spacing: 4) {
          HStack(spacing: 4) {
            Image(systemName: "externaldrive")
            Text(model.storageUsageText)
          }
          .accessibilityElement(children: .ignore)
          .accessibilityLabel(model.storageUsageAccessibilityText)
          Spacer(minLength: 4)
          workspaceOptions
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
      }

      if let storageFailure = model.storageFailure {
        HStack(spacing: 5) {
          Image(systemName: "externaldrive.badge.exclamationmark")
          Text(storageFailure.message).lineLimit(2)
          Spacer(minLength: 0)
          Button("Retry") { model.retryStorage() }.buttonStyle(.link)
          if model.canRevealStorageLocation {
            Button("Reveal") { model.revealStorageLocation() }.buttonStyle(.link)
          }
        }
        .font(.caption2)
        .foregroundStyle(.orange)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Shelf storage unavailable. \(storageFailure.message)")
      } else if let error = model.lastError {
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

      if let airDropFeedback {
        HStack(spacing: 5) {
          Image(systemName: airDropFeedback.icon)
          Text(airDropFeedback.message).lineLimit(2)
          Spacer(minLength: 0)
          if airDropFeedback.canRetry {
            Button("Try Again") { model.shareAllItems(using: airDrop) }.buttonStyle(.link)
          }
          if airDropFeedback.canDismiss {
            Button("Dismiss") { airDrop.dismissFeedback() }.buttonStyle(.link)
          }
        }
        .font(.caption2)
        .foregroundStyle(airDropFeedback.isFailure ? .orange : .secondary)
        .accessibilityElement(children: .contain)
      }

      if model.isStorageAvailable, model.selectedItems.isEmpty {
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
          LazyHStack(spacing: 10) {
            ForEach(model.selectedItems) { item in
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
    .onAppear { airDrop.refreshAvailability() }
    .overlay {
      if shelfDropTargeted {
        RoundedRectangle(cornerRadius: 12)
          .strokeBorder(appTheme.color(for: .shelf), lineWidth: 2)
      }
    }
  }

  private var airDropHelp: String {
    if !airDrop.isServiceAvailable { return "AirDrop is unavailable on this Mac" }
    if airDrop.isSharing { return "AirDrop share in progress" }
    if airDrop.state == .busy { return "Another AirDrop share is in progress" }
    return "Share all Shelf items with AirDrop"
  }

  private var airDropHint: String {
    if !airDrop.isServiceAvailable { return "AirDrop is unavailable" }
    if airDrop.isSharing { return "Wait for the current share to finish" }
    if airDrop.state == .busy { return "Another Shelf share must finish first" }
    return "Opens AirDrop for every item on the Shelf"
  }

  private var airDropFeedback: AirDropFeedback? {
    switch airDrop.state {
    case .ready, .sharing: nil
    case .unavailable:
      .init(
        icon: "airplayaudio.badge.exclamationmark", message: "AirDrop is unavailable on this Mac.",
        isFailure: true, canRetry: false, canDismiss: false)
    case .cancelled:
      .init(
        icon: "xmark.circle", message: "AirDrop was cancelled. Your Shelf items are still here.",
        isFailure: false, canRetry: true, canDismiss: true)
    case .busy:
      .init(
        icon: "hourglass", message: "Another AirDrop share is still in progress.",
        isFailure: false, canRetry: false, canDismiss: true)
    case .failed(let reason):
      .init(
        icon: "exclamationmark.triangle.fill",
        message: "AirDrop failed: \(reason) Your Shelf items are still here.",
        isFailure: true, canRetry: true, canDismiss: true)
    }
  }

  private struct AirDropFeedback {
    let icon: String
    let message: String
    let isFailure: Bool
    let canRetry: Bool
    let canDismiss: Bool
  }

  private var workspaceOptions: some View {
    Menu {
      Menu("Expire items") {
        ForEach(ShelfExpiryRule.allCases) { rule in
          Button {
            guard let stack = model.selectedStack else { return }
            Task { await model.setExpiryRule(rule, for: stack) }
          } label: {
            if model.selectedStack?.expiryRule == rule {
              Label(rule.title, systemImage: "checkmark")
            } else {
              Text(rule.title)
            }
          }
        }
      }
      Menu("Same file") {
        ForEach(ShelfSameFileDuplicatePolicy.allCases) { policy in
          Button {
            Task { await model.setSameFileDuplicatePolicy(policy) }
          } label: {
            if model.sameFileDuplicatePolicy == policy {
              Label(policy.title, systemImage: "checkmark")
            } else {
              Text(policy.title)
            }
          }
        }
      }
      Menu("Same name") {
        ForEach(ShelfSameNameDuplicatePolicy.allCases) { policy in
          Button {
            Task { await model.setSameNameDuplicatePolicy(policy) }
          } label: {
            if model.sameNameDuplicatePolicy == policy {
              Label(policy.title, systemImage: "checkmark")
            } else {
              Text(policy.title)
            }
          }
        }
      }
    } label: {
      Image(systemName: "ellipsis.circle")
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
    .accessibilityLabel("Shelf workspace options")
    .help("Workspace, expiry, and duplicate options")
  }

  private func createStack() {
    let name = newStackName
    Task {
      guard await model.createStack(named: name) != nil else { return }
      newStackName = ""
      isCreatingStack = false
    }
  }
}

struct ShelfItemView: View {
  let item: ShelfItem
  @ObservedObject var model: ShelfModel
  @State private var hovering = false
  @State private var thumbnailImage: NSImage?
  @State private var thumbnailVisibilityOwner = UUID()

  var body: some View {
    VStack(spacing: 3) {
      ZStack(alignment: .topTrailing) {
        Button {
          model.quickLook(item)
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
        .accessibilityLabel("Quick Look \(item.name)")
        .accessibilityHint("Opens a preview of this Shelf item")
        .help("Quick Look \(item.name)")

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
      if let expiry = model.expirationText(for: item) {
        Text(expiry)
          .font(.system(size: 8))
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .frame(width: 70)
      }
    }
    .onHover { hovering = $0 }
    .onAppear {
      model.setThumbnailVisibility(
        for: item, owner: thumbnailVisibilityOwner, isVisible: true)
      updateThumbnail()
    }
    .onDisappear {
      model.setThumbnailVisibility(
        for: item, owner: thumbnailVisibilityOwner, isVisible: false)
    }
    .onChange(of: item.thumbnail) { _, _ in updateThumbnail() }
    .accessibilityElement(children: .contain)
    .contextMenu {
      Button("Quick Look") { model.quickLook(item) }
      Button("Open") { model.open(item) }
      Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
      Menu("Move to Workspace") {
        ForEach(model.stacks.filter { $0.id != item.stackID }) { stack in
          Button(stack.name) { Task { await model.move(item, to: stack) } }
        }
      }
      Button("Remove from Shelf", role: .destructive) {
        Task { await model.remove(item) }
      }
    }
    // Drag back out to Finder / other apps.
    .onDrag { model.itemProvider(for: item) }
  }

  private func updateThumbnail() {
    thumbnailImage = item.thumbnail.flatMap(NSImage.init(data:))
  }
}
