import Foundation

/// Pure geometry derived from raw screen numbers. AppKit coordinates (origin bottom-left).
struct NotchGeometry: Equatable {
  let screenFrame: CGRect
  let notchSize: CGSize
  let hasHardwareNotch: Bool
  let menuBarHeight: CGFloat

  init(
    screenFrame: CGRect, safeAreaTop: CGFloat, auxLeftWidth: CGFloat,
    auxRightWidth: CGFloat, menuBarHeight: CGFloat
  ) {
    self.screenFrame = screenFrame
    self.menuBarHeight = menuBarHeight
    if safeAreaTop > 0, auxLeftWidth > 0, auxRightWidth > 0 {
      hasHardwareNotch = true
      notchSize = CGSize(
        width: screenFrame.width - auxLeftWidth - auxRightWidth,
        height: safeAreaTop)
    } else {
      hasHardwareNotch = false
      notchSize = CGSize(width: Metrics.fallbackNotchWidth, height: max(menuBarHeight, 24))
    }
  }

  var notchRect: CGRect {
    CGRect(
      x: screenFrame.midX - notchSize.width / 2,
      y: screenFrame.maxY - notchSize.height,
      width: notchSize.width, height: notchSize.height)
  }

  /// Bigger than it looks: extends sideways and downward, never above screen top.
  var hitRect: CGRect {
    CGRect(
      x: notchRect.minX - Metrics.hitSlop,
      y: notchRect.minY - Metrics.hitSlop,
      width: notchRect.width + Metrics.hitSlop * 2,
      height: notchRect.height + Metrics.hitSlop)
  }

  var expandedRect: CGRect {
    CGRect(
      x: screenFrame.midX - Metrics.expandedSize.width / 2,
      y: screenFrame.maxY - Metrics.expandedSize.height,
      width: Metrics.expandedSize.width, height: Metrics.expandedSize.height)
  }

  var panelFrame: CGRect {
    let w = Metrics.expandedSize.width + Metrics.earMargin * 2
    let h = Metrics.expandedSize.height + Metrics.shadowPadding
    return CGRect(x: screenFrame.midX - w / 2, y: screenFrame.maxY - h, width: w, height: h)
  }
}
