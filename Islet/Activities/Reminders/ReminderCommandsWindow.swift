import AppKit
import Defaults
import SwiftUI

/// A regular key window for reminder writes. The notch stays non-activating, while this window
/// provides standard keyboard focus and VoiceOver navigation for every command.
@MainActor
final class ReminderCommandsWindow: NSObject, NSWindowDelegate {
  static let shared = ReminderCommandsWindow()

  private var window: NSWindow?

  func present(provider: RemindersProvider) {
    let content = ReminderCommandsView(provider: provider)
    if let window {
      window.contentView = NSHostingView(rootView: content)
      NSApp.activate()
      window.makeKeyAndOrderFront(nil)
      return
    }

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 440, height: 360),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.title = "Reminder Commands"
    window.isReleasedWhenClosed = false
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
}

private struct ReminderCommandsView: View {
  @ObservedObject var provider: RemindersProvider
  @ObservedObject private var reminderCommandHotKey = ReminderCommandHotKey.shared
  @Default(.remindersEnabled) private var remindersEnabled
  @State private var selectedReminderID: String?
  @State private var moveListID: String?

  private var writableLists: [ReminderListItem] {
    guard remindersEnabled, provider.authorization.canRead else { return [] }
    return provider.availableLists.filter(\.isWritable)
  }

  private var presentation: ReminderCommandPresentation {
    ReminderCommandPresentation(
      reminders: provider.reminders,
      selectedReminderID: selectedReminderID,
      writableListIDs: Set(writableLists.map(\.id)),
      hasCompletionUndo: provider.completionUndo != nil)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Text("Reminder Commands").font(.headline)
        Spacer()
        Button("New Reminder") { perform(.create) }
          .accessibilityHint("Opens a keyboard-accessible reminder editor")
          .disabled(presentation.route(for: .create) == nil)
      }
      Text(
        reminderCommandHotKey.isAvailable
          ? "Global shortcut: ⌘⌥⇧R"
          : "Global shortcut unavailable"
      )
      .font(.caption)
      .foregroundStyle(.secondary)

      if let availabilityMessage {
        Text(availabilityMessage)
          .font(.caption)
          .foregroundStyle(.secondary)
        availabilityAction
      }

      if provider.completionUndo != nil {
        Button("Undo Last Completion") { perform(.undo) }
          .accessibilityHint("Restores the most recently completed reminder")
          .disabled(presentation.route(for: .undo) == nil)
      }

      if provider.reminders.isEmpty {
        if availabilityMessage == nil {
          Text("No reminders due soon").foregroundStyle(.secondary)
        }
      } else {
        Picker("Reminder", selection: $selectedReminderID) {
          Text("Choose a reminder").tag(Optional<String>.none)
          ForEach(provider.reminders) { item in
            Text(item.title).tag(Optional(item.id))
          }
        }

        HStack {
          Button("Complete") { perform(.complete) }
            .disabled(presentation.route(for: .complete) == nil)
          Button("Edit") { perform(.edit) }
            .disabled(presentation.route(for: .edit) == nil)
          Menu("Snooze") {
            ForEach(RemindersLogic.SnoozePreset.allCases, id: \.self) { preset in
              Button(preset.title) { perform(.snooze(preset)) }
            }
            Divider()
            Button("Choose Date and Time…") { perform(.customSnooze) }
          }
          .disabled(presentation.route(for: .customSnooze) == nil)
        }

        HStack {
          Picker("Move to", selection: $moveListID) {
            Text("Choose a list").tag(Optional<String>.none)
            ForEach(writableLists) { list in
              Text(list.title).tag(Optional(list.id))
            }
          }
          Button("Move") {
            guard let moveListID else { return }
            perform(.move(toListID: moveListID))
          }
          .disabled(moveListID == nil || presentation.route(for: moveIntent) == nil)
        }
      }

      if let error = provider.lastActionError {
        Text(error)
          .font(.caption)
          .foregroundStyle(.orange)
          .accessibilityLabel("Reminder error: \(error)")
      }
    }
    .padding(16)
    .frame(width: 400)
    .onAppear { selectFirstReminderIfNeeded() }
    .onChange(of: provider.reminders.map(\.id)) { _, _ in selectFirstReminderIfNeeded() }
  }

  private var availabilityMessage: String? {
    if !remindersEnabled { return "Reminders are disabled in Islet Settings." }
    if !provider.authorization.canRead {
      return "Reminders access: \(provider.authorization.summary)."
    }
    if writableLists.isEmpty { return "No writable reminder lists are available." }
    return nil
  }

  @ViewBuilder private var availabilityAction: some View {
    if !remindersEnabled {
      Button("Open Islet Settings") { SettingsOpener.open(destination: .activities) }
    } else if provider.authorization == .notDetermined
      || provider.authorization.requiresSettingsRecovery
    {
      Button(
        provider.authorization == .notDetermined
          ? "Allow Reminders Access" : "Open Reminders Settings"
      ) {
        Task { await provider.recoverAccess() }
      }
    } else if provider.authorization.canRead, writableLists.isEmpty {
      Button("Open Reminders") { provider.openRemindersApp() }
    }
  }

  private var moveIntent: ReminderCommandPresentation.Intent {
    guard let moveListID else { return .move(toListID: "") }
    return .move(toListID: moveListID)
  }

  private func selectFirstReminderIfNeeded() {
    guard !provider.reminders.contains(where: { $0.id == selectedReminderID }) else { return }
    selectedReminderID = provider.reminders.first?.id
  }

  private func perform(_ intent: ReminderCommandPresentation.Intent) {
    guard let route = presentation.route(for: intent) else { return }
    switch route {
    case .create:
      ReminderEditorWindow.shared.presentEditor(provider: provider, item: nil)
    case .complete(let item):
      provider.complete(item)
    case .undo:
      provider.undoLastCompletion()
    case .edit(let item):
      ReminderEditorWindow.shared.presentEditor(provider: provider, item: item)
    case .snooze(let item, let preset):
      _ = provider.snooze(item, preset: preset)
    case .customSnooze(let item):
      ReminderEditorWindow.shared.presentSnooze(provider: provider, item: item)
    case .move(let item, let listID):
      _ = provider.move(item, toListWithID: listID)
    }
  }
}
