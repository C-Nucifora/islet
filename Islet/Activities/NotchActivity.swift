import SwiftUI

enum ActivityPriority: Int, Comparable {
  case ambient = 0
  case media = 1
  case timer = 2  // a running countdown is time-sensitive — it takes the primary slot
  case agent = 3  // an agent working or waiting for the user should stay visible

  static func < (l: Self, r: Self) -> Bool { l.rawValue < r.rawValue }
}

@MainActor
protocol NotchActivity: AnyObject {
  var id: String { get }
  var priority: ActivityPriority { get }
  var isActive: Bool { get }
  var activationDate: Date? { get }
  var compactLeading: AnyView { get }
  var compactTrailing: AnyView { get }
  var expandedView: AnyView { get }
  /// SF Symbol used for this activity's chip in the expanded switcher.
  var tabIcon: String { get }
  /// Height tier this activity's expanded view wants. Defaults to the base tier; dense tabs
  /// (power, system stats) return `Metrics.tallExpandedHeight`.
  var preferredExpandedHeight: CGFloat { get }
}

extension NotchActivity {
  var tabIcon: String { "app.dashed" }
  var preferredExpandedHeight: CGFloat { Metrics.expandedSize.height }
}
