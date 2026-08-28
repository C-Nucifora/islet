import XCTest

@testable import Islet

final class ActivityTabLayoutTests: XCTestCase {
  private func ids(_ count: Int) -> [String] {
    ["home"] + (1..<count).map { "activity-\($0)" }
  }

  func testFiveTabsStayVisibleWhenFiveControlsFit() {
    let result = ActivityTabLayout.split(
      tabIDs: ids(5), selectedID: "home", controlCapacity: 5)
    XCTAssertEqual(result.visibleIDs, ids(5))
    XCTAssertTrue(result.overflowIDs.isEmpty)
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

  func testPreferredWidthFitsAllSixTabsBesideHardwareNotch() {
    let containerWidth = ActivityTabLayout.preferredContainerWidth(
      tabCount: 6, notchWidth: 296, minimumWidth: Metrics.expandedSize.width,
      maximumWidth: 1_000)
    let stripWidth = ActivityTabLayout.leftStripWidth(
      containerWidth: containerWidth, horizontalPadding: 12, notchWidth: 296, spacing: 4,
      minimum: 20)
    let capacity = ActivityTabLayout.controlCapacity(
      width: stripWidth, controlWidth: 20, spacing: 4)
    let result = ActivityTabLayout.split(
      tabIDs: ids(6), selectedID: "home", controlCapacity: capacity)

    XCTAssertEqual(containerWidth, 608)
    XCTAssertEqual(stripWidth, 140)
    XCTAssertEqual(capacity, 6)
    XCTAssertEqual(result.visibleIDs, ids(6))
    XCTAssertTrue(result.overflowIDs.isEmpty)
  }

  func testPreferredWidthShrinksToTheMinimumWithFewTabs() {
    XCTAssertEqual(
      ActivityTabLayout.preferredContainerWidth(
        tabCount: 3, notchWidth: 209, minimumWidth: 520, maximumWidth: 1_000),
      520)
  }

  func testPreferredWidthGrowsToFitEveryCataloguedTab() {
    XCTAssertEqual(
      ActivityTabLayout.preferredContainerWidth(
        tabCount: 12, notchWidth: 209, minimumWidth: 520, maximumWidth: 1_000),
      809)
  }

  func testScreenLimitFallsBackToOverflow() {
    let containerWidth = ActivityTabLayout.preferredContainerWidth(
      tabCount: 12, notchWidth: 209, minimumWidth: 520, maximumWidth: 600)
    let stripWidth = ActivityTabLayout.leftStripWidth(
      containerWidth: containerWidth, horizontalPadding: 12, notchWidth: 209, spacing: 4,
      minimum: 20)
    let capacity = ActivityTabLayout.controlCapacity(
      width: stripWidth, controlWidth: 20, spacing: 4)
    let result = ActivityTabLayout.split(
      tabIDs: ids(12), selectedID: "home", controlCapacity: capacity)

    XCTAssertEqual(containerWidth, 600)
    XCTAssertEqual(capacity, 7)
    XCTAssertEqual(result.visibleIDs.count, 6)
    XCTAssertEqual(result.overflowIDs.count, 6)
  }
}
