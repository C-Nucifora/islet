import AppKit
import SwiftUI

/// A single countdown timer (incl. Pomodoro presets) shown as a determinate progress activity.
/// The model publishes only on state changes; the views tick themselves via TimelineView, so
/// nothing runs while no timer is active.
@MainActor
final class TimerActivity: NotchActivity, ObservableObject {
  let id = "timer"
  let priority = ActivityPriority.timer
  let tabIcon = "timer"
  private(set) var activationDate: Date?

  @Published private(set) var endDate: Date?  // nil while paused or idle
  @Published private(set) var total: TimeInterval = 0
  @Published private(set) var isPaused = false
  @Published private(set) var finished = false
  @Published private(set) var label: String?  // e.g. "Focus" / "Break"
  private var pausedRemaining: TimeInterval?
  private var completionTask: Task<Void, Never>?
  @Published private(set) var notificationFallbackMessage: String?
  private(set) var lastDuration: TimeInterval?
  private(set) var lastLabel: String?
  private let persistenceStore: TimerPersistenceStore
  private let completionNotifier: any TimerCompletionNotifying
  private var completionID = UUID()

  init(
    persistenceStore: TimerPersistenceStore = .defaults, now: Date = Date(),
    completionNotifier: any TimerCompletionNotifying = TimerCompletionNotifications.shared
  ) {
    self.persistenceStore = persistenceStore
    self.completionNotifier = completionNotifier
    restore(now: now)
  }

  var isActive: Bool { endDate != nil || isPaused || finished }
  var isRunning: Bool { endDate != nil && !isPaused && !finished }

  /// Live remaining time, computed on read so no per-tick model churn is needed.
  var remainingNow: TimeInterval {
    remaining(at: Date())
  }

  private func remaining(at now: Date) -> TimeInterval {
    if finished { return 0 }
    if isPaused { return pausedRemaining ?? 0 }
    guard let endDate else { return 0 }
    return max(0, endDate.timeIntervalSince(now))
  }

  var progressNow: Double {
    total > 0 ? max(0, min(1, 1 - remainingNow / total)) : 0
  }

  // MARK: - Control

  func start(_ duration: TimeInterval, label: String? = nil) {
    guard let duration = TimerLogic.validatedDuration(duration) else { return }
    let now = Date()
    completionID = UUID()
    notificationFallbackMessage = nil
    completionNotifier.prepareForTimerStart { [weak self] in
      self?.notificationFallbackMessage = TimerActivity.notificationFallbackMessage
    }
    total = duration
    let cleanLabel = label?.trimmingCharacters(in: .whitespacesAndNewlines)
    self.label = cleanLabel?.isEmpty == true ? nil : cleanLabel
    lastDuration = duration
    lastLabel = self.label
    persistLastPreset()
    pausedRemaining = nil
    isPaused = false
    finished = false
    activationDate = now
    endDate = now.addingTimeInterval(duration)
    persistSession(savedAt: now)
    scheduleCompletion()
  }

  func togglePause() {
    guard !finished else { return }
    let now = Date()
    if isPaused {
      guard let remaining = pausedRemaining else { return }
      endDate = now.addingTimeInterval(remaining)
      isPaused = false
      pausedRemaining = nil
      persistSession(savedAt: now)
      scheduleCompletion()
    } else {
      let remaining = remaining(at: now)
      // The deadline can pass just before the scheduled completion task gets its main-actor turn.
      // Pausing in that sliver must complete the timer, not create a permanently paused 0:00.
      guard remaining > 0 else {
        fire()
        return
      }
      pausedRemaining = remaining
      endDate = nil
      isPaused = true
      completionTask?.cancel()
      persistSession(savedAt: now)
    }
  }

  func addMinute() {
    adjust(by: 60)
  }

  /// Adjusts an active timer without allowing the remaining time to become zero or exceed a week.
  func adjust(by delta: TimeInterval) {
    guard !finished else { return }
    let now = Date()
    let remaining = remaining(at: now)
    guard remaining > 0 else { return }
    let adjusted = TimerLogic.adjustedRemaining(remaining, by: delta)
    let appliedDelta = adjusted - remaining
    total = min(TimerLogic.maximumDuration, max(adjusted, total + appliedDelta))
    if isPaused {
      pausedRemaining = adjusted
    } else if endDate != nil {
      endDate = now.addingTimeInterval(adjusted)
      scheduleCompletion()
    }
    persistSession(savedAt: now)
  }

  func restartLastTimer() {
    guard let lastDuration else { return }
    start(lastDuration, label: lastLabel)
  }

  func cancel() {
    completionTask?.cancel()
    endDate = nil
    isPaused = false
    finished = false
    total = 0
    label = nil
    pausedRemaining = nil
    activationDate = nil
    notificationFallbackMessage = nil
    persistenceStore.writeSessionData(nil)
  }

  private func restore(now: Date) {
    if let preset = TimerPersistence.restorePreset(from: persistenceStore) {
      lastDuration = preset.duration
      lastLabel = preset.label
    }

    switch TimerPersistence.restoreSession(from: persistenceStore, now: now) {
    case .none, .discard:
      break
    case .running(let session):
      apply(session, activationDate: session.deadline?.addingTimeInterval(-session.duration))
      scheduleCompletion()
    case .paused(let session):
      apply(session, activationDate: session.savedAt)
    case .completed(let session):
      apply(session, activationDate: session.deadline?.addingTimeInterval(-session.duration))
      finish(playEffects: false)
    }
  }

  private func apply(_ session: TimerSessionSnapshot, activationDate: Date?) {
    total = session.duration
    label = session.label
    endDate = session.deadline
    isPaused = session.isPaused
    pausedRemaining = session.pausedRemaining
    finished = false
    self.activationDate = activationDate
  }

  private func persistSession(savedAt: Date) {
    guard isRunning || isPaused else {
      persistenceStore.writeSessionData(nil)
      return
    }
    let session = TimerSessionSnapshot(
      savedAt: savedAt,
      label: label,
      duration: total,
      deadline: endDate,
      isPaused: isPaused,
      pausedRemaining: pausedRemaining)
    persistenceStore.writeSessionData(TimerPersistence.encode(session))
  }

  private func persistLastPreset() {
    guard let lastDuration else { return }
    let preset = TimerPresetSnapshot(duration: lastDuration, label: lastLabel)
    persistenceStore.writePresetData(TimerPersistence.encode(preset))
  }

  private func scheduleCompletion() {
    completionTask?.cancel()
    guard let endDate else { return }
    completionTask = Task { [weak self] in
      let delay = endDate.timeIntervalSinceNow
      if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
      guard !Task.isCancelled else { return }
      self?.fire()
    }
  }

  private func fire() {
    finish(playEffects: true)
  }

  private func finish(playEffects: Bool) {
    endDate = nil
    isPaused = false
    pausedRemaining = nil
    finished = true
    persistenceStore.writeSessionData(nil)
    if playEffects {
      let title = "\(label ?? "Timer") done"
      Haptics.perform(.levelChange)
      NSSound(named: NSSound.Name("Glass"))?.play()
      SystemEventBus.shared.emit(
        SystemEvent(
          sourceID: "timer", icon: "timer", title: title,
          accentHex: EventAccent.warning, motion: .chargeComplete, urgency: .alert, duration: 4,
          announcement: title))
      completionNotifier.notifyTimerFinished(
        completionID: completionID, title: title, body: "Your timer finished."
      ) { [weak self] in
        self?.notificationFallbackMessage = TimerActivity.notificationFallbackMessage
      }
    }
    // A completion is a user-visible state, not a transient effect. Keep it until the user
    // dismisses it or starts another timer. The TimerActivity outlives rebuilt panel views, so
    // the completion card remains available while the island is rebuilt or reopened.
  }

  // MARK: - Views

  var compactLeading: AnyView { AnyView(TimerRingView(activity: self, lineWidth: 2)) }
  var compactTrailing: AnyView { AnyView(TimerCountdownText(activity: self)) }
  var expandedView: AnyView { AnyView(TimerExpandedView(activity: self)) }

  private static let notificationFallbackMessage =
    "Timer notifications are off. Islet will still play its completion sound and show Done in the island."
}

/// A thin progress ring driven live off the activity, ticking only while running.
struct TimerRingView: View {
  @ObservedObject var activity: TimerActivity
  @Environment(\.appTheme) private var appTheme
  var lineWidth: CGFloat = 2

  var body: some View {
    TimelineView(.animation(minimumInterval: 0.2, paused: !activity.isRunning)) { _ in
      ZStack {
        Circle().stroke(.white.opacity(0.22), lineWidth: lineWidth)
        Circle()
          .trim(from: 0, to: activity.progressNow)
          .stroke(
            appTheme.color(for: TimerPresentation.tintRole(finished: activity.finished)),
            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
          )
          .rotationEffect(.degrees(-90))
      }
    }
    .frame(width: 16, height: 16)
    .accessibilityHidden(true)  // decorative; the countdown text carries the value
  }
}

struct TimerCountdownText: View {
  @ObservedObject var activity: TimerActivity
  @Environment(\.appTheme) private var appTheme

  var body: some View {
    // A paused timer may remain in the island for hours. An animation schedule can be paused,
    // unlike a periodic schedule, so it creates no needless twice-per-second view invalidations.
    TimelineView(.animation(minimumInterval: 0.5, paused: !activity.isRunning)) { _ in
      Text(TimerFormat.mmss(activity.remainingNow))
        .font(.caption.weight(.semibold)).monospacedDigit()
        .foregroundStyle(
          appTheme.color(for: TimerPresentation.tintRole(finished: activity.finished))
        )
        .accessibilityLabel(activity.label.map { "\($0) timer" } ?? "Timer")
        .accessibilityValue(
          activity.finished
            ? "Done"
            : "\(TimerFormat.accessible(activity.remainingNow)) remaining\(activity.isPaused ? ", paused" : "")"
        )
    }
  }
}

struct TimerExpandedView: View {
  @ObservedObject var activity: TimerActivity
  @Environment(\.appTheme) private var appTheme

  var body: some View {
    HStack(spacing: 20) {
      TimelineView(.animation(minimumInterval: 0.2, paused: !activity.isRunning)) { _ in
        ZStack {
          Circle().stroke(.white.opacity(0.18), lineWidth: 6)
          Circle()
            .trim(from: 0, to: activity.progressNow)
            .stroke(
              appTheme.color(for: TimerPresentation.tintRole(finished: activity.finished)),
              style: StrokeStyle(lineWidth: 6, lineCap: .round)
            )
            .rotationEffect(.degrees(-90))
          VStack(spacing: 0) {
            Text(TimerFormat.mmss(activity.remainingNow))
              .font(.title3.weight(.bold)).monospacedDigit()
            if let label = activity.label {
              Text(label).font(.caption2).foregroundStyle(.secondary)
            }
          }
        }
        .frame(width: 96, height: 96)
      }

      VStack(spacing: 10) {
        if activity.finished {
          Text("Done").font(.headline)
            .foregroundStyle(
              appTheme.color(for: TimerPresentation.tintRole(finished: activity.finished)))
          HStack {
            Button("Repeat") { activity.restartLastTimer() }
              .buttonStyle(.borderedProminent).tint(appTheme.color(for: .timer))
            Button("Dismiss") { activity.cancel() }.buttonStyle(.bordered)
          }
        } else {
          HStack(spacing: 14) {
            control(
              activity.isPaused ? "play.fill" : "pause.fill",
              label: activity.isPaused ? "Resume timer" : "Pause timer"
            ) { activity.togglePause() }
            control("minus", label: "Remove one minute") { activity.adjust(by: -60) }
            control("plus", label: "Add one minute") { activity.addMinute() }
            control("xmark", label: "Cancel timer") { activity.cancel() }
          }
          Text(activity.isPaused ? "Paused" : "Running")
            .font(.caption2).foregroundStyle(.secondary)
          if let message = activity.notificationFallbackMessage {
            Text(message)
              .font(.caption2)
              .foregroundStyle(.orange)
              .multilineTextAlignment(.center)
          }
        }
      }
    }
    .foregroundStyle(.white)
  }

  private func control(
    _ symbol: String, label: String, _ action: @escaping () -> Void
  ) -> some View {
    Button {
      action()
    } label: {
      Image(systemName: symbol)
        .font(.body)
        .frame(width: 34, height: 34)
        .background(Circle().fill(appTheme.color(for: .timer).opacity(0.18)))
    }
    .buttonStyle(.plain)
    .accessibilityLabel(label)
  }
}

enum TimerPresentation {
  /// Completion changes the copy and controls, but the selected theme remains the visual identity
  /// in both compact and expanded presentations.
  nonisolated static func tintRole(finished: Bool) -> AppThemeRole {
    switch finished {
    case false, true: .timer
    }
  }
}

enum TimerLogic {
  static let minimumDuration: TimeInterval = 1
  static let maximumDuration: TimeInterval = 7 * 24 * 60 * 60

  static func validatedDuration(_ duration: TimeInterval) -> TimeInterval? {
    guard duration.isFinite, duration >= minimumDuration else { return nil }
    return min(duration, maximumDuration)
  }

  static func adjustedRemaining(_ remaining: TimeInterval, by delta: TimeInterval) -> TimeInterval {
    guard remaining.isFinite, delta.isFinite else {
      return min(maximumDuration, max(minimumDuration, remaining.isFinite ? remaining : 0))
    }
    return min(maximumDuration, max(minimumDuration, remaining + delta))
  }
}

enum TimerEditorValidation: Equatable {
  case valid(TimeInterval)
  case missingDuration
  case invalidDuration
  case nonPositiveDuration
  case overMaximumDuration

  static func validate(minutes input: String) -> Self {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return .missingDuration }
    guard let minutes = Int(trimmed) else { return .invalidDuration }
    guard minutes > 0 else { return .nonPositiveDuration }
    guard minutes <= maximumMinutes else { return .overMaximumDuration }
    return .valid(TimeInterval(minutes * 60))
  }

  static var maximumMinutes: Int { Int(TimerLogic.maximumDuration / 60) }

  var message: String? {
    switch self {
    case .valid:
      nil
    case .missingDuration:
      "Enter a duration in minutes."
    case .invalidDuration:
      "Enter a whole number of minutes."
    case .nonPositiveDuration:
      "Duration must be at least one minute."
    case .overMaximumDuration:
      "Duration cannot exceed \(Self.maximumMinutes) minutes."
    }
  }
}

enum TimerFormat {
  static func mmss(_ t: TimeInterval) -> String {
    guard t.isFinite else { return "0:00" }
    let s = max(0, Int(t.rounded(.up)))
    if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
    return String(format: "%d:%02d", s / 60, s % 60)
  }

  static func accessible(_ t: TimeInterval) -> String {
    guard t.isFinite else { return "0 seconds" }
    let seconds = max(0, Int(t.rounded(.up)))
    let hours = seconds / 3600
    let minutes = (seconds % 3600) / 60
    let remainder = seconds % 60
    return [
      hours > 0 ? "\(hours) hour\(hours == 1 ? "" : "s")" : nil,
      minutes > 0 ? "\(minutes) minute\(minutes == 1 ? "" : "s")" : nil,
      remainder > 0 || seconds == 0 ? "\(remainder) second\(remainder == 1 ? "" : "s")" : nil,
    ].compactMap { $0 }.joined(separator: ", ")
  }
}
