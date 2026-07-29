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

  // MARK: - Island alignment

  /// Width of the drawn island body — the black shape, EXCLUDING the outward corner flare — for a
  /// pair of measured compact slot widths. One definition, shared by the view that draws it and by
  /// `collapsedIslandRect` below that says where it lands.
  func islandBodyWidth(compactLeading: CGFloat, compactTrailing: CGFloat) -> CGFloat {
    notchSize.width + Metrics.closedOversize * 2 + compactLeading + compactTrailing
  }

  /// Horizontal offset that lines the island's notch cut-out up with the hardware notch.
  ///
  /// `panel` must be the frame the window ACTUALLY occupies, not the frame the app asked for. The
  /// island is drawn centred in the real window, so any divergence between requested and real maps
  /// 1:1 onto a horizontal shift of the drawn island — the drift this function exists to make
  /// testable. Positioning off the notch's offset within the panel rather than the panel's centre
  /// also keeps the island aligned while the panel is still held at expanded size mid-collapse.
  func islandOffset(inPanel panel: CGRect, compactLeading: CGFloat, compactTrailing: CGFloat)
    -> CGFloat
  {
    notchRect.midX - panel.midX + (compactTrailing - compactLeading) / 2
  }

  /// Where the collapsed island body lands on screen, given the panel it is drawn in. Height is the
  /// `.closed` body; `.peek` grows by 4pt instead of 2pt but never moves in x, so every alignment
  /// assertion here holds for both.
  func collapsedIslandRect(inPanel panel: CGRect, compactLeading: CGFloat, compactTrailing: CGFloat)
    -> CGRect
  {
    let width = islandBodyWidth(compactLeading: compactLeading, compactTrailing: compactTrailing)
    let height = notchSize.height + Metrics.closedOversize
    let centreX =
      panel.midX
      + islandOffset(
        inPanel: panel, compactLeading: compactLeading, compactTrailing: compactTrailing)
    return CGRect(
      x: centreX - width / 2, y: panel.maxY - height, width: width, height: height)
  }
}
