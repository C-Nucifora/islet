import Foundation

struct ReminderDashboardReconciliation {
  enum Mutation: Equatable {
    case insert(ReminderItem)
    case replace(originalID: String, with: ReminderItem)
    case remove(String)
  }

  let reminders: [ReminderItem]
  let hasMoreReminders: Bool
  let requiresReload: Bool

  static func make(
    visibleReminders: [ReminderItem], hasMoreReminders: Bool, mutation: Mutation,
    now: Date = Date(), calendar: Calendar = .current,
    policy: RemindersLogic.DashboardPolicy = .standard
  ) -> ReminderDashboardReconciliation {
    var knownReminders = visibleReminders
    switch mutation {
    case .insert(let item):
      knownReminders.removeAll { $0.id == item.id }
      knownReminders.append(item)
    case .replace(let originalID, let item):
      knownReminders.removeAll { $0.id == originalID }
      knownReminders.removeAll { $0.id == item.id }
      knownReminders.append(item)
    case .remove(let id):
      knownReminders.removeAll { $0.id == id }
    }

    let selection = RemindersLogic.dashboardSelection(
      knownReminders, now: now, calendar: calendar, policy: policy)
    let reminders = RemindersLogic.display(selection.items, limit: policy.displayLimit)
    let requiresReload: Bool
    switch mutation {
    case .replace:
      // The current dashboard does not retain the hidden candidate that may now outrank this item.
      requiresReload = hasMoreReminders
    case .insert, .remove:
      requiresReload = hasMoreReminders && reminders.count < visibleReminders.count
    }
    return ReminderDashboardReconciliation(
      reminders: reminders,
      hasMoreReminders: hasMoreReminders || selection.hasMore,
      requiresReload: requiresReload)
  }
}
