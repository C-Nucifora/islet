import Foundation

struct ReminderItem: Identifiable, Equatable, Sendable {
  let id: String
  var title: String
  var dueDate: Date?
  /// EventKit represents an all-day due date as midnight. Keep whether the original
  /// `DateComponents` actually contained a clock time so the UI never invents “12:00 am”.
  var hasDueTime: Bool
  var priority: Int  // EventKit: 0 none, 1 high … 9 low
  var listColorHex: String?

  init(
    id: String, title: String, dueDate: Date?, hasDueTime: Bool = true, priority: Int,
    listColorHex: String?
  ) {
    self.id = id
    self.title = title
    self.dueDate = dueDate
    self.hasDueTime = dueDate != nil && hasDueTime
    self.priority = priority
    self.listColorHex = listColorHex
  }
}

enum RemindersLogic {
  /// Bounds the reminders dashboard. Thirty days keeps the compact view focused on work that is
  /// actionable soon, while two reserved slots keep high-priority undated reminders visible.
  struct DashboardPolicy: Equatable, Sendable {
    static let standard = DashboardPolicy(
      horizonDays: 30, displayLimit: 8, reservedUndatedItems: 2)

    let horizonDays: Int
    let displayLimit: Int
    let reservedUndatedItems: Int
  }

  struct DashboardSelection<Item> {
    let items: [Item]
    let hasMore: Bool
  }

  private struct RankedDashboardItem<Item> {
    let item: Item
    let dueDate: Date?
    let priority: Int
    let stableID: String
  }

  enum SnoozePreset: String, CaseIterable, Sendable {
    case oneHour
    case tomorrowMorning

    var title: String {
      switch self {
      case .oneHour: "In 1 Hour"
      case .tomorrowMorning: "Tomorrow Morning"
      }
    }
  }

  /// Resolves EventKit date components in their declared calendar/time zone, falling back to the
  /// user's current local calendar. `DateComponents.date` can be nil or use surprising defaults
  /// when a provider omits one of those fields.
  static func dueDate(
    from components: DateComponents?, fallbackCalendar: Calendar = .current
  ) -> Date? {
    guard let components else { return nil }
    var calendar = components.calendar ?? fallbackCalendar
    if let timeZone = components.timeZone { calendar.timeZone = timeZone }
    return calendar.date(from: components)
  }

  static func dueComponents(
    for date: Date, hasTime: Bool, calendar: Calendar = .current
  ) -> DateComponents {
    var components = calendar.dateComponents(
      hasTime ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day], from: date)
    components.calendar = calendar
    components.timeZone = calendar.timeZone
    return components
  }

  /// Concrete dates for the dashboard's quick-snooze actions. Calendar arithmetic keeps the
  /// actions correct through daylight-saving changes instead of assuming every day is 86,400 s.
  static func snoozeDate(
    _ preset: SnoozePreset, from now: Date, calendar: Calendar = .current
  ) -> Date? {
    switch preset {
    case .oneHour:
      return calendar.date(byAdding: .hour, value: 1, to: now)
    case .tomorrowMorning:
      guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) else { return nil }
      return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow)
    }
  }

  /// Ordering for the dashboard: dated reminders first (soonest due first),
  /// then undated, then by EventKit priority (1 highest, treating 0/none as lowest).
  static func display(_ items: [ReminderItem], limit: Int = 8) -> [ReminderItem] {
    let sorted = items.sorted { a, b in
      switch (a.dueDate, b.dueDate) {
      case (let da?, let db?):
        if da != db { return da < db }
      case (.some, .none):
        return true
      case (.none, .some):
        return false
      case (.none, .none):
        break
      }
      return priorityRank(a.priority) < priorityRank(b.priority)
    }
    return Array(sorted.prefix(limit))
  }

  /// Selects the small set materialized for the dashboard without first mapping the whole EventKit
  /// result. EventKit has no result limit or undated-only predicate, so callers still inspect each
  /// fetched object. This keeps only `displayLimit` dated and undated candidates in memory.
  static func dashboardSelection<Item>(
    _ items: [Item], now: Date = Date(), calendar: Calendar = .current,
    policy: DashboardPolicy = .standard, dueDate: (Item) -> Date?, priority: (Item) -> Int,
    stableID: (Item) -> String
  ) -> DashboardSelection<Item> {
    let limit = max(0, policy.displayLimit)
    guard limit > 0 else { return DashboardSelection(items: [], hasMore: !items.isEmpty) }

    let horizon =
      calendar.date(byAdding: .day, value: max(0, policy.horizonDays), to: now) ?? now
    var dated: [RankedDashboardItem<Item>] = []
    var undated: [RankedDashboardItem<Item>] = []

    for item in items {
      let due = dueDate(item)
      let ranked = RankedDashboardItem(
        item: item, dueDate: due, priority: priority(item), stableID: stableID(item))
      if let due {
        guard due <= horizon else { continue }
        insertBounded(ranked, into: &dated, limit: limit, orderedBy: datedBefore)
      } else {
        insertBounded(ranked, into: &undated, limit: limit, orderedBy: undatedBefore)
      }
    }

    let prioritizedUndatedCount = undated.lazy.filter { $0.priority != 0 }.count
    let undatedReserve = min(
      max(0, policy.reservedUndatedItems), prioritizedUndatedCount, limit)
    let datedCount = min(dated.count, limit - undatedReserve)
    let undatedCount = min(undated.count, limit - datedCount)
    let selected = dated.prefix(datedCount).map(\.item) + undated.prefix(undatedCount).map(\.item)
    return DashboardSelection(items: selected, hasMore: items.count > selected.count)
  }

  static func dashboardSelection(
    _ items: [ReminderItem], now: Date = Date(), calendar: Calendar = .current,
    policy: DashboardPolicy = .standard
  ) -> DashboardSelection<ReminderItem> {
    dashboardSelection(
      items, now: now, calendar: calendar, policy: policy, dueDate: \.dueDate,
      priority: \.priority, stableID: \.id)
  }

  /// Whether a reminder is overdue relative to `now` (has a due date in the past).
  static func isOverdue(_ item: ReminderItem, now: Date) -> Bool {
    guard let due = item.dueDate else { return false }
    // A date-only reminder is due for the whole local calendar day, not at its synthetic
    // midnight representation.
    if !item.hasDueTime, Calendar.current.isDate(due, inSameDayAs: now) { return false }
    return due < now
  }

  /// Maps EventKit priority (0 = none, 1 = high, 9 = low) to a sortable rank (lower = higher).
  private static func priorityRank(_ priority: Int) -> Int {
    priority == 0 ? Int.max : priority
  }

  private static func datedBefore<Item>(
    _ lhs: RankedDashboardItem<Item>, _ rhs: RankedDashboardItem<Item>
  ) -> Bool {
    if let lhsDueDate = lhs.dueDate, let rhsDueDate = rhs.dueDate, lhsDueDate != rhsDueDate {
      return lhsDueDate < rhsDueDate
    }
    let lhsPriority = priorityRank(lhs.priority)
    let rhsPriority = priorityRank(rhs.priority)
    if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
    return lhs.stableID < rhs.stableID
  }

  private static func undatedBefore<Item>(
    _ lhs: RankedDashboardItem<Item>, _ rhs: RankedDashboardItem<Item>
  ) -> Bool {
    let lhsPriority = priorityRank(lhs.priority)
    let rhsPriority = priorityRank(rhs.priority)
    if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
    return lhs.stableID < rhs.stableID
  }

  private static func insertBounded<Item>(
    _ candidate: RankedDashboardItem<Item>, into items: inout [RankedDashboardItem<Item>],
    limit: Int,
    orderedBy areInIncreasingOrder: (
      RankedDashboardItem<Item>, RankedDashboardItem<Item>
    ) -> Bool
  ) {
    items.append(candidate)
    items.sort(by: areInIncreasingOrder)
    if items.count > limit { items.removeLast() }
  }
}
