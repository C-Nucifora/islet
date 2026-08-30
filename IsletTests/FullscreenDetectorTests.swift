import XCTest

@testable import Islet

final class FullscreenDetectorTests: XCTestCase {
  func testNativeFullscreenTransitionUsesCurrentSpaceType() throws {
    let entered = try XCTUnwrap(
      FullscreenDetector.managedSpaceState(
        from: [managedDisplay(uuid: "built-in", spaceType: 4)]))
    XCTAssertEqual(entered.fullscreenDisplayUUIDs, ["built-in"])

    let exited = try XCTUnwrap(
      FullscreenDetector.managedSpaceState(
        from: [managedDisplay(uuid: "built-in", spaceType: 0)]))
    XCTAssertEqual(exited.fullscreenDisplayUUIDs, [])
  }

  func testFullscreenStateIsTrackedPerDisplay() throws {
    let state = try XCTUnwrap(
      FullscreenDetector.managedSpaceState(
        from: [
          managedDisplay(uuid: "built-in", spaceType: 0),
          managedDisplay(uuid: "external", spaceType: 4),
        ]))

    XCTAssertEqual(state.displayUUIDs, ["built-in", "external"])
    XCTAssertEqual(state.fullscreenDisplayUUIDs, ["external"])
  }

  func testNormalSpaceBeatsStaleFullscreenWindowList() throws {
    let managedSpaces = try XCTUnwrap(
      FullscreenDetector.managedSpaceState(
        from: [managedDisplay(uuid: "built-in", spaceType: 0)]))
    var usedFallback = false

    XCTAssertEqual(
      FullscreenDetector.resolvedDisplayUUIDs(
        managedSpaces: managedSpaces, requestedDisplayUUIDs: ["built-in"],
        windowListFallback: {
          usedFallback = true
          return ["built-in"]
        }),
      [])
    XCTAssertFalse(usedFallback)
  }

  func testBorderlessCoveringWindowDoesNotCountOnNormalSpace() throws {
    let display = CGRect(x: 0, y: 0, width: 1728, height: 1117)
    XCTAssertTrue(FullscreenDetector.covers(window: display, display: display))

    let managedSpaces = try XCTUnwrap(
      FullscreenDetector.managedSpaceState(
        from: [managedDisplay(uuid: "built-in", spaceType: 0)]))
    XCTAssertEqual(
      FullscreenDetector.resolvedDisplayUUIDs(
        managedSpaces: managedSpaces, requestedDisplayUUIDs: ["built-in"],
        windowListFallback: { ["built-in"] }),
      [])
  }

  func testMalformedOrIncompleteManagedSnapshotUsesWindowListFallback() {
    XCTAssertNil(
      FullscreenDetector.managedSpaceState(
        from: [["Display Identifier": "built-in"]]))

    let incomplete = FullscreenDetector.ManagedSpaceState(
      displayUUIDs: ["external"], fullscreenDisplayUUIDs: ["external"])
    XCTAssertEqual(
      FullscreenDetector.resolvedDisplayUUIDs(
        managedSpaces: incomplete, requestedDisplayUUIDs: ["built-in"],
        windowListFallback: { ["built-in"] }),
      ["built-in"])
  }

  func testRapidSpaceSwitchInvalidatesEarlierTransitionFollowUps() {
    var revision = FullscreenTransitionRevision()
    let first = revision.begin()
    let second = revision.begin()

    XCTAssertFalse(revision.accepts(first))
    XCTAssertTrue(revision.accepts(second))
    XCTAssertEqual(FullscreenTransitionRevision.followUpDelays, [0.2, 0.8])
  }

  func testWindowMustCoverTheTargetDisplaysPositionNotOnlyItsSize() {
    let left = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let right = CGRect(x: 1920, y: 0, width: 1920, height: 1080)

    XCTAssertTrue(FullscreenDetector.covers(window: left, display: left))
    XCTAssertFalse(FullscreenDetector.covers(window: left, display: right))
  }

  func testCoverageHandlesDisplaysAboveAndBelowThePrimary() {
    let above = CGRect(x: 300, y: -900, width: 1440, height: 900)
    let below = CGRect(x: -200, y: 1080, width: 1440, height: 900)

    XCTAssertTrue(FullscreenDetector.covers(window: above, display: above))
    XCTAssertTrue(FullscreenDetector.covers(window: below, display: below))
    XCTAssertFalse(FullscreenDetector.covers(window: above, display: below))
  }

  func testOnePixelWindowServerRoundingIsAcceptedButRealGapsAreNot() {
    let display = CGRect(x: 1920, y: 0, width: 2560, height: 1440)
    XCTAssertTrue(
      FullscreenDetector.covers(
        window: display.insetBy(dx: 1, dy: 1), display: display, tolerance: 1))
    XCTAssertFalse(
      FullscreenDetector.covers(
        window: display.insetBy(dx: 2, dy: 2), display: display, tolerance: 1))
  }

  private func managedDisplay(uuid: String, spaceType: Int) -> [String: Any] {
    [
      "Display Identifier": uuid,
      "Current Space": ["type": NSNumber(value: spaceType)],
    ]
  }
}
