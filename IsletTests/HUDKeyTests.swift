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
    XCTAssertNil(HUDKey.decode(data1: data1(keyCode: 0, state: 0xC)))
  }

  func testMasterVolumeIsPreferredWhenAvailable() {
    XCTAssertEqual(VolumeControlLayout.preferredElements(from: [2, 0, 1]), [0])
    XCTAssertEqual(VolumeControlLayout.preferredElements(from: [2, 1, 2]), [1, 2])
  }

  func testVolumeShiftPreservesPerChannelBalance() {
    let shifted = VolumeControlLayout.shiftedValues(
      [1: 0.4, 2: 0.6], reference: 0.4, target: 0.5)
    XCTAssertEqual(shifted[1] ?? -1, 0.5, accuracy: 1e-6)
    XCTAssertEqual(shifted[2] ?? -1, 0.7, accuracy: 1e-6)
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

  func testOnlySuccessfulKeyDownConsumesMatchingKeyUp() {
    var state = HUDKeyConsumptionState()
    XCTAssertFalse(state.recordKeyDown(.volumeUp, applied: false))
    XCTAssertFalse(state.shouldConsumeKeyUp(.volumeUp))

    XCTAssertTrue(state.recordKeyDown(.volumeUp, applied: true))
    XCTAssertTrue(state.shouldConsumeKeyUp(.volumeUp))
    XCTAssertFalse(state.shouldConsumeKeyUp(.volumeUp))
  }

  func testFailedRepeatReturnsKeyOwnershipToMacOS() {
    var state = HUDKeyConsumptionState()
    XCTAssertTrue(state.recordKeyDown(.brightnessDown, applied: true))
    XCTAssertFalse(state.recordKeyDown(.brightnessDown, applied: false))
    XCTAssertFalse(state.shouldConsumeKeyUp(.brightnessDown))
  }
}
