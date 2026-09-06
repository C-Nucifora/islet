import AppKit
import Combine
import Defaults
import SwiftUI

struct ContinuityReadDiagnostics: Equatable {
  private(set) var lastSuccessfulRead: Date?
  private(set) var compatibilityError: LiveActivityAXCompatibilityError?

  mutating func record(_ result: LiveActivityAXReadResult, at date: Date) {
    switch result {
    case .success:
      lastSuccessfulRead = date
      compatibilityError = nil
    case .schemaChanged(let error):
      compatibilityError = error
    case .permissionDenied, .controlCenterUnavailable:
      compatibilityError = nil
    }
  }
}

struct ContinuityEventBaseline: Equatable {
  private(set) var cards: [LiveActivityCard] = []

  mutating func reconcile(
    with fresh: [LiveActivityCard], readSucceeded: Bool
  ) -> (added: [LiveActivityCard], removed: [LiveActivityCard]) {
    guard readSucceeded else { return ([], []) }
    let changes = SetDiff.changes(from: cards, to: fresh)
    cards = fresh
    return changes
  }

  mutating func reset() { cards = [] }
}

/// Owns the accessibility read and publishes what the island should draw.
@MainActor
final class ContinuityMonitor: ObservableObject {
  static let shared = ContinuityMonitor()

  @Published private(set) var cards: [LiveActivityCard] = []
  @Published private(set) var availability: ContinuityAvailability = .waiting
  @Published private(set) var readDiagnostics = ContinuityReadDiagnostics()

  var lastSuccessfulRead: Date? { readDiagnostics.lastSuccessfulRead }
  var lastCompatibilityError: LiveActivityAXCompatibilityError? {
    readDiagnostics.compatibilityError
  }

  private let reader = LiveActivityAXReader.shared
  private var didStart = false
  private var pollTimer: AnyCancellable?
  private var eventBaseline = ContinuityEventBaseline()

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
    eventBaseline.reset()
    availability = .waiting
  }

  /// Retries both the AX observer and the read. Settings uses this after a permission grant or a
  /// transient ControlCenter failure.
  func retry() {
    reader.retryObservation()
    refresh()
  }

  private func refresh() {
    // Polling also repairs an observer that could not attach before Accessibility was granted.
    reader.retryObservation()
    let readResult = reader.read()
    readDiagnostics.record(readResult, at: Date())
    let items: [MenuBarLiveActivity]
    let readSucceeded: Bool
    switch readResult {
    case .success(let current):
      items = current
      readSucceeded = true
    case .schemaChanged(let error):
      items = []
      readSucceeded = false
      Log.app.error("Continuity: incompatible accessibility schema: \(String(describing: error))")
    case .permissionDenied, .controlCenterUnavailable:
      items = []
      readSucceeded = false
    }
    let fresh = LiveActivityCatalog.cards(
      from: items,
      isInstalledLocally: { bundleIdentifier in
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil
      })

    let diff = eventBaseline.reconcile(with: fresh, readSucceeded: readSucceeded)
    cards = fresh
    availability = .resolve(
      readResult: readResult, systemEnabled: ControlCenterLiveActivitySettings.read().remoteEnabled,
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
        announcement: appearing
          ? String(localized: "iPhone: \(text) live activity started") : text))
  }
}
