import XCTest

@testable import Islet

final class ShelfLogicTests: XCTestCase {
  func testShelfHasBoundedCapacity() {
    XCTAssertEqual(ShelfModel.maximumItemCount, 100)
    XCTAssertTrue(ShelfLogic.hasCapacity(currentCount: 99, pendingCount: 0, maximum: 100))
    XCTAssertFalse(ShelfLogic.hasCapacity(currentCount: 99, pendingCount: 1, maximum: 100))
    XCTAssertFalse(ShelfLogic.hasCapacity(currentCount: 100, pendingCount: 0, maximum: 100))
  }

  func testInvalidCapacityInputsFailClosed() {
    XCTAssertFalse(ShelfLogic.hasCapacity(currentCount: -1, pendingCount: 0, maximum: 100))
    XCTAssertFalse(ShelfLogic.hasCapacity(currentCount: 0, pendingCount: -1, maximum: 100))
    XCTAssertFalse(ShelfLogic.hasCapacity(currentCount: 0, pendingCount: 0, maximum: 0))
  }
}
