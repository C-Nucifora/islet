import Foundation
import XCTest

@testable import Islet

final class AppRelauncherTests: XCTestCase {
  func testHelperWaitsForParentPIDBeforeOpeningBundle() {
    let bundleURL = URL(fileURLWithPath: "/Applications/Islet Test.app")
    let arguments = AppRelauncher.helperArguments(parentPID: 4_321, bundleURL: bundleURL)

    XCTAssertEqual(arguments[0], "-c")
    XCTAssertEqual(
      arguments[1],
      "while kill -0 \"$1\" 2>/dev/null; do sleep 0.1; done; exec /usr/bin/open -n \"$2\"")
    XCTAssertEqual(arguments[2], "islet-relaunch")
    XCTAssertEqual(arguments[3], "4321")
    XCTAssertEqual(arguments[4], bundleURL.path)
  }
}
