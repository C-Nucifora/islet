import XCTest

@testable import Islet

@MainActor
final class ReminderReloadCoordinatorTests: XCTestCase {
  @MainActor
  private final class ScheduledOperation {
    let operation: @MainActor @Sendable () -> Void
    var isCancelled = false

    init(operation: @escaping @MainActor @Sendable () -> Void) {
      self.operation = operation
    }
  }

  @MainActor
  private final class ManualScheduler {
    private(set) var operations: [ScheduledOperation] = []

    func schedule(
      delay _: Duration, operation: @escaping @MainActor @Sendable () -> Void
    ) -> ReminderReloadDebouncer.Cancellation {
      let scheduled = ScheduledOperation(operation: operation)
      operations.append(scheduled)
      return { scheduled.isCancelled = true }
    }

    func runScheduledOperations() {
      for scheduled in operations where !scheduled.isCancelled {
        scheduled.operation()
      }
    }
  }

  func testNotificationBurstRunsOnlyLatestScheduledReload() {
    let scheduler = ManualScheduler()
    let debouncer = ReminderReloadDebouncer { delay, operation in
      scheduler.schedule(delay: delay, operation: operation)
    }
    var reloadCount = 0

    debouncer.schedule { reloadCount += 1 }
    debouncer.schedule { reloadCount += 1 }
    debouncer.schedule { reloadCount += 1 }
    scheduler.runScheduledOperations()

    XCTAssertEqual(scheduler.operations.map(\.isCancelled), [true, true, false])
    XCTAssertEqual(reloadCount, 1)
  }

  func testCancellingPendingReloadPreventsItFromRunning() {
    let scheduler = ManualScheduler()
    let debouncer = ReminderReloadDebouncer { delay, operation in
      scheduler.schedule(delay: delay, operation: operation)
    }
    var reloadCount = 0

    debouncer.schedule { reloadCount += 1 }
    debouncer.cancel()
    scheduler.runScheduledOperations()

    XCTAssertTrue(scheduler.operations[0].isCancelled)
    XCTAssertEqual(reloadCount, 0)
  }

  func testNewReloadSupersedesOlderFetchResult() {
    var state = ReminderReloadState()
    let olderGeneration = state.beginReload()
    let newerGeneration = state.beginReload()
    let oldItems = [item("old")]
    let newItems = [item("new")]

    XCTAssertNil(state.finish(oldItems, generation: olderGeneration))
    XCTAssertEqual(state.finish(newItems, generation: newerGeneration), newItems)
  }

  func testOptimisticCompletionStaysHiddenUntilEventKitStopsReturningIt() {
    var state = ReminderReloadState()
    state.markCompleted("done")

    let firstGeneration = state.beginReload()
    let firstVisible = state.finish(
      [item("done"), item("open")], generation: firstGeneration)
    let secondGeneration = state.beginReload()
    let secondVisible = state.finish(
      [item("done"), item("open")], generation: secondGeneration)
    let confirmedGeneration = state.beginReload()
    let confirmedVisible = state.finish([item("open")], generation: confirmedGeneration)
    let laterGeneration = state.beginReload()
    let laterVisible = state.finish(
      [item("done"), item("open")], generation: laterGeneration)

    XCTAssertEqual(firstVisible, [item("open")])
    XCTAssertEqual(secondVisible, [item("open")])
    XCTAssertEqual(confirmedVisible, [item("open")])
    XCTAssertEqual(laterVisible, [item("done"), item("open")])
  }

  private func item(_ id: String) -> ReminderItem {
    ReminderItem(
      id: id, title: id, dueDate: nil, priority: 0, listColorHex: nil)
  }
}
