import Foundation

struct ReminderDashboardPresentation: Equatable {
  enum Action: Hashable {
    case create
    case undo
  }

  enum Content: Equatable {
    case loading
    case failed(String)
    case empty(message: String, showsMore: Bool)
    case items
  }

  let actions: Set<Action>
  let content: Content

  static func make(
    loadState: RemindersProvider.LoadState,
    reminderCount: Int,
    hasMoreReminders: Bool,
    hasCompletionUndo: Bool
  ) -> ReminderDashboardPresentation {
    var actions: Set<Action> = [.create]
    if hasCompletionUndo { actions.insert(.undo) }

    let content: Content
    switch loadState {
    case .loading:
      content = .loading
    case .failed(let message):
      content = .failed(message)
    case .idle, .loaded:
      if reminderCount > 0 {
        content = .items
      } else if hasMoreReminders {
        content = .empty(message: "No reminders due soon", showsMore: true)
      } else {
        content = .empty(message: "All clear", showsMore: false)
      }
    }

    return ReminderDashboardPresentation(actions: actions, content: content)
  }
}
