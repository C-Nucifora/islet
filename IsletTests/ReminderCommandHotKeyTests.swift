import XCTest

@testable import Islet

@MainActor
final class ReminderCommandHotKeyTests: XCTestCase {
  private final class Registration: ReminderCommandHotKeyRegistering {
    var shouldRegister = true
    private(set) var registrationCount = 0
    private(set) var unregistrationCount = 0
    private var handler: (@MainActor () -> Void)?

    func register(handler: @escaping @MainActor () -> Void) -> Bool {
      registrationCount += 1
      self.handler = handler
      return shouldRegister
    }

    func unregister() {
      unregistrationCount += 1
      handler = nil
    }

    @MainActor func fire() { handler?() }
  }

  func testStartRegistersOnceAndStopUnregistersOnce() {
    let registration = Registration()
    let hotKey = ReminderCommandHotKey(registration: registration, dispatch: {})

    hotKey.start()
    hotKey.start()
    hotKey.stop()
    hotKey.stop()

    XCTAssertEqual(registration.registrationCount, 1)
    XCTAssertEqual(registration.unregistrationCount, 1)
    XCTAssertFalse(hotKey.isAvailable)
  }

  func testRegisteredHotKeyDispatchesReminderCommandsExactlyOnce() {
    let registration = Registration()
    var dispatchCount = 0
    let hotKey = ReminderCommandHotKey(registration: registration) { dispatchCount += 1 }

    hotKey.start()
    registration.fire()

    XCTAssertTrue(hotKey.isAvailable)
    XCTAssertEqual(dispatchCount, 1)
  }

  func testFailedRegistrationDoesNotAdvertiseKeyboardAvailability() {
    let registration = Registration()
    registration.shouldRegister = false
    let hotKey = ReminderCommandHotKey(registration: registration, dispatch: {})

    hotKey.start()

    XCTAssertEqual(registration.registrationCount, 1)
    XCTAssertEqual(registration.unregistrationCount, 0)
    XCTAssertFalse(hotKey.isAvailable)
  }

  func testFailedRegistrationCanBeRetriedAfterConflictClears() {
    let registration = Registration()
    registration.shouldRegister = false
    let hotKey = ReminderCommandHotKey(registration: registration, dispatch: {})

    hotKey.start()
    registration.shouldRegister = true
    hotKey.start()
    hotKey.stop()

    XCTAssertEqual(registration.registrationCount, 2)
    XCTAssertEqual(registration.unregistrationCount, 1)
    XCTAssertFalse(hotKey.isAvailable)
  }
}
