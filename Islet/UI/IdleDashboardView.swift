import Defaults
import SwiftUI

/// The expanded view shown when nothing is playing: today's agenda plus reminders you can complete.
struct IdleDashboardView: View {
  @ObservedObject var calendar = AppState.calendar
  @ObservedObject var reminders = RemindersProvider.shared
  @Default(.calendarEnabled) private var calendarEnabled
  @Default(.remindersEnabled) private var remindersEnabled

  var body: some View {
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
    .foregroundStyle(.white)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  private func column<Content: View>(
    _ title: String, systemImage: String, @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Label(title, systemImage: systemImage)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
      content()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  // MARK: - Agenda

  @ViewBuilder private var agenda: some View {
    if calendar.accessDenied {
      deniedRow("Calendar access off")
    } else if calendar.events.isEmpty {
      emptyRow("No events today")
    } else {
      ScrollView(.vertical, showsIndicators: false) {
        VStack(alignment: .leading, spacing: 6) {
          ForEach(Array(calendar.events.prefix(6).enumerated()), id: \.offset) { _, event in
            HStack(spacing: 6) {
              // Vertical bar tinted with the event's calendar colour (like Calendar.app).
              Capsule()
                .fill(Color(isletHex: event.calendarColorHex) ?? .secondary)
                .frame(width: 3, height: 14)
              // Wide enough for "12:00 pm" — monospacedDigit only pins the digits, and the pm/am
              // pair is the widest suffix, so a tighter frame wraps the label onto two lines.
              Text(event.start, format: .dateTime.hour().minute())
                .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 54, alignment: .leading)
              Text(event.title).font(.caption).lineLimit(1)
              Spacer(minLength: 0)
              if let url = event.joinURL {
                Button {
                  NSWorkspace.shared.open(url)
                } label: {
                  Image(systemName: "video.fill").foregroundStyle(.green)
                    .font(.caption2)
                }
                .buttonStyle(.plain)
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
      deniedRow("Reminders access off")
    } else if reminders.reminders.isEmpty {
      emptyRow("All clear")
    } else {
      ScrollView(.vertical, showsIndicators: false) {
        VStack(alignment: .leading, spacing: 6) {
          ForEach(reminders.reminders) { item in
            HStack(spacing: 6) {
              Button {
                Haptics.perform(.levelChange)
                withAnimation(.snappy) { reminders.complete(item) }
              } label: {
                // Circle tinted with the reminder list's colour (like Reminders.app).
                Image(systemName: "circle")
                  .foregroundStyle(Color(isletHex: item.listColorHex) ?? .secondary)
                  .font(.caption)
              }
              .buttonStyle(.plain)
              VStack(alignment: .leading, spacing: 0) {
                Text(item.title).font(.caption).lineLimit(1)
                if let due = item.dueDate {
                  Text(due, format: .dateTime.hour().minute())
                    .font(.system(size: 9)).monospacedDigit()
                    .foregroundStyle(
                      RemindersLogic.isOverdue(item, now: Date())
                        ? .red : .secondary)
                }
              }
              Spacer(minLength: 0)
            }
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

  private func deniedRow(_ text: String) -> some View {
    Text(text).font(.caption2).foregroundStyle(.orange)
  }
}
