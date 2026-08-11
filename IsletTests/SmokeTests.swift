import SwiftUI
import XCTest

@testable import Islet

final class SmokeTests: XCTestCase {
  func testTruth() { XCTAssertTrue(true) }

  func testMenuBarIconUsesAThinHorizonAndCenteredNotch() {
    let path = IsletMenuBarIconShape().path(in: CGRect(x: 0, y: 0, width: 18, height: 16))

    XCTAssertEqual(path.boundingRect, CGRect(x: 1.5, y: 2.5, width: 15, height: 6))
    XCTAssertTrue(path.contains(CGPoint(x: 2, y: 3), eoFill: true))
    XCTAssertFalse(path.contains(CGPoint(x: 2, y: 5), eoFill: true))
    XCTAssertTrue(path.contains(CGPoint(x: 9, y: 8), eoFill: true))
    XCTAssertFalse(path.contains(CGPoint(x: 9, y: 9), eoFill: true))
  }

  func testMenuBarIconNotchIsHorizontallySymmetric() {
    let path = IsletMenuBarIconShape().path(in: CGRect(x: 0, y: 0, width: 18, height: 16))

    for point in [CGPoint(x: 6.75, y: 6), CGPoint(x: 7.5, y: 7.5), CGPoint(x: 8.5, y: 8)] {
      XCTAssertEqual(
        path.contains(point, eoFill: true),
        path.contains(CGPoint(x: 18 - point.x, y: point.y), eoFill: true))
    }
  }
}
