import AppKit
import Combine
import Defaults
import EventKit
import Foundation

/// Queries reminders through a store isolated from writer resets and authoritative readback.
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
  @Published private(set) var availableLists: [ReminderListItem] = []
  @Published private(set) var completionUndo: ReminderWriteCoordinator.CompletionUndo?
  @Published private(set) var editorSession: ReminderEditorSession?

  var accessDenied: Bool { !authorization.canRead }

  private let store: EKEventStore
  private let writes: ReminderWriteCoordinator
  private var cancellables: Set<AnyCancellable> = []
  private var observing = false
  private var isRunning = false
  private let storeChangeDebouncer = ReminderReloadDebouncer()
  private var reloadState = ReminderReloadState()
  private var undoExpiryTask: Task<Void, Never>?
  private var pendingReconciliationTask: Task<Void, Never>?

  init(store: EKEventStore = EKEventStore(), writes: ReminderWriteCoordinator? = nil) {
    self.store = store
    if let writes {
      self.writes = writes
    } else {
      let stores = ReminderEventKitStoreRoles(queryStore: store)
      self.writes = ReminderWriteCoordinator(
        store: EventKitReminderWriteStore(
          store: stores.writeStore,
          authoritativeReadbackStore: stores.authoritativeReadbackStore))
    }
  }

  func start() {
    guard !isRunning else { return }
    isRunning = true
    if Defaults[.remindersEnabled] { Task { await refreshAuthorization() } }
    Defaults.publisher(.remindersEnabled)
      .dropFirst()
      .receive(on: DispatchQueue.main)
      .sink { [weak self] change in
        guard change.newValue else {
          self?.storeChangeDebouncer.cancel()
          self?.reloadState.invalidate(clearOptimisticCompletions: true)
          self?.reminders = []
          self?.availableLists = []
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
    undoExpiryTask?.cancel()
    undoExpiryTask = nil
    pendingReconciliationTask?.cancel()
    pendingReconciliationTask = nil
    reminders = []
    availableLists = []
    completionUndo = nil
    if editorSession?.isPending != true { editorSession = nil }
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
      availableLists = writes.lists()
      observeStoreChanges()
      await reload()
    } else if isRunning {
      storeChangeDebouncer.cancel()
      reloadState.invalidate(clearOptimisticCompletions: true)
      reminders = []
      availableLists = []
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
      availableLists = []
      hasMoreReminders = false
      loadState = .idle
      return
    }
    let generation = reloadState.beginReload()
    let pendingIdentity = editorSession.flatMap { session in
      session.draft.pendingCommitReceipt.map {
        ReminderEditorPendingIdentity(sessionID: session.id, receipt: $0)
      }
    }
    loadState = .loading
    let predicate = store.predicateForIncompleteReminders(
      withDueDateStarting: nil, ending: nil, calendars: nil)
    let result: (items: [ReminderItem], hasMore: Bool) = await withCheckedContinuation {
      continuation in
      // Explicitly @Sendable so the closure is NOT @MainActor-isolated: EventKit invokes it on
      // its own queue, and a MainActor-isolated closure would trap on a dispatch-queue assertion.
      let handler: @Sendable ([EKReminder]?) -> Void = { fetched in
        let selection = RemindersLogic.dashboardSelection(
          fetched ?? [],
          dueDate: { RemindersLogic.dueDate(from: $0.dueDateComponents) },
          priority: \.priority, stableID: \.calendarItemIdentifier)
        let items = selection.items.map { r in
          let dueComponents = r.dueDateComponents
          let hasDueTime =
            dueComponents?.hour != nil || dueComponents?.minute != nil
            || dueComponents?.second != nil
          return ReminderItem(
            id: r.calendarItemIdentifier,
            title: r.title ?? "Untitled",
            dueDate: RemindersLogic.dueDate(from: dueComponents),
            hasDueTime: hasDueTime,
            priority: r.priority,
            listColorHex: ColorHex.string(from: r.calendar?.cgColor),
            listID: r.calendar?.calendarIdentifier,
            listTitle: r.calendar?.title)
        }
        continuation.resume(returning: (items, selection.hasMore))
      }
      store.fetchReminders(matching: predicate, completion: handler)
    }
    guard isRunning, Defaults[.remindersEnabled],
      let visibleItems = reloadState.finish(result.items, generation: generation)
    else { return }
    reminders = RemindersLogic.display(visibleItems)
    availableLists = writes.lists()
    hasMoreReminders = result.hasMore
    loadState = .loaded
    reconcilePendingEditorSessionAfterAcceptedReload(expectedIdentity: pendingIdentity)
  }

  @discardableResult
  func openRemindersApp() -> Bool {
    guard
      let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.reminders")
    else { return false }
    NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    return true
  }

  var hasEditorSession: Bool { editorSession != nil }
  var hasPendingEditorSession: Bool { editorSession?.isPending == true }

  @discardableResult
  func beginEditorSession(for item: ReminderItem?) -> Bool {
    if editorSession != nil { return true }

    availableLists = writes.lists()
    let coordinatorDraft: ReminderCoordinatorDraft
    if let item {
      switch writes.writeDraft(for: item) {
      case .success(let draft):
        coordinatorDraft = draft
      case .failure(let error):
        report(error, action: "open \(item.title) for editing")
        return false
      }
    } else {
      coordinatorDraft = ReminderCoordinatorDraft(
        title: "",
        listID: ReminderEditorPresentation.initialListID(
          defaultID: writes.defaultListID(), lists: availableLists))
    }

    var calendar = Calendar(identifier: .gregorian)
    let displayTimeZone = TimeZone.current
    calendar.timeZone = displayTimeZone
    editorSession = ReminderEditorSession(
      draft: coordinatorDraft, calendar: calendar, displayTimeZone: displayTimeZone)
    lastActionError = nil
    return true
  }

  func updateEditorDraft(_ draft: ReminderCoordinatorDraft) {
    guard var session = editorSession,
      !ReminderEditorPresentation.isReadOnly(session.draft)
    else { return }
    session.draft = draft
    editorSession = session
  }

  func reportEditorFieldError(_ message: ReminderEditorFieldMessage) {
    guard var session = editorSession,
      !ReminderEditorPresentation.isReadOnly(session.draft)
    else { return }
    session.fieldMessages.removeAll { $0.field == message.field }
    session.fieldMessages.append(message)
    editorSession = session
  }

  func cancelEditorSession() {
    guard editorSession?.isPending != true else { return }
    editorSession = nil
  }

  func editorWindowDidClose() {
    cancelEditorSession()
  }

  func startNewEditorSession() {
    if editorSession?.isPending == true { return }
    availableLists = writes.lists()
    var calendar = Calendar(identifier: .gregorian)
    let displayTimeZone = TimeZone.current
    calendar.timeZone = displayTimeZone
    editorSession = ReminderEditorSession(
      draft: ReminderCoordinatorDraft(
        title: "",
        listID: ReminderEditorPresentation.initialListID(
          defaultID: writes.defaultListID(), lists: availableLists)),
      calendar: calendar, displayTimeZone: displayTimeZone)
    lastActionError = nil
  }

  @discardableResult
  func submitEditorSession() -> Bool {
    guard var session = editorSession else { return false }
    switch ReminderEditorPresentation.prepareForSubmission(session.draft) {
    case .invalid(let draft, let messages):
      session.draft = draft
      session.fieldMessages = messages
      session.generalMessage = messages.first?.message
      editorSession = session
      lastActionError = session.generalMessage
      return false
    case .valid(let draft):
      session.draft = draft
      session.fieldMessages = []
      session.generalMessage = nil
    }

    let originalID = session.draft.reminderID
    let result =
      originalID == nil
      ? writes.createOutcome(session.draft)
      : writes.updateOutcome(session.draft)
    switch result {
    case .failure(let error):
      session.generalMessage = error.localizedDescription
      editorSession = session
      report(error, action: originalID == nil ? "create reminder" : "update reminder")
      availableLists = writes.lists()
      return false
    case .success(let write):
      availableLists = writes.lists()
      if retainEditorSession(for: write, existingSession: session) { return false }
      switch write.outcome {
      case .noChanges:
        editorSession = nil
        lastActionError = nil
        return true
      case .saved(let record):
        if let originalID {
          reconcileDashboard(.replace(originalID: originalID, with: record.item))
        } else {
          reconcileDashboard(.insert(record.item))
        }
        editorSession = nil
        lastActionError = nil
        return true
      case .committedWithNormalization, .commitStatusUnknown:
        assertionFailure("Attention-requiring write did not retain an editor session")
        return false
      }
    }
  }

  func deletionPayload() -> ReminderEditorDeletionPayload? {
    guard let session = editorSession,
      ReminderEditorPresentation.canDelete(session.draft)
    else {
      return nil
    }
    return ReminderEditorDeletionPayload(sessionID: session.id, draft: session.draft)
  }

  func confirmDeletion(_ payload: ReminderEditorDeletionPayload) {
    let name = payload.draft.baselineRecord?.title ?? payload.draft.title
    let alert = NSAlert()
    alert.messageText = "Delete \"\(name)\"?"
    alert.informativeText = "This reminder will be removed from its Reminders list."
    alert.alertStyle = .warning
    configure(
      alert, buttons: ReminderEditorAlertConfiguration.deleteButtons)
    guard alert.runModal() == .alertSecondButtonReturn else { return }

    switch writes.delete(payload.draft) {
    case .success:
      if editorSession?.id == payload.sessionID { editorSession = nil }
      lastActionError = nil
      availableLists = writes.lists()
      requestEditorReload()
    case .failure(let error):
      if var session = editorSession, session.id == payload.sessionID {
        session.generalMessage = error.localizedDescription
        editorSession = session
      }
      report(error, action: "delete \(name)")
      availableLists = writes.lists()
    }
  }

  func confirmRemindersHandoffAndStopWaiting(
    onAbandoned: @escaping @MainActor @Sendable () -> Void = {}
  ) {
    guard let session = editorSession,
      let receipt = session.draft.pendingCommitReceipt
    else { return }
    let alert = NSAlert()
    alert.messageText = "Stop waiting for this reminder?"
    alert.informativeText =
      "Islet will open Reminders and stop trying to confirm the pending commit."
    alert.alertStyle = .warning
    configure(
      alert, buttons: ReminderEditorAlertConfiguration.stopWaitingButtons)
    guard alert.runModal() == .alertSecondButtonReturn else { return }

    let expectedIdentity = ReminderEditorPendingIdentity(
      sessionID: session.id, receipt: receipt)
    guard
      let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.reminders")
    else {
      applyRemindersHandoffCompletion(
        expectedIdentity: expectedIdentity, openedRunningApplication: false,
        errorDescription: "The Reminders application could not be found.",
        onAbandoned: onAbandoned)
      return
    }

    NSWorkspace.shared.openApplication(
      at: url, configuration: NSWorkspace.OpenConfiguration()
    ) { [weak self] application, error in
      let openedRunningApplication = application != nil
      let errorDescription = error?.localizedDescription
      Task { @MainActor [weak self] in
        self?.applyRemindersHandoffCompletion(
          expectedIdentity: expectedIdentity,
          openedRunningApplication: openedRunningApplication,
          errorDescription: errorDescription, onAbandoned: onAbandoned)
      }
    }
  }

  /// Marks a reminder complete and offers one short, source-revision-bound undo.
  func complete(_ item: ReminderItem) {
    switch writes.completeOutcome(item) {
    case .failure(let error):
      report(error, action: "complete \(item.title)")
    case .success(let completion):
      completionUndo = completion.undo
      if let undo = completion.undo {
        scheduleUndoExpiry(undo)
      } else {
        undoExpiryTask?.cancel()
        undoExpiryTask = nil
      }
      _ = routeQuickWrite(.success(completion.write), action: "complete \(item.title)") {
        outcome in
        guard case .saved = outcome, completion.undo != nil else {
          return .failure(.missingCompletionDate)
        }
        reloadState.markCompleted(item.id)
        reconcileDashboard(.remove(item.id))
        return .success(())
      }
    }
  }

  @discardableResult
  func create(_ draft: ReminderDraft) -> Bool {
    switch writes.create(draft) {
    case .success(let item):
      lastActionError = nil
      reconcileDashboard(.insert(item))
      availableLists = writes.lists()
      return true
    case .failure(let error):
      report(error, action: "create reminder")
      availableLists = writes.lists()
      return false
    }
  }

  @discardableResult
  func update(_ item: ReminderItem, with draft: ReminderDraft) -> Bool {
    apply(writes.update(item, with: draft), replacing: item, action: "update \(item.title)")
  }

  /// Changes only the reminder's calendar. EventKit retains notes, recurrence, due date and
  /// priority because the coordinator starts from the store's current record.
  @discardableResult
  func move(_ item: ReminderItem, toListWithID listID: String) -> Bool {
    routeQuickWrite(
      writes.moveOutcome(item, toListWithID: listID), action: "move \(item.title)"
    ) { outcome in
      guard let record = exactRecord(from: outcome) else {
        return .failure(.normalizedQuickWrite)
      }
      reconcileDashboard(.replace(originalID: item.id, with: record.item))
      return .success(())
    }
  }

  @discardableResult
  func reschedule(_ item: ReminderItem, to date: Date, hasTime: Bool = true) -> Bool {
    routeQuickWrite(
      writes.rescheduleOutcome(item, to: date, hasTime: hasTime),
      action: "reschedule \(item.title)"
    ) { outcome in
      guard let record = exactRecord(from: outcome) else {
        return .failure(.normalizedQuickWrite)
      }
      reconcileDashboard(.replace(originalID: item.id, with: record.item))
      return .success(())
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

  func undoLastCompletion() {
    undoExpiryTask?.cancel()
    undoExpiryTask = nil
    completionUndo = nil
    let succeeded = routeQuickWrite(
      writes.undoCompletionOutcome(), action: "undo completion"
    ) { outcome in
      guard case .saved(let record) = outcome else {
        return .failure(.noUndoAvailable)
      }
      reloadState.restoreCompleted(record.id)
      reconcileDashboard(.insert(record.item))
      return .success(())
    }
    if !succeeded, editorSession == nil { Task { await reload() } }
  }

  func defaultDraft() -> ReminderDraft {
    var draft = ReminderDraft.empty
    draft.listID = writes.defaultListID()
    return draft
  }

  func draft(for item: ReminderItem) -> ReminderDraft? {
    switch writes.draft(for: item) {
    case .success(let draft):
      lastActionError = nil
      return draft
    case .failure(let error):
      report(error, action: "open \(item.title) for editing")
      availableLists = writes.lists()
      return nil
    }
  }

  private func apply(
    _ result: Result<ReminderItem, ReminderWriteError>, replacing original: ReminderItem,
    action: String
  ) -> Bool {
    switch result {
    case .success(let item):
      lastActionError = nil
      reconcileDashboard(.replace(originalID: original.id, with: item))
      availableLists = writes.lists()
      return true
    case .failure(let error):
      report(error, action: action)
      availableLists = writes.lists()
      return false
    }
  }

  private func routeQuickWrite(
    _ result: Result<ReminderCoordinatorWrite, ReminderWriteError>, action: String,
    onExact: (ReminderCoordinatorOutcome) -> Result<Void, ReminderWriteError>
  ) -> Bool {
    switch result {
    case .failure(let error):
      report(error, action: action)
      availableLists = writes.lists()
      return false
    case .success(let write):
      availableLists = writes.lists()
      if retainEditorSession(for: write, existingSession: nil) { return false }
      switch write.outcome {
      case .noChanges, .saved:
        switch onExact(write.outcome) {
        case .success:
          lastActionError = nil
          return true
        case .failure(let error):
          report(error, action: action)
          return false
        }
      case .committedWithNormalization, .commitStatusUnknown:
        assertionFailure("Attention-requiring quick write did not retain an editor session")
        return false
      }
    }
  }

  private func exactRecord(from outcome: ReminderCoordinatorOutcome) -> ReminderWriteRecord? {
    switch outcome {
    case .noChanges(let record), .saved(let record): record
    case .committedWithNormalization, .commitStatusUnknown: nil
    }
  }

  @discardableResult
  private func retainEditorSession(
    for write: ReminderCoordinatorWrite, existingSession: ReminderEditorSession?
  ) -> Bool {
    var calendar = Calendar(identifier: .gregorian)
    let displayTimeZone = TimeZone.current
    calendar.timeZone = displayTimeZone
    guard
      let retention = ReminderEditorPresentation.retention(
        for: write, existingSession: existingSession,
        calendar: calendar, displayTimeZone: displayTimeZone)
    else { return false }

    if retention.invalidatesReloadGeneration {
      reloadState.invalidate(clearOptimisticCompletions: false)
    }
    editorSession = retention.session
    lastActionError = retention.session.generalMessage
    if retention.requestsReload { requestEditorReload() }
    return true
  }

  private func applyRemindersHandoffCompletion(
    expectedIdentity: ReminderEditorPendingIdentity,
    openedRunningApplication: Bool, errorDescription: String?,
    onAbandoned: @escaping @MainActor @Sendable () -> Void
  ) {
    let completion = ReminderEditorPresentation.handoffCompletion(
      expectedSessionID: expectedIdentity.sessionID,
      expectedReceipt: expectedIdentity.receipt,
      currentSessionID: editorSession?.id,
      currentReceipt: editorSession?.draft.pendingCommitReceipt,
      currentSessionIsPending: editorSession?.isPending == true,
      openedRunningApplication: openedRunningApplication,
      errorDescription: errorDescription)
    switch completion {
    case .ignore:
      return
    case .retain(let message):
      guard var session = editorSession,
        expectedIdentity.matches(sessionID: session.id, draft: session.draft)
      else { return }
      session.generalMessage = message
      editorSession = session
      lastActionError = message
    case .abandon:
      guard writes.abandonPendingCommitAfterRemindersHandoff() else {
        let message =
          "Couldn’t stop waiting for this reminder. Keep Reminders open, then try again."
        guard var session = editorSession,
          expectedIdentity.matches(sessionID: session.id, draft: session.draft)
        else { return }
        session.generalMessage = message
        editorSession = session
        lastActionError = message
        return
      }
      pendingReconciliationTask?.cancel()
      pendingReconciliationTask = nil
      editorSession = nil
      lastActionError = nil
      onAbandoned()
    }
  }

  private func reconcileDashboard(_ mutation: ReminderDashboardReconciliation.Mutation) {
    let reconciliation = ReminderDashboardReconciliation.make(
      visibleReminders: reminders, hasMoreReminders: hasMoreReminders, mutation: mutation)
    reminders = reconciliation.reminders
    hasMoreReminders = reconciliation.hasMoreReminders
    if reconciliation.requiresReload {
      Task { await reload() }
    }
  }

  private func scheduleUndoExpiry(_ undo: ReminderWriteCoordinator.CompletionUndo) {
    undoExpiryTask?.cancel()
    undoExpiryTask = Task { @MainActor [weak self] in
      let delay = max(undo.expiresAt.timeIntervalSinceNow, 0)
      do {
        try await Task.sleep(for: .seconds(delay))
      } catch {
        return
      }
      guard self?.completionUndo == undo else { return }
      self?.writes.discardExpiredUndo()
      self?.completionUndo = nil
      self?.undoExpiryTask = nil
    }
  }

  private func reconcilePendingEditorSessionAfterAcceptedReload(
    expectedIdentity: ReminderEditorPendingIdentity?
  ) {
    guard var session = editorSession,
      let expectedIdentity,
      expectedIdentity.matches(sessionID: session.id, draft: session.draft),
      let identifier = ReminderEditorPresentation.pendingLookupID(for: session.draft)
    else {
      return
    }
    let record = (store.calendarItem(withIdentifier: identifier) as? EKReminder).map {
      ReminderEventKitCodec.record(from: $0)
    }
    guard
      let authoritativeRecord = ReminderEditorPresentation.authoritativePendingRecord(
        for: session.draft, acceptedReloadGeneration: true, record: record)
    else {
      return
    }

    switch writes.reconcilePendingCommit(with: authoritativeRecord) {
    case .success(let resolvedDraft?):
      pendingReconciliationTask = nil
      session.draft = resolvedDraft
      session.fieldMessages = resolvedDraft.normalizationMismatches.map {
        ReminderEditorFieldMessage(field: $0.field, message: $0.reason)
      }
      session.generalMessage = ReminderEditorPresentation.reviewMessage(
        for: resolvedDraft, fieldMessages: session.fieldMessages)
      editorSession = session
      lastActionError = session.generalMessage
    case .success(nil):
      break
    case .failure(let error):
      session.generalMessage = error.localizedDescription
      editorSession = session
      report(error, action: "reconcile pending reminder")
    }
  }

  private func requestEditorReload() {
    pendingReconciliationTask?.cancel()
    pendingReconciliationTask = Task { @MainActor [weak self] in
      guard let self else { return }
      await reload()
      for delay in ReminderEditorPresentation.pendingRetryDelays {
        guard editorSession?.isPending == true else {
          pendingReconciliationTask = nil
          return
        }
        do {
          try await Task.sleep(for: delay)
        } catch {
          return
        }
        guard !Task.isCancelled else { return }
        await reload()
      }
      pendingReconciliationTask = nil
    }
  }

  private func configure(_ alert: NSAlert, buttons: [ReminderEditorAlertButton]) {
    for configuration in buttons {
      let button = alert.addButton(withTitle: configuration.title)
      button.keyEquivalent = configuration.isDefault ? "\r" : ""
      button.hasDestructiveAction = configuration.isDestructive
    }
  }

  private func report(_ error: ReminderWriteError, action: String) {
    lastActionError = error.localizedDescription
    Log.app.error("Failed to \(action): \(error.localizedDescription)")
  }
}
