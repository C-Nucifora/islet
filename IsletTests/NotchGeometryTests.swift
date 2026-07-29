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
}
