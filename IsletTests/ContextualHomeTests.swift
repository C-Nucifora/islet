import XCTest

@testable import Islet

final class ContextualHomeTests: XCTestCase {
  private let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

  func testRankingUsesPriorityThenDeadlineAndStableIdentity() {
    let later = item(id: "later", source: .calendar, priority: .high, dueAt: now + 600)
    let sooner = item(id: "sooner", source: .calendar, priority: .high, dueAt: now + 300)
    let criticalZ = item(id: "z", source: .pulse, priority: .critical)
    let criticalA = item(id: "a", source: .pulse, priority: .critical)

    let first = HomeAttentionRanking.ranked(
      [later, criticalZ, sooner, criticalA], now: now)
    let reversed = HomeAttentionRanking.ranked(
      Array([criticalA, sooner, criticalZ, later].reversed()), now: now)

    XCTAssertEqual(first.map(\.stableID), ["a", "z", "sooner", "later"])
    XCTAssertEqual(reversed.map(\.stableID), first.map(\.stableID))
  }

  func testExpiryRemovesAnItemAtItsDeadline() {
    let live = item(id: "live", source: .pulse, priority: .normal, expiresAt: now + 1)
    let expired = item(id: "expired", source: .pulse, priority: .critical, expiresAt: now)

    XCTAssertEqual(
      HomeAttentionRanking.ranked([expired, live], now: now).map(\.stableID), ["live"])
    XCTAssertTrue(HomeAttentionRanking.ranked([live], now: now + 1).isEmpty)
  }

  func testDismissalHidesOnlyTheCurrentOccurrence() {
    let old = item(id: "build:1", stableID: "build", source: .pulse, priority: .high)
    let update = item(id: "build:2", stableID: "build", source: .pulse, priority: .high)
    var disposition = HomeAttentionDisposition()

    disposition.dismiss(old)

    XCTAssertTrue(disposition.visible([old], now: now).isEmpty)
    XCTAssertEqual(disposition.visible([old, update], now: now).map(\.id), ["build:2"])
  }

  func testSnoozeReturnsAnItemAfterTheRequestedTime() {
    let reminder = item(
      id: "reminder", source: .reminders, priority: .urgent, allowsSnooze: true)
    var disposition = HomeAttentionDisposition()
    disposition.snooze(reminder, until: now + 3_600)

    XCTAssertTrue(disposition.visible([reminder], now: now + 3_599).isEmpty)
    XCTAssertEqual(disposition.visible([reminder], now: now + 3_600), [reminder])
  }

  func testOverflowKeepsThreeAndPlacesTheRemainingSixBehindMore() {
    let nine = (0..<9).map {
      item(id: "item-\($0)", source: .reminders, priority: .normal)
    }
    let ranked = HomeAttentionRanking.ranked(nine, now: now)
    let split = HomeAttentionOverflow.split(ranked)

    XCTAssertEqual(split.primary.count, 3)
    XCTAssertEqual(split.overflow.count, 6)
    XCTAssertEqual(split.primary + split.overflow, ranked)
  }

  func testBuilderCombinesEveryRequiredSourceIntoNineReadableItems() throws {
    let calendarEvents = [
      agenda(id: "event-1", title: "Design review", startsIn: 300),
      agenda(id: "event-2", title: "Planning", startsIn: 3_600),
    ]
    let reminders = [
      ReminderItem(
        id: "reminder-1", title: "Send notes", dueDate: now - 60, priority: 1,
        listColorHex: nil),
      ReminderItem(
        id: "reminder-2", title: "Buy milk", dueDate: now + 7_200, priority: 0,
        listColorHex: nil),
    ]
    let timer = HomeTimerSnapshot(
      occurrenceID: "timer-1", label: "Focus", endDate: now + 45, remaining: 45,
      isPaused: false, finished: false)
    let agent = T3AgentSnapshot(
      environmentID: "mac", threadID: "thread", title: "Fix tests", project: "Islet",
      providerInstance: "Codex", model: "gpt", branch: "feature", phase: .needsInput,
      planStep: nil, completedPlanSteps: nil, totalPlanSteps: nil, updatedAt: now)
    let pulse = try PulseItem(
      payload: PulsePayload(
        id: "build", source: "xcode", title: "Build failed", subtitle: nil,
        symbol: "hammer.fill", accentHex: nil, progress: nil, state: .failed,
        priority: .high, expiresAt: now + 600, actions: nil),
      now: now)

    let items = HomeAttentionBuilder.items(
      calendarEvents: calendarEvents, reminders: reminders, timer: timer,
      t3Agents: [agent], pulseItems: [pulse],
      battery: BatteryState(percent: 9, isCharging: false, onAC: false),
      pendingTransfers: 2, now: now)

    XCTAssertEqual(items.count, 9)
    XCTAssertEqual(Set(items.map(\.source)), Set(HomeAttentionSource.allCases))
    XCTAssertEqual(HomeAttentionOverflow.split(items).overflow.count, 6)
  }

  func testVoiceOverValueNamesStatePriorityAndAvailableActions() {
    let attention = item(
      id: "agent", source: .t3Code, priority: .critical, allowsSnooze: true,
      primaryAction: HomeAttentionAction(
        title: "Open T3 Code", symbol: "terminal.fill", kind: .openActivity("t3Code")))

    XCTAssertTrue(attention.voiceOverValue.contains("Needs attention"))
    XCTAssertTrue(attention.voiceOverValue.contains("Critical priority"))
    XCTAssertTrue(attention.voiceOverValue.contains("Action available: Open T3 Code"))
    XCTAssertTrue(attention.voiceOverValue.contains("Snooze available"))
  }

  private func item(
    id: String, stableID: String? = nil, source: HomeAttentionSource,
    priority: HomeAttentionPriority, dueAt: Date? = nil, expiresAt: Date? = nil,
    allowsSnooze: Bool = false, primaryAction: HomeAttentionAction? = nil
  ) -> HomeAttentionItem {
    HomeAttentionItem(
      id: id, stableID: stableID ?? id, source: source, title: id, detail: nil,
      symbol: "circle", accentHex: nil, state: "Needs attention", priority: priority,
      rankingReason: "Test reason", dueAt: dueAt, expiresAt: expiresAt, progress: nil,
      primaryAction: primaryAction, allowsDismiss: true, allowsSnooze: allowsSnooze)
  }

  private func agenda(id: String, title: String, startsIn: TimeInterval) -> AgendaEvent {
    AgendaEvent(
      id: id, title: title, start: now + startsIn, end: now + startsIn + 1_800,
      isAllDay: false, calendarColorHex: nil, joinURL: nil)
  }
}
