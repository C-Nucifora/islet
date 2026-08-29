import XCTest

@testable import Islet

final class PushDistanceScaleTests: XCTestCase {
  func testDefaultDistanceIsFourHundredPoints() {
    XCTAssertEqual(Metrics.barrierPushDistance, 400)
  }

  func testScalePreservesEndpoints() {
    XCTAssertEqual(PushDistanceScale.distance(for: 0), 20, accuracy: 0.001)
    XCTAssertEqual(PushDistanceScale.distance(for: 1), 1_000, accuracy: 0.001)
  }

  func testScaleProvidesMoreResolutionAtShortDistances() {
    let firstQuarter = PushDistanceScale.distance(for: 0.25) - PushDistanceScale.distance(for: 0)
    let lastQuarter = PushDistanceScale.distance(for: 1) - PushDistanceScale.distance(for: 0.75)
    XCTAssertLessThan(firstQuarter, lastQuarter)
  }

  func testScaleRoundTripsPhysicalDistance() {
    for distance in [20.0, 64, 196, 400, 1_000] {
      let position = PushDistanceScale.sliderPosition(for: distance)
      XCTAssertEqual(PushDistanceScale.distance(for: position), distance, accuracy: 0.001)
    }
  }

  func testScaleClampsOutOfRangeValues() {
    XCTAssertEqual(PushDistanceScale.distance(for: -1), 20, accuracy: 0.001)
    XCTAssertEqual(PushDistanceScale.distance(for: 2), 1_000, accuracy: 0.001)
    XCTAssertEqual(PushDistanceScale.sliderPosition(for: 20), 0, accuracy: 0.001)
    XCTAssertEqual(PushDistanceScale.sliderPosition(for: 9_000), 1, accuracy: 0.001)
  }
}
