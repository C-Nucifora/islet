import AppKit
import Defaults
import SwiftUI

/// A ranked view of current work across the built-in activities and Pulse. Home deliberately owns
/// no source data. It reduces the live activity models into `HomeAttentionItem` values, then sends
/// actions back to the source that supplied them.
struct IdleDashboardView: View {
  @ObservedObject var vm: NotchViewModel
  let onOpenActivity: (String) -> Void

  @ObservedObject private var calendar = AppState.calendar
  @ObservedObject private var reminders = RemindersProvider.shared
  @ObservedObject private var timer = AppState.timer
  @ObservedObject private var t3Code = AppState.t3Code
  @ObservedObject private var pulse = PulseCenter.shared
  @ObservedObject private var battery = AppState.battery
  @ObservedObject private var shelf = ShelfModel.shared
  @ObservedObject private var keepAwake = KeepAwakeManager.shared
  @Default(.calendarEnabled) private var calendarEnabled
  @Default(.remindersEnabled) private var remindersEnabled
  @Default(.disabledActivities) private var disabledActivities

  @State private var showsAll = false

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      keepAwakeControls
      Divider().overlay(Color.white.opacity(0.12))
      TimelineView(.periodic(from: .now, by: 10)) { context in
        dashboard(now: context.date)
      }
    }
    .foregroundStyle(.white)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  private var keepAwakeControls: some View {
    HStack(spacing: 8) {
      Image(systemName: keepAwake.isActive ? "cup.and.heat.waves.fill" : "cup.and.heat.waves")
        .appThemeForeground(.interaction)
      VStack(alignment: .leading, spacing: 1) {
        Text(keepAwake.isActive ? "Mac stays awake" : "Keep Mac awake")
          .font(.caption.weight(.semibold))
        if keepAwake.isActive {
          Text(keepAwake.lastError ?? keepAwake.statusText)
            .font(.caption2.monospacedDigit())
            .foregroundStyle(keepAwake.lastError == nil ? Color.secondary : Color.orange)
            .lineLimit(1)
        } else if let error = keepAwake.lastError {
          Text(error).font(.caption2).foregroundStyle(.orange).lineLimit(1)
        }
      }
      Spacer(minLength: 4)
      if keepAwake.isActive {
        Menu {
          Button("Indefinitely") { keepAwake.start(duration: .indefinitely) }
          ForEach(Array(KeepAwakeDuration.presets.enumerated()), id: \.offset) { _, preset in
            Button(preset.title) { keepAwake.start(duration: preset.duration) }
          }
        } label: {
          Image(systemName: "timer")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Change keep-awake duration")
        .accessibilityHint("Replaces the current keep-awake timer")
        Button("Stop") { keepAwake.stop(reason: .manual) }
          .buttonStyle(.bordered)
          .controlSize(.small)
          .accessibilityHint("Allows the Mac to idle-sleep again")
      } else if keepAwake.hasUnreleasedAssertions {
        Button("Retry") { keepAwake.retryUnreleasedAssertions() }
          .buttonStyle(.bordered)
          .controlSize(.small)
          .accessibilityLabel("Retry releasing keep-awake assertions")
          .accessibilityHint("Tries again to let the Mac and display idle-sleep")
      } else {
        Menu("Start") {
          Button("Indefinitely") { keepAwake.start(duration: .indefinitely) }
          ForEach(Array(KeepAwakeDuration.presets.enumerated()), id: \.offset) { _, preset in
            Button(preset.title) { keepAwake.start(duration: preset.duration) }
          }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Start keep-awake session")
        .accessibilityHint("Choose how long the Mac should stay awake")
      }
    }
    .accessibilityElement(children: .contain)
  }

  @ViewBuilder private func dashboard(now: Date) -> some View {
    let allItems = sourceItems(now: now)
    let visibleItems = vm.visibleHomeAttentionItems(allItems, now: now)
    let overflow = HomeAttentionOverflow.split(visibleItems)
    let shownItems = showsAll ? visibleItems : overflow.primary

    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 7) {
        Label("Home", systemImage: "square.grid.2x2.fill")
          .font(.caption.weight(.semibold))
          .appThemeForeground(.interaction)
        if let first = visibleItems.first {
          Text("First because \(first.rankingReason.lowercased())")
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .help(
              HomeAttentionRanking.explanation(
                for: first, above: visibleItems.dropFirst().first))
        }
        Spacer(minLength: 0)
        Text("\(visibleItems.count)")
          .font(.caption2.monospacedDigit())
          .foregroundStyle(.secondary)
          .accessibilityLabel("\(visibleItems.count) items need attention")
        if remindersEnabled, reminders.authorization.canRead {
          Button {
            ReminderEditorWindow.shared.presentEditor(provider: reminders, item: nil)
          } label: {
            Image(systemName: "plus")
          }
          .buttonStyle(.plain)
          .accessibilityLabel("New reminder")
          .accessibilityHint("Opens a keyboard-accessible reminder editor")
          .disabled(reminderCommands.route(for: .create) == nil)
          if reminders.completionUndo != nil {
            Button("Undo") { reminders.undoLastCompletion() }
              .buttonStyle(.link)
              .font(.caption2)
              .accessibilityLabel("Undo last reminder completion")
              .disabled(reminderCommands.route(for: .undo) == nil)
          }
        }
        if !overflow.overflow.isEmpty {
          Button(showsAll ? "Show less" : "More (\(overflow.overflow.count))") {
            withAnimation(Motion.gated(.snappy)) { showsAll.toggle() }
          }
          .buttonStyle(.link)
          .font(.caption2)
          .accessibilityHint(
            showsAll
              ? "Shows the three highest-ranked items"
              : "Shows all \(visibleItems.count) items in a scrollable list")
        }
      }

      if shownItems.isEmpty {
        emptyState
      } else {
        ScrollView(.vertical, showsIndicators: showsAll) {
          LazyVStack(spacing: 5) {
            ForEach(Array(shownItems.enumerated()), id: \.element.id) { index, item in
              HomeAttentionRow(
                item: item,
                rankExplanation: HomeAttentionRanking.explanation(
                  for: item,
                  above: visibleItems.dropFirst(index + 1).first),
                action: { perform($0) },
                dismiss: { dismiss($0) },
                snooze: { snooze($0, now: now) })
            }
          }
          .padding(.bottom, 1)
        }
      }
    }
    .onChange(of: allItems.map(\.id), initial: true) { _, _ in
      vm.reconcileHomeAttention(with: allItems)
    }
  }

  private func sourceItems(now: Date) -> [HomeAttentionItem] {
    var items = HomeAttentionBuilder.items(
      calendarEvents: calendarEnabled ? calendar.events : [],
      reminders: remindersEnabled ? reminders.reminders : [],
      timer: timerSnapshot,
      t3Agents: t3Code.agents,
      pulseItems: pulse.items,
      battery: battery.currentState,
      pendingTransfers: shelf.pendingImportCount,
      disabledActivities: disabledActivities,
      now: now)
    items += serviceIssues
    return HomeAttentionRanking.ranked(items, now: now)
  }

  private var reminderCommands: ReminderCommandPresentation {
    ReminderCommandPresentation(
      reminders: reminders.reminders,
      selectedReminderID: nil,
      writableListIDs: Set(reminders.availableLists.filter(\.isWritable).map(\.id)),
      hasCompletionUndo: reminders.completionUndo != nil)
  }

  private var serviceIssues: [HomeAttentionItem] {
    var issues: [HomeAttentionItem] = []
    if calendarEnabled, !calendar.authorization.canRead {
      issues.append(
        HomeAttentionBuilder.serviceIssue(
          id: "permission", source: .calendar, title: "Calendar access is off",
          detail: calendar.authorization.summary, state: "Needs access",
          action: HomeAttentionAction(
            title: "Review access", symbol: "gearshape.fill", kind: .recoverCalendarAccess)))
    } else if calendarEnabled, case .failed(let message) = calendar.loadState {
      issues.append(
        HomeAttentionBuilder.serviceIssue(
          id: "load", source: .calendar, title: "Calendar could not refresh", detail: message,
          state: "Unavailable",
          action: HomeAttentionAction(
            title: "Retry", symbol: "arrow.clockwise", kind: .retryCalendar)))
    }
    if remindersEnabled, !reminders.authorization.canRead {
      issues.append(
        HomeAttentionBuilder.serviceIssue(
          id: "permission", source: .reminders, title: "Reminders access is off",
          detail: reminders.authorization.summary, state: "Needs access",
          action: HomeAttentionAction(
            title: "Review access", symbol: "gearshape.fill", kind: .recoverRemindersAccess)))
    } else if remindersEnabled, case .failed(let message) = reminders.loadState {
      issues.append(
        HomeAttentionBuilder.serviceIssue(
          id: "load", source: .reminders, title: "Reminders could not refresh", detail: message,
          state: "Unavailable",
          action: HomeAttentionAction(
            title: "Retry", symbol: "arrow.clockwise", kind: .retryReminders)))
    }
    return issues
  }

  private var timerSnapshot: HomeTimerSnapshot? {
    guard timer.isActive else { return nil }
    let occurrence =
      timer.activationDate?.timeIntervalSinceReferenceDate
      ?? timer.endDate?.timeIntervalSinceReferenceDate
      ?? 0
    return HomeTimerSnapshot(
      occurrenceID: String(occurrence), label: timer.label ?? "Timer", endDate: timer.endDate,
      remaining: timer.remainingNow, isPaused: timer.isPaused, finished: timer.finished)
  }

  private var emptyState: some View {
    VStack(spacing: 6) {
      Image(systemName: "checkmark.circle")
        .font(.title2)
        .foregroundStyle(.green)
      Text("Nothing needs attention")
        .font(.caption.weight(.medium))
      Text(
        "New events, reminders, timers, agents, Pulse updates, battery warnings, and transfers will appear here."
      )
      .font(.caption2)
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.center)
      .frame(maxWidth: 300)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityElement(children: .combine)
  }

  private func perform(_ action: HomeAttentionAction) {
    switch action.kind {
    case .openActivity(let id):
      onOpenActivity(id)
    case .openURL(let url):
      NSWorkspace.shared.open(url)
    case .openMeetingLink(let link):
      guard !link.trust.requiresConfirmation else { return }
      NSWorkspace.shared.open(link.url)
    case .completeReminder(let id):
      guard let item = reminders.reminders.first(where: { $0.id == id }) else { return }
      reminders.complete(item)
    case .toggleTimer:
      timer.togglePause()
    case .dismissTimer:
      timer.cancel()
    case .recoverCalendarAccess:
      Task { await calendar.recoverAccess() }
    case .recoverRemindersAccess:
      Task { await reminders.recoverAccess() }
    case .retryCalendar:
      Task { await calendar.refreshAuthorization() }
    case .retryReminders:
      Task { await reminders.reload() }
    }
  }

  private func dismiss(_ item: HomeAttentionItem) {
    if item.source == .pulse {
      pulse.dismiss(item.stableID)
    } else if item.source == .timer, item.state == "Done" {
      timer.cancel()
    } else {
      vm.dismissHomeAttention(item)
    }
  }

  private func snooze(_ item: HomeAttentionItem, now: Date) {
    guard let until = Calendar.current.date(byAdding: .hour, value: 1, to: now) else { return }
    vm.snoozeHomeAttention(item, until: until)
  }
}

private struct HomeAttentionRow: View {
  let item: HomeAttentionItem
  let rankExplanation: String
  let action: (HomeAttentionAction) -> Void
  let dismiss: (HomeAttentionItem) -> Void
  let snooze: (HomeAttentionItem) -> Void
  @State private var meetingLinkConfirmationPresented = false

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: item.symbol)
        .font(.caption)
        .frame(width: 19)
        .foregroundStyle(accent)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 1) {
        HStack(spacing: 5) {
          Text(item.source.title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(accent)
          Text(item.state)
            .font(.caption2)
            .foregroundStyle(.secondary)
          Spacer(minLength: 0)
          Text(item.priority.title)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(priorityColor)
        }
        HStack(spacing: 4) {
          Text(item.title).font(.caption.weight(.medium)).lineLimit(1)
          if let detail = item.detail {
            Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
          }
        }
        Text(item.rankingReason)
          .font(.system(size: 9))
          .foregroundStyle(.tertiary)
          .lineLimit(1)
      }
      Spacer(minLength: 3)
      if let primaryAction = item.primaryAction {
        if case .openMeetingLink(let link) = primaryAction.kind {
          Button {
            performPrimaryAction(primaryAction)
          } label: {
            primaryActionLabel(primaryAction)
          }
          .buttonStyle(.plain)
          .help(primaryAction.title)
          .accessibilityHidden(true)
          .calendarMeetingLinkConfirmation(
            link: link, isPresented: $meetingLinkConfirmationPresented)
        } else {
          Button {
            performPrimaryAction(primaryAction)
          } label: {
            primaryActionLabel(primaryAction)
          }
          .buttonStyle(.plain)
          .help(primaryAction.title)
          .accessibilityHidden(true)
        }
      }
      if item.allowsSnooze || item.allowsDismiss {
        Menu {
          if item.allowsSnooze {
            Button("Snooze for 1 hour") { snooze(item) }
          }
          if item.allowsDismiss {
            Button("Dismiss") { dismiss(item) }
          }
        } label: {
          Image(systemName: "ellipsis")
            .font(.caption2.weight(.semibold))
            .frame(width: 22, height: 22)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityHidden(true)
      }
    }
    .padding(.horizontal, 7)
    .padding(.vertical, 4)
    .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(item.source.title), \(item.title)")
    .accessibilityValue(item.voiceOverValue)
    .accessibilityHint(rankExplanation)
    .accessibilityActions {
      if let primaryAction = item.primaryAction {
        Button(primaryAction.title) { performPrimaryAction(primaryAction) }
      }
      if item.allowsSnooze {
        Button("Snooze for 1 hour") { snooze(item) }
      }
      if item.allowsDismiss {
        Button("Dismiss") { dismiss(item) }
      }
    }
  }

  private func primaryActionLabel(_ action: HomeAttentionAction) -> some View {
    Image(systemName: action.symbol)
      .font(.caption2)
      .frame(width: 22, height: 22)
  }

  private func performPrimaryAction(_ primaryAction: HomeAttentionAction) {
    if case .openMeetingLink(let link) = primaryAction.kind {
      CalendarMeetingLinkPresentation.activate(link) {
        meetingLinkConfirmationPresented = true
      }
    } else {
      action(primaryAction)
    }
  }

  private var accent: Color {
    if item.source == .battery || item.state == "Failed" { return .red }
    if item.state == "Needs action" || item.state == "Needs input"
      || item.state == "Needs approval"
    {
      return .orange
    }
    return Color(isletHex: item.accentHex) ?? .cyan
  }

  private var priorityColor: Color {
    switch item.priority {
    case .critical: .red
    case .urgent: .orange
    case .high: .yellow
    case .normal, .low: .secondary
    }
  }
}
