import AppIntents
import Foundation

struct StartIsletTimerIntent: AppIntent {
  static let title: LocalizedStringResource = "Start an Islet Timer"
  static let description = IntentDescription("Starts a countdown in Islet.")
  static let openAppWhenRun = false

  @Parameter(title: "Minutes", default: 25, inclusiveRange: (1, 480))
  var minutes: Int

  @Parameter(title: "Label")
  var label: String?

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    AppState.timer.start(TimeInterval(minutes * 60), label: label)
    return .result(dialog: "Started a \(minutes)-minute timer.")
  }
}

struct CancelIsletTimerIntent: AppIntent {
  static let title: LocalizedStringResource = "Cancel the Islet Timer"
  static let description = IntentDescription("Cancels the current Islet countdown.")
  static let openAppWhenRun = false

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    AppState.timer.cancel()
    return .result(dialog: "Cancelled the timer.")
  }
}

struct ToggleIsletTimerIntent: AppIntent {
  static let title: LocalizedStringResource = "Pause or Resume the Islet Timer"
  static let description = IntentDescription("Pauses or resumes the current countdown.")
  static let openAppWhenRun = false

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    guard AppState.timer.isActive, !AppState.timer.finished else {
      return .result(dialog: "There is no running timer.")
    }
    AppState.timer.togglePause()
    return .result(dialog: AppState.timer.isPaused ? "Paused the timer." : "Resumed the timer.")
  }
}

struct AddTimeToIsletTimerIntent: AppIntent {
  static let title: LocalizedStringResource = "Add Time to the Islet Timer"
  static let description = IntentDescription("Adds minutes to the current countdown.")
  static let openAppWhenRun = false

  @Parameter(title: "Minutes", default: 5, inclusiveRange: (1, 120))
  var minutes: Int

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    guard AppState.timer.isActive, !AppState.timer.finished else {
      return .result(dialog: "There is no running timer.")
    }
    AppState.timer.adjust(by: TimeInterval(minutes * 60))
    return .result(dialog: "Added \(minutes) minutes.")
  }
}

struct RestartIsletTimerIntent: AppIntent {
  static let title: LocalizedStringResource = "Restart the Last Islet Timer"
  static let description = IntentDescription(
    "Starts the most recent timer duration and label again.")
  static let openAppWhenRun = false

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    guard AppState.timer.lastDuration != nil else {
      return .result(dialog: "There is no previous timer.")
    }
    AppState.timer.restartLastTimer()
    return .result(dialog: "Restarted the last timer.")
  }
}

struct ShowIsletIntent: AppIntent {
  static let title: LocalizedStringResource = "Show Islet"
  static let description = IntentDescription("Opens the Islet notch panel.")
  static let openAppWhenRun = false

  @MainActor
  func perform() async throws -> some IntentResult {
    ScreenManager.shared.viewModel?.apply(.clickedNotch)
    return .result()
  }
}

struct PublishPulseEventIntent: AppIntent {
  static let title: LocalizedStringResource = "Publish an Islet Pulse Event"
  static let description = IntentDescription(
    "Shows a short-lived event in Islet from Shortcuts or Siri.")
  static let openAppWhenRun = false

  @Parameter(title: "Title")
  var eventTitle: String

  @Parameter(title: "Identifier")
  var identifier: String?

  @Parameter(title: "Details")
  var details: String?

  @Parameter(title: "Priority", default: .normal)
  var eventPriority: PulseIntentPriority

  @Parameter(title: "Seconds", default: 8, inclusiveRange: (2, 300))
  var seconds: Int

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
    let suppliedID = identifier?.trimmingCharacters(in: .whitespacesAndNewlines)
    let id = suppliedID.flatMap { $0.isEmpty ? nil : $0 } ?? "intent-\(UUID().uuidString)"
    let payload = PulsePayload(
      id: id, source: "shortcuts", title: eventTitle, subtitle: details,
      symbol: "sparkles", accentHex: "#64D2FF", progress: nil, state: .active,
      priority: eventPriority.pulseValue,
      expiresAt: Date().addingTimeInterval(TimeInterval(seconds)),
      actions: nil)
    let center = PulseCenter.shared
    let response = center.applyIfEnabled(
      PulseCommand(token: "", operation: .event, activity: payload, id: nil))
    guard response.ok else { throw PulseIntentError.rejected(response.error ?? "Unknown error") }
    if center.items.contains(where: { $0.id == id }) {
      return .result(value: id, dialog: "Published to Islet.")
    }
    return .result(
      value: id, dialog: "Accepted by Islet, but hidden by the current Pulse delivery rules.")
  }
}

struct UpdatePulseProgressIntent: AppIntent {
  static let title: LocalizedStringResource = "Update Islet Pulse Progress"
  static let description = IntentDescription(
    "Creates or updates progress from Shortcuts under the Shortcuts provider source.")
  static let openAppWhenRun = false

  @Parameter(title: "Identifier")
  var identifier: String

  @Parameter(title: "Title")
  var activityTitle: String

  @Parameter(title: "Details")
  var details: String?

  @Parameter(title: "Progress", inclusiveRange: (0, 1))
  var progress: Double

  @Parameter(title: "Priority", default: .normal)
  var activityPriority: PulseIntentPriority

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    let payload = PulsePayload(
      id: identifier, source: "shortcuts", title: activityTitle, subtitle: details,
      symbol: "chart.bar.fill", accentHex: "#64D2FF", progress: progress, state: .progress,
      priority: activityPriority.pulseValue, expiresAt: nil, actions: nil)
    let response = PulseCenter.shared.applyIfEnabled(
      PulseCommand(token: "", operation: .update, activity: payload, id: nil))
    guard response.ok else { throw PulseIntentError.rejected(response.error ?? "Unknown error") }
    return .result(dialog: "Updated Pulse progress.")
  }
}

struct EndPulseItemIntent: AppIntent {
  static let title: LocalizedStringResource = "End an Islet Pulse Item"
  static let description = IntentDescription(
    "Ends a Pulse item created by the Shortcuts provider source.")
  static let openAppWhenRun = false

  @Parameter(title: "Identifier")
  var identifier: String

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    let response = PulseCenter.shared.applyIfEnabled(
      PulseCommand(
        token: "", operation: .end, activity: nil, id: identifier, source: "shortcuts"))
    guard response.ok else { throw PulseIntentError.rejected(response.error ?? "Unknown error") }
    return .result(dialog: "Ended the Pulse item if it was active.")
  }
}

enum PulseIntentPriority: String, AppEnum {
  case low
  case normal
  case high
  case critical

  static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Pulse Priority")
  static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
    .low: "Low", .normal: "Normal", .high: "High", .critical: "Critical",
  ]

  var pulseValue: PulsePriority {
    switch self {
    case .low: .low
    case .normal: .normal
    case .high: .high
    case .critical: .critical
    }
  }
}

enum PulseIntentProfile: String, AppEnum {
  case everything
  case focused
  case criticalOnly
  case paused

  static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Pulse Delivery Profile")
  static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
    .everything: "Everything", .focused: "Focus", .criticalOnly: "Critical Only",
    .paused: "Paused",
  ]

  var pulseValue: PulseDeliveryProfile {
    switch self {
    case .everything: .everything
    case .focused: .focused
    case .criticalOnly: .criticalOnly
    case .paused: .paused
    }
  }
}

struct SetPulseDeliveryProfileIntent: AppIntent {
  static let title: LocalizedStringResource = "Set Islet Pulse Delivery"
  static let description = IntentDescription(
    "Changes which local provider updates Islet shows for the current session.")
  static let openAppWhenRun = false

  @Parameter(title: "Profile", default: .focused)
  var profile: PulseIntentProfile

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    PulseCenter.shared.deliveryProfile = profile.pulseValue
    return .result(dialog: "Pulse delivery is now \(profile.pulseValue.title).")
  }
}

struct DismissPulseItemsIntent: AppIntent {
  static let title: LocalizedStringResource = "Dismiss Islet Pulse Items"
  static let description = IntentDescription(
    "Dismisses all retained Pulse provider items, including currently filtered or muted state.")
  static let openAppWhenRun = false

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    let center = PulseCenter.shared
    let count = center.retainedItemCount
    center.removeAll()
    return .result(
      dialog: count == 1 ? "Dismissed one Pulse item." : "Dismissed \(count) Pulse items.")
  }
}

struct PauseClipboardHistoryIntent: AppIntent {
  static let title: LocalizedStringResource = "Pause Islet Clipboard History"
  static let description = IntentDescription(
    "Clears copies retained by Islet and stops capturing new ones until resumed.")
  static let openAppWhenRun = false

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    ClipboardModel.shared.setPaused(true)
    return .result(dialog: "Paused and cleared Islet clipboard history.")
  }
}

struct ResumeClipboardHistoryIntent: AppIntent {
  static let title: LocalizedStringResource = "Resume Islet Clipboard History"
  static let description = IntentDescription(
    "Resumes capturing new copies without backfilling anything copied while paused.")
  static let openAppWhenRun = false

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    ClipboardModel.shared.setPaused(false)
    return .result(dialog: "Resumed Islet clipboard history.")
  }
}

private enum PulseIntentError: LocalizedError {
  case rejected(String)

  var errorDescription: String? {
    switch self {
    case .rejected(let message): message
    }
  }
}

struct IsletShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: StartIsletTimerIntent(),
      phrases: ["Start a timer in \(.applicationName)"],
      shortTitle: "Start Timer",
      systemImageName: "timer")
    AppShortcut(
      intent: ToggleIsletTimerIntent(),
      phrases: [
        "Pause the timer in \(.applicationName)", "Resume the timer in \(.applicationName)",
      ],
      shortTitle: "Pause Timer",
      systemImageName: "pause.circle")
    AppShortcut(
      intent: ShowIsletIntent(),
      phrases: ["Show \(.applicationName)"],
      shortTitle: "Show Islet",
      systemImageName: "waveform.path.ecg")
    AppShortcut(
      intent: PublishPulseEventIntent(),
      phrases: ["Publish to \(.applicationName)"],
      shortTitle: "Publish Event",
      systemImageName: "sparkles")
    AppShortcut(
      intent: SetPulseDeliveryProfileIntent(),
      phrases: ["Set Pulse delivery in \(.applicationName)"],
      shortTitle: "Set Pulse Delivery",
      systemImageName: "scope")
    AppShortcut(
      intent: DismissPulseItemsIntent(),
      phrases: ["Dismiss Pulse in \(.applicationName)"],
      shortTitle: "Dismiss Pulse",
      systemImageName: "xmark.circle")
    AppShortcut(
      intent: UpdatePulseProgressIntent(),
      phrases: ["Update Pulse progress in \(.applicationName)"],
      shortTitle: "Update Progress",
      systemImageName: "chart.bar.fill")
    AppShortcut(
      intent: EndPulseItemIntent(),
      phrases: ["End a Pulse item in \(.applicationName)"],
      shortTitle: "End Pulse Item",
      systemImageName: "checkmark.circle")
    AppShortcut(
      intent: PauseClipboardHistoryIntent(),
      phrases: ["Pause clipboard history in \(.applicationName)"],
      shortTitle: "Pause Clipboard",
      systemImageName: "clipboard")
    AppShortcut(
      intent: ResumeClipboardHistoryIntent(),
      phrases: ["Resume clipboard history in \(.applicationName)"],
      shortTitle: "Resume Clipboard",
      systemImageName: "clipboard.fill")
  }
}
