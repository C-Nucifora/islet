import Combine
import Defaults
import SwiftUI

/// The iPhone tab: which apps are running Live Activities on the paired phone.
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

  /// The card the compact island shows: the leftmost in the menu bar, matching what the user's eye
  /// lands on first.
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
}
