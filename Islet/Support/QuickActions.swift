import AppKit
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
        id: "show", title: "Show Islet", detail: "Open the current activity surface",
        symbol: "waveform.path.ecg", keywords: "open expand island notch", isAvailable: { true }
      ) {
        ScreenManager.shared.viewModel?.apply(.clickedNotch)
      },
      .init(
        id: "timer-5", title: "Start 5-minute timer", detail: "Start a short countdown",
        symbol: "timer", keywords: "countdown short break", isAvailable: { true }
      ) {
        AppState.timer.start(5 * 60, label: "Timer")
      },
      .init(
        id: "timer-25", title: "Start focus session", detail: "Start a 25-minute timer",
        symbol: "brain.head.profile", keywords: "pomodoro timer work", isAvailable: { true }
      ) {
        AppState.timer.start(25 * 60, label: "Focus")
      },
      .init(
        id: "timer-cancel", title: "Cancel timer", detail: "Stop the current countdown",
        symbol: "timer.square", keywords: "stop dismiss", isAvailable: { AppState.timer.isActive }
      ) {
        AppState.timer.cancel()
      },
      .init(
        id: "pulse-focus", title: "Focus Pulse", detail: "Allow high-priority and actionable updates",
        symbol: "scope", keywords: "filter rules profile notifications", isAvailable: {
          PulseCenter.shared.deliveryProfile != .focused
        }
      ) {
        PulseCenter.shared.deliveryProfile = .focused
      },
      .init(
        id: "pulse-resume", title: "Show all Pulse updates", detail: "Return to the Everything profile",
        symbol: "waveform.path.ecg", keywords: "resume unpause all rules", isAvailable: {
          PulseCenter.shared.deliveryProfile != .everything
        }
      ) {
        PulseCenter.shared.deliveryProfile = .everything
      },
      .init(
        id: "pulse-clear", title: "Dismiss all Pulse items", detail: "Clear the current provider stack",
        symbol: "xmark.circle", keywords: "end clear notifications", isAvailable: {
          !PulseCenter.shared.items.isEmpty
        }
      ) {
        PulseCenter.shared.removeAll()
      },
      .init(
        id: "clipboard-pause", title: "Pause clipboard history",
        detail: "Clear retained copies and stop capturing this session",
        symbol: "clipboard", keywords: "privacy secret stop clear", isAvailable: {
          !ClipboardModel.shared.isPaused
        }
      ) {
        ClipboardModel.shared.setPaused(true)
      },
      .init(
        id: "clipboard-resume", title: "Resume clipboard history",
        detail: "Capture new copies without backfilling missed items",
        symbol: "clipboard.fill", keywords: "privacy start capture", isAvailable: {
          ClipboardModel.shared.isPaused
        }
      ) {
        ClipboardModel.shared.setPaused(false)
      },
      .init(
        id: "clipboard-clear", title: "Clear clipboard history",
        detail: "Remove all copies retained by Islet",
        symbol: "trash", keywords: "privacy remove copies", isAvailable: {
          !ClipboardModel.shared.items.isEmpty
        }
      ) {
        ClipboardModel.shared.clear()
      },
      .init(
        id: "settings", title: "Open Settings", detail: "Configure activities and integrations",
        symbol: "gearshape", keywords: "preferences configuration", isAvailable: { true }
      ) {
        SettingsOpener.open()
      },
    ]
  }
}

@MainActor
enum QuickActionsOpener {
  private static var panel: NSPanel?

  static func open() {
    NSApp.activate(ignoringOtherApps: true)
    if let panel {
      panel.makeKeyAndOrderFront(nil)
      return
    }
    let hosting = NSHostingController(rootView: QuickActionsView())
    let window = NSPanel(contentViewController: hosting)
    window.title = "Islet Quick Actions"
    window.styleMask = [.titled, .closable, .resizable, .utilityWindow]
    window.setContentSize(NSSize(width: 560, height: 430))
    window.contentMinSize = NSSize(width: 440, height: 320)
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
  @State private var query = ""

  private var actions: [IsletQuickAction] {
    let available = IsletQuickAction.all.filter { $0.isAvailable() }
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !needle.isEmpty else { return available }
    return available.filter {
      "\($0.title) \($0.detail) \($0.keywords)".lowercased().contains(needle)
    }
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
          Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Clear search")
        }
      }
      .padding(14)
      Divider()
      if actions.isEmpty {
        ContentUnavailableView.search(text: query)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          LazyVStack(spacing: 4) {
            ForEach(actions) { action in
              Button { perform(action) } label: {
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
        Text("Type to filter • Return runs the first action")
        Spacer()
        Text("⌘K from the Islet menu")
      }
      .font(.caption2)
      .foregroundStyle(.secondary)
      .padding(.horizontal, 14)
      .padding(.vertical, 8)
    }
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
