import Combine
import Defaults
import SwiftUI

/// Owns the Live Activity subscription and publishes what the island should draw.
///
/// The bridge calls back on an arbitrary queue; everything past this class is main-actor state
/// feeding SwiftUI, so this is where the hop happens and the only place the two meet.
@MainActor
final class ContinuityMonitor: ObservableObject {
  static let shared = ContinuityMonitor()

  @Published private(set) var cards: [LiveActivityCard] = []
  @Published private(set) var availability: ContinuityAvailability = .waiting

  private var store = LiveActivityStore()
  private var didStart = false
  private var settingsTimer: AnyCancellable?

  private init() {}

  func start() {
    guard !didStart else { return }
    didStart = true
    refreshAvailability()

    ACActivityBridge.shared.start(
      onDescriptors: { descriptors in
        Task { @MainActor in ContinuityMonitor.shared.ingest(descriptors: descriptors) }
      },
      onContent: { content in
        Task { @MainActor in ContinuityMonitor.shared.ingest(content: content) }
      })

    // ControlCenter rewrites its pairing cache only when it notices a change, so nothing notifies
    // us; a slow poll is enough to keep the empty-state sentence honest and costs one plist read.
    settingsTimer = Timer.publish(every: 15, on: .main, in: .common).autoconnect()
      .sink { [weak self] _ in self?.refreshAvailability() }
  }

  private func ingest(descriptors: [RawLiveActivity]) {
    if Defaults[.continuityCapture] {
      descriptors.forEach { ContinuityCapture.append(kind: "descriptor", activity: $0) }
    }
    apply(store.apply(descriptors: descriptors))
  }

  private func ingest(content: RawLiveActivity) {
    if Defaults[.continuityCapture] {
      ContinuityCapture.append(kind: "content", activity: content)
    }
    apply(store.apply(content: content))
  }

  private func apply(_ change: LiveActivityStore.Change) {
    cards = store.ordered()
    refreshAvailability()
    guard Defaults[.continuitySneaks] else { return }
    change.added.forEach { submitSneak(for: $0, appearing: true) }
    change.removed.forEach { submitSneak(for: $0, appearing: false) }
  }

  private func refreshAvailability() {
    let settings = ControlCenterLiveActivitySettings.read()
    availability = .resolve(
      bridgeAvailable: ACActivityBridge.shared.availability == .available,
      systemEnabled: settings.remoteEnabled,
      companionPaired: settings.companionPaired,
      cardCount: cards.count)
  }

  private func submitSneak(for card: LiveActivityCard, appearing: Bool) {
    let text = appearing ? card.compactText : "\(card.appName) ended"
    SneakQueue.shared.submit(
      Sneak(
        // Keyed per activity so a burst of updates for one activity coalesces instead of queueing
        // a sneak each, the way SneakLogic already handles repeated events from one source.
        source: "continuity.\(card.id)",
        leading: AnyView(
          Image(systemName: card.render.symbol ?? LiveActivityAppStyle.fallbackSymbol)
            .font(.caption)
            .foregroundStyle(appearing ? Color.green : Color.secondary)),
        trailing: AnyView(
          Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .lineLimit(1)),
        announcement: appearing ? "iPhone: \(text)" : text))
  }
}
