import Foundation

struct ReminderCommandPresentation {
  enum Intent: Equatable {
    case create
    case complete
    case undo
    case edit
    case snooze(RemindersLogic.SnoozePreset)
    case customSnooze
    case move(toListID: String)
  }

  enum Route: Equatable {
    case create
    case complete(ReminderItem)
    case undo
    case edit(ReminderItem)
    case snooze(ReminderItem, preset: RemindersLogic.SnoozePreset)
    case customSnooze(ReminderItem)
    case move(ReminderItem, toListID: String)
  }

  let reminders: [ReminderItem]
  let selectedReminderID: String?
  let writableListIDs: Set<String>
  let hasCompletionUndo: Bool

  init(
    reminders: [ReminderItem], selectedReminderID: String?, writableListIDs: Set<String>,
    hasCompletionUndo: Bool
  ) {
    self.reminders = reminders
    self.selectedReminderID = selectedReminderID
    self.writableListIDs = writableListIDs
    self.hasCompletionUndo = hasCompletionUndo
  }

  func route(for intent: Intent) -> Route? {
    switch intent {
    case .create:
      return .create
    case .undo:
      return hasCompletionUndo ? .undo : nil
    case .complete, .edit, .snooze, .customSnooze, .move:
      guard let selectedReminder else { return nil }
      switch intent {
      case .complete:
        return .complete(selectedReminder)
      case .edit:
        return .edit(selectedReminder)
      case .snooze(let preset):
        return .snooze(selectedReminder, preset: preset)
      case .customSnooze:
        return .customSnooze(selectedReminder)
      case .move(let listID):
        guard writableListIDs.contains(listID) else { return nil }
        return .move(selectedReminder, toListID: listID)
      case .create, .undo:
        return nil
      }
    }
  }

  private var selectedReminder: ReminderItem? {
    reminders.first { $0.id == selectedReminderID }
  }
}
