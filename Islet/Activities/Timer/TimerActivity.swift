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

  var isActive: Bool { endDate != nil || isPaused || finished }
  var isRunning: Bool { endDate != nil && !isPaused && !finished }

  /// Live remaining time, computed on read so no per-tick model churn is needed.
  var remainingNow: TimeInterval {
    if finished { return 0 }
    if isPaused { return pausedRemaining ?? 0 }
    guard let endDate else { return 0 }
    return max(0, endDate.timeIntervalSinceNow)
  }

  var progressNow: Double {
    total > 0 ? max(0, min(1, 1 - remainingNow / total)) : 0
  }

  // MARK: - Control

  func start(_ duration: TimeInterval, label: String? = nil) {
    total = duration
    self.label = label
    pausedRemaining = nil
    isPaused = false
    finished = false
    activationDate = Date()
    endDate = Date().addingTimeInterval(duration)
    scheduleCompletion()
    Haptics.perform()
  }

  func togglePause() {
    guard !finished else { return }
    if isPaused {
      guard let remaining = pausedRemaining else { return }
      endDate = Date().addingTimeInterval(remaining)
      isPaused = false
      pausedRemaining = nil
      scheduleCompletion()
    } else {
      pausedRemaining = remainingNow
      endDate = nil
      isPaused = true
      completionTask?.cancel()
    }
  }

  func addMinute() {
    guard !finished else { return }
    total += 60
    if isPaused {
      pausedRemaining = (pausedRemaining ?? 0) + 60
    } else if let endDate {
      self.endDate = endDate.addingTimeInterval(60)
      scheduleCompletion()
    }
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
    endDate = nil
    isPaused = false
    finished = true
    Haptics.perform(.levelChange)
    NSSound(named: NSSound.Name("Glass"))?.play()
    SneakQueue.shared.submit(
      Sneak(
        source: "timer", duration: 4,
        leading: AnyView(Image(systemName: "timer").foregroundStyle(.orange).font(.caption)),
        trailing: AnyView(
          Text("\(label ?? "Timer") done")
            .font(.caption2.weight(.semibold)).foregroundStyle(.white).lineLimit(1)),
        announcement: "\(label ?? "Timer") done"))
    // Auto-clear the finished state after a few seconds.
    completionTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(6))
      guard !Task.isCancelled else { return }
      self?.cancel()
    }
  }

  // MARK: - Views

  var compactLeading: AnyView { AnyView(TimerRingView(activity: self, lineWidth: 2)) }
  var compactTrailing: AnyView { AnyView(TimerCountdownText(activity: self)) }
  var expandedView: AnyView { AnyView(TimerExpandedView(activity: self)) }
}

/// A thin progress ring driven live off the activity, ticking only while running.
struct TimerRingView: View {
  @ObservedObject var activity: TimerActivity
  var lineWidth: CGFloat = 2

  var body: some View {
    TimelineView(.animation(minimumInterval: 0.2, paused: !activity.isRunning)) { _ in
      ZStack {
        Circle().stroke(.white.opacity(0.22), lineWidth: lineWidth)
        Circle()
          .trim(from: 0, to: activity.progressNow)
          .stroke(
            activity.finished ? Color.green : .orange,
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

  var body: some View {
    TimelineView(.periodic(from: .now, by: 0.5)) { _ in
      Text(TimerFormat.mmss(activity.remainingNow))
        .font(.caption.weight(.semibold)).monospacedDigit()
        .foregroundStyle(activity.finished ? .green : .orange)
    }
  }
}

struct TimerExpandedView: View {
  @ObservedObject var activity: TimerActivity

  var body: some View {
    HStack(spacing: 20) {
      TimelineView(.animation(minimumInterval: 0.2, paused: !activity.isRunning)) { _ in
        ZStack {
          Circle().stroke(.white.opacity(0.18), lineWidth: 6)
          Circle()
            .trim(from: 0, to: activity.progressNow)
            .stroke(
              activity.finished ? Color.green : .orange,
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
          Text("Done").font(.headline).foregroundStyle(.green)
          Button("Dismiss") { activity.cancel() }.buttonStyle(.borderedProminent).tint(.orange)
        } else {
          HStack(spacing: 14) {
            control(activity.isPaused ? "play.fill" : "pause.fill") { activity.togglePause() }
            control("plus") { activity.addMinute() }
            control("xmark") { activity.cancel() }
          }
          Text(activity.isPaused ? "Paused" : "Running")
            .font(.caption2).foregroundStyle(.secondary)
        }
      }
    }
    .foregroundStyle(.white)
  }

  private func control(_ symbol: String, _ action: @escaping () -> Void) -> some View {
    Button {
      Haptics.perform()
      action()
    } label: {
      Image(systemName: symbol)
        .font(.body)
        .frame(width: 34, height: 34)
        .background(Circle().fill(.white.opacity(0.12)))
    }
    .buttonStyle(.plain)
  }
}

enum TimerFormat {
  static func mmss(_ t: TimeInterval) -> String {
    let s = Int(t.rounded(.up))
    if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
    return String(format: "%d:%02d", s / 60, s % 60)
  }
}
