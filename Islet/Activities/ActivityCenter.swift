import Combine
import Defaults
import SwiftUI

@MainActor
final class ActivityCenter: ObservableObject {
  static let shared = ActivityCenter()

  private(set) var activities: [any NotchActivity] = []
  private var cancellables: Set<AnyCancellable> = []
  private var cachedActiveActivities: [any NotchActivity] = []
  private var cachedOrder: [String]?
  private var cachedDisabled: Set<String>?
  private var cacheInvalidated = true

  init() {
    // Republish when the user reorders or disables activities so the notch updates live.
    Defaults.publisher(.disabledActivities)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in
        self?.cacheInvalidated = true
        self?.objectWillChange.send()
      }
      .store(in: &cancellables)
    Defaults.publisher(.activityOrder)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in
        self?.cacheInvalidated = true
        self?.objectWillChange.send()
      }
      .store(in: &cancellables)
    Defaults.publisher(.systemAlwaysVisible)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in
        self?.cacheInvalidated = true
        self?.objectWillChange.send()
      }
      .store(in: &cancellables)
  }

  func register<T: NotchActivity & ObservableObject>(_ activity: T) {
    guard !activities.contains(where: { $0.id == activity.id }) else { return }
    activities.append(activity)
    cacheInvalidated = true
    activity.objectWillChange
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in
        self?.cacheInvalidated = true
        self?.objectWillChange.send()
      }
      .store(in: &cancellables)
    objectWillChange.send()
  }

  /// All active activities, ordered by the user's configured order (unlisted ones fall back to
  /// priority, then most-recently-activated).
  var activeActivities: [any NotchActivity] {
    let order = Defaults[.activityOrder]
    let disabled = Set(Defaults[.disabledActivities])
    if !cacheInvalidated, cachedOrder == order, cachedDisabled == disabled {
      return cachedActiveActivities
    }
    func rank(_ a: any NotchActivity) -> Int { order.firstIndex(of: a.id) ?? Int.max }
    cachedActiveActivities =
      activities
      .filter(\.isActive)
      .filter { ActivityEnablement.isEnabled($0.id, disabledActivities: disabled) }
      .sorted {
        let ra = rank($0)
        let rb = rank($1)
        if ra != rb { return ra < rb }
        if $0.priority != $1.priority { return $0.priority > $1.priority }
        return ($0.activationDate ?? .distantPast) > ($1.activationDate ?? .distantPast)
      }
    cachedOrder = order
    cachedDisabled = disabled
    cacheInvalidated = false
    return cachedActiveActivities
  }

  /// Activities shown as expanded tabs. Utility surfaces such as the File Shelf stay reachable
  /// without claiming the compact notch when they have no live content.
  var expandedActivities: [any NotchActivity] {
    expandedActivities(temporarilyIncluding: nil)
  }

  /// A notification click may reveal one active disabled activity without changing the user's
  /// persisted switch. The caller owns the lifetime of this temporary presentation.
  func expandedActivities(temporarilyIncluding temporaryActivityID: String?)
    -> [any NotchActivity]
  {
    let order = Defaults[.activityOrder]
    let disabled = Set(Defaults[.disabledActivities])
    return sorted(
      activities.filter {
        ($0.isActive || $0.isAvailableWhenInactive)
          && (ActivityEnablement.isEnabled($0.id, disabledActivities: disabled)
            || ($0.isActive && $0.id == temporaryActivityID))
      },
      order: order)
  }

  var primaryActivity: (any NotchActivity)? { activeActivities.first }

  func isAvailableInExpandedSwitcher(_ id: String) -> Bool {
    expandedActivities.contains { $0.id == id }
  }

  private func sorted(
    _ candidates: [any NotchActivity], order: [String]
  ) -> [any NotchActivity] {
    candidates.sorted {
      let firstRank = order.firstIndex(of: $0.id) ?? Int.max
      let secondRank = order.firstIndex(of: $1.id) ?? Int.max
      if firstRank != secondRank { return firstRank < secondRank }
      if $0.priority != $1.priority { return $0.priority > $1.priority }
      return ($0.activationDate ?? .distantPast) > ($1.activationDate ?? .distantPast)
    }
  }
}
