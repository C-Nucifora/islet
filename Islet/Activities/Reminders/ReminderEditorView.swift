import AppKit
import SwiftUI

struct ReminderEditorView: View {
  @FocusState private var titleFocused: Bool
  @State private var draft: ReminderDraft

  let heading: String
  let submitTitle: String
  let lists: [ReminderListItem]
  let errorMessage: String?
  let onCancel: () -> Void
  let onSubmit: (ReminderDraft) -> Bool

  init(
    heading: String, submitTitle: String, draft: ReminderDraft, lists: [ReminderListItem],
    errorMessage: String?, onCancel: @escaping () -> Void,
    onSubmit: @escaping (ReminderDraft) -> Bool
  ) {
    self.heading = heading
    self.submitTitle = submitTitle
    self.lists = lists
    self.errorMessage = errorMessage
    self.onCancel = onCancel
    self.onSubmit = onSubmit
    _draft = State(initialValue: draft)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(heading).font(.headline)
      TextField("Title", text: $draft.title)
        .textFieldStyle(.roundedBorder)
        .focused($titleFocused)
        .accessibilityLabel("Reminder title")

      Picker("List", selection: $draft.listID) {
        ForEach(lists) { list in
          Text(list.title).tag(Optional(list.id))
        }
      }
      .accessibilityHint("Choose the Reminders list")

      Toggle("Due date", isOn: hasDueDate)
      if draft.dueDate != nil {
        DatePicker("Date", selection: dueDate, displayedComponents: .date)
        Toggle("Include time", isOn: $draft.hasDueTime)
        if draft.hasDueTime {
          DatePicker("Time", selection: dueDate, displayedComponents: .hourAndMinute)
        }
      }

      Picker("Priority", selection: $draft.priority) {
        Text("None").tag(0)
        Text("High").tag(1)
        Text("Medium").tag(5)
        Text("Low").tag(9)
      }

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
        Button(submitTitle) {
          if onSubmit(draft) { onCancel() }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding(16)
    .frame(width: 320)
    .onAppear { titleFocused = true }
  }

  private var hasDueDate: Binding<Bool> {
    Binding(
      get: { draft.dueDate != nil },
      set: { enabled in
        if enabled {
          if draft.dueDate == nil { draft.dueDate = Date() }
        } else {
          draft.dueDate = nil
          draft.hasDueTime = false
        }
      })
  }

  private var dueDate: Binding<Date> {
    Binding(
      get: { draft.dueDate ?? Date() },
      set: { draft.dueDate = $0 })
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
  let item: ReminderItem?
  let draft: ReminderDraft
  let close: () -> Void

  var body: some View {
    ReminderEditorView(
      heading: item == nil ? "New reminder" : "Edit reminder",
      submitTitle: item == nil ? "Add" : "Save", draft: draft,
      lists: provider.availableLists, errorMessage: provider.lastActionError,
      onCancel: close
    ) { draft in
      if let item { return provider.update(item, with: draft) }
      return provider.create(draft)
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

  func presentEditor(provider: RemindersProvider, item: ReminderItem?) {
    provider.dismissActionError()
    let draft: ReminderDraft
    if let item {
      guard let editDraft = provider.draft(for: item) else { return }
      draft = editDraft
    } else {
      draft = provider.defaultDraft()
    }
    present(
      title: item == nil ? "New reminder" : "Edit reminder",
      content: ReminderEditorWindowContent(
        provider: provider, item: item, draft: draft,
        close: { [weak self] in self?.close() }))
  }

  func presentSnooze(provider: RemindersProvider, item: ReminderItem) {
    provider.dismissActionError()
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
      contentRect: NSRect(x: 0, y: 0, width: 360, height: 390),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.title = title
    window.isReleasedWhenClosed = false
    window.level = .floating
    window.delegate = self
    window.contentView = NSHostingView(rootView: content)
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
  }

  private func close() { window?.close() }
}
