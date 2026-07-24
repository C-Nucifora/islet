import Combine
import Defaults
import SwiftUI

@MainActor
final class ActivityCenter: ObservableObject {
  static let shared = ActivityCenter()

  private(set) var activities: [any NotchActivity] = []
  private var cancellables: Set<AnyCancellable> = []

  init() {
    // Republish when the user reorders or disables activities so the notch updates live.
    Defaults.publisher(.disabledActivities)
      .sink { [weak self] _ in Task { @MainActor in self?.objectWillChange.send() } }
      .store(in: &cancellables)
    Defaults.publisher(.activityOrder)
      .sink { [weak self] _ in Task { @MainActor in self?.objectWillChange.send() } }
      .store(in: &cancellables)
  }

  func register<T: NotchActivity & ObservableObject>(_ activity: T) {
    activities.append(activity)
    activity.objectWillChange
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in self?.objectWillChange.send() }
      .store(in: &cancellables)
    objectWillChange.send()
  }

  /// All active activities, ordered by the user's configured order (unlisted ones fall back to
  /// priority, then most-recently-activated).
  var activeActivities: [any NotchActivity] {
    let order = Defaults[.activityOrder]
    let disabled = Set(Defaults[.disabledActivities])
    func rank(_ a: any NotchActivity) -> Int { order.firstIndex(of: a.id) ?? Int.max }
    return
      activities
      .filter(\.isActive)
      .filter { !disabled.contains($0.id) }
      .sorted {
        let ra = rank($0)
        let rb = rank($1)
        if ra != rb { return ra < rb }
        if $0.priority != $1.priority { return $0.priority > $1.priority }
        return ($0.activationDate ?? .distantPast) > ($1.activationDate ?? .distantPast)
      }
  }

  var primaryActivity: (any NotchActivity)? { activeActivities.first }
}
