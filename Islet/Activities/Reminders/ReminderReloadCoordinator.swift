import Foundation

@MainActor
final class ReminderReloadDebouncer {
  typealias Cancellation = @MainActor () -> Void
  typealias Scheduler =
    @MainActor (
      _ delay: Duration, _ operation: @escaping @MainActor @Sendable () -> Void
    ) -> Cancellation

  private let delay: Duration
  private let scheduler: Scheduler
  private var cancelPending: Cancellation?

  init(
    delay: Duration = .milliseconds(250),
    scheduler: @escaping Scheduler = ReminderReloadDebouncer.taskScheduler
  ) {
    self.delay = delay
    self.scheduler = scheduler
  }

  func schedule(_ operation: @escaping @MainActor @Sendable () -> Void) {
    cancelPending?()
    cancelPending = scheduler(delay, operation)
  }

  func cancel() {
    cancelPending?()
    cancelPending = nil
  }

  private static func taskScheduler(
    delay: Duration, operation: @escaping @MainActor @Sendable () -> Void
  ) -> Cancellation {
    let task = Task { @MainActor in
      do {
        try await Task.sleep(for: delay)
      } catch {
        return
      }
      guard !Task.isCancelled else { return }
      operation()
    }
    return { task.cancel() }
  }
}

struct ReminderReloadState {
  private var generation = 0
  private var optimisticCompletionIDs: Set<String> = []

  mutating func beginReload() -> Int {
    generation += 1
    return generation
  }

  mutating func invalidate(clearOptimisticCompletions: Bool) {
    generation += 1
    if clearOptimisticCompletions { optimisticCompletionIDs.removeAll() }
  }

  mutating func markCompleted(_ id: String) {
    optimisticCompletionIDs.insert(id)
  }

  mutating func finish(_ items: [ReminderItem], generation completedGeneration: Int)
    -> [ReminderItem]?
  {
    guard completedGeneration == generation else { return nil }
    let visibleItems = items.filter { !optimisticCompletionIDs.contains($0.id) }
    // EventKit can return the pre-save snapshot more than once. Keep each optimistic completion
    // hidden until an accepted fetch proves that identifier has disappeared from the store.
    optimisticCompletionIDs.formIntersection(Set(items.map(\.id)))
    return visibleItems
  }
}
