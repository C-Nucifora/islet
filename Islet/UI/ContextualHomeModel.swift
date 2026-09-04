import Foundation

enum HomeAttentionSource: String, CaseIterable, Sendable {
  case calendar
  case reminders
  case timer
  case t3Code
  case pulse
  case battery
  case transfer

  var title: String {
    switch self {
    case .calendar: "Calendar"
    case .reminders: "Reminders"
    case .timer: "Timer"
    case .t3Code: "T3 Code"
    case .pulse: "Pulse"
    case .battery: "Battery"
    case .transfer: "File transfer"
    }
  }

  fileprivate var tieBreakRank: Int {
    switch self {
    case .battery: 0
    case .timer: 1
    case .t3Code: 2
    case .pulse: 3
    case .calendar: 4
    case .reminders: 5
    case .transfer: 6
    }
  }

  fileprivate var gatedActivityID: String? {
    switch self {
    case .timer: "timer"
    case .t3Code: "t3Code"
    case .pulse: "pulse"
    case .battery: "battery"
    case .transfer: "shelf"
    case .calendar, .reminders: nil
    }
  }
}

enum HomeAttentionPriority: Int, Comparable, Sendable {
  case low = 0
  case normal = 1
  case high = 2
  case urgent = 3
  case critical = 4

  static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

  var title: String {
    switch self {
    case .low: "Low"
    case .normal: "Normal"
    case .high: "High"
    case .urgent: "Urgent"
    case .critical: "Critical"
    }
  }
}

struct HomeAttentionAction: Equatable, Sendable {
  enum Kind: Equatable, Sendable {
    case openActivity(String)
    case openURL(URL)
    case openMeetingLink(CalendarMeetingLink)
    case completeReminder(String)
    case toggleTimer
    case dismissTimer
    case recoverCalendarAccess
    case recoverRemindersAccess
    case retryCalendar
    case retryReminders
  }

  let title: String
  let symbol: String
  let kind: Kind
}

struct HomeAttentionItem: Identifiable, Equatable, Sendable {
  /// Identifies one occurrence, not merely its source object. A meaningful source update gets a new
  /// occurrence so a dismissed stale state does not hide new work.
  let id: String
  let stableID: String
  let source: HomeAttentionSource
  let title: String
  let detail: String?
  let symbol: String
  let accentHex: String?
  let state: String
  let priority: HomeAttentionPriority
  let rankingReason: String
  let dueAt: Date?
  let expiresAt: Date?
  let progress: Double?
  let primaryAction: HomeAttentionAction?
  let allowsDismiss: Bool
  let allowsSnooze: Bool

  var voiceOverValue: String {
    var parts = [state, "\(priority.title) priority", rankingReason]
    if let primaryAction { parts.append("Action available: \(primaryAction.title)") }
    if allowsDismiss { parts.append("Dismiss available") }
    if allowsSnooze { parts.append("Snooze available") }
    return parts.joined(separator: ". ")
  }
}

struct HomeTimerSnapshot: Equatable, Sendable {
  let occurrenceID: String
  let label: String
  let endDate: Date?
  let remaining: TimeInterval
  let isPaused: Bool
  let finished: Bool
}

enum HomeAttentionRanking {
  static func ranked(_ items: [HomeAttentionItem], now: Date) -> [HomeAttentionItem] {
    items
      .filter { ($0.expiresAt ?? .distantFuture) > now }
      .sorted(by: comesBefore)
  }

  static func explanation(
    for item: HomeAttentionItem, above next: HomeAttentionItem?
  ) -> String {
    guard let next else { return item.rankingReason }
    if item.priority != next.priority {
      return
        "\(item.rankingReason). Ranked above \(next.source.title) because it has \(item.priority.title.lowercased()) priority."
    }
    if let itemDue = item.dueAt, let nextDue = next.dueAt, itemDue != nextDue {
      return "\(item.rankingReason). Ranked above \(next.source.title) because it is due sooner."
    }
    if item.dueAt != nil, next.dueAt == nil {
      return "\(item.rankingReason). Ranked above \(next.source.title) because it has a deadline."
    }
    if item.source.tieBreakRank != next.source.tieBreakRank {
      return
        "\(item.rankingReason). Equal-priority items use a stable source order, which places \(item.source.title) before \(next.source.title)."
    }
    if item.stableID != next.stableID {
      return
        "\(item.rankingReason). Equal-priority \(item.source.title) items use their stable item identifier."
    }
    if item.id != next.id {
      return
        "\(item.rankingReason). Equal-priority occurrences use their occurrence identifier as the final tie-break."
    }
    return "\(item.rankingReason). This item has the same ranking keys as the next item."
  }

  private static func comesBefore(_ lhs: HomeAttentionItem, _ rhs: HomeAttentionItem) -> Bool {
    if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
    switch (lhs.dueAt, rhs.dueAt) {
    case (let left?, let right?) where left != right:
      return left < right
    case (.some, .none):
      return true
    case (.none, .some):
      return false
    default:
      break
    }
    if lhs.source.tieBreakRank != rhs.source.tieBreakRank {
      return lhs.source.tieBreakRank < rhs.source.tieBreakRank
    }
    if lhs.stableID != rhs.stableID { return lhs.stableID < rhs.stableID }
    return lhs.id < rhs.id
  }
}

enum HomeAttentionOverflow {
  static let primaryLimit = 3

  struct Result: Equatable, Sendable {
    let primary: [HomeAttentionItem]
    let overflow: [HomeAttentionItem]
  }

  static func split(_ items: [HomeAttentionItem]) -> Result {
    Result(
      primary: Array(items.prefix(primaryLimit)),
      overflow: Array(items.dropFirst(primaryLimit)))
  }
}

struct HomeAttentionDisposition: Equatable, Sendable {
  private(set) var dismissedOccurrenceIDs: Set<String> = []
  private(set) var snoozedUntil: [String: Date] = [:]

  mutating func dismiss(_ item: HomeAttentionItem) {
    dismissedOccurrenceIDs.insert(item.id)
    snoozedUntil[item.id] = nil
  }

  mutating func snooze(_ item: HomeAttentionItem, until: Date) {
    guard item.allowsSnooze else { return }
    snoozedUntil[item.id] = until
  }

  mutating func reconcile(with items: [HomeAttentionItem]) {
    let liveOccurrenceIDs = Set(items.map(\.id))
    dismissedOccurrenceIDs.formIntersection(liveOccurrenceIDs)
    snoozedUntil = snoozedUntil.filter { liveOccurrenceIDs.contains($0.key) }
  }

  func visible(_ items: [HomeAttentionItem], now: Date) -> [HomeAttentionItem] {
    HomeAttentionRanking.ranked(
      items.filter { item in
        !dismissedOccurrenceIDs.contains(item.id)
          && (snoozedUntil[item.id] ?? .distantPast) <= now
      },
      now: now)
  }
}

enum HomeAttentionBuilder {
  static func items(
    calendarEvents: [AgendaEvent], reminders: [ReminderItem], timer: HomeTimerSnapshot?,
    t3Agents: [T3AgentSnapshot], pulseItems: [PulseItem], battery: BatteryState?,
    pendingTransfers: Int, disabledActivities: [String] = [], now: Date
  ) -> [HomeAttentionItem] {
    var result: [HomeAttentionItem] = []
    result += calendarEvents.compactMap { calendarItem($0, now: now) }
    result += reminders.map { reminderItem($0, now: now) }
    if let timer { result.append(timerItem(timer, now: now)) }
    result += t3Agents.map(t3Item)
    result += pulseItems.map(pulseItem)
    if let batteryItem = batteryItem(battery) { result.append(batteryItem) }
    if pendingTransfers > 0 { result.append(transferItem(count: pendingTransfers)) }
    let disabled = Set(disabledActivities)
    return HomeAttentionRanking.ranked(
      result.filter { item in
        guard let activityID = item.source.gatedActivityID else { return true }
        return !disabled.contains(activityID)
      },
      now: now)
  }

  static func serviceIssue(
    id: String, source: HomeAttentionSource, title: String, detail: String?, state: String,
    action: HomeAttentionAction
  ) -> HomeAttentionItem {
    HomeAttentionItem(
      id: "service:\(source.rawValue):\(id)", stableID: id, source: source, title: title,
      detail: detail, symbol: source == .calendar ? "calendar.badge.exclamationmark" : "checklist",
      accentHex: EventAccent.warning, state: state, priority: .high,
      rankingReason: "This source cannot provide its Home items", dueAt: nil, expiresAt: nil,
      progress: nil, primaryAction: action, allowsDismiss: true, allowsSnooze: false)
  }

  private static func calendarItem(_ event: AgendaEvent, now: Date) -> HomeAttentionItem? {
    guard event.end > now else { return nil }
    let seconds = event.start.timeIntervalSince(now)
    let priority: HomeAttentionPriority
    let state: String
    let reason: String
    if event.isAllDay {
      priority = .low
      state = "All day"
      reason = "The event is scheduled for today"
    } else if seconds <= 0 {
      priority = .urgent
      state = "In progress"
      reason = "The event is happening now"
    } else if seconds <= 15 * 60 {
      priority = .urgent
      state = "Starts in \(CalendarLogic.countdownText(to: event.start, now: now))"
      reason = "The event starts within 15 minutes"
    } else if seconds <= 60 * 60 {
      priority = .high
      state = "Starts in \(CalendarLogic.countdownText(to: event.start, now: now))"
      reason = "The event starts within an hour"
    } else {
      priority = .normal
      state = "Upcoming"
      reason = "This is the next scheduled work"
    }
    let action =
      event.joinURL.flatMap(CalendarMeetingLinkPolicy.candidate).map {
        HomeAttentionAction(title: "Join", symbol: "video.fill", kind: .openMeetingLink($0))
      }
      ?? HomeAttentionAction(
        title: "Open Calendar", symbol: "calendar", kind: .openActivity("calendar"))
    return HomeAttentionItem(
      id: "calendar:\(event.id)", stableID: event.id, source: .calendar,
      title: event.title, detail: event.start.formatted(date: .omitted, time: .shortened),
      symbol: "calendar", accentHex: event.calendarColorHex, state: state, priority: priority,
      rankingReason: reason, dueAt: event.start, expiresAt: event.end, progress: nil,
      primaryAction: action, allowsDismiss: true, allowsSnooze: true)
  }

  private static func reminderItem(_ reminder: ReminderItem, now: Date) -> HomeAttentionItem {
    let overdue = RemindersLogic.isOverdue(reminder, now: now)
    let dueToday = reminder.dueDate.map { Calendar.current.isDate($0, inSameDayAs: now) } ?? false
    let priority: HomeAttentionPriority = overdue ? .urgent : (dueToday ? .high : .normal)
    let state = overdue ? "Overdue" : (dueToday ? "Due today" : "Incomplete")
    let reason =
      overdue
      ? "The reminder is overdue"
      : (dueToday ? "The reminder is due today" : "The reminder is incomplete")
    return HomeAttentionItem(
      id: "reminder:\(reminder.id)", stableID: reminder.id, source: .reminders,
      title: reminder.title, detail: nil, symbol: "checklist", accentHex: reminder.listColorHex,
      state: state, priority: priority, rankingReason: reason, dueAt: reminder.dueDate,
      expiresAt: nil, progress: nil,
      primaryAction: HomeAttentionAction(
        title: "Complete", symbol: "checkmark", kind: .completeReminder(reminder.id)),
      allowsDismiss: true, allowsSnooze: true)
  }

  private static func timerItem(_ timer: HomeTimerSnapshot, now: Date) -> HomeAttentionItem {
    let priority: HomeAttentionPriority
    let reason: String
    let state: String
    if timer.finished {
      priority = .urgent
      reason = "The timer finished"
      state = "Done"
    } else if timer.remaining <= 60 {
      priority = .critical
      reason = "The timer has less than one minute remaining"
      state = timer.isPaused ? "Paused" : "Ends soon"
    } else if timer.remaining <= 5 * 60 {
      priority = .urgent
      reason = "The timer has less than five minutes remaining"
      state = timer.isPaused ? "Paused" : "Running"
    } else {
      priority = .high
      reason = timer.isPaused ? "The timer is paused" : "A countdown is running"
      state = timer.isPaused ? "Paused" : "Running"
    }
    let action =
      timer.finished
      ? HomeAttentionAction(title: "Dismiss", symbol: "xmark", kind: .dismissTimer)
      : HomeAttentionAction(
        title: timer.isPaused ? "Resume" : "Pause",
        symbol: timer.isPaused ? "play.fill" : "pause.fill", kind: .toggleTimer)
    return HomeAttentionItem(
      id: "timer:\(timer.occurrenceID)", stableID: timer.occurrenceID, source: .timer,
      title: timer.label, detail: TimerFormat.mmss(timer.remaining), symbol: "timer",
      accentHex: nil, state: state, priority: priority, rankingReason: reason,
      dueAt: timer.endDate, expiresAt: nil, progress: nil, primaryAction: action,
      allowsDismiss: false, allowsSnooze: false)
  }

  private static func t3Item(_ agent: T3AgentSnapshot) -> HomeAttentionItem {
    let priority: HomeAttentionPriority
    let reason: String
    switch agent.phase {
    case .needsInput, .needsApproval:
      priority = .critical
      reason = "The agent needs your response"
    case .failed:
      priority = .critical
      reason = "The agent failed"
    case .working:
      priority = .high
      reason = "The agent is working"
    case .finished:
      priority = .normal
      reason = "The agent finished recently"
    case .monitoring:
      priority = .low
      reason = "The agent is monitoring"
    }
    return HomeAttentionItem(
      id: "t3:\(agent.id):\(agent.phase.rawValue)", stableID: agent.id, source: .t3Code,
      title: agent.title, detail: agent.project, symbol: agent.phase.symbol, accentHex: nil,
      state: agent.phase.label, priority: priority, rankingReason: reason, dueAt: nil,
      expiresAt: nil, progress: nil,
      primaryAction: HomeAttentionAction(
        title: "Open T3 Code", symbol: "terminal.fill", kind: .openActivity("t3Code")),
      allowsDismiss: true, allowsSnooze: true)
  }

  private static func pulseItem(_ item: PulseItem) -> HomeAttentionItem {
    let priority: HomeAttentionPriority
    let reason: String
    if item.state == .failed {
      priority = .critical
      reason = "The provider reported a failure"
    } else if item.state == .needsAction {
      priority = .critical
      reason = "The provider needs your response"
    } else {
      switch item.priority {
      case .critical:
        priority = .critical
        reason = "The provider marked this critical"
      case .high:
        priority = .high
        reason = "The provider marked this high priority"
      case .normal:
        priority = .normal
        reason = "The provider has an active update"
      case .low:
        priority = .low
        reason = "The provider has a background update"
      }
    }
    let action =
      item.actions.first.map {
        HomeAttentionAction(title: $0.title, symbol: "arrow.up.right", kind: .openURL($0.url))
      }
      ?? HomeAttentionAction(
        title: "Open Pulse", symbol: "waveform.path.ecg", kind: .openActivity("pulse"))
    return HomeAttentionItem(
      id: "pulse:\(item.id):\(item.updatedAt.timeIntervalSinceReferenceDate)",
      stableID: item.id, source: .pulse, title: item.title, detail: item.subtitle,
      symbol: item.symbol, accentHex: item.accentHex, state: pulseStateTitle(item.state),
      priority: priority, rankingReason: reason, dueAt: nil, expiresAt: item.expiresAt,
      progress: item.progress, primaryAction: action, allowsDismiss: true, allowsSnooze: true)
  }

  private static func pulseStateTitle(_ state: PulseState) -> String {
    switch state {
    case .active: "Active"
    case .progress: "In progress"
    case .needsAction: "Needs action"
    case .succeeded: "Succeeded"
    case .failed: "Failed"
    case .cancelled: "Cancelled"
    }
  }

  private static func batteryItem(_ state: BatteryState?) -> HomeAttentionItem? {
    guard let state, !state.onAC, state.percent <= 20 else { return nil }
    let critical = state.percent <= 10
    return HomeAttentionItem(
      id: "battery:low:\(critical ? 10 : 20)", stableID: "internal", source: .battery,
      title: "Low battery", detail: "\(state.percent)% remaining",
      symbol: BatteryActivity.batterySymbol(for: state.percent), accentHex: EventAccent.danger,
      state: critical ? "Charge now" : "Running low", priority: critical ? .critical : .urgent,
      rankingReason: critical ? "Battery is at or below 10%" : "Battery is at or below 20%",
      dueAt: nil, expiresAt: nil, progress: Double(state.percent) / 100,
      primaryAction: HomeAttentionAction(
        title: "Open Battery", symbol: "battery.100percent.bolt",
        kind: .openActivity("battery")),
      allowsDismiss: true, allowsSnooze: true)
  }

  private static func transferItem(count: Int) -> HomeAttentionItem {
    HomeAttentionItem(
      id: "transfer:shelf-import", stableID: "shelf-import", source: .transfer,
      title: count == 1 ? "Adding one Shelf item" : "Adding \(count) Shelf items",
      detail: nil, symbol: "arrow.down.doc", accentHex: nil, state: "Copying",
      priority: .high, rankingReason: "A file transfer is still running", dueAt: nil,
      expiresAt: nil, progress: nil,
      primaryAction: HomeAttentionAction(
        title: "Open Shelf", symbol: "tray.full.fill", kind: .openActivity("shelf")),
      allowsDismiss: false, allowsSnooze: false)
  }
}
