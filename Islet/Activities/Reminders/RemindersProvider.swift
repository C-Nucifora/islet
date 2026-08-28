import AppKit
import Combine
import Defaults
import EventKit
import Foundation

/// Loads incomplete reminders via EventKit and completes them on request.
/// Only requests access once the feature is enabled, to avoid an unwanted permission prompt.
@MainActor
final class RemindersProvider: ObservableObject {
  enum LoadState: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)
  }

  static let shared = RemindersProvider()

  @Published private(set) var reminders: [ReminderItem] = []
  @Published private(set) var authorization = EventKitPermissionState(
    EKEventStore.authorizationStatus(for: .reminder))
  @Published private(set) var hasRequestedAccess = false
  @Published private(set) var loadState: LoadState = .idle
  @Published private(set) var lastActionError: String?

  var accessDenied: Bool { !authorization.canRead }

  private let store = EKEventStore()
  private var cancellables: Set<AnyCancellable> = []
  private var observing = false
  private var isRunning = false
  /// Invalidates EventKit callbacks that arrive after a stop, disable, or newer reload.
  private var reloadGeneration = 0

  func start() {
    guard !isRunning else { return }
    isRunning = true
    if Defaults[.remindersEnabled] { Task { await requestAccess() } }
    Defaults.publisher(.remindersEnabled)
      .dropFirst()
      .sink { [weak self] change in
        guard change.newValue else {
          self?.reloadGeneration += 1
          self?.reminders = []
          self?.loadState = .idle
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

  func stop() {
    guard isRunning else { return }
    isRunning = false
    cancellables.removeAll()
    observing = false
    reloadGeneration += 1
    reminders = []
    loadState = .idle
    lastActionError = nil
  }

  private func observeStoreChanges() {
    guard !observing else { return }
    observing = true
    NotificationCenter.default
      .publisher(for: .EKEventStoreChanged)
      .sink { [weak self] _ in Task { await self?.reload() } }
      .store(in: &cancellables)
  }

  func requestAccess() async {
    guard isRunning, Defaults[.remindersEnabled] else { return }
    hasRequestedAccess = true
    authorization = EventKitPermissionState(EKEventStore.authorizationStatus(for: .reminder))
    if authorization.canRead {
      observeStoreChanges()
      await reload()
      return
    }
    reminders = []
    guard authorization == .notDetermined else { return }
    do {
      let granted = try await store.requestFullAccessToReminders()
      guard isRunning, Defaults[.remindersEnabled] else { return }
      authorization = EventKitPermissionState(EKEventStore.authorizationStatus(for: .reminder))
      if granted, authorization.canRead {
        observeStoreChanges()
        await reload()
      } else {
        loadState = .idle
      }
    } catch {
      guard isRunning, Defaults[.remindersEnabled] else { return }
      authorization = EventKitPermissionState(EKEventStore.authorizationStatus(for: .reminder))
      loadState = .failed(error.localizedDescription)
      Log.app.error("Reminders access error: \(error.localizedDescription)")
    }
  }

  func recoverAccess() async {
    await refreshAuthorization()
    if authorization == .notDetermined {
      await requestAccess()
    } else if authorization.requiresSettingsRecovery {
      SystemSettingsPrivacyPane.reminders.open()
    }
  }

  func refreshAuthorization() async {
    guard isRunning, Defaults[.remindersEnabled] else { return }
    authorization = EventKitPermissionState(EKEventStore.authorizationStatus(for: .reminder))
    if authorization.canRead {
      observeStoreChanges()
      await reload()
    } else {
      reloadGeneration += 1
      reminders = []
      loadState = .idle
    }
  }

  func reload() async {
    guard isRunning, Defaults[.remindersEnabled] else { return }
    // Re-check authorization so a mid-session revoke flips to "access off" (and re-grant recovers).
    authorization = EventKitPermissionState(EKEventStore.authorizationStatus(for: .reminder))
    guard authorization.canRead else {
      reloadGeneration += 1
      reminders = []
      loadState = .idle
      return
    }
    reloadGeneration += 1
    let generation = reloadGeneration
    loadState = .loading
    let predicate = store.predicateForIncompleteReminders(
      withDueDateStarting: nil, ending: nil, calendars: nil)
    let items: [ReminderItem] = await withCheckedContinuation { continuation in
      // Explicitly @Sendable so the closure is NOT @MainActor-isolated: EventKit invokes it on
      // its own queue, and a MainActor-isolated closure would trap on a dispatch-queue assertion.
      let handler: @Sendable ([EKReminder]?) -> Void = { fetched in
        let mapped = (fetched ?? []).map { r in
          let dueComponents = r.dueDateComponents
          let hasDueTime =
            dueComponents?.hour != nil || dueComponents?.minute != nil
            || dueComponents?.second != nil
          ReminderItem(
            id: r.calendarItemIdentifier,
            title: r.title ?? "Untitled",
            dueDate: RemindersLogic.dueDate(from: dueComponents),
            hasDueTime: hasDueTime,
            priority: r.priority,
            listColorHex: ColorHex.string(from: r.calendar?.cgColor))
        }
        continuation.resume(returning: mapped)
      }
      store.fetchReminders(matching: predicate, completion: handler)
    }
    guard generation == reloadGeneration, isRunning, Defaults[.remindersEnabled] else { return }
    reminders = RemindersLogic.display(items)
    loadState = .loaded
  }

  /// Marks a reminder complete and refreshes.
  func complete(_ item: ReminderItem) {
    guard let reminder = store.calendarItem(withIdentifier: item.id) as? EKReminder else {
      lastActionError = "That reminder is no longer available."
      Task { await reload() }
      return
    }
    reminder.isCompleted = true
    do {
      try store.save(reminder, commit: true)
      lastActionError = nil
      reminders.removeAll { $0.id == item.id }  // optimistic; store-change reload confirms
    } catch {
      lastActionError = "Couldn’t complete \(item.title)."
      Log.app.error("Failed to complete reminder: \(error.localizedDescription)")
    }
  }

  /// Moves a reminder without changing its list, notes, recurrence, or other EventKit metadata.
  /// This is the model operation used by future quick-snooze surfaces and automation actions.
  @discardableResult
  func reschedule(_ item: ReminderItem, to date: Date, hasTime: Bool = true) -> Bool {
    guard authorization.canRead,
      let reminder = store.calendarItem(withIdentifier: item.id) as? EKReminder
    else {
      lastActionError = "That reminder is no longer available."
      return false
    }
    reminder.dueDateComponents = RemindersLogic.dueComponents(for: date, hasTime: hasTime)
    do {
      try store.save(reminder, commit: true)
      lastActionError = nil
      if let index = reminders.firstIndex(where: { $0.id == item.id }) {
        reminders[index].dueDate = date
        reminders[index].hasDueTime = hasTime
        reminders = RemindersLogic.display(reminders)
      }
      return true
    } catch {
      lastActionError = "Couldn’t reschedule \(item.title)."
      Log.app.error("Failed to reschedule reminder: \(error.localizedDescription)")
      return false
    }
  }

  /// User-facing quick snooze. Snoozes intentionally gain a clock time, even when the original
  /// reminder was date-only, because both presets represent a specific future notification time.
  @discardableResult
  func snooze(
    _ item: ReminderItem, preset: RemindersLogic.SnoozePreset, now: Date = Date()
  ) -> Bool {
    guard let date = RemindersLogic.snoozeDate(preset, from: now) else {
      lastActionError = "Couldn’t calculate a new due date."
      return false
    }
    return reschedule(item, to: date, hasTime: true)
  }

  func dismissActionError() { lastActionError = nil }
}
