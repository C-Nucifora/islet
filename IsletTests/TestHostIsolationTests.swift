import Defaults
import Foundation
import XCTest

@testable import Islet

final class TestHostIsolationTests: XCTestCase {
  func testHostUsesItsOwnApplicationIdentity() {
    XCTAssertEqual(Bundle.main.bundleIdentifier, "dev.islet.tests")
  }

  func testStandardAndDefaultsWritesStayOutsideProductionPreferences() throws {
    let defaults = UserDefaults.standard
    let productionBefore = defaults.persistentDomain(forName: "dev.islet") ?? [:]
    let probe = "testIsolationProbe-\(UUID().uuidString)"
    let previousActivities = Defaults[.disabledActivities]
    defer {
      defaults.removeObject(forKey: probe)
      Defaults[.disabledActivities] = previousActivities
    }

    defaults.set("test-only", forKey: probe)
    Defaults[.disabledActivities] = [probe]

    let testDomain = defaults.persistentDomain(forName: "dev.islet.tests") ?? [:]
    XCTAssertEqual(testDomain[probe] as? String, "test-only")
    XCTAssertEqual(testDomain["disabledActivities"] as? [String], [probe])
    let productionAfter = defaults.persistentDomain(forName: "dev.islet") ?? [:]
    XCTAssertTrue(
      NSDictionary(dictionary: productionBefore).isEqual(to: productionAfter),
      "Test writes must not modify production preferences")
  }
}
