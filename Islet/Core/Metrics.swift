import SwiftUI

enum Metrics {
  static let expandedSize = CGSize(width: 640, height: 190)
  static let shadowPadding: CGFloat = 20
  static let earMargin: CGFloat = 64
  static let closedOversize: CGFloat = 2  // draw wider/taller than hardware
  static let hitSlop: CGFloat = 4  // hit target extends this far beyond notch
  static let peekGrowth: CGFloat = 4
  static let fallbackNotchWidth: CGFloat = 200

  static let closedRadii = (top: CGFloat(6), bottom: CGFloat(14))
  static let expandedRadii = (top: CGFloat(19), bottom: CGFloat(24))

  static let opening: Animation = .bouncy(duration: 0.4)
  static let closing: Animation = .smooth(duration: 0.4)
  static let compact: Animation = .snappy(duration: 0.4)
}
