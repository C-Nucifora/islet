import Foundation

struct ReminderItem: Identifiable, Equatable, Sendable {
  let id: String
  var title: String
  var dueDate: Date?
  var priority: Int  // EventKit: 0 none, 1 high … 9 low
  var listColorHex: String?
}

enum RemindersLogic {
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
    return due < now
  }

  /// Maps EventKit priority (0 = none, 1 = high, 9 = low) to a sortable rank (lower = higher).
  private static func priorityRank(_ priority: Int) -> Int {
    priority == 0 ? Int.max : priority
  }
}
