import AppKit
import Combine
import Defaults
import EventKit
import Foundation

/// Loads incomplete reminders via EventKit and completes them on request.
/// Only requests access once the feature is enabled, to avoid an unwanted permission prompt.
@MainActor
final class RemindersProvider: ObservableObject {
  static let shared = RemindersProvider()

  @Published private(set) var reminders: [ReminderItem] = []
  @Published private(set) var accessDenied = false
  @Published private(set) var hasRequestedAccess = false

  private let store = EKEventStore()
  private var cancellables: Set<AnyCancellable> = []
  private var observing = false

  func start() {
    if Defaults[.remindersEnabled] { Task { await requestAccess() } }
    Defaults.publisher(.remindersEnabled)
      .dropFirst()
      .sink { [weak self] change in
        guard change.newValue else {
          self?.reminders = []
          return
        }
        Task { await self?.requestAccess() }
      }
      .store(in: &cancellables)
    // Reflect grants made in System Settings immediately after the app becomes active again.
    NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
      .sink { [weak self] _ in Task { await self?.refreshAuthorization() } }
      .store(in: &cancellables)
  }

  private func observeStoreChanges() {
    guard !observing else { return }
    observing = true
    NotificationCenter.default
      .publisher(for: .EKEventStoreChanged, object: store)
      .sink { [weak self] _ in Task { await self?.reload() } }
      .store(in: &cancellables)
  }

  func requestAccess() async {
    hasRequestedAccess = true
    do {
      let granted = try await store.requestFullAccessToReminders()
      accessDenied = !granted
      if granted {
        observeStoreChanges()
        await reload()
      }
    } catch {
      accessDenied = true
      Log.app.error("Reminders access error: \(error.localizedDescription)")
    }
  }

  private func refreshAuthorization() async {
    let status = EKEventStore.authorizationStatus(for: .reminder)
    accessDenied = status != .fullAccess
    if status == .fullAccess {
      observeStoreChanges()
      await reload()
    }
  }

  func reload() async {
    guard Defaults[.remindersEnabled] else { return }
    // Re-check authorization so a mid-session revoke flips to "access off" (and re-grant recovers).
    accessDenied = EKEventStore.authorizationStatus(for: .reminder) != .fullAccess
    guard !accessDenied else {
      reminders = []
      return
    }
    let predicate = store.predicateForIncompleteReminders(
      withDueDateStarting: nil, ending: nil, calendars: nil)
    let items: [ReminderItem] = await withCheckedContinuation { continuation in
      // Explicitly @Sendable so the closure is NOT @MainActor-isolated: EventKit invokes it on
      // its own queue, and a MainActor-isolated closure would trap on a dispatch-queue assertion.
      let handler: @Sendable ([EKReminder]?) -> Void = { fetched in
        let mapped = (fetched ?? []).map { r in
          ReminderItem(
            id: r.calendarItemIdentifier,
            title: r.title ?? "Untitled",
            dueDate: r.dueDateComponents?.date,
            priority: r.priority,
            listColorHex: ColorHex.string(from: r.calendar?.cgColor))
        }
        continuation.resume(returning: mapped)
      }
      store.fetchReminders(matching: predicate, completion: handler)
    }
    reminders = RemindersLogic.display(items)
  }

  /// Marks a reminder complete and refreshes.
  func complete(_ item: ReminderItem) {
    guard let reminder = store.calendarItem(withIdentifier: item.id) as? EKReminder else {
      return
    }
    reminder.isCompleted = true
    do {
      try store.save(reminder, commit: true)
      reminders.removeAll { $0.id == item.id }  // optimistic; store-change reload confirms
    } catch {
      Log.app.error("Failed to complete reminder: \(error.localizedDescription)")
    }
  }
}
