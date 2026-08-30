import XCTest

@testable import Islet

final class LaunchAtLoginTests: XCTestCase {
  func testSyncPreservesAnEnabledOrPendingRegistration() {
    XCTAssertEqual(
      LaunchAtLoginPolicy.action(desiredEnabled: true, status: .enabled),
      .none)
    XCTAssertEqual(
      LaunchAtLoginPolicy.action(desiredEnabled: true, status: .requiresApproval),
      .none)
  }

  func testSyncRegistersOnlyWhenTheDesiredItemIsMissing() {
    XCTAssertEqual(
      LaunchAtLoginPolicy.action(desiredEnabled: true, status: .notRegistered),
      .register)
    XCTAssertEqual(
      LaunchAtLoginPolicy.action(desiredEnabled: true, status: .notFound),
      .register)
  }

  func testDisablingRemovesEnabledAndPendingRegistrations() {
    XCTAssertEqual(
      LaunchAtLoginPolicy.action(desiredEnabled: false, status: .enabled),
      .unregister)
    XCTAssertEqual(
      LaunchAtLoginPolicy.action(desiredEnabled: false, status: .requiresApproval),
      .unregister)
    XCTAssertEqual(
      LaunchAtLoginPolicy.action(desiredEnabled: false, status: .notRegistered),
      .none)
  }
}
