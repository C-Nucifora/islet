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
}
