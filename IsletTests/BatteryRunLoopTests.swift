import AppKit
import XCTest

@testable import Islet

@MainActor
final class BatteryRunLoopTests: XCTestCase {
  private final class CallbackCounter {
    var value = 0
  }

  func testCommonModeSourceFiresOnceInTrackingAndDefaultModesAndStopsAfterRemoval() {
    let runLoop = CFRunLoopGetCurrent()!
    let trackingMode = CFRunLoopMode(
      rawValue: RunLoop.Mode.eventTracking.rawValue as CFString)
    CFRunLoopAddCommonMode(runLoop, trackingMode)

    let counter = CallbackCounter()
    var context = CFRunLoopSourceContext(
      version: 0,
      info: Unmanaged.passUnretained(counter).toOpaque(),
      retain: nil,
      release: nil,
      copyDescription: nil,
      equal: nil,
      hash: nil,
      schedule: nil,
      cancel: nil,
      perform: { context in
        guard let context else { return }
        Unmanaged<CallbackCounter>.fromOpaque(context).takeUnretainedValue().value += 1
      })
    let source = CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &context)!
    let registration = PowerSourceRunLoopRegistration(runLoop: runLoop)

    XCTAssertTrue(registration.install(source))
    XCTAssertFalse(registration.install(source))
    XCTAssertTrue(CFRunLoopContainsSource(runLoop, source, trackingMode))
    XCTAssertTrue(CFRunLoopContainsSource(runLoop, source, .defaultMode))

    CFRunLoopSourceSignal(source)
    CFRunLoopRunInMode(trackingMode, 0.01, false)
    XCTAssertEqual(counter.value, 1)

    CFRunLoopRunInMode(.defaultMode, 0.01, false)
    XCTAssertEqual(counter.value, 1)

    CFRunLoopSourceSignal(source)
    CFRunLoopRunInMode(.defaultMode, 0.01, false)
    XCTAssertEqual(counter.value, 2)

    XCTAssertTrue(registration.remove())
    XCTAssertFalse(registration.remove())
    XCTAssertFalse(CFRunLoopContainsSource(runLoop, source, trackingMode))
    XCTAssertFalse(CFRunLoopContainsSource(runLoop, source, .defaultMode))

    CFRunLoopSourceSignal(source)
    CFRunLoopRunInMode(trackingMode, 0.01, false)
    CFRunLoopRunInMode(.defaultMode, 0.01, false)
    XCTAssertEqual(counter.value, 2)
  }
}
