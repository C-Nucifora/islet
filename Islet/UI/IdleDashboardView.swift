import Defaults
import SwiftUI

/// The expanded view shown when nothing is playing: today's agenda plus reminders you can complete.
struct IdleDashboardView: View {
  @ObservedObject var calendar = AppState.calendar
  @ObservedObject var reminders = RemindersProvider.shared
  @ObservedObject private var keepAwake = KeepAwakeManager.shared
  @Default(.calendarEnabled) private var calendarEnabled
  @Default(.remindersEnabled) private var remindersEnabled

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      keepAwakeControls
      Divider().overlay(Color.white.opacity(0.12))
      Group {
        if calendarEnabled || remindersEnabled {
          HStack(alignment: .top, spacing: 14) {
            if calendarEnabled {
              column("Today", systemImage: "calendar") { agenda }
            }
            if calendarEnabled && remindersEnabled {
              Divider().overlay(Color.white.opacity(0.12))
            }
            if remindersEnabled {
              column("Reminders", systemImage: "checklist") { remindersList }
            }
          }
        } else {
          enableHint
        }
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

  private func column<Content: View>(
    _ title: String, systemImage: String, @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Label(title, systemImage: systemImage)
        .font(.caption.weight(.semibold))
        .appThemeForeground(systemImage == "calendar" ? .calendar : .reminders)
      content()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  // MARK: - Agenda

  @ViewBuilder private var agenda: some View {
    if !calendar.authorization.canRead {
      permissionRow("Calendar: \(calendar.authorization.summary)", permission: "Calendar") {
        Task { await calendar.recoverAccess() }
      }
    } else if calendar.loadState == .loading {
      ProgressView().controlSize(.small).accessibilityLabel("Loading calendar")
    } else if case .failed(let message) = calendar.loadState {
      HStack(spacing: 5) {
        Text(message).font(.caption2).foregroundStyle(.orange).lineLimit(2)
        Button("Retry") { Task { await calendar.refreshAuthorization() } }
          .buttonStyle(.link).font(.caption2)
      }
    } else if calendar.events.isEmpty {
      emptyRow("No events today")
    } else {
      ScrollView(.vertical, showsIndicators: false) {
        VStack(alignment: .leading, spacing: 6) {
          ForEach(calendar.events.prefix(6)) { event in
            HStack(spacing: 6) {
              // Vertical bar tinted with the event's calendar colour (like Calendar.app).
              Capsule()
                .fill(Color(isletHex: event.calendarColorHex) ?? .secondary)
                .frame(width: 3, height: 14)
              // Wide enough for "12:00 pm" — monospacedDigit only pins the digits, and the pm/am
              // pair is the widest suffix, so a tighter frame wraps the label onto two lines.
              if event.isAllDay {
                Text("All day")
                  .font(.caption2).foregroundStyle(.secondary)
                  .lineLimit(1)
                  .frame(width: 54, alignment: .leading)
              } else {
                Text(event.start, format: .dateTime.hour().minute())
                  .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                  .lineLimit(1)
                  .frame(width: 54, alignment: .leading)
              }
              Text(event.title).font(.caption).lineLimit(1)
              Spacer(minLength: 0)
              if let url = event.joinURL, let link = CalendarMeetingLinkPolicy.candidate(url) {
                CalendarMeetingLinkButton(link: link, eventTitle: event.title)
              }
            }
          }
        }
      }
    }
  }

  // MARK: - Reminders

  @ViewBuilder private var remindersList: some View {
    if reminders.accessDenied {
      permissionRow(
        "Reminders: \(reminders.authorization.summary)", permission: "Reminders"
      ) {
        Task { await reminders.recoverAccess() }
      }
    } else if reminders.loadState == .loading {
      ProgressView().controlSize(.small).accessibilityLabel("Loading reminders")
    } else if case .failed(let message) = reminders.loadState {
      HStack(spacing: 5) {
        Text(message).font(.caption2).foregroundStyle(.orange).lineLimit(2)
        Button("Retry") { Task { await reminders.reload() } }
          .buttonStyle(.link).font(.caption2)
      }
    } else if reminders.reminders.isEmpty {
      if reminders.hasMoreReminders {
        VStack(alignment: .leading, spacing: 5) {
          emptyRow("No reminders due soon")
          moreRemindersButton
        }
      } else {
        emptyRow("All clear")
      }
    } else {
      ScrollView(.vertical, showsIndicators: false) {
        VStack(alignment: .leading, spacing: 6) {
          if let error = reminders.lastActionError {
            HStack(spacing: 5) {
              Text(error).font(.caption2).foregroundStyle(.orange).lineLimit(1)
              Button("Dismiss") { reminders.dismissActionError() }
                .buttonStyle(.link).font(.caption2)
            }
          }
          ForEach(reminders.reminders) { item in
            HStack(spacing: 6) {
              Button {
                withAnimation(Motion.gated(.snappy)) { reminders.complete(item) }
              } label: {
                // Circle tinted with the reminder list's colour (like Reminders.app).
                Image(systemName: "circle")
                  .foregroundStyle(Color(isletHex: item.listColorHex) ?? .secondary)
                  .font(.caption)
              }
              .buttonStyle(.plain)
              .accessibilityLabel("Complete \(item.title)")
              VStack(alignment: .leading, spacing: 0) {
                Text(item.title).font(.caption).lineLimit(1)
                if let due = item.dueDate {
                  reminderDueText(item, due: due)
                    .font(.caption2).monospacedDigit()
                    .foregroundStyle(
                      RemindersLogic.isOverdue(item, now: Date())
                        ? .red : .secondary)
                }
              }
              Spacer(minLength: 0)
              Menu {
                ForEach(RemindersLogic.SnoozePreset.allCases, id: \.self) { preset in
                  Button(preset.title) {
                    _ = reminders.snooze(item, preset: preset)
                  }
                }
              } label: {
                Image(systemName: "clock.arrow.circlepath")
                  .font(.caption2).foregroundStyle(.secondary)
              }
              .menuStyle(.borderlessButton)
              .menuIndicator(.hidden)
              .fixedSize()
              .accessibilityLabel("Snooze \(item.title)")
            }
          }
          if reminders.hasMoreReminders {
            moreRemindersButton
          }
        }
      }
    }
  }

  // MARK: - Fallbacks

  private var enableHint: some View {
    VStack(spacing: 6) {
      Image(systemName: "calendar.badge.checkmark").font(.title2)
      Text("Enable Calendar or Reminders in Settings")
        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func emptyRow(_ text: String) -> some View {
    Text(text).font(.caption).foregroundStyle(.secondary)
  }

  private var moreRemindersButton: some View {
    Button("More in Reminders") { reminders.openRemindersApp() }
      .buttonStyle(.link)
      .font(.caption2)
      .accessibilityHint("Opens the Reminders app")
  }

  @ViewBuilder private func reminderDueText(_ item: ReminderItem, due: Date) -> some View {
    if item.hasDueTime {
      Text(due, format: .dateTime.hour().minute())
    } else if Calendar.current.isDateInToday(due) {
      Text("Today")
    } else if Calendar.current.isDateInTomorrow(due) {
      Text("Tomorrow")
    } else {
      Text(due, format: .dateTime.month(.abbreviated).day())
    }
  }

  private func permissionRow(
    _ text: String, permission: String, action: @escaping () -> Void
  ) -> some View {
    HStack(spacing: 5) {
      Text(text).font(.caption2).foregroundStyle(.orange)
      Button("Review…", action: action)
        .font(.caption2)
        .buttonStyle(.link)
        .accessibilityLabel("Review \(permission) permission")
    }
  }
}
