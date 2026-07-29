import SwiftUI

enum Metrics {
  static let expandedSize = CGSize(width: 640, height: 190)
  static let shadowPadding: CGFloat = 20
  static let earMargin: CGFloat = 64
  static let closedOversize: CGFloat = 2  // draw wider/taller than hardware
  static let hitSlop: CGFloat = 4  // hit target extends this far beyond notch
  static let peekGrowth: CGFloat = 4
  static let fallbackNotchWidth: CGFloat = 200
  /// Breathing room between the drawn island and the panel edge that clips it, so fractional
  /// compact widths can't shave the outward corner flare.
  static let islandMargin: CGFloat = 4
  /// Extra height the collapsed panel carries below the notch: peek growth plus the drop target.
  static let collapsedDepth: CGFloat = 12

  static let closedRadii = (top: CGFloat(6), bottom: CGFloat(14))
  static let expandedRadii = (top: CGFloat(19), bottom: CGFloat(24))

  static let closingDuration: TimeInterval = 0.4
  static let opening: Animation = .bouncy(duration: 0.4)
  static let closing: Animation = .smooth(duration: closingDuration)
  static let compact: Animation = .snappy(duration: 0.4)
  /// The panel has to stay oversized until the closing animation has finished drawing — but not a
  /// frame longer, since every extra millisecond is menu bar nobody can click.
  static let panelShrinkDelay: Duration = .milliseconds(Int(closingDuration * 1000) + 32)
}
