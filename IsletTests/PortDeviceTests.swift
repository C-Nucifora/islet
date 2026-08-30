import XCTest

@testable import Islet

final class PortDeviceTests: XCTestCase {
  func testDuplicateProductNamesWithoutLocationIDsHaveDistinctStableKeys() throws {
    let first = try XCTUnwrap(PortsReader.device(from: USBDeviceFixtures.identicalKeyboardA))
    let second = try XCTUnwrap(PortsReader.device(from: USBDeviceFixtures.identicalKeyboardB))

    XCTAssertEqual(first.name, second.name)
    XCTAssertNil(first.locationID)
    XCTAssertNil(second.locationID)
    XCTAssertNotEqual(first.id, second.id)
    XCTAssertNotEqual(first.id, first.name)
    XCTAssertEqual(Set([first.id, second.id]).count, 2)
  }

  func testIdentitySurvivesRefreshWhenOptionalPropertiesAreMissingOrChange() throws {
    let first = try XCTUnwrap(PortsReader.device(from: USBDeviceFixtures.missingProperties))
    let refreshed = try XCTUnwrap(
      PortsReader.device(from: USBDeviceFixtures.missingPropertiesRefresh))

    XCTAssertEqual(first.id, refreshed.id)
    XCTAssertEqual(refreshed.name, "USB Device")
    XCTAssertNil(refreshed.vendor)
    XCTAssertNil(refreshed.speed)
  }

  func testPhysicalPathIsAStableFallbackWhenRegistryIDIsUnavailable() throws {
    let first = try XCTUnwrap(PortsReader.device(from: USBDeviceFixtures.pathOnly))
    let refreshed = try XCTUnwrap(PortsReader.device(from: USBDeviceFixtures.pathOnly))

    XCTAssertEqual(first.id, refreshed.id)
    XCTAssertEqual(first.id, "path:/AppleUSBXHCI/Port@14400000/Device@1")
  }

  func testMovingDeviceToAnotherPhysicalPortReportsDetachAndAttach() throws {
    let original = try XCTUnwrap(PortsReader.device(from: USBDeviceFixtures.movedDeviceOriginal))
    let moved = try XCTUnwrap(PortsReader.device(from: USBDeviceFixtures.movedDevice))

    let diff = SetDiff.changes(from: [original], to: [moved])
    XCTAssertEqual(diff.removed, [original])
    XCTAssertEqual(diff.added, [moved])
  }

  func testEntryWithoutStableRegistryDataIsNotPublished() {
    XCTAssertNil(
      PortsReader.device(
        from: .init(
          registryEntryID: nil, servicePath: nil, locationID: nil,
          productName: "Keyboard", vendorName: nil, deviceSpeed: nil)))
  }
}

private enum USBDeviceFixtures {
  static let identicalKeyboardA = USBDeviceRegistryEntry(
    registryEntryID: 0x101,
    servicePath: "/AppleUSBXHCI/Port@14100000/Device@1",
    locationID: nil,
    productName: "USB Keyboard",
    vendorName: nil,
    deviceSpeed: nil)

  static let identicalKeyboardB = USBDeviceRegistryEntry(
    registryEntryID: 0x102,
    servicePath: "/AppleUSBXHCI/Port@14200000/Device@1",
    locationID: nil,
    productName: "USB Keyboard",
    vendorName: nil,
    deviceSpeed: nil)

  static let missingProperties = USBDeviceRegistryEntry(
    registryEntryID: 0x201,
    servicePath: "/AppleUSBXHCI/Port@14300000/Device@1",
    locationID: nil,
    productName: nil,
    vendorName: nil,
    deviceSpeed: nil)

  static let missingPropertiesRefresh = USBDeviceRegistryEntry(
    registryEntryID: 0x201,
    servicePath: "/AppleUSBXHCI/Port@14300000/Device@1",
    locationID: nil,
    productName: nil,
    vendorName: nil,
    deviceSpeed: nil)

  static let movedDeviceOriginal = USBDeviceRegistryEntry(
    registryEntryID: 0x301,
    servicePath: "/AppleUSBXHCI/Port@14100000/Device@1",
    locationID: nil,
    productName: "USB Keyboard",
    vendorName: nil,
    deviceSpeed: nil)

  static let pathOnly = USBDeviceRegistryEntry(
    registryEntryID: nil,
    servicePath: "/AppleUSBXHCI/Port@14400000/Device@1",
    locationID: nil,
    productName: "USB Keyboard",
    vendorName: nil,
    deviceSpeed: nil)

  static let movedDevice = USBDeviceRegistryEntry(
    registryEntryID: 0x301,
    servicePath: "/AppleUSBXHCI/Port@14200000/Device@1",
    locationID: nil,
    productName: "USB Keyboard",
    vendorName: nil,
    deviceSpeed: nil)
}
