import Foundation

/// Screenshots.
///
/// A Spotlight query on `kMDItemIsScreenCapture` — a real, indexed attribute — rather than watching
/// the screenshot folder, which the user can relocate and which would also catch every unrelated
/// file that lands there.
///
/// `NSMetadataQuery` delivers its first batch as "everything that already matches", which for this
/// predicate is every screenshot ever taken. That gather phase is discarded; only live updates after
/// it emit.
@MainActor
final class ScreenshotEventSource: SystemEventSource {
  let id = "screenshot"
  let displayName = "Screenshots"
  let tier = SystemEventTier.extended

  private var query: NSMetadataQuery?
  private var observers: [NSObjectProtocol] = []
  private var gathered = false

  func start() {
    guard query == nil else { return }
    let q = NSMetadataQuery()
    q.predicate = NSPredicate(format: "kMDItemIsScreenCapture == 1")
    q.searchScopes = [NSMetadataQueryUserHomeScope]

    let center = NotificationCenter.default
    observers.append(
      center.addObserver(
        forName: .NSMetadataQueryDidFinishGathering, object: q, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.gathered = true }
      })
    observers.append(
      center.addObserver(
        forName: .NSMetadataQueryDidUpdate, object: q, queue: .main
      ) { [weak self] note in
        // Notification is not Sendable, so pull the two Sendable values out here — this closure
        // already runs on the main queue — rather than carrying the notification across the hop.
        let added = note.userInfo?[kMDQueryUpdateAddedItems as String] as? [NSMetadataItem] ?? []
        let count = added.count
        let name = added.first?.value(forAttribute: kMDItemDisplayName as String) as? String
        MainActor.assumeIsolated { self?.report(count: count, name: name) }
      })

    query = q
    q.start()
  }

  func stop() {
    query?.stop()
    query = nil
    observers.forEach { NotificationCenter.default.removeObserver($0) }
    observers.removeAll()
    gathered = false
  }

  private func report(count: Int, name: String?) {
    // Everything before the gather completes is history, not news.
    guard gathered, count > 0 else { return }
    let name = name ?? "Screenshot"
    SystemEventBus.shared.emit(
      SystemEvent(
        sourceID: id, icon: "camera.viewfinder",
        title: count > 1 ? "\(count) screenshots" : "Screenshot",
        subtitle: count > 1 ? nil : name,
        accentHex: EventAccent.info, motion: .screenshot,
        urgency: .ambient, duration: 1.5,
        announcement: "Screenshot taken"))
  }
}
