import AppKit
import SwiftUI

struct ReminderEditorView: View {
  @Binding var draft: ReminderCoordinatorDraft
  @FocusState private var focusedField: ReminderEditorFocus?
  @State private var detailsExpanded = true

  let heading: String
  let submitTitle: String
  let lists: [ReminderListItem]
  let fieldMessages: [ReminderEditorFieldMessage]
  let generalMessage: String?
  let calendar: Calendar
  let displayTimeZone: TimeZone
  let onCancel: () -> Void
  let onSubmit: () -> Void
  let onNew: () -> Void
  let onDelete: () -> Void
  let onOpenReminders: () -> Void
  let onStopWaiting: () -> Void
  let onFieldError: (ReminderEditorFieldMessage) -> Void

  var body: some View {
    VStack(spacing: 0) {
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          Text(heading).font(.headline)
          Group {
            TextField("Title", text: $draft.title)
              .textFieldStyle(.roundedBorder)
              .focused($focusedField, equals: .title)
              .accessibilityLabel("Reminder title")
            fieldMessages(for: .title)

            Picker("List", selection: $draft.listID) {
              ForEach(
                ReminderEditorPresentation.listOptions(
                  lists: lists, selectedID: draft.listID)
              ) { option in
                Text(option.title).tag(Optional(option.id))
              }
            }
            .accessibilityHint("Choose the Reminders list")
            fieldMessages(for: .list)

            Toggle("Due date", isOn: hasDueDate)
            if let dueDate = draft.dueDate {
              DatePicker("Date", selection: dateBinding(for: .dueDate), displayedComponents: .date)
                .environment(\.calendar, pickerCalendar(for: dueDate))
                .environment(\.timeZone, effectiveTimeZone(for: dueDate))
              Toggle("Include time", isOn: includesDueTime)
              if hasClock(dueDate) {
                DatePicker(
                  "Time", selection: dateBinding(for: .dueDate),
                  displayedComponents: .hourAndMinute
                )
                .environment(\.calendar, pickerCalendar(for: dueDate))
                .environment(\.timeZone, effectiveTimeZone(for: dueDate))
              }
            }
            fieldMessages(for: .dueDate)

            Picker("Priority", selection: $draft.priority) {
              Text("None").tag(0)
              Text("High").tag(1)
              Text("Medium").tag(5)
              Text("Low").tag(9)
            }
            fieldMessages(for: .priority)
          }
          .disabled(isReadOnly)

          DisclosureGroup("Details", isExpanded: $detailsExpanded) {
            VStack(alignment: .leading, spacing: 12) {
              Text("Notes").font(.subheadline)
              TextEditor(text: notes)
                .frame(minHeight: 88)
                .focused($focusedField, equals: .notes)
                .accessibilityLabel("Reminder notes")
                .accessibilityHint("Return adds a new line. Use the Save button to submit.")
              fieldMessages(for: .notes)

              TextField("URL", text: $draft.urlText)
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: .url)
                .accessibilityLabel("Reminder URL")
              fieldMessages(for: .url)

              Toggle("Start date", isOn: hasStartDate)
              if let startDate = draft.startDate {
                DatePicker(
                  "Start date", selection: dateBinding(for: .startDate),
                  displayedComponents: .date
                )
                .environment(\.calendar, pickerCalendar(for: startDate))
                .environment(\.timeZone, effectiveTimeZone(for: startDate))
                Toggle("Include start time", isOn: includesStartTime)
                if hasClock(startDate) {
                  DatePicker(
                    "Start time", selection: dateBinding(for: .startDate),
                    displayedComponents: .hourAndMinute
                  )
                  .environment(\.calendar, pickerCalendar(for: startDate))
                  .environment(\.timeZone, effectiveTimeZone(for: startDate))
                }
                timeZonePicker("Start time zone", value: startDate, field: .startDate)
              }
              fieldMessages(for: .startDate)

              if let dueDate = draft.dueDate {
                timeZonePicker("Due time zone", value: dueDate, field: .dueDate)
              }

              Toggle("Completed", isOn: completion)
              if draft.isCompleted {
                DatePicker("Completion date", selection: completionDate)
                  .focused($focusedField, equals: .completionDate)
                  .environment(\.calendar, calendar)
                  .environment(\.timeZone, displayTimeZone)
              }
              fieldMessages(for: .completion)
            }
            .padding(.top, 8)
            .disabled(isReadOnly)
          }

          if let generalMessage {
            Text(generalMessage)
              .font(.caption)
              .foregroundStyle(.orange)
              .accessibilityLabel("Reminder error: \(generalMessage)")
          }
        }
        .padding(16)
      }

      Divider()
      HStack {
        if ReminderEditorPresentation.offersOpenInReminders(for: draft) {
          Button("Open in Reminders", action: onOpenReminders)
        }
        if draft.pendingCommitReceipt != nil {
          Button("Open Reminders and Stop Waiting", action: onStopWaiting)
        } else if ReminderEditorPresentation.canDelete(draft) {
          Button("Delete", role: .destructive, action: onDelete)
            .accessibilityHint("Opens a confirmation. Return does not delete.")
        }
        Spacer()
        Button("Cancel", action: onCancel)
          .keyboardShortcut(.cancelAction)
        Button(submitTitle, action: onSubmit)
          .disabled(!ReminderEditorPresentation.canSubmit(draft))
      }
      .padding(16)
    }
    .frame(minWidth: 420, minHeight: 460)
    .onAppear { focusedField = .title }
    .onKeyPress(.return) {
      guard
        ReminderEditorPresentation.action(
          for: .returnKey, focus: focusedField,
          isPending: draft.pendingCommitReceipt != nil,
          isSubmissionEnabled: ReminderEditorPresentation.canSubmit(draft)) == .submit
      else {
        return .ignored
      }
      onSubmit()
      return .handled
    }
    .background {
      Button("New reminder", action: onNew)
        .keyboardShortcut("n", modifiers: .command)
        .hidden()
    }
  }

  private var isReadOnly: Bool {
    ReminderEditorPresentation.isReadOnly(draft)
  }

  private var hasDueDate: Binding<Bool> {
    Binding(
      get: { draft.dueDate != nil },
      set: { setDateEnabled($0, field: .dueDate) })
  }

  private var hasStartDate: Binding<Bool> {
    Binding(
      get: { draft.startDate != nil },
      set: { setDateEnabled($0, field: .startDate) })
  }

  private var includesDueTime: Binding<Bool> {
    Binding(
      get: { draft.dueDate.map(hasClock) ?? false },
      set: { setTimeEnabled($0, field: .dueDate) })
  }

  private var includesStartTime: Binding<Bool> {
    Binding(
      get: { draft.startDate.map(hasClock) ?? false },
      set: { setTimeEnabled($0, field: .startDate) })
  }

  private var notes: Binding<String> {
    Binding(get: { draft.notes ?? "" }, set: { draft.notes = $0 })
  }

  private var completion: Binding<Bool> {
    Binding(
      get: { draft.isCompleted },
      set: {
        draft = ReminderEditorPresentation.settingCompletion($0, in: draft, now: Date())
      })
  }

  private var completionDate: Binding<Date> {
    Binding(get: { draft.completionDate ?? Date() }, set: { draft.completionDate = $0 })
  }

  private func fieldMessages(for field: ReminderField) -> some View {
    ForEach(Array(fieldMessages.filter { $0.field == field }.enumerated()), id: \.offset) {
      _, message in
      Text(message.message)
        .font(.caption)
        .foregroundStyle(.orange)
    }
  }

  @ViewBuilder
  private func timeZonePicker(
    _ title: String, value: ReminderDateValue, field: ReminderField
  ) -> some View {
    Picker(title, selection: timeZone(value: value, field: field)) {
      Text("Floating").tag("")
      ForEach(
        ReminderEditorPresentation.timeZoneIdentifiers(
          selectedIdentifier: value.components.timeZone?.identifier),
        id: \.self
      ) { identifier in
        Text(identifier).tag(identifier)
      }
    }
  }

  private func timeZone(
    value: ReminderDateValue, field: ReminderField
  ) -> Binding<String> {
    Binding(
      get: { value.components.timeZone?.identifier ?? "" },
      set: { identifier in
        do {
          let changed = try ReminderEditorPresentation.assigningTimeZone(
            identifier.isEmpty ? nil : TimeZone(identifier: identifier), to: value)
          setDate(changed, field: field)
        } catch {
          onFieldError(
            ReminderEditorFieldMessage(
              field: field, message: ReminderWriteError.invalidDateComponents.localizedDescription))
        }
      })
  }

  private func dateBinding(for field: ReminderField) -> Binding<Date> {
    Binding(
      get: {
        guard let value = date(for: field),
          let displayed = try? ReminderEditorPresentation.displayDate(
            for: value, calendar: calendar, displayTimeZone: displayTimeZone)
        else {
          return Date()
        }
        return displayed
      },
      set: { selected in
        guard let current = date(for: field) else { return }
        do {
          let changed = try ReminderEditorPresentation.dateValue(
            from: selected, includesTime: hasClock(current),
            timeZone: current.components.timeZone, calendar: calendar,
            displayTimeZone: displayTimeZone)
          setDate(changed, field: field)
        } catch {
          onFieldError(
            ReminderEditorFieldMessage(
              field: field, message: ReminderWriteError.invalidDateComponents.localizedDescription))
        }
      })
  }

  private func setDateEnabled(_ enabled: Bool, field: ReminderField) {
    guard enabled else {
      setDate(nil, field: field)
      return
    }
    guard date(for: field) == nil else { return }
    do {
      setDate(
        try ReminderEditorPresentation.dateValue(
          from: Date(), includesTime: false, timeZone: nil, calendar: calendar,
          displayTimeZone: displayTimeZone),
        field: field)
    } catch {
      onFieldError(
        ReminderEditorFieldMessage(
          field: field, message: ReminderWriteError.invalidDateComponents.localizedDescription))
    }
  }

  private func setTimeEnabled(_ enabled: Bool, field: ReminderField) {
    guard let current = date(for: field) else { return }
    do {
      let changed =
        enabled
        ? try ReminderEditorPresentation.addingTime(
          to: current, clock: Date(), calendar: calendar,
          displayTimeZone: displayTimeZone)
        : try ReminderEditorPresentation.removingTime(from: current)
      setDate(changed, field: field)
    } catch {
      onFieldError(
        ReminderEditorFieldMessage(
          field: field, message: ReminderWriteError.invalidDateComponents.localizedDescription))
    }
  }

  private func date(for field: ReminderField) -> ReminderDateValue? {
    field == .startDate ? draft.startDate : draft.dueDate
  }

  private func setDate(_ value: ReminderDateValue?, field: ReminderField) {
    if field == .startDate { draft.startDate = value } else { draft.dueDate = value }
  }

  private func hasClock(_ value: ReminderDateValue) -> Bool {
    value.components.hour != nil && value.components.minute != nil
  }

  private func effectiveTimeZone(for value: ReminderDateValue) -> TimeZone {
    value.components.timeZone ?? displayTimeZone
  }

  private func pickerCalendar(for value: ReminderDateValue) -> Calendar {
    var pickerCalendar = calendar
    pickerCalendar.timeZone = effectiveTimeZone(for: value)
    return pickerCalendar
  }
}

struct ReminderCustomSnoozeView: View {
  @State private var date: Date

  let reminderTitle: String
  let errorMessage: String?
  let onCancel: () -> Void
  let onSubmit: (Date) -> Bool

  init(
    reminderTitle: String, initialDate: Date, errorMessage: String?,
    onCancel: @escaping () -> Void,
    onSubmit: @escaping (Date) -> Bool
  ) {
    self.reminderTitle = reminderTitle
    self.errorMessage = errorMessage
    self.onCancel = onCancel
    self.onSubmit = onSubmit
    _date = State(initialValue: initialDate)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Snooze \(reminderTitle)").font(.headline).lineLimit(2)
      DatePicker("New due date", selection: $date, in: Date()...)
      if let errorMessage {
        Text(errorMessage)
          .font(.caption)
          .foregroundStyle(.orange)
          .accessibilityLabel("Reminder error: \(errorMessage)")
      }
      HStack {
        Spacer()
        Button("Cancel") { onCancel() }
          .keyboardShortcut(.cancelAction)
        Button("Snooze") {
          if onSubmit(date) { onCancel() }
        }
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(16)
    .frame(width: 320)
  }
}

private struct ReminderEditorWindowContent: View {
  @ObservedObject var provider: RemindersProvider
  let close: @MainActor @Sendable () -> Void
  let updateWindowTitle: @MainActor (String) -> Void

  @ViewBuilder
  var body: some View {
    if let session = provider.editorSession {
      ReminderEditorView(
        draft: Binding(
          get: { provider.editorSession?.draft ?? session.draft },
          set: { provider.updateEditorDraft($0) }),
        heading: ReminderEditorPresentation.windowTitle(for: session.draft),
        submitTitle: session.draft.reminderID == nil ? "Add" : "Save",
        lists: provider.availableLists,
        fieldMessages: session.fieldMessages,
        generalMessage: session.generalMessage,
        calendar: session.calendar,
        displayTimeZone: session.displayTimeZone,
        onCancel: {
          provider.cancelEditorSession()
          close()
        },
        onSubmit: {
          if provider.submitEditorSession() { close() }
        },
        onNew: { provider.startNewEditorSession() },
        onDelete: {
          guard let payload = provider.deletionPayload() else { return }
          provider.confirmDeletion(payload)
          if provider.editorSession == nil { close() }
        },
        onOpenReminders: { _ = provider.openRemindersApp() },
        onStopWaiting: {
          provider.confirmRemindersHandoffAndStopWaiting(onAbandoned: close)
        },
        onFieldError: { provider.reportEditorFieldError($0) }
      )
      .id(session.id)
      .onAppear {
        updateWindowTitle(ReminderEditorPresentation.windowTitle(for: session.draft))
      }
      .onChange(of: session.draft.reminderID) { _, _ in
        updateWindowTitle(ReminderEditorPresentation.windowTitle(for: session.draft))
      }
    } else {
      EmptyView()
    }
  }
}

private struct ReminderSnoozeWindowContent: View {
  @ObservedObject var provider: RemindersProvider
  let item: ReminderItem
  let initialDate: Date
  let close: () -> Void

  var body: some View {
    ReminderCustomSnoozeView(
      reminderTitle: item.title, initialDate: initialDate,
      errorMessage: provider.lastActionError, onCancel: close
    ) { date in
      provider.reschedule(item, to: date, hasTime: true)
    }
  }
}

/// The notch uses a non-activating panel, so editable controls live in a regular key window.
/// This keeps text entry, tab navigation, Return, Escape, and VoiceOver focus reliable.
@MainActor
final class ReminderEditorWindow: NSObject, NSWindowDelegate {
  static let shared = ReminderEditorWindow()

  private var window: NSWindow?
  private weak var provider: RemindersProvider?

  func presentEditor(provider: RemindersProvider, item: ReminderItem?) {
    provider.dismissActionError()
    guard provider.beginEditorSession(for: item) else { return }
    self.provider = provider
    present(
      title: provider.editorSession.map { ReminderEditorPresentation.windowTitle(for: $0.draft) }
        ?? "New reminder",
      content: ReminderEditorWindowContent(
        provider: provider, close: { [weak self] in self?.close() },
        updateWindowTitle: { [weak self] title in self?.window?.title = title }))
  }

  func presentSnooze(provider: RemindersProvider, item: ReminderItem) {
    if provider.hasEditorSession {
      presentEditor(provider: provider, item: nil)
      return
    }
    provider.dismissActionError()
    self.provider = provider
    present(
      title: "Snooze reminder",
      content: ReminderSnoozeWindowContent(
        provider: provider, item: item, initialDate: Date().addingTimeInterval(60 * 60),
        close: { [weak self] in self?.close() }))
  }

  private func present<Content: View>(title: String, content: Content) {
    if let window {
      window.title = title
      window.contentView = NSHostingView(rootView: content)
      NSApp.activate()
      window.makeKeyAndOrderFront(nil)
      return
    }
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 480, height: 560),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.title = title
    window.isReleasedWhenClosed = false
    window.level = .floating
    window.delegate = self
    window.contentView = NSHostingView(rootView: content)
    window.contentMinSize = NSSize(width: 420, height: 360)
    window.center()
    self.window = window
    NSApp.activate()
    window.makeKeyAndOrderFront(nil)
  }

  func windowWillClose(_ notification: Notification) {
    guard let closedWindow = notification.object as? NSWindow, closedWindow === window else {
      return
    }
    closedWindow.contentView = nil
    window = nil
    provider?.editorWindowDidClose()
    provider = nil
  }

  private func close() { window?.close() }
}
