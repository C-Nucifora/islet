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

  func testFallbackWhenNoNotch() {
    let ext = NotchGeometry(
      screenFrame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
      safeAreaTop: 0, auxLeftWidth: 0, auxRightWidth: 0, menuBarHeight: 24)
    XCTAssertFalse(ext.hasHardwareNotch)
    XCTAssertEqual(ext.notchSize, CGSize(width: Metrics.fallbackNotchWidth, height: 24))
  }
}
