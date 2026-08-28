import Combine
import Defaults
import Foundation

/// Registration, enable/disable and delivery for every system-event source.
///
/// Mirrors `ActivityCenter` on purpose: same registration shape, same Defaults-driven
/// enable/disable, so the Settings section and the Debug menu both generate from `SourceCatalog`
/// rather than being hand-maintained alongside it.
///
/// Delivery goes through the existing `SneakQueue` untouched. The bus's own contribution is the
/// burst coalescer: one physical action (docking) can fire six sources at once, and the queue is
/// strictly FIFO with a 2s dwell.
@MainActor
final class SystemEventBus: ObservableObject {
  static let shared = SystemEventBus(queue: SneakQueue.shared)

  private let queue: SneakQueue?
  /// Test seam. Left nil in production, where `queue` does the delivering.
  var onSneak: ((Sneak) -> Void)?

  private(set) var sources: [any SystemEventSource] = []
  private var coalescer = BurstCoalescer()
  private var flushTask: Task<Void, Never>?
  private var isRunning = false

  init(queue: SneakQueue?) {
    self.queue = queue
  }

  // MARK: - Registration

  /// Idempotent: registering the same id twice keeps the first registration, so a double call in
  /// `AppDelegate` cannot double-start an observer.
  func register(_ source: any SystemEventSource) {
    guard !sources.contains(where: { $0.id == source.id }) else { return }
    if !SourceCatalog.all.contains(where: { $0.id == source.id }) {
      Log.app.error(
        "Event source \(source.id, privacy: .public) is not in SourceCatalog; it will have no Settings toggle"
      )
    }
    sources.append(source)
    objectWillChange.send()
  }

  /// Starts every source the user has left enabled. Called once at launch.
  func startEnabled() {
    guard !isRunning else { return }
    isRunning = true
    for source in sources where isEnabled(source.id) {
      source.start()
    }
  }

  func stopAll() {
    isRunning = false
    flushTask?.cancel()
    flushTask = nil
    coalescer.reset()
    for source in sources { source.stop() }
  }

  // MARK: - Enable / disable

  func isEnabled(_ sourceID: String) -> Bool {
    !Defaults[.disabledEventSources].contains(sourceID)
  }

  /// Toggling actually starts or stops the source. A disabled source holds no registration, no
  /// run-loop source and no timer — "off" means off, not muted.
  func setEnabled(_ enabled: Bool, for sourceID: String) {
    var disabled = Defaults[.disabledEventSources]
    if enabled {
      disabled.removeAll { $0 == sourceID }
    } else if !disabled.contains(sourceID) {
      disabled.append(sourceID)
    }
    Defaults[.disabledEventSources] = disabled

    // A configuration boundary also invalidates an in-flight burst: otherwise a summary can name
    // a source after the user has disabled it. Canceling the task and resetting both pieces keeps
    // their lifecycle atomic.
    flushTask?.cancel()
    flushTask = nil
    coalescer.reset()

    if isRunning, let source = sources.first(where: { $0.id == sourceID }) {
      if enabled { source.start() } else { source.stop() }
    }
    objectWillChange.send()
  }

  // MARK: - Emission

  /// The one path from a source to the island.
  ///
  /// The enabled check is repeated here even though a disabled source is stopped: a source with an
  /// in-flight callback can emit once after `stop()` returns, and that event should not appear.
  func emit(_ event: SystemEvent) {
    guard isRunning, isEnabled(event.sourceID) else { return }
    // Unlike Date, systemUptime does not jump when NTP or the user adjusts the wall clock. A
    // backwards clock jump used to keep a held burst alive indefinitely.
    let now = ProcessInfo.processInfo.systemUptime
    switch coalescer.accept(event, at: now) {
    case .pass(let passed):
      deliver(passed)
    case .hold:
      scheduleFlush()
    }
  }

  private func deliver(_ event: SystemEvent) {
    let sneak = Sneak(event: event)
    if let onSneak {
      onSneak(sneak)
    } else {
      queue?.submit(sneak)
    }
  }

  /// A single pending flush, re-armed rather than stacked: the coalescer returns nil until the burst
  /// has been quiet for a full window, so an early wake-up simply reschedules.
  private func scheduleFlush() {
    guard flushTask == nil else { return }
    flushTask = Task { [weak self] in
      while true {
        try? await Task.sleep(for: .milliseconds(400))
        guard let self, !Task.isCancelled else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let summary = self.coalescer.flush(at: now) {
          self.deliver(summary)
          self.flushTask = nil
          return
        }
        if !self.coalescer.isHolding {
          self.flushTask = nil
          return
        }
      }
    }
  }
}
