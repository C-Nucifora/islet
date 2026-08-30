import AppKit
import Carbon.HIToolbox
import Defaults
import SwiftUI

@MainActor
struct IsletQuickAction: Identifiable {
  let id: String
  let title: String
  let detail: String
  let symbol: String
  let keywords: String
  let opensIsletWindow: Bool
  let isAvailable: () -> Bool
  let perform: () -> Void

  init(
    id: String, title: String, detail: String, symbol: String, keywords: String,
    opensIsletWindow: Bool = false, isAvailable: @escaping () -> Bool,
    perform: @escaping () -> Void
  ) {
    self.id = id
    self.title = title
    self.detail = detail
    self.symbol = symbol
    self.keywords = keywords
    self.opensIsletWindow = opensIsletWindow
    self.isAvailable = isAvailable
    self.perform = perform
  }

  static var all: [Self] {
    [
      .init(
        id: "show", title: "Show Islet", detail: "Expand the notch panel",
        symbol: "waveform.path.ecg", keywords: "open expand island notch",
        opensIsletWindow: true, isAvailable: { true },
        perform: { ScreenManager.shared.viewModel?.apply(.clickedNotch) }),
      .init(
        id: "shelf-open", title: "Open File Shelf", detail: "View files held in Islet",
        symbol: "tray.full.fill", keywords: "files drop drag tray open", opensIsletWindow: true,
        isAvailable: { ActivityCenter.shared.isAvailableInExpandedSwitcher("shelf") },
        perform: {
          ScreenManager.shared.performOnActionTarget { viewModel in
            viewModel.selectActivity("shelf")
            if !viewModel.state.isExpanded { viewModel.apply(.clickedNotch) }
          }
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
        id: "timer-toggle", title: AppState.timer.isPaused ? "Resume timer" : "Pause timer",
        detail: AppState.timer.isPaused
          ? "Continue the current countdown" : "Hold the current countdown",
        symbol: AppState.timer.isPaused ? "play.circle" : "pause.circle",
        keywords: "timer hold continue",
        isAvailable: { AppState.timer.isActive && !AppState.timer.finished },
        perform: { AppState.timer.togglePause() }),
      .init(
        id: "timer-add-5", title: "Add 5 minutes", detail: "Extend the current countdown",
        symbol: "plus.circle", keywords: "timer extend more",
        isAvailable: { AppState.timer.isActive && !AppState.timer.finished },
        perform: { AppState.timer.adjust(by: 5 * 60) }),
      .init(
        id: "pulse-focus", title: "Focus Pulse",
        detail: "Allow high-priority and actionable updates", symbol: "scope",
        keywords: "filter rules profile notifications",
        isAvailable: { PulseCenter.shared.deliveryProfile != .focused },
        perform: { PulseCenter.shared.deliveryProfile = .focused }),
      .init(
        id: "pulse-critical", title: "Critical Pulse only",
        detail: "Allow only critical and failed provider updates",
        symbol: "exclamationmark.shield", keywords: "filter rules profile urgent",
        isAvailable: { PulseCenter.shared.deliveryProfile != .criticalOnly },
        perform: { PulseCenter.shared.deliveryProfile = .criticalOnly }),
      .init(
        id: "pulse-pause", title: "Pause Pulse delivery",
        detail: "Retain provider state without showing new items", symbol: "pause.circle",
        keywords: "filter rules profile mute notifications",
        isAvailable: { PulseCenter.shared.deliveryProfile != .paused },
        perform: { PulseCenter.shared.deliveryProfile = .paused }),
      .init(
        id: "pulse-resume", title: "Show all Pulse updates",
        detail: "Return to the Everything profile", symbol: "waveform.path.ecg",
        keywords: "resume unpause all rules",
        isAvailable: { PulseCenter.shared.deliveryProfile != .everything },
        perform: { PulseCenter.shared.deliveryProfile = .everything }),
      .init(
        id: "pulse-clear", title: "Dismiss all Pulse items",
        detail: "Clear visible, filtered, and muted provider state", symbol: "xmark.circle",
        keywords: "end clear notifications",
        isAvailable: { PulseCenter.shared.retainedItemCount > 0 },
        perform: { PulseCenter.shared.removeAll() }),
      .init(
        id: "pulse-settings", title: "Open Pulse providers",
        detail: "Review providers, routing rules and session history",
        symbol: "point.3.connected.trianglepath.dotted",
        keywords: "integration settings history sources token", opensIsletWindow: true,
        isAvailable: { true },
        perform: { SettingsOpener.open(destination: .pulse) }),
      .init(
        id: "clipboard-pause", title: "Pause clipboard history",
        detail: "Clear retained copies and stop capturing this session", symbol: "clipboard",
        keywords: "privacy secret stop clear", isAvailable: { !ClipboardModel.shared.isPaused },
        perform: { ClipboardModel.shared.setPaused(true) }),
      .init(
        id: "clipboard-resume", title: "Resume clipboard history",
        detail: "Capture new copies without backfilling missed items", symbol: "clipboard.fill",
        keywords: "privacy start capture",
        isAvailable: { ClipboardModel.shared.canResumeManualPause },
        perform: { ClipboardModel.shared.setPaused(false) }),
      .init(
        id: "clipboard-clear", title: "Clear clipboard history",
        detail: "Remove all copies retained by Islet", symbol: "trash",
        keywords: "privacy remove copies", isAvailable: { !ClipboardModel.shared.items.isEmpty },
        perform: { ClipboardModel.shared.clear() }),
      .init(
        id: "settings", title: "Open Settings", detail: "Configure activities and integrations",
        symbol: "gearshape", keywords: "preferences configuration", opensIsletWindow: true,
        isAvailable: { true },
        perform: { SettingsOpener.open(destination: .overview) }),
    ]
  }
}

enum CommandPaletteResultKind: Int, CaseIterable, Sendable {
  case action
  case activity
  case pulse
  case setting

  var title: String {
    switch self {
    case .action: "Actions"
    case .activity: "Activities"
    case .pulse: "Pulse"
    case .setting: "Settings"
    }
  }
}

@MainActor
struct CommandPaletteResult: Identifiable {
  let id: String
  let title: String
  let detail: String
  let symbol: String
  let kind: CommandPaletteResultKind
  let searchableContent: [String]
  let opensIsletWindow: Bool
  let isAvailable: () -> Bool
  let perform: () -> Void

  init(
    id: String, title: String, detail: String, symbol: String, kind: CommandPaletteResultKind,
    searchableContent: [String], opensIsletWindow: Bool = false,
    isAvailable: @escaping () -> Bool, perform: @escaping () -> Void
  ) {
    self.id = id
    self.title = title
    self.detail = detail
    self.symbol = symbol
    self.kind = kind
    self.searchableContent = searchableContent
    self.opensIsletWindow = opensIsletWindow
    self.isAvailable = isAvailable
    self.perform = perform
  }
}

enum CommandPaletteSearch {
  @MainActor
  static func ranked(_ candidates: [CommandPaletteResult], query: String) -> [CommandPaletteResult]
  {
    let queryWords = SettingsSearch.words(in: query)
    guard !queryWords.isEmpty else { return candidates }
    return candidates.filter {
      SettingsSearch.matches(query, in: [$0.title, $0.detail] + $0.searchableContent)
    }.sorted {
      let left = score($0, query: query, words: queryWords)
      let right = score($1, query: query, words: queryWords)
      if left != right { return left < right }
      if $0.kind.rawValue != $1.kind.rawValue { return $0.kind.rawValue < $1.kind.rawValue }
      return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
    }
  }

  @MainActor
  private static func score(
    _ result: CommandPaletteResult, query: String, words: [String]
  ) -> Int {
    let titleWords = SettingsSearch.words(in: result.title)
    let compactQuery = SettingsSearch.compact(query)
    let compactTitle = SettingsSearch.compact(result.title)
    if compactTitle == compactQuery { return 0 }
    if compactTitle.hasPrefix(compactQuery) { return 1 }
    if words.allSatisfy({ word in titleWords.contains { $0.hasPrefix(word) } }) { return 2 }
    if SettingsSearch.matches(query, in: [result.title]) { return 3 }
    if SettingsSearch.matches(query, in: [result.detail]) { return 4 }
    return 5
  }
}

struct CommandPaletteSelection: Equatable {
  private(set) var index = 0

  mutating func reset() { index = 0 }

  mutating func updateResultCount(_ count: Int) {
    index = count > 0 ? min(index, count - 1) : 0
  }

  mutating func move(_ direction: Int, resultCount: Int) {
    guard resultCount > 0 else {
      index = 0
      return
    }
    index = (index + direction + resultCount) % resultCount
  }
}

@MainActor
enum CommandPaletteCatalog {
  static func availableResults(from candidates: [CommandPaletteResult]) -> [CommandPaletteResult] {
    candidates.filter { $0.isAvailable() }
  }

  static var all: [CommandPaletteResult] {
    actionResults + activityResults + pulseResults + settingResults
  }

  private static var actionResults: [CommandPaletteResult] {
    IsletQuickAction.all.map { action in
      CommandPaletteResult(
        id: "action:\(action.id)", title: action.title, detail: action.detail,
        symbol: action.symbol, kind: .action, searchableContent: [action.keywords],
        opensIsletWindow: action.opensIsletWindow,
        isAvailable: action.isAvailable, perform: action.perform)
    }
  }

  private static var activityResults: [CommandPaletteResult] {
    ActivityCatalog.orderable.map { activity in
      CommandPaletteResult(
        id: "activity:\(activity.id)", title: "Open \(activity.name)",
        detail: "Show the \(activity.name) activity in Islet", symbol: activity.icon,
        kind: .activity, searchableContent: [activity.id, activity.name], opensIsletWindow: true,
        isAvailable: { ActivityCenter.shared.isAvailableInExpandedSwitcher(activity.id) },
        perform: { openActivity(activity.id) })
    }
  }

  private static var pulseResults: [CommandPaletteResult] {
    PulseCenter.shared.items.flatMap { item in
      var results = [
        CommandPaletteResult(
          id: "pulse:\(item.source):\(item.id)", title: item.title,
          detail: item.subtitle ?? "Pulse from \(item.source)", symbol: item.symbol,
          kind: .pulse,
          searchableContent: [item.source, item.subtitle ?? "", item.state.rawValue],
          opensIsletWindow: true,
          isAvailable: { PulseCenter.shared.items.contains { $0.id == item.id } },
          perform: { openActivity("pulse") })
      ]
      results += item.actions.map { action in
        CommandPaletteResult(
          id: "pulse-action:\(item.source):\(item.id):\(action.id)", title: action.title,
          detail: "\(item.title) · \(item.source)", symbol: "arrow.up.right.square",
          kind: .pulse, searchableContent: [item.title, item.subtitle ?? "", item.source],
          isAvailable: {
            PulseCenter.shared.items.contains { current in
              current.id == item.id && current.actions.contains { $0.id == action.id }
            }
          },
          perform: { NSWorkspace.shared.open(action.url) })
      }
      return results
    }
  }

  private static var settingResults: [CommandPaletteResult] {
    SettingsDetailPage.allCases.flatMap { page in
      page.paletteControls.enumerated().map { index, control in
        CommandPaletteResult(
          id: "setting:\(page.rawValue):\(index)", title: control,
          detail: "Settings · \(page.title)", symbol: page.icon, kind: .setting,
          searchableContent: [page.title, page.subtitle], opensIsletWindow: true,
          isAvailable: { true },
          perform: { SettingsOpener.open(page: page) })
      }
    }
  }

  private static func openActivity(_ id: String) {
    guard let viewModel = ScreenManager.shared.viewModel else { return }
    viewModel.selectActivity(id)
    if !viewModel.state.isExpanded { viewModel.apply(.clickedNotch) }
  }
}

@MainActor
final class CommandPaletteModel: ObservableObject {
  @Published var query = "" { didSet { refresh(resetSelection: true) } }
  @Published private(set) var results: [CommandPaletteResult] = []
  @Published private(set) var selection = CommandPaletteSelection()
  private let candidates: () -> [CommandPaletteResult]
  private let recentIDs: () -> [String]
  private let saveRecentIDs: ([String]) -> Void
  private let dismiss: (_ restorePreviousApplication: Bool) -> Void

  init(
    candidates: @escaping () -> [CommandPaletteResult] = { CommandPaletteCatalog.all },
    recentIDs: @escaping () -> [String] = { Defaults[.commandPaletteRecentResultIDs] },
    saveRecentIDs: @escaping ([String]) -> Void = {
      Defaults[.commandPaletteRecentResultIDs] = $0
    },
    dismiss: @escaping (_ restorePreviousApplication: Bool) -> Void = {
      QuickActionsOpener.close(restorePreviousApplication: $0)
    }
  ) {
    self.candidates = candidates
    self.recentIDs = recentIDs
    self.saveRecentIDs = saveRecentIDs
    self.dismiss = dismiss
    refresh()
  }

  var selectedResult: CommandPaletteResult? {
    guard results.indices.contains(selection.index) else { return nil }
    return results[selection.index]
  }

  var recentResultIDs: Set<String> { Set(recentIDs().prefix(5)) }

  func refresh(resetSelection: Bool = false) {
    let available = CommandPaletteCatalog.availableResults(from: candidates())
    if SettingsSearch.words(in: query).isEmpty {
      let recents = recentIDs()
      results = available.sorted { left, right in
        let leftIndex = recents.firstIndex(of: left.id) ?? Int.max
        let rightIndex = recents.firstIndex(of: right.id) ?? Int.max
        if leftIndex != rightIndex { return leftIndex < rightIndex }
        if left.kind.rawValue != right.kind.rawValue {
          return left.kind.rawValue < right.kind.rawValue
        }
        return left.title.localizedCaseInsensitiveCompare(right.title) == .orderedAscending
      }
    } else {
      results = CommandPaletteSearch.ranked(available, query: query)
    }
    if resetSelection { selection.reset() }
    selection.updateResultCount(results.count)
  }

  func moveSelection(_ direction: Int) {
    selection.move(direction, resultCount: results.count)
    objectWillChange.send()
  }

  func performSelected() {
    guard let result = selectedResult else { return }
    perform(result)
  }

  func perform(_ result: CommandPaletteResult) {
    var recents = recentIDs().filter { $0 != result.id }
    recents.insert(result.id, at: 0)
    saveRecentIDs(Array(recents.prefix(5)))
    dismiss(!result.opensIsletWindow)
    result.perform()
  }
}

private enum CommandPaletteKeyCommand { case up, down, perform, close }

private final class CommandPalettePanel: NSPanel {
  var handleCommand: ((CommandPaletteKeyCommand) -> Void)?

  override func sendEvent(_ event: NSEvent) {
    guard event.type == .keyDown else {
      super.sendEvent(event)
      return
    }
    let command: CommandPaletteKeyCommand?
    switch Int(event.keyCode) {
    case kVK_UpArrow: command = .up
    case kVK_DownArrow: command = .down
    case kVK_Return, kVK_ANSI_KeypadEnter: command = .perform
    case kVK_Escape: command = .close
    default: command = nil
    }
    guard let command else {
      super.sendEvent(event)
      return
    }
    handleCommand?(command)
  }

  override func performClose(_ sender: Any?) {
    guard let handleCommand else {
      super.performClose(sender)
      return
    }
    handleCommand(.close)
  }
}

@MainActor
enum QuickActionsOpener {
  private static var panel: CommandPalettePanel?
  private static var previousApplication: NSRunningApplication?

  static func open() {
    if panel?.isVisible != true {
      let frontmost = NSWorkspace.shared.frontmostApplication
      previousApplication =
        frontmost?.processIdentifier == ProcessInfo.processInfo.processIdentifier
        ? nil : frontmost
    }
    NSApp.activate(ignoringOtherApps: true)
    let model = CommandPaletteModel()
    let hosting = NSHostingController(rootView: QuickActionsView(model: model))
    let window: CommandPalettePanel
    if let panel {
      window = panel
      window.contentViewController = hosting
    } else {
      window = CommandPalettePanel(contentViewController: hosting)
      window.title = "Islet Command Palette"
      window.styleMask = [.titled, .closable, .resizable, .utilityWindow]
      window.setContentSize(NSSize(width: 620, height: 520))
      window.contentMinSize = NSSize(width: 480, height: 340)
      window.isFloatingPanel = true
      window.hidesOnDeactivate = false
      window.isReleasedWhenClosed = false
      window.center()
      panel = window
    }
    window.handleCommand = { command in
      switch command {
      case .up: model.moveSelection(-1)
      case .down: model.moveSelection(1)
      case .perform: model.performSelected()
      case .close: close()
      }
    }
    window.makeKeyAndOrderFront(nil)
  }

  fileprivate static func close(restorePreviousApplication: Bool = true) {
    panel?.orderOut(nil)
    let application = previousApplication
    previousApplication = nil
    if restorePreviousApplication { application?.activate() }
  }
}

private struct QuickActionsView: View {
  @Default(.appTheme) private var appTheme
  @ObservedObject var model: CommandPaletteModel
  @ObservedObject private var timer = AppState.timer
  @ObservedObject private var pulse = PulseCenter.shared
  @ObservedObject private var clipboard = ClipboardModel.shared
  @ObservedObject private var center = ActivityCenter.shared
  @FocusState private var searchFocused: Bool

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
        TextField("Search actions, activities, Pulse, and Settings", text: $model.query)
          .textFieldStyle(.plain)
          .font(.title3)
          .focused($searchFocused)
        if !model.query.isEmpty {
          Button {
            model.query = ""
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
      resultList
      Divider()
      HStack(spacing: 14) {
        Label("Select", systemImage: "arrow.up.arrow.down")
        Label("Run", systemImage: "return")
        Label("Close", systemImage: "escape")
        Spacer()
        if let shortcut = Defaults[.commandPaletteShortcut] { Text(shortcut.displayName) }
      }
      .font(.caption2)
      .foregroundStyle(.secondary)
      .padding(.horizontal, 14)
      .padding(.vertical, 8)
    }
    .tint(appTheme.accentColor)
    .environment(\.appTheme, appTheme)
    .frame(minWidth: 480, minHeight: 340)
    .onAppear { searchFocused = true }
    .onReceive(timer.objectWillChange) { _ in model.refresh() }
    .onReceive(pulse.objectWillChange) { _ in model.refresh() }
    .onReceive(clipboard.objectWillChange) { _ in model.refresh() }
    .onReceive(center.objectWillChange) { _ in model.refresh() }
  }

  @ViewBuilder private var resultList: some View {
    if model.results.isEmpty {
      ContentUnavailableView.search(text: model.query)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 4) {
            if SettingsSearch.words(in: model.query).isEmpty {
              sectionHeader("Recent actions")
              let recents = model.results.filter { model.recentResultIDs.contains($0.id) }
              if recents.isEmpty {
                Text("Commands you run will appear here.")
                  .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12)
              } else {
                ForEach(recents) { resultRow($0) }
              }
              sectionHeader("All commands")
            }
            ForEach(
              model.results.filter { result in
                !SettingsSearch.words(in: model.query).isEmpty
                  || !model.recentResultIDs.contains(result.id)
              }
            ) { resultRow($0) }
          }
          .padding(8)
        }
        .onChange(of: model.selection.index) { _, index in
          guard model.results.indices.contains(index) else { return }
          proxy.scrollTo(model.results[index].id, anchor: .center)
        }
      }
    }
  }

  private func sectionHeader(_ title: String) -> some View {
    Text(title)
      .font(.caption.weight(.semibold))
      .foregroundStyle(.secondary)
      .padding(.horizontal, 12)
      .padding(.top, 6)
  }

  private func resultRow(_ result: CommandPaletteResult) -> some View {
    let selected = model.selectedResult?.id == result.id
    return Button {
      model.perform(result)
    } label: {
      HStack(spacing: 12) {
        Image(systemName: result.symbol)
          .font(.title3).frame(width: 28).foregroundStyle(.tint).accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 2) {
          Text(result.title).font(.body.weight(.medium))
          Text(result.detail).font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Text(result.kind.title).font(.caption2).foregroundStyle(.tertiary)
      }
      .contentShape(Rectangle())
      .padding(.horizontal, 12)
      .padding(.vertical, 9)
      .background(
        RoundedRectangle(cornerRadius: 8)
          .fill(selected ? appTheme.accentColor.opacity(0.22) : .clear))
    }
    .id(result.id)
    .buttonStyle(.plain)
    .accessibilityHint(result.detail)
    .accessibilityAddTraits(selected ? .isSelected : [])
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
