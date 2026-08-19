import Combine
import Defaults
import SwiftUI

/// Formats the compact countdown.
///
/// `CalendarLogic.countdownText` rounds to whole minutes, which is right for "your meeting is in
/// 12m" and wrong here: a Live Activity is very often a running timer, and a timer that reads "1m"
/// for sixty seconds looks broken.
enum LiveActivityCountdown {
  static func text(to end: Date, now: Date) -> String {
    let seconds = Int(end.timeIntervalSince(now).rounded())
    guard seconds > 0 else { return "0:00" }
    if seconds < 3600 { return String(format: "%d:%02d", seconds / 60, seconds % 60) }
    let hours = seconds / 3600
    let minutes = (seconds % 3600) / 60
    return String(format: "%d:%02d", hours, minutes)
  }
}

/// The iPhone tab: Live Activities replicated from the paired phone.
@MainActor
final class ContinuityActivity: NotchActivity, ObservableObject {
  let id = "continuity"
  let priority = ActivityPriority.ambient
  let tabIcon = "iphone.gen3"
  private(set) var activationDate: Date?

  let monitor = ContinuityMonitor.shared
  private var cancellables: Set<AnyCancellable> = []

  var isActive: Bool {
    guard Defaults[.continuityEnabled] else { return false }
    return !monitor.cards.isEmpty || Defaults[.continuityAlwaysVisible]
  }

  /// The card the compact island shows. `cards` is already ordered most-relevant first.
  var promoted: LiveActivityCard? { monitor.cards.first }

  func start() {
    monitor.start()
    monitor.objectWillChange
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in
        guard let self else { return }
        if self.isActive, self.activationDate == nil { self.activationDate = Date() }
        if !self.isActive { self.activationDate = nil }
        self.objectWillChange.send()
      }
      .store(in: &cancellables)
  }

  var compactLeading: AnyView { AnyView(ContinuityCompactLeading(activity: self)) }
  var compactTrailing: AnyView { AnyView(ContinuityCompactTrailing(activity: self)) }
  var expandedView: AnyView { AnyView(ContinuityExpandedView(activity: self)) }
  /// A list of cards needs the dense tier; at the base height three activities already clip.
  var preferredExpandedHeight: CGFloat { Metrics.tallExpandedHeight }
}
