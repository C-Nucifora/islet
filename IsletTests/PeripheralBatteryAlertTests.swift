import XCTest

@testable import Islet

final class PeripheralBatteryAlertTests: XCTestCase {
  func testDeviceTypesAreDerivedFromNames() {
    XCTAssertEqual(PeripheralDeviceType(name: "Magic Mouse"), .mouse)
    XCTAssertEqual(PeripheralDeviceType(name: "Magic Trackpad"), .trackpad)
    XCTAssertEqual(PeripheralDeviceType(name: "Magic Keyboard"), .keyboard)
    XCTAssertEqual(PeripheralDeviceType(name: "Apple Pencil"), .pencil)
    XCTAssertEqual(PeripheralDeviceType(name: "Game Controller"), .other)
  }

  func testPeripheralIdentityPrefersHardwareIdentityAndSeparatesSameModelDevices() {
    XCTAssertEqual(
      PeripheralBatteryReader.stableIdentifier(
        serialNumber: " ABC123 ", deviceAddress: "AA-BB", registryEntryID: 1),
      "serial:abc123")
    XCTAssertEqual(
      PeripheralBatteryReader.stableIdentifier(
        serialNumber: nil, deviceAddress: " AA-BB ", registryEntryID: 1),
      "address:aa-bb")
    XCTAssertNotEqual(
      PeripheralBatteryReader.stableIdentifier(
        serialNumber: nil, deviceAddress: nil, registryEntryID: 1),
      PeripheralBatteryReader.stableIdentifier(
        serialNumber: nil, deviceAddress: nil, registryEntryID: 2))
  }

  func testConfiguredThresholdAppliesPerDeviceType() {
    var detector = PeripheralBatteryAlertDetector()
    detector.seed([
      PeripheralBattery(id: "mouse", name: "Magic Mouse", percent: 35),
      PeripheralBattery(id: "keys", name: "Magic Keyboard", percent: 35),
    ])
    let alerts = detector.evaluate(
      [
        PeripheralBattery(id: "mouse", name: "Magic Mouse", percent: 29),
        PeripheralBattery(id: "keys", name: "Magic Keyboard", percent: 29),
      ],
      thresholds: ["mouse": 30, "keyboard": 20])

    XCTAssertEqual(alerts.count, 1)
    XCTAssertEqual(alerts.first?.device.id, "mouse")
    XCTAssertEqual(alerts.first?.alert, .warning(threshold: 30))
  }

  func testDuplicatePeripheralIdentifiersSeedWithoutTrapping() {
    var detector = PeripheralBatteryAlertDetector()
    detector.seed([
      PeripheralBattery(id: "duplicate", name: "Magic Mouse", percent: 40),
      PeripheralBattery(id: "duplicate", name: "Magic Mouse", percent: 30),
    ])

    let alerts = detector.evaluate(
      [PeripheralBattery(id: "duplicate", name: "Magic Mouse", percent: 19)],
      thresholds: ["mouse": 20])

    XCTAssertEqual(alerts.map(\.alert), [.warning(threshold: 20)])
  }

  func testDisabledEarlyWarningKeepsCriticalEvent() {
    var detector = PeripheralBatteryAlertDetector()
    detector.seed([PeripheralBattery(id: "mouse", name: "Magic Mouse", percent: 25)])
    let warning = detector.evaluate(
      [PeripheralBattery(id: "mouse", name: "Magic Mouse", percent: 19)],
      thresholds: ["mouse": 0])
    XCTAssertTrue(warning.isEmpty)

    let critical = detector.evaluate(
      [PeripheralBattery(id: "mouse", name: "Magic Mouse", percent: 10)],
      thresholds: ["mouse": 0])
    XCTAssertEqual(critical.map(\.alert), [.critical])
  }

  func testDropPastEarlyAndCriticalThresholdProducesOnlyCriticalAlert() {
    var detector = PeripheralBatteryAlertDetector()
    detector.seed([PeripheralBattery(id: "mouse", name: "Magic Mouse", percent: 35)])
    let alerts = detector.evaluate(
      [PeripheralBattery(id: "mouse", name: "Magic Mouse", percent: 8)],
      thresholds: ["mouse": 30])
    XCTAssertEqual(alerts.map(\.alert), [.critical])
  }

  func testFirstReadingAndSteadyLowReadingDoNotAlert() {
    var detector = PeripheralBatteryAlertDetector()
    XCTAssertTrue(
      detector.evaluate(
        [PeripheralBattery(id: "mouse", name: "Magic Mouse", percent: 9)],
        thresholds: ["mouse": 20]
      ).isEmpty)
    XCTAssertTrue(
      detector.evaluate(
        [PeripheralBattery(id: "mouse", name: "Magic Mouse", percent: 8)],
        thresholds: ["mouse": 20]
      ).isEmpty)
  }
}
