import Combine
import XCTest

@testable import Islet

@MainActor
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

  func testLegacyUSBRegistrySpeedIsMapped() throws {
    let device = try XCTUnwrap(PortsReader.device(from: USBDeviceFixtures.legacyUSB))

    XCTAssertEqual(device.speed, "480 Mbps")
  }

  func testNegotiatedLinkSpeedTakesPriorityOverUSBMarketingSpeed() throws {
    let device = try XCTUnwrap(PortsReader.device(from: USBDeviceFixtures.usb20Gbps))

    XCTAssertEqual(device.speed, "20 Gbps")
  }

  func testNegotiatedUSB4LinkSpeedsAreMapped() throws {
    let forty = try XCTUnwrap(PortsReader.device(from: USBDeviceFixtures.usb40Gbps))
    let eighty = try XCTUnwrap(PortsReader.device(from: USBDeviceFixtures.usb80Gbps))

    XCTAssertEqual(forty.speed, "40 Gbps")
    XCTAssertEqual(eighty.speed, "80 Gbps")
  }

  func testUnknownLinkSpeedHasAnExplicitLabel() throws {
    let device = try XCTUnwrap(PortsReader.device(from: USBDeviceFixtures.unknownSpeed))

    XCTAssertEqual(device.speed, "Unknown (123456789)")
  }

  func testFailedReadRetainsLastValidSnapshotDuringGracePeriod() {
    var now = Date(timeIntervalSince1970: 1_000)
    var results: [PortEnumerationResult] = [
      .devices([USBDeviceFixtures.monitorDevice]),
      .error(.matchingServices(-1)),
    ]
    let monitor = PortMonitor(
      reader: { results.removeFirst() }, now: { now }, gracePeriod: 10)

    monitor.refresh()
    now.addTimeInterval(9)
    monitor.refresh()

    XCTAssertEqual(monitor.devices, [USBDeviceFixtures.monitorDevice])
    XCTAssertEqual(
      monitor.readerHealth,
      .stale(error: .matchingServices(-1), lastSuccessfulRead: Date(timeIntervalSince1970: 1_000)))
  }

  func testGraceExpiryClearsTheDisplayedSnapshotButNotTheEventSnapshot() {
    var now = Date(timeIntervalSince1970: 1_000)
    var results: [PortEnumerationResult] = [
      .devices([USBDeviceFixtures.monitorDevice]),
      .error(.matchingServices(-1)),
    ]
    let monitor = PortMonitor(
      reader: { results.removeFirst() }, now: { now }, gracePeriod: 10)

    monitor.refresh()
    now.addTimeInterval(1)
    monitor.refresh()
    now.addTimeInterval(9)
    monitor.expireGraceIfNeeded()

    XCTAssertEqual(monitor.devices, [])
    XCTAssertEqual(monitor.eventDevices, [USBDeviceFixtures.monitorDevice])
    XCTAssertEqual(monitor.previousDevices, [USBDeviceFixtures.monitorDevice])
    XCTAssertEqual(
      monitor.readerHealth,
      .failed(error: .matchingServices(-1), lastSuccessfulRead: Date(timeIntervalSince1970: 1_000)))
  }

  func testRetryRecoversReaderWithoutInventingDisconnectOrReconnectEvents() {
    var now = Date(timeIntervalSince1970: 1_000)
    var results: [PortEnumerationResult] = [
      .devices([USBDeviceFixtures.monitorDevice]),
      .error(.matchingServices(-1)),
      .devices([USBDeviceFixtures.monitorDevice]),
    ]
    let monitor = PortMonitor(
      reader: { results.removeFirst() }, now: { now }, gracePeriod: 10)
    var eventSnapshots: [[PortDevice]] = []
    let cancellable = monitor.$eventDevices.dropFirst().sink { eventSnapshots.append($0) }
    defer { cancellable.cancel() }

    monitor.refresh()
    now.addTimeInterval(1)
    monitor.refresh()
    now.addTimeInterval(9)
    monitor.expireGraceIfNeeded()
    monitor.retry()

    XCTAssertEqual(monitor.devices, [USBDeviceFixtures.monitorDevice])
    XCTAssertEqual(
      monitor.readerHealth,
      .current(lastSuccessfulRead: Date(timeIntervalSince1970: 1_010)))
    XCTAssertEqual(eventSnapshots, [[USBDeviceFixtures.monitorDevice]])
  }

  func testFirstSuccessAfterAnInitialFailureBecomesTheEventBaseline() {
    var now = Date(timeIntervalSince1970: 1_000)
    var results: [PortEnumerationResult] = [
      .error(.matchingServices(-1)),
      .devices([USBDeviceFixtures.monitorDevice]),
    ]
    let monitor = PortMonitor(reader: { results.removeFirst() }, now: { now }, gracePeriod: 10)

    monitor.refresh()
    now.addTimeInterval(1)
    monitor.retry()

    XCTAssertEqual(monitor.eventDevices, [USBDeviceFixtures.monitorDevice])
    XCTAssertEqual(monitor.previousDevices, [USBDeviceFixtures.monitorDevice])
    let changes = SetDiff.changes(from: monitor.previousDevices, to: monitor.eventDevices)
    XCTAssertTrue(changes.added.isEmpty)
    XCTAssertTrue(changes.removed.isEmpty)
  }

  func testClockMovingBackwardExpiresRatherThanExtendingAStaleSnapshot() {
    var now = Date(timeIntervalSince1970: 1_000)
    var results: [PortEnumerationResult] = [
      .devices([USBDeviceFixtures.monitorDevice]),
      .error(.matchingServices(-1)),
    ]
    let monitor = PortMonitor(reader: { results.removeFirst() }, now: { now }, gracePeriod: 10)

    monitor.refresh()
    now.addTimeInterval(-1)
    monitor.refresh()

    XCTAssertTrue(monitor.devices.isEmpty)
    XCTAssertEqual(
      monitor.readerHealth,
      .failed(error: .matchingServices(-1), lastSuccessfulRead: Date(timeIntervalSince1970: 1_000)))
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

  static let legacyUSB = USBDeviceRegistryEntry(
    registryEntryID: 0x401,
    servicePath: "/AppleUSBXHCI/Port@14600000/Device@1",
    locationID: nil,
    productName: "USB Keyboard",
    vendorName: "Example",
    deviceSpeed: Int(kUSBDeviceSpeedHigh))

  static let usb20Gbps = USBDeviceRegistryEntry(
    registryEntryID: 0x402,
    servicePath: "/AppleUSBXHCI/Port@14700000/Device@1",
    locationID: nil,
    productName: "USB4 40Gbps device",
    vendorName: "Example",
    deviceSpeed: Int(kUSBDeviceSpeedSuper),
    linkSpeed: Int(kIOUSBLinkSpeed20Gbps),
    usbSpeed: Int(kIOUSBHostConnectionSpeedSuperPlus.rawValue))

  static let usb40Gbps = USBDeviceRegistryEntry(
    registryEntryID: 0x403,
    servicePath: "/AppleUSBXHCI/Port@14800000/Device@1",
    locationID: nil,
    productName: "USB4 40Gbps device",
    vendorName: "Example",
    deviceSpeed: nil,
    linkSpeed: Int(kIOUSBLinkSpeed40Gbps))

  static let usb80Gbps = USBDeviceRegistryEntry(
    registryEntryID: 0x404,
    servicePath: "/AppleUSBXHCI/Port@14900000/Device@1",
    locationID: nil,
    productName: "USB4 80Gbps device",
    vendorName: "Example",
    deviceSpeed: nil,
    linkSpeed: Int(kIOUSBLinkSpeed80Gbps))

  static let unknownSpeed = USBDeviceRegistryEntry(
    registryEntryID: 0x405,
    servicePath: "/AppleUSBXHCI/Port@14A00000/Device@1",
    locationID: nil,
    productName: "Future USB device",
    vendorName: "Example",
    deviceSpeed: nil,
    linkSpeed: 123_456_789)

  static let monitorDevice = PortDevice(
    id: "registry:0000000000000401|path:/AppleUSBXHCI/Port@14500000/Device@1",
    name: "USB Keyboard",
    vendor: "Example",
    speed: "480 Mbps",
    locationID: 0x1450_0000)
}
