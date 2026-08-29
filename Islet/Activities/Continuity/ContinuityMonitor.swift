import AppKit
import Combine
import Defaults
import SwiftUI

/// Owns the accessibility read and publishes what the island should draw.
@MainActor
final class ContinuityMonitor: ObservableObject {
  static let shared = ContinuityMonitor()

  @Published private(set) var cards: [LiveActivityCard] = []
  @Published private(set) var availability: ContinuityAvailability = .waiting

  private let reader = LiveActivityAXReader.shared
  private var didStart = false
  private var pollTimer: AnyCancellable?

  private init() {}

  func start() {
    guard !didStart else { return }
    didStart = true
    refresh()
    reader.startObserving { [weak self] in self?.refresh() }
    // A slow backstop. Accessibility notifications carry the load, but Islet may launch before
    // Accessibility is granted — in which case no observer was ever attached and only a poll will
    // notice the grant landing. `HUDController` handles the same problem the same way.
    pollTimer = Timer.publish(every: 10, on: .main, in: .common).autoconnect()
      .sink { [weak self] _ in self?.refresh() }
  }

  func stop() {
    guard didStart else { return }
    didStart = false
    pollTimer = nil
    reader.stopObserving()
    cards = []
    availability = .waiting
  }

  private func refresh() {
    let items = reader.read()
    let fresh = LiveActivityCatalog.cards(
      from: items ?? [],
      isInstalledLocally: { bundleIdentifier in
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil
      })

    let diff = SetDiff.changes(from: cards, to: fresh)
    cards = fresh
    availability = .resolve(
      isTrusted: reader.isTrusted,
      controlCenterReachable: items != nil,
      systemEnabled: ControlCenterLiveActivitySettings.read().remoteEnabled,
      cardCount: fresh.count)

    guard Defaults[.continuitySneaks] else { return }
    for card in diff.added { submitSneak(for: card, appearing: true) }
    for card in diff.removed { submitSneak(for: card, appearing: false) }
  }

  private func submitSneak(for card: LiveActivityCard, appearing: Bool) {
    let text = appearing ? card.appName : "\(card.appName) ended"
    SneakQueue.shared.submit(
      Sneak(
        // Keyed per activity so repeated churn for one app coalesces rather than queueing a sneak
        // each, the way SneakLogic already handles repeated events from one source.
        source: "continuity.\(card.id)",
        leading: AnyView(
          Image(systemName: card.symbol)
            .font(.caption)
            .foregroundStyle(appearing ? Color.blue : Color.secondary)),
        trailing: AnyView(
          Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .lineLimit(1)),
        announcement: appearing ? "iPhone: \(text) live activity started" : text))
  }
}
