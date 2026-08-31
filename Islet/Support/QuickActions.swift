import AppKit
import Defaults
import SwiftUI

@MainActor
struct IsletQuickAction: Identifiable {
  let id: String
  let title: String
  let detail: String
  let symbol: String
  let keywords: String
  let isAvailable: () -> Bool
  let perform: () -> Void

  static var all: [Self] {
    [
      .init(
        id: "show", title: "Show Islet", detail: "Expand the notch panel",
        symbol: "waveform.path.ecg", keywords: "open expand island notch", isAvailable: { true },
        perform: { ScreenManager.shared.viewModel?.apply(.clickedNotch) }),
      .init(
        id: "shelf-open", title: "Open File Shelf", detail: "View files held in Islet",
        symbol: "tray.full.fill", keywords: "files drop drag tray open",
        isAvailable: { ActivityCenter.shared.isAvailableInExpandedSwitcher("shelf") },
        perform: {
          ShelfModel.shared.requestPresentation()
          let viewModel = ScreenManager.shared.viewModel
          if viewModel?.state.isExpanded != true { viewModel?.apply(.clickedNotch) }
        }),
      .init(
        id: "timer-5", title: "Start 5-minute timer", detail: "Set a five-minute countdown",
        symbol: "timer", keywords: "countdown short break", isAvailable: { true },
        perform: { AppState.timer.start(5 * 60, label: "Timer") }),
      .init(
        id: "timer-25", title: "Start focus session", detail: "Start a 25-minute timer",
        symbol: "brain.head.profile", keywords: "pomodoro timer work", isAvailable: { true },
        perform: { AppState.timer.start(25 * 60, label: "Focus") }),
      .init(
        id: "timer-cancel", title: "Cancel timer", detail: "Stop the current countdown",
        symbol: "timer.square", keywords: "stop dismiss", isAvailable: { AppState.timer.isActive },
        perform: { AppState.timer.cancel() }),
      .init(
        id: "timer-toggle",
        title: AppState.timer.isPaused ? "Resume timer" : "Pause timer",
        detail: AppState.timer.isPaused
          ? "Continue the current countdown" : "Hold the current countdown",
        symbol: AppState.timer.isPaused ? "play.circle" : "pause.circle",
        keywords: "timer hold continue",
        isAvailable: {
          AppState.timer.isActive && !AppState.timer.finished
        },
        perform: { AppState.timer.togglePause() }),
      .init(
        id: "timer-add-5", title: "Add 5 minutes", detail: "Extend the current countdown",
        symbol: "plus.circle", keywords: "timer extend more",
        isAvailable: {
          AppState.timer.isActive && !AppState.timer.finished
        },
        perform: { AppState.timer.adjust(by: 5 * 60) }),
      .init(
        id: "pulse-focus", title: "Focus Pulse",
        detail: "Allow high-priority and actionable updates",
        symbol: "scope", keywords: "filter rules profile notifications",
        isAvailable: {
          PulseCenter.shared.deliveryProfile != .focused
        },
        perform: { PulseCenter.shared.deliveryProfile = .focused }),
      .init(
        id: "pulse-critical", title: "Critical Pulse only",
        detail: "Allow only critical and failed provider updates",
        symbol: "exclamationmark.shield", keywords: "filter rules profile urgent",
        isAvailable: {
          PulseCenter.shared.deliveryProfile != .criticalOnly
        },
        perform: { PulseCenter.shared.deliveryProfile = .criticalOnly }),
      .init(
        id: "pulse-pause", title: "Pause Pulse delivery",
        detail: "Retain provider state without showing new items",
        symbol: "pause.circle", keywords: "filter rules profile mute notifications",
        isAvailable: {
          PulseCenter.shared.deliveryProfile != .paused
        },
        perform: { PulseCenter.shared.deliveryProfile = .paused }),
      .init(
        id: "pulse-resume", title: "Show all Pulse updates",
        detail: "Return to the Everything profile",
        symbol: "waveform.path.ecg", keywords: "resume unpause all rules",
        isAvailable: {
          PulseCenter.shared.deliveryProfile != .everything
        },
        perform: { PulseCenter.shared.deliveryProfile = .everything }),
      .init(
        id: "pulse-clear", title: "Dismiss all Pulse items",
        detail: "Clear visible, filtered, and muted provider state",
        symbol: "xmark.circle", keywords: "end clear notifications",
        isAvailable: {
          PulseCenter.shared.retainedItemCount > 0
        },
        perform: { PulseCenter.shared.removeAll() }),
      .init(
        id: "pulse-settings", title: "Open Pulse providers",
        detail: "Review providers, routing rules and session history",
        symbol: "point.3.connected.trianglepath.dotted",
        keywords: "integration settings history sources token", isAvailable: { true },
        perform: { SettingsOpener.open(destination: .pulse) }),
      .init(
        id: "clipboard-pause", title: "Pause clipboard history",
        detail: "Clear retained copies and stop capturing this session",
        symbol: "clipboard", keywords: "privacy secret stop clear",
        isAvailable: {
          !ClipboardModel.shared.isPaused
        },
        perform: { ClipboardModel.shared.setPaused(true) }),
      .init(
        id: "clipboard-resume", title: "Resume clipboard history",
        detail: "Capture new copies without backfilling missed items",
        symbol: "clipboard.fill", keywords: "privacy start capture",
        isAvailable: {
          ClipboardModel.shared.isPaused
        },
        perform: { ClipboardModel.shared.setPaused(false) }),
      .init(
        id: "clipboard-clear", title: "Clear clipboard history",
        detail: "Remove all copies retained by Islet",
        symbol: "trash", keywords: "privacy remove copies",
        isAvailable: {
          !ClipboardModel.shared.items.isEmpty
        },
        perform: { ClipboardModel.shared.clear() }),
      .init(
        id: "settings", title: "Open Settings", detail: "Configure activities and integrations",
        symbol: "gearshape", keywords: "preferences configuration", isAvailable: { true },
        perform: { SettingsOpener.open(destination: .overview) }),
    ]
  }
}

@MainActor
enum QuickActionsOpener {
  private static var panel: NSPanel?

  static func open() {
    NSApp.activate(ignoringOtherApps: true)
    if let panel {
      panel.contentViewController = NSHostingController(rootView: QuickActionsView())
      panel.makeKeyAndOrderFront(nil)
      return
    }
    let hosting = NSHostingController(rootView: QuickActionsView())
    let window = NSPanel(contentViewController: hosting)
    window.title = "Islet Quick Actions"
    window.styleMask = [.titled, .closable, .resizable, .utilityWindow]
    window.setContentSize(NSSize(width: 560, height: 470))
    window.contentMinSize = NSSize(width: 440, height: 360)
    window.isFloatingPanel = true
    window.hidesOnDeactivate = false
    window.isReleasedWhenClosed = false
    window.center()
    window.makeKeyAndOrderFront(nil)
    panel = window
  }

  fileprivate static func close() { panel?.orderOut(nil) }
}

private struct QuickActionsView: View {
  @Default(.appTheme) private var appTheme
  @ObservedObject private var timer = AppState.timer
  @ObservedObject private var pulse = PulseCenter.shared
  @ObservedObject private var clipboard = ClipboardModel.shared
  @State private var query = ""

  private var actions: [IsletQuickAction] {
    let available = IsletQuickAction.all.filter { $0.isAvailable() }
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !needle.isEmpty else { return available }
    return available.filter { QuickActionSearch.matches(needle, action: $0) }
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
        TextField("Search actions", text: $query)
          .textFieldStyle(.plain)
          .font(.title3)
          .onSubmit { performFirst() }
        if !query.isEmpty {
          Button {
            query = ""
          } label: {
            Image(systemName: "xmark.circle.fill")
          }
          .buttonStyle(.plain)
          .foregroundStyle(.secondary)
          .accessibilityLabel("Clear search")
        }
      }
      .padding(14)
      Divider()
      TimerEditor(timer: timer) {
        QuickActionsOpener.close()
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 10)
      Divider()
      if actions.isEmpty {
        ContentUnavailableView.search(text: query)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          LazyVStack(spacing: 4) {
            ForEach(actions) { action in
              Button {
                perform(action)
              } label: {
                HStack(spacing: 12) {
                  Image(systemName: action.symbol)
                    .font(.title3)
                    .frame(width: 28)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                  VStack(alignment: .leading, spacing: 2) {
                    Text(action.title).font(.body.weight(.medium))
                    Text(action.detail).font(.caption).foregroundStyle(.secondary)
                  }
                  Spacer()
                  Image(systemName: "return").font(.caption).foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
              }
              .buttonStyle(.plain)
              .accessibilityHint(action.detail)
            }
          }
          .padding(8)
        }
      }
      Divider()
      HStack {
        Text("Type to filter. Return runs the first action.")
        Spacer()
        Text("⌘K from the Islet menu")
      }
      .font(.caption2)
      .foregroundStyle(.secondary)
      .padding(.horizontal, 14)
      .padding(.vertical, 8)
    }
    .tint(appTheme.accentColor)
    .environment(\.appTheme, appTheme)
    .frame(minWidth: 440, minHeight: 320)
  }

  private func performFirst() {
    guard let first = actions.first else { return }
    perform(first)
  }

  private func perform(_ action: IsletQuickAction) {
    QuickActionsOpener.close()
    action.perform()
  }
}

private struct TimerEditor: View {
  private enum Field: Hashable {
    case duration
    case label
  }

  @ObservedObject var timer: TimerActivity
  let onStart: () -> Void

  @State private var minutes = ""
  @State private var label = ""
  @State private var hasAttemptedStart = false
  @FocusState private var focusedField: Field?

  private var validation: TimerEditorValidation {
    TimerEditorValidation.validate(minutes: minutes)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Start a custom timer").font(.headline)
      HStack(spacing: 8) {
        TextField("Minutes", text: $minutes)
          .textFieldStyle(.roundedBorder)
          .frame(width: 100)
          .focused($focusedField, equals: .duration)
          .accessibilityLabel("Timer duration in minutes")
          .accessibilityHint(
            "Enter a whole number from 1 to \(TimerEditorValidation.maximumMinutes).")
        TextField("Label (optional)", text: $label)
          .textFieldStyle(.roundedBorder)
          .focused($focusedField, equals: .label)
          .accessibilityLabel("Timer label, optional")
        Button("Start") { start() }
          .buttonStyle(.borderedProminent)
          .accessibilityHint("Starts the timer with this duration and label.")
      }
      .onSubmit(start)

      if hasAttemptedStart, let message = validation.message {
        Text(message)
          .font(.caption)
          .foregroundStyle(.orange)
          .accessibilityLabel("Timer duration error: \(message)")
      }
      HStack(spacing: 8) {
        Text("Shortcuts").font(.caption).foregroundStyle(.secondary)
        Button("5 min") { startPreset(minutes: 5, label: "Timer") }
        Button("25 min") { startPreset(minutes: 25, label: "Focus") }
      }
      .font(.caption)
    }
    .onAppear { focusedField = .duration }
  }

  private func start() {
    hasAttemptedStart = true
    guard case .valid(let duration) = validation else {
      if let message = validation.message { A11y.announce(message) }
      focusedField = .duration
      return
    }
    timer.start(duration, label: label)
    onStart()
  }

  private func startPreset(minutes: Int, label: String) {
    timer.start(TimeInterval(minutes * 60), label: label)
    onStart()
  }
}

enum QuickActionSearch {
  @MainActor
  static func matches(_ query: String, action: IsletQuickAction) -> Bool {
    let searchable = "\(action.title) \(action.detail) \(action.keywords)".lowercased()
    return query.split(whereSeparator: \.isWhitespace).allSatisfy {
      searchable.contains(String($0))
    }
  }
}
