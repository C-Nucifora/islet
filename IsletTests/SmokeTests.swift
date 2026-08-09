import SwiftUI
import XCTest

@testable import Islet

final class SmokeTests: XCTestCase {
  func testTruth() { XCTAssertTrue(true) }

  func testMenuBarIconKeepsItsNotchCutoutAndRoundedBody() {
    let path = IsletMenuBarIconShape().path(in: CGRect(x: 0, y: 0, width: 18, height: 16))

    XCTAssertEqual(path.boundingRect, CGRect(x: 1, y: 2, width: 16, height: 12))
    XCTAssertTrue(path.contains(CGPoint(x: 3, y: 8), eoFill: true))
    XCTAssertTrue(path.contains(CGPoint(x: 9, y: 12), eoFill: true))
    XCTAssertFalse(path.contains(CGPoint(x: 9, y: 3), eoFill: true))
    XCTAssertFalse(path.contains(CGPoint(x: 0, y: 8), eoFill: true))
  }
}
