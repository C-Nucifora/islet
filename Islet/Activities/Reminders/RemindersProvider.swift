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
  @Published private(set) var hasMoreReminders = false
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
  private let storeChangeDebouncer = ReminderReloadDebouncer()
  private var reloadState = ReminderReloadState()

  func start() {
    guard !isRunning else { return }
    isRunning = true
    if Defaults[.remindersEnabled] { Task { await refreshAuthorization() } }
    Defaults.publisher(.remindersEnabled)
      .dropFirst()
      .sink { [weak self] change in
        guard change.newValue else {
          self?.storeChangeDebouncer.cancel()
          self?.reloadState.invalidate(clearOptimisticCompletions: true)
          self?.reminders = []
          self?.hasMoreReminders = false
          self?.loadState = .idle
          return
        }
        Task { await self?.refreshAuthorization() }
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
    storeChangeDebouncer.cancel()
    reloadState.invalidate(clearOptimisticCompletions: true)
    reminders = []
    hasMoreReminders = false
    loadState = .idle
    lastActionError = nil
  }

  private func observeStoreChanges() {
    guard !observing else { return }
    observing = true
    NotificationCenter.default
      .publisher(for: .EKEventStoreChanged)
      .sink { [weak self] _ in self?.scheduleStoreChangeReload() }
      .store(in: &cancellables)
  }

  private func scheduleStoreChangeReload() {
    // Reject a fetch that was already in flight when EventKit announced a newer store revision.
    // The debounced fetch starts after notifications have been quiet for a moment.
    reloadState.invalidate(clearOptimisticCompletions: false)
    storeChangeDebouncer.schedule { [weak self] in
      Task { await self?.reload() }
    }
  }

  func requestAccess() async {
    hasRequestedAccess = true
    authorization = EventKitPermissionState(EKEventStore.authorizationStatus(for: .reminder))
    if authorization.canRead {
      if isRunning, Defaults[.remindersEnabled] {
        observeStoreChanges()
        await reload()
      }
      return
    }
    reminders = []
    hasMoreReminders = false
    guard authorization == .notDetermined else { return }
    do {
      let granted = try await store.requestFullAccessToReminders()
      authorization = EventKitPermissionState(EKEventStore.authorizationStatus(for: .reminder))
      if granted, authorization.canRead, isRunning, Defaults[.remindersEnabled] {
        observeStoreChanges()
        await reload()
      } else {
        loadState = .idle
      }
    } catch {
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
    authorization = EventKitPermissionState(EKEventStore.authorizationStatus(for: .reminder))
    if authorization.canRead, isRunning, Defaults[.remindersEnabled] {
      observeStoreChanges()
      await reload()
    } else if isRunning {
      storeChangeDebouncer.cancel()
      reloadState.invalidate(clearOptimisticCompletions: true)
      reminders = []
      hasMoreReminders = false
      loadState = .idle
    }
  }

  func reload() async {
    storeChangeDebouncer.cancel()
    guard isRunning, Defaults[.remindersEnabled] else { return }
    // Re-check authorization so a mid-session revoke flips to "access off" (and re-grant recovers).
    authorization = EventKitPermissionState(EKEventStore.authorizationStatus(for: .reminder))
    guard authorization.canRead else {
      reloadState.invalidate(clearOptimisticCompletions: true)
      reminders = []
      hasMoreReminders = false
      loadState = .idle
      return
    }
    let generation = reloadState.beginReload()
    loadState = .loading
    // EventKit cannot combine a due-date horizon with undated reminders, and it provides no
    // result limit. Fetching all incomplete reminders is therefore required to retain important
    // undated work. The selection below applies the documented 30-day horizon and eight-item
    // budget before titles, colours, and other display fields are materialized.
    let predicate = store.predicateForIncompleteReminders(
      withDueDateStarting: nil, ending: nil, calendars: nil)
    let result: (items: [ReminderItem], hasMore: Bool) = await withCheckedContinuation {
      continuation in
      // Explicitly @Sendable so the closure is NOT @MainActor-isolated: EventKit invokes it on
      // its own queue, and a MainActor-isolated closure would trap on a dispatch-queue assertion.
      let handler: @Sendable ([EKReminder]?) -> Void = { fetched in
        let selection = RemindersLogic.dashboardSelection(
          fetched ?? [], dueDate: { RemindersLogic.dueDate(from: $0.dueDateComponents) },
          priority: \.priority, stableID: \.calendarItemIdentifier)
        let items = selection.items.map { reminder in
          let dueComponents = reminder.dueDateComponents
          let hasDueTime =
            dueComponents?.hour != nil || dueComponents?.minute != nil
            || dueComponents?.second != nil
          return ReminderItem(
            id: reminder.calendarItemIdentifier,
            title: reminder.title ?? "Untitled",
            dueDate: RemindersLogic.dueDate(from: dueComponents),
            hasDueTime: hasDueTime,
            priority: reminder.priority,
            listColorHex: ColorHex.string(from: reminder.calendar?.cgColor))
        }
        continuation.resume(returning: (items, selection.hasMore))
      }
      store.fetchReminders(matching: predicate, completion: handler)
    }
    guard isRunning, Defaults[.remindersEnabled],
      let visibleItems = reloadState.finish(result.items, generation: generation)
    else { return }
    reminders = visibleItems
    hasMoreReminders = result.hasMore
    loadState = .loaded
  }

  func openRemindersApp() {
    guard
      let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.reminders")
    else { return }
    NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
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
      reloadState.markCompleted(item.id)
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
