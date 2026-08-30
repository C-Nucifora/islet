import AppKit
import Combine
import SwiftUI

@MainActor
final class PulseActivity: NotchActivity, ObservableObject {
  let id = "pulse"
  let priority = ActivityPriority.agent
  let tabIcon = "waveform.path.ecg"
  private let center = PulseCenter.shared
  private var cancellable: AnyCancellable?

  init() {
    cancellable = center.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
  }

  var isActive: Bool { !center.items.isEmpty }
  var activationDate: Date? { center.primary?.createdAt }

  func start() { PulseServer.shared.start() }
  func stop() {
    PulseServer.shared.stop()
    center.removeAll()
  }

  var compactLeading: AnyView {
    AnyView(PulseCompactIcon(item: center.primary, fallbackSymbol: tabIcon))
  }

  var compactTrailing: AnyView {
    AnyView(
      Text(center.primary?.title ?? "Pulse")
        .font(.caption.weight(.semibold))
        .lineLimit(1)
        .frame(maxWidth: 110)
        .appThemeForeground(.pulse))
  }

  var expandedView: AnyView { AnyView(PulseExpandedView(center: center)) }
}

private struct PulseCompactIcon: View {
  @Environment(\.appTheme) private var appTheme
  let item: PulseItem?
  let fallbackSymbol: String

  var body: some View {
    Image(systemName: item?.symbol ?? fallbackSymbol)
      .font(.caption2)
      .foregroundStyle(color)
  }

  private var color: Color {
    if item?.state == .failed { return .red }
    if item?.state == .needsAction { return .orange }
    return appTheme.color(for: .pulse)
  }
}

struct PulseExpandedView: View {
  @ObservedObject var center: PulseCenter

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Label("Now", systemImage: "waveform.path.ecg")
          .font(.headline)
        Spacer()
        if center.hiddenItemCount > 0 {
          Text("\(center.hiddenItemCount) filtered")
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .accessibilityLabel("\(center.hiddenItemCount) Pulse items filtered")
        }
        Text("\(center.items.count)")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
          .accessibilityLabel("\(center.items.count) active items")
        Menu {
          Picker("Delivery", selection: $center.deliveryProfile) {
            ForEach(PulseDeliveryProfile.allCases) { profile in
              Text(profile.title).tag(profile)
            }
          }
          if !center.items.isEmpty {
            Divider()
            Button("Dismiss Visible") { center.dismissVisible() }
          }
        } label: {
          Image(systemName: "line.3.horizontal.decrease.circle")
            .frame(width: 24, height: 24)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Pulse delivery and stack actions")
        .help("Pulse delivery: \(center.deliveryProfile.title)")
      }
      ScrollView(.vertical, showsIndicators: false) {
        LazyVStack(spacing: 6) {
          ForEach(center.items) { item in PulseItemRow(item: item, center: center) }
        }
      }
    }
    .foregroundStyle(.white)
  }
}

private struct PulseItemRow: View {
  let item: PulseItem
  let center: PulseCenter

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: item.symbol)
        .frame(width: 18)
        .foregroundStyle(accent)
        .accessibilityLabel("\(item.source), \(stateLabel)")
      VStack(alignment: .leading, spacing: 2) {
        Text(item.title).font(.caption.weight(.semibold)).lineLimit(1)
        if let subtitle = item.subtitle {
          Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        if let progress = item.progress {
          ProgressView(value: progress).tint(accent)
            .accessibilityLabel("Progress")
            .accessibilityValue(Text(progress, format: .percent))
        }
      }
      Spacer(minLength: 4)
      if !item.actions.isEmpty {
        Menu {
          ForEach(item.actions) { action in
            Button(action.title) { NSWorkspace.shared.open(action.url) }
          }
        } label: {
          Image(systemName: "ellipsis.circle")
            .frame(width: 24, height: 24)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Actions for \(item.title)")
        .help("Actions for \(item.title)")
      }
      Button {
        center.dismiss(item.id)
      } label: {
        Image(systemName: "xmark")
          .font(.caption2)
          .frame(width: 24, height: 24)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Dismiss \(item.title)")
      .help("Dismiss \(item.title)")
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
  }

  private var accent: Color {
    if item.state == .failed { return .red }
    if item.state == .needsAction { return .orange }
    return Color(isletHex: item.accentHex) ?? .cyan
  }

  private var stateLabel: String {
    switch item.state {
    case .active: "active"
    case .progress: "in progress"
    case .needsAction: "needs action"
    case .succeeded: "succeeded"
    case .failed: "failed"
    }
  }
}
