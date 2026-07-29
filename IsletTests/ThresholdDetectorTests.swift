import XCTest

@testable import Islet

final class ThresholdDetectorTests: XCTestCase {
  let lowBattery = ThresholdDetector(thresholds: [20, 10], direction: .falling)
  let hotCPU = ThresholdDetector(thresholds: [80, 90], direction: .rising)

  func testFallingCrossingFiresOnce() {
    XCTAssertEqual(lowBattery.crossings(from: 21, to: 20), [20])
  }

  func testFallingDoesNotRefireBelowTheThreshold() {
    XCTAssertEqual(lowBattery.crossings(from: 20, to: 19), [])
    XCTAssertEqual(lowBattery.crossings(from: 15, to: 12), [])
  }

  func testFallingReportsEveryThresholdSkippedInOneStep() {
    // Declaration order, not numeric order: callers render them in the order they listed them.
    XCTAssertEqual(lowBattery.crossings(from: 21, to: 9), [20, 10])
  }

  func testNilBaselineIsNotACrossing() {
    // The first sample establishes a baseline; announcing it would fire an event at every launch.
    XCTAssertEqual(lowBattery.crossings(from: nil, to: 5), [])
    XCTAssertEqual(hotCPU.crossings(from: nil, to: 99), [])
  }

  func testEqualValuesDoNotCross() {
    XCTAssertEqual(lowBattery.crossings(from: 20, to: 20), [])
    XCTAssertEqual(lowBattery.crossings(from: 50, to: 50), [])
    XCTAssertEqual(hotCPU.crossings(from: 80, to: 80), [])
  }

  func testRisingCrossingFiresOnce() {
    XCTAssertEqual(hotCPU.crossings(from: 79, to: 85), [80])
  }

  func testRisingFiresOnLandingExactlyOnTheThreshold() {
    XCTAssertEqual(hotCPU.crossings(from: 79, to: 80), [80])
  }

  func testRisingDoesNotRefireAboveTheThreshold() {
    XCTAssertEqual(hotCPU.crossings(from: 80, to: 85), [])
    XCTAssertEqual(hotCPU.crossings(from: 85, to: 89), [])
  }

  func testRisingReportsEveryThresholdSkippedInOneStep() {
    XCTAssertEqual(hotCPU.crossings(from: 79, to: 95), [80, 90])
  }

  func testDetectorsCompareByThresholdsAndDirection() {
    XCTAssertEqual(lowBattery, ThresholdDetector(thresholds: [20, 10], direction: .falling))
    XCTAssertNotEqual(lowBattery, ThresholdDetector(thresholds: [20, 10], direction: .rising))
    XCTAssertNotEqual(lowBattery, ThresholdDetector(thresholds: [10, 20], direction: .falling))
  }
}
