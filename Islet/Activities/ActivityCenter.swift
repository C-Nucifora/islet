import Combine
import SwiftUI

@MainActor
final class ActivityCenter: ObservableObject {
  static let shared = ActivityCenter()

  private(set) var activities: [any NotchActivity] = []
  private var cancellables: Set<AnyCancellable> = []

  func register<T: NotchActivity & ObservableObject>(_ activity: T) {
    activities.append(activity)
    activity.objectWillChange
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in self?.objectWillChange.send() }
      .store(in: &cancellables)
    objectWillChange.send()
  }

  /// All active activities, highest priority first (ties broken by most recently activated).
  var activeActivities: [any NotchActivity] {
    activities
      .filter(\.isActive)
      .sorted {
        if $0.priority != $1.priority { return $0.priority > $1.priority }
        return ($0.activationDate ?? .distantPast) > ($1.activationDate ?? .distantPast)
      }
  }

  var primaryActivity: (any NotchActivity)? { activeActivities.first }
}
