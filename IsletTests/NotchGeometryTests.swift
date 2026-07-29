import XCTest

@testable import Islet

final class NotchGeometryTests: XCTestCase {
  // 14" MBP-like frame in points; notch 32pt tall, aux areas 716pt each -> notch 296pt wide
  let mbp = NotchGeometry(
    screenFrame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
    safeAreaTop: 32, auxLeftWidth: 716, auxRightWidth: 716, menuBarHeight: 37)

  func testHardwareNotchDetected() {
    XCTAssertTrue(mbp.hasHardwareNotch)
    XCTAssertEqual(mbp.notchSize, CGSize(width: 1728 - 716 - 716, height: 32))
  }

  func testNotchRectTopCentered() {
    XCTAssertEqual(mbp.notchRect.midX, 864, accuracy: 0.5)
    XCTAssertEqual(mbp.notchRect.maxY, 1117)  // AppKit: top edge = screen maxY
    XCTAssertEqual(mbp.notchRect.height, 32)
  }

  func testHitRectExpandsDownAndSideways() {
    XCTAssertEqual(mbp.hitRect.width, mbp.notchRect.width + 8)
    XCTAssertEqual(mbp.hitRect.maxY, mbp.notchRect.maxY)  // top unchanged
    XCTAssertEqual(mbp.hitRect.minY, mbp.notchRect.minY - 4)  // extends downward
  }

  func testPanelFrameFixedAndTopCentered() {
    XCTAssertEqual(mbp.panelFrame.width, Metrics.expandedSize.width + Metrics.earMargin * 2)
    XCTAssertEqual(mbp.panelFrame.height, Metrics.expandedSize.height + Metrics.shadowPadding)
    XCTAssertEqual(mbp.panelFrame.maxY, 1117)
    XCTAssertEqual(mbp.panelFrame.midX, 864, accuracy: 0.5)
  }

  /// Distance from the notch edge to the panel edge: oversize + corner flare + margin.
  private var collapsedEdge: CGFloat {
    Metrics.closedOversize + Metrics.closedRadii.top + Metrics.islandMargin
  }

  func testCollapsedPanelFrameHugsTheIsland() {
    let bare = mbp.collapsedPanelFrame()
    // Far narrower than the expanded panel, so the rest of the menu bar keeps its clicks.
    XCTAssertLessThan(bare.width, mbp.panelFrame.width)
    XCTAssertLessThan(bare.height, mbp.panelFrame.height)
    XCTAssertEqual(bare.width, mbp.notchSize.width + collapsedEdge * 2)
    XCTAssertEqual(bare.midX, 864, accuracy: 0.5)  // no compact content -> symmetric
    XCTAssertEqual(bare.maxY, 1117)
  }

  func testCollapsedPanelFrameFollowsEachFlankIndependently() {
    let wide = mbp.collapsedPanelFrame(compactLeading: 20, compactTrailing: 90)
    XCTAssertGreaterThan(wide.width, mbp.collapsedPanelFrame().width)
    // Each side tracks its own slot. Mirroring the wider flank onto both would leave an invisible
    // dead-click strip on the narrow side — the bug this frame exists to remove.
    XCTAssertEqual(wide.minX, 864 - mbp.notchSize.width / 2 - 20 - collapsedEdge, accuracy: 0.01)
    XCTAssertEqual(wide.maxX, 864 + mbp.notchSize.width / 2 + 90 + collapsedEdge, accuracy: 0.01)
    XCTAssertNotEqual(wide, mbp.collapsedPanelFrame(compactLeading: 90, compactTrailing: 20))
  }

  func testCollapsedPanelFrameClearsTheCornerFlare() {
    let f = mbp.collapsedPanelFrame(compactLeading: 12.5, compactTrailing: 44.25)
    // The drawn shape ends at body + flare; the panel must leave margin beyond it on both sides
    // so pixel-aligning a fractional frame can't shave the outward curve.
    let flare = Metrics.closedOversize + Metrics.closedRadii.top
    XCTAssertEqual(f.maxX - (864 + mbp.notchSize.width / 2 + 44.25 + flare), Metrics.islandMargin)
    XCTAssertEqual((864 - mbp.notchSize.width / 2 - 12.5 - flare) - f.minX, Metrics.islandMargin)
  }

  func testFallbackWhenNoNotch() {
    let ext = NotchGeometry(
      screenFrame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
      safeAreaTop: 0, auxLeftWidth: 0, auxRightWidth: 0, menuBarHeight: 24)
    XCTAssertFalse(ext.hasHardwareNotch)
    XCTAssertEqual(ext.notchSize, CGSize(width: Metrics.fallbackNotchWidth, height: 24))
  }

  // MARK: - Island alignment
  //
  // The island is drawn centred in the panel window and nudged sideways by `islandOffset`. If that
  // nudge is computed against a frame the window does not actually have, the divergence lands 1:1
  // on the drawn island — it slides right and disappears under the hardware notch, and no hover
  // ever clears it. These pin the offset down as a function of the REAL panel frame.

  func testIslandScreenPositionIsInvariantUnderAnArbitraryPanelFrame() {
    let leading: CGFloat = 18
    let trailing: CGFloat = 76
    let sized = mbp.collapsedPanelFrame(compactLeading: leading, compactTrailing: trailing)
    // Where the island body must land, expressed only in hardware terms.
    let expectedMinX = mbp.notchRect.minX - Metrics.closedOversize - leading
    let expectedMaxX = mbp.notchRect.maxX + Metrics.closedOversize + trailing

    let panels: [CGRect] = [
      sized,  // the frame we asked for
      sized.offsetBy(dx: 37, dy: 0),  // AppKit nudged us right
      sized.offsetBy(dx: -12.5, dy: 0),  // ... or left, fractionally
      mbp.panelFrame,  // ... or we are still held at expanded size mid-collapse
    ]
    for panel in panels {
      let body = mbp.collapsedIslandRect(
        inPanel: panel, compactLeading: leading, compactTrailing: trailing)
      XCTAssertEqual(body.minX, expectedMinX, accuracy: 0.01, "panel \(panel)")
      XCTAssertEqual(body.maxX, expectedMaxX, accuracy: 0.01, "panel \(panel)")
      XCTAssertEqual(body.maxY, panel.maxY, accuracy: 0.01, "panel \(panel)")
    }
  }

  func testASizedPanelFullyContainsItsIslandOnBothFlanks() {
    let leading: CGFloat = 18
    let trailing: CGFloat = 76
    let panel = mbp.collapsedPanelFrame(compactLeading: leading, compactTrailing: trailing)
    let body = mbp.collapsedIslandRect(
      inPanel: panel, compactLeading: leading, compactTrailing: trailing)
    XCTAssertTrue(panel.contains(body), "panel \(panel) clips island \(body)")
    // Asymmetric slots must not eat the margin on the narrow side: both flanks keep the corner
    // flare plus the island margin, which is the whole point of sizing each flank independently.
    let slack = Metrics.closedRadii.top + Metrics.islandMargin
    XCTAssertEqual(body.minX - panel.minX, slack, accuracy: 0.01)
    XCTAssertEqual(panel.maxX - body.maxX, slack, accuracy: 0.01)
  }

  // MARK: - Notch origin
  //
  // Every fixture above sits at screen origin (0,0) with symmetric 716/716 aux areas, so nothing
  // catches an x term that forgot `screenFrame.minX` or one that assumed a centred notch.

  func testNotchRectFollowsAuxLeftWidthNotTheScreenCentre() {
    // Real hardware: the aux areas differ by a few points. Deriving the origin from the screen
    // centre puts the notch at 712 and drags the whole island 4pt right of the hardware.
    let offCentre = NotchGeometry(
      screenFrame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
      safeAreaTop: 32, auxLeftWidth: 716, auxRightWidth: 708, menuBarHeight: 37)
    XCTAssertEqual(offCentre.notchSize.width, 304)
    XCTAssertEqual(offCentre.notchRect.minX, 716, accuracy: 0.01)
    XCTAssertEqual(offCentre.notchRect.maxX, 1728 - 708, accuracy: 0.01)
    XCTAssertNotEqual(offCentre.notchRect.midX, offCentre.screenFrame.midX)
  }

  func testPanelsCentreOnTheNotchForAScreenAtANonZeroOrigin() {
    // A second display placed to the right of the built-in one. notch = 1512 - 610 - 610 = 292,
    // starting at 1728 + 610 = 2338, so its centre is 2484.
    let secondary = NotchGeometry(
      screenFrame: CGRect(x: 1728, y: 0, width: 1512, height: 982),
      safeAreaTop: 32, auxLeftWidth: 610, auxRightWidth: 610, menuBarHeight: 37)
    XCTAssertEqual(secondary.notchSize.width, 292)
    XCTAssertEqual(secondary.notchRect.minX, 2338, accuracy: 0.01)
    XCTAssertEqual(secondary.notchRect.midX, 2484, accuracy: 0.01)
    XCTAssertEqual(secondary.panelFrame.midX, 2484, accuracy: 0.01)
    XCTAssertEqual(secondary.expandedRect.midX, 2484, accuracy: 0.01)
    XCTAssertEqual(secondary.collapsedPanelFrame().midX, 2484, accuracy: 0.01)
    XCTAssertEqual(secondary.panelFrame.maxY, 982)
    let body = secondary.collapsedIslandRect(
      inPanel: secondary.collapsedPanelFrame(), compactLeading: 0, compactTrailing: 0)
    XCTAssertEqual(body.midX, 2484, accuracy: 0.01)
  }

  func testFallbackNotchStaysScreenCentred() {
    // No hardware notch: there is no aux area to anchor to, so the 200pt rectangle keeps centring
    // on the screen — including on a screen that does not start at x = 0.
    let ext = NotchGeometry(
      screenFrame: CGRect(x: 2560, y: 0, width: 2560, height: 1440),
      safeAreaTop: 0, auxLeftWidth: 0, auxRightWidth: 0, menuBarHeight: 24)
    XCTAssertFalse(ext.hasHardwareNotch)
    XCTAssertEqual(ext.notchRect.midX, ext.screenFrame.midX, accuracy: 0.01)
    XCTAssertEqual(ext.notchRect.minX, 3840 - Metrics.fallbackNotchWidth / 2, accuracy: 0.01)
  }

  // MARK: - Notch stickiness

  private var notchedReading: NotchStickiness.Reading {
    NotchStickiness.Reading(safeAreaTop: 32, auxLeftWidth: 716, auxRightWidth: 708)
  }
  private var emptyReading: NotchStickiness.Reading {
    NotchStickiness.Reading(safeAreaTop: 0, auxLeftWidth: 0, auxRightWidth: 0)
  }

  func testAKnownNotchedBuiltinDisplayKeepsItsNotchWhenAuxAreasReadEmpty() {
    var sticky = NotchStickiness()
    XCTAssertTrue(notchedReading.hasNotch)
    XCTAssertFalse(emptyReading.hasNotch)
    XCTAssertEqual(
      sticky.resolve(displayUUID: "builtin", isBuiltin: true, reading: notchedReading),
      notchedReading)
    // A transient empty read must not downgrade it to the 200pt fallback.
    XCTAssertEqual(
      sticky.resolve(displayUUID: "builtin", isBuiltin: true, reading: emptyReading),
      notchedReading)
    // ... and the geometry built from what we hand back still has a hardware notch.
    let remembered = sticky.resolve(
      displayUUID: "builtin", isBuiltin: true, reading: emptyReading)
    let geometry = NotchGeometry(
      screenFrame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
      safeAreaTop: remembered.safeAreaTop, auxLeftWidth: remembered.auxLeftWidth,
      auxRightWidth: remembered.auxRightWidth, menuBarHeight: 37)
    XCTAssertTrue(geometry.hasHardwareNotch)
    XCTAssertEqual(geometry.notchRect.minX, 716, accuracy: 0.01)
  }

  func testAnExternalDisplayIsNeverStickied() {
    var sticky = NotchStickiness()
    _ = sticky.resolve(displayUUID: "external", isBuiltin: false, reading: notchedReading)
    // An external display that stops reporting a notch really has stopped having one.
    XCTAssertEqual(
      sticky.resolve(displayUUID: "external", isBuiltin: false, reading: emptyReading),
      emptyReading)
  }

  func testStickinessIsKeyedPerDisplay() {
    var sticky = NotchStickiness()
    _ = sticky.resolve(displayUUID: "A", isBuiltin: true, reading: notchedReading)
    XCTAssertEqual(
      sticky.resolve(displayUUID: "B", isBuiltin: true, reading: emptyReading), emptyReading)
  }
}
