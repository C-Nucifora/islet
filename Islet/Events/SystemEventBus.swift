import Combine
import Foundation

/// Registration, enable/disable and delivery for every system-event source.
///
/// Mirrors `ActivityCenter` on purpose: same registration shape, same preference-driven
/// enable/disable, so the Settings section and the Debug menu both generate from `SourceCatalog`
/// rather than being hand-maintained alongside it.
///
/// Delivery goes through `SneakQueue`, which prioritizes queued alerts and applies a bounded
/// fairness turn for ambient work. The bus's own contribution is the burst coalescer: one physical
/// action (docking) can fire six sources at once.
@MainActor
final class SystemEventBus: ObservableObject {
  static let shared = SystemEventBus(queue: SneakQueue.shared)

  private let queue: SneakQueue?
  let preferences: EventSourcePreferences
  /// Test seam. Left nil in production, where `queue` does the delivering.
  var onSneak: ((Sneak) -> Void)?

  private(set) var sources: [any SystemEventSource] = []
  private var coalescer = BurstCoalescer()
  private var flushTask: Task<Void, Never>?
  private var preferencesCancellable: AnyCancellable?
  private var appliedDisabledSourceIDs: Set<String>
  private var isRunning = false

  init(queue: SneakQueue?, preferences: EventSourcePreferences = .shared) {
    self.queue = queue
    self.preferences = preferences
    appliedDisabledSourceIDs = Set(preferences.disabledSourceIDs)
    preferencesCancellable = preferences.$disabledSourceIDs.dropFirst().sink { [weak self] _ in
      Task { @MainActor in self?.reconcileSourceLifecycles() }
    }
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
    appliedDisabledSourceIDs = Set(preferences.disabledSourceIDs)
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
    preferences.isEnabled(sourceID)
  }

  /// Toggling actually starts or stops the source. A disabled source holds no registration, no
  /// run-loop source and no timer — "off" means off, not muted.
  func setEnabled(_ enabled: Bool, for sourceID: String) {
    let changed = preferences.setEnabled(enabled, for: sourceID)
    guard changed else { return }
    appliedDisabledSourceIDs = Set(preferences.disabledSourceIDs)

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

  /// Settings imports and legacy migration replace the stored list as one transaction instead of
  /// calling `setEnabled` for each source. Reconcile those published changes with the observers
  /// that are already running so persisted state and live state cannot diverge until relaunch.
  private func reconcileSourceLifecycles() {
    let updatedDisabledSourceIDs = Set(preferences.disabledSourceIDs)
    let previousDisabledSourceIDs = appliedDisabledSourceIDs
    guard updatedDisabledSourceIDs != previousDisabledSourceIDs else { return }
    appliedDisabledSourceIDs = updatedDisabledSourceIDs
    guard isRunning else { return }
    flushTask?.cancel()
    flushTask = nil
    coalescer.reset()
    for source in sources
    where previousDisabledSourceIDs.contains(source.id)
      != updatedDisabledSourceIDs.contains(source.id)
    {
      if updatedDisabledSourceIDs.contains(source.id) { source.stop() } else { source.start() }
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
