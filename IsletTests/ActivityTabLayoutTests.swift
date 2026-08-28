import XCTest

@testable import Islet

final class ActivityTabLayoutTests: XCTestCase {
  private func ids(_ count: Int) -> [String] {
    ["home"] + (1..<count).map { "activity-\($0)" }
  }

  func testFiveActivitiesUseFourPriorityControlsAndMore() {
    let result = ActivityTabLayout.split(
      tabIDs: ids(5), selectedID: "home", controlCapacity: 5)
    XCTAssertEqual(result.visibleIDs, ["home", "activity-1", "activity-2", "activity-3"])
    XCTAssertEqual(result.overflowIDs, ["activity-4"])
  }

  func testSixNineAndTwelveActivitiesStayBounded() {
    for count in [6, 9, 12] {
      let result = ActivityTabLayout.split(
        tabIDs: ids(count), selectedID: "home", controlCapacity: 5)
      XCTAssertEqual(result.visibleIDs.count, 4)
      XCTAssertEqual(result.overflowIDs.count, count - 4)
      XCTAssertEqual(Set(result.visibleIDs + result.overflowIDs), Set(ids(count)))
    }
  }

  func testOverflowSelectionIsPromotedWithoutLosingHome() {
    let result = ActivityTabLayout.split(
      tabIDs: ids(9), selectedID: "activity-8", controlCapacity: 5)
    XCTAssertEqual(result.visibleIDs.first, "home")
    XCTAssertEqual(result.visibleIDs.last, "activity-8")
    XCTAssertFalse(result.overflowIDs.contains("activity-8"))
  }

  func testNarrowEarDropsOnePriorityTabToKeepMoreVisible() {
    let result = ActivityTabLayout.split(
      tabIDs: ids(9), selectedID: "home", controlCapacity: 4)
    XCTAssertEqual(result.visibleIDs.count, 3)
    XCTAssertEqual(result.overflowIDs.count, 6)
  }

  func testReferenceGeometryEndsBeforeCenteredNotch() {
    let width = ActivityTabLayout.leftStripWidth(
      containerWidth: 480, horizontalPadding: 12, notchWidth: 200, spacing: 4, minimum: 20)
    XCTAssertEqual(width, 124)
    XCTAssertEqual(
      ActivityTabLayout.controlCapacity(width: width, controlWidth: 20, spacing: 4), 5)
  }

  func testExpandedIslandFitsFourTabsBesideHardwareNotch() {
    let width = ActivityTabLayout.leftStripWidth(
      containerWidth: Metrics.expandedSize.width, horizontalPadding: 12, notchWidth: 296,
      spacing: 4, minimum: 20)
    let capacity = ActivityTabLayout.controlCapacity(width: width, controlWidth: 20, spacing: 4)
    let result = ActivityTabLayout.split(
      tabIDs: ids(4), selectedID: "home", controlCapacity: capacity)

    XCTAssertEqual(width, 96)
    XCTAssertEqual(capacity, 4)
    XCTAssertEqual(result.visibleIDs, ids(4))
    XCTAssertTrue(result.overflowIDs.isEmpty)
  }
}
