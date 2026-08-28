import XCTest

@testable import Islet

final class IORegistryReaderTests: XCTestCase {
  func testSignedIntPassesThroughNonNegativeValues() {
    XCTAssertEqual(IORegistryReader.signedInt(0), 0)
    XCTAssertEqual(IORegistryReader.signedInt(1500), 1500)
    XCTAssertEqual(IORegistryReader.signedInt(Int(Int32.max)), Int(Int32.max))
  }

  func testSignedIntDecodesTheTwosComplementNegatives() {
    // AppleSmartBattery reports a discharging current as an unsigned register value.
    XCTAssertEqual(IORegistryReader.signedInt(Int(UInt32.max)), -1)
    XCTAssertEqual(IORegistryReader.signedInt(4_294_966_796), -500)
    XCTAssertEqual(IORegistryReader.signedInt(4_294_964_796), -2500)
  }

  func testSignedIntIsNilForNil() {
    XCTAssertNil(IORegistryReader.signedInt(nil))
  }

  func testUnknownServiceHasNoProperties() {
    XCTAssertNil(IORegistryReader.properties(matching: "IsletNoSuchServiceExists"))
    XCTAssertNil(
      IORegistryReader.properties(
        matching: "IsletNoSuchServiceExists", keys: ["AnyProperty"]))
    XCTAssertTrue(IORegistryReader.allProperties(matching: "IsletNoSuchServiceExists").isEmpty)
  }

  func testNarrowReadReturnsOnlyRequestedProperties() {
    let props = IORegistryReader.properties(
      matching: "IOPlatformExpertDevice", keys: ["IOPlatformUUID"])
    XCTAssertEqual(Set(props?.keys.map { $0 } ?? []), Set(["IOPlatformUUID"]))
    XCTAssertNotNil(props?["IOPlatformUUID"] as? String)
  }

  func testPlatformExpertPropertiesComeBackInOneRead() {
    // IOPlatformExpertDevice is present on every Mac and carries IOPlatformUUID, so this asserts
    // the bulk read really returns the whole dictionary and not just a handle.
    let props = IORegistryReader.properties(matching: "IOPlatformExpertDevice")
    XCTAssertNotNil(props)
    XCTAssertFalse(props?.isEmpty ?? true)
    XCTAssertNotNil(props?["IOPlatformUUID"] as? String)
  }

  func testAllPropertiesEnumeratesEveryMatchingNode() {
    let nodes = IORegistryReader.allProperties(matching: "IOPlatformExpertDevice")
    XCTAssertGreaterThanOrEqual(nodes.count, 1)
    XCTAssertNotNil(nodes.first?["IOPlatformUUID"] as? String)
  }
}
