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

  /// Panel frame while collapsed. A window swallows every mouse event inside its frame, so the
  /// expanded frame left the whole top-centre of the screen — several menu bar items included —
  /// dead to clicks. Collapsed, the panel hugs the drawn island instead.
  ///
  /// Each flank is sized from its own compact slot rather than the wider of the two: the slots are
  /// rarely the same width (a HUD is an icon against a 70pt bar), and mirroring the wider one just
  /// moves the invisible dead-click strip to the narrow side.
  func collapsedPanelFrame(compactLeading: CGFloat = 0, compactTrailing: CGFloat = 0) -> CGRect {
    // Beyond the body the shape's top corners flare outward by their radius.
    let edge = Metrics.closedOversize + Metrics.closedRadii.top + Metrics.islandMargin
    let left = notchSize.width / 2 + compactLeading + edge
    let right = notchSize.width / 2 + compactTrailing + edge
    let h = notchSize.height + Metrics.collapsedDepth
    return CGRect(
      x: notchRect.midX - left, y: screenFrame.maxY - h, width: left + right, height: h)
  }
}
