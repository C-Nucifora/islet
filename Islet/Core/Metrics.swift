import SwiftUI

enum Metrics {
  /// The base height tier. Width is fixed for every tier; only the height varies per tab.
  static let expandedSize = CGSize(width: 480, height: 190)
  /// The tall tier, for information-dense tabs (power, system stats).
  static let tallExpandedHeight: CGFloat = 250
  static let shadowPadding: CGFloat = 20
  static let earMargin: CGFloat = 64
  static let closedOversize: CGFloat = 2  // draw wider/taller than hardware
  static let hitSlop: CGFloat = 4  // hit target extends this far beyond notch
  static let peekGrowth: CGFloat = 4
  /// Upward cursor travel needed to push through the hover barrier.
  static let barrierPushDistance: CGFloat = 12
  /// Extra downward stretch at maximum pressure, before the island snaps open.
  static let barrierStretch: CGFloat = 8
  /// Point in the push where the trackpad acknowledges contact with the barrier.
  static let barrierContactProgress: CGFloat = 0.35
  static let fallbackNotchWidth: CGFloat = 200
  /// Breathing room between the drawn island and the panel edge that clips it, so fractional
  /// compact widths can't shave the outward corner flare.
  static let islandMargin: CGFloat = 4
  /// Extra height the collapsed panel carries below the notch: peek growth plus the drop target.
  static let collapsedDepth: CGFloat = 12

  static let closedRadii = (top: CGFloat(6), bottom: CGFloat(14))
  static let expandedRadii = (top: CGFloat(19), bottom: CGFloat(24))
}
