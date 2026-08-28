import XCTest

@testable import Islet

final class HUDKeyTests: XCTestCase {
  /// Builds a data1 value the way the system encodes it: keyCode in bits 16+, state in byte 1.
  func data1(keyCode: Int, state: Int) -> Int {
    (keyCode << 16) | (state << 8)
  }

  func testDecodeVolumeUpKeyDown() {
    let r = HUDKey.decode(data1: data1(keyCode: 0, state: 0xA))
    XCTAssertEqual(r?.key, .volumeUp)
    XCTAssertEqual(r?.isKeyDown, true)
  }

  func testDecodeVolumeDownKeyUp() {
    let r = HUDKey.decode(data1: data1(keyCode: 1, state: 0xB))
    XCTAssertEqual(r?.key, .volumeDown)
    XCTAssertEqual(r?.isKeyDown, false)
  }

  func testDecodeMuteAndBrightness() {
    XCTAssertEqual(HUDKey.decode(data1: data1(keyCode: 7, state: 0xA))?.key, .mute)
    XCTAssertEqual(HUDKey.decode(data1: data1(keyCode: 2, state: 0xA))?.key, .brightnessUp)
    XCTAssertEqual(HUDKey.decode(data1: data1(keyCode: 3, state: 0xA))?.key, .brightnessDown)
  }

  func testUnhandledKeyReturnsNil() {
    XCTAssertNil(HUDKey.decode(data1: data1(keyCode: 10, state: 0xA)))
  }

  func testBrightnessClassification() {
    XCTAssertTrue(HUDKey.brightnessUp.isBrightness)
    XCTAssertFalse(HUDKey.volumeUp.isBrightness)
  }

  func testSteppingClampsAndMoves() {
    XCTAssertEqual(HUDMath.stepped(0.5, up: true), 0.5 + 1.0 / 16.0, accuracy: 1e-6)
    XCTAssertEqual(HUDMath.stepped(0.0, up: false), 0)
    XCTAssertEqual(HUDMath.stepped(1.0, up: true), 1)
    XCTAssertEqual(HUDMath.stepped(0.5, up: true, divisor: 4), 0.5 + 1.0 / 64.0, accuracy: 1e-6)
  }

  func testBrightnessTargetFollowsThePointerToTheExternalDisplay() {
    let displays = [
      BrightnessDisplayTarget(
        displayID: 1, frame: CGRect(x: 0, y: 0, width: 1728, height: 1117)),
      BrightnessDisplayTarget(
        displayID: 42, frame: CGRect(x: 1728, y: 0, width: 1920, height: 1080)),
    ]

    XCTAssertEqual(
      BrightnessTargetResolver.displayID(
        at: CGPoint(x: 2200, y: 500), displays: displays),
      42)
  }

  func testBrightnessAdjustmentUsesTheRequestedDisplay() {
    var readDisplayIDs: [CGDirectDisplayID] = []
    var writtenDisplayID: CGDirectDisplayID?
    var writtenLevel: Float?

    let level = BrightnessController.adjustBrightness(
      displayID: 42, up: true, divisor: 1,
      read: { displayID in
        readDisplayIDs.append(displayID)
        return 0.5
      },
      write: { displayID, level in
        writtenDisplayID = displayID
        writtenLevel = level
        return true
      })

    XCTAssertEqual(readDisplayIDs, [42])
    XCTAssertEqual(writtenDisplayID, 42)
    XCTAssertEqual(writtenLevel ?? -1, 0.5 + 1.0 / 16.0, accuracy: 1e-6)
    XCTAssertEqual(level ?? -1, 0.5 + 1.0 / 16.0, accuracy: 1e-6)
  }

  func testBrightnessAdjustmentFailsWhenTheDisplayRejectsTheWrite() {
    let level = BrightnessController.adjustBrightness(
      displayID: 42, up: true, divisor: 1,
      read: { _ in 0.5 },
      write: { _, _ in false })

    XCTAssertNil(level)
  }

  func testFailedBrightnessKeyDownLeavesItsKeyUpUnconsumed() {
    var state = HUDKeyConsumptionState()

    XCTAssertFalse(state.recordKeyDown(.brightnessDown, applied: false))
    XCTAssertFalse(state.shouldConsumeKeyUp(.brightnessDown))
  }

  func testSuccessfulBrightnessKeyDownConsumesItsKeyUpOnce() {
    var state = HUDKeyConsumptionState()

    XCTAssertTrue(state.recordKeyDown(.brightnessUp, applied: true))
    XCTAssertTrue(state.shouldConsumeKeyUp(.brightnessUp))
    XCTAssertFalse(state.shouldConsumeKeyUp(.brightnessUp))
  }
}
