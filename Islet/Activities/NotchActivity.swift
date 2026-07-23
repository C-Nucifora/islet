import SwiftUI

enum ActivityPriority: Int, Comparable {
  case ambient = 0
  case media = 1

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
}

extension NotchActivity {
  var tabIcon: String { "app.dashed" }
}
