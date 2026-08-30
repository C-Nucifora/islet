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

@MainActor
final class ExternalBrightnessTests: XCTestCase {
  private let display = ExternalBrightnessDisplay(
    displayID: 42, id: "fake-display-42", name: "Fake DDC Display",
    vendorID: 10, productID: 20, serialNumber: 30)

  func testSuccessfulProbeAndWriteControlTheFakeDisplay() async {
    let fake = FakeExternalBrightnessBackend()
    let deadlines = ManualBrightnessDeadlineScheduler()
    let controller = ExternalBrightnessController(
      backend: fake.backend, deadlineScheduler: deadlines.scheduler)

    controller.refresh(displays: [display], disabledDisplayIDs: [])
    XCTAssertEqual(controller.statuses.first?.capability, .probing)
    fake.completeRead(.success(0.5))
    await settleMainActorTasks()

    let target = controller.adjust(displayID: display.displayID, up: true, divisor: 1)
    XCTAssertEqual(target ?? -1, 0.5 + 1.0 / 16.0, accuracy: 1e-6)
    XCTAssertEqual(fake.writtenLevels, [0.5 + 1.0 / 16.0])

    fake.completeWrite(.success(target!))
    await settleMainActorTasks()
    XCTAssertEqual(controller.statuses.first?.capability, .available(level: target!))
  }

  func testProbeTimeoutRejectsLateReplyAndFallsBack() async {
    let fake = FakeExternalBrightnessBackend()
    let deadlines = ManualBrightnessDeadlineScheduler()
    let controller = ExternalBrightnessController(
      backend: fake.backend, deadlineScheduler: deadlines.scheduler)

    controller.refresh(displays: [display], disabledDisplayIDs: [])
    deadlines.fireAll()
    await settleMainActorTasks()

    XCTAssertEqual(controller.statuses.first?.capability, .unavailable(.timedOut))
    XCTAssertNil(controller.adjust(displayID: display.displayID, up: true, divisor: 1))

    fake.completeRead(.success(0.8))
    await settleMainActorTasks()
    XCTAssertEqual(controller.statuses.first?.capability, .unavailable(.timedOut))
  }

  func testRejectedProbeLeavesMediaKeyForNativeHandling() async {
    let fake = FakeExternalBrightnessBackend()
    let controller = ExternalBrightnessController(
      backend: fake.backend,
      deadlineScheduler: ManualBrightnessDeadlineScheduler().scheduler)

    controller.refresh(displays: [display], disabledDisplayIDs: [])
    fake.completeRead(.failure(.rejected("fake monitor refused VCP 0x10")))
    await settleMainActorTasks()

    XCTAssertEqual(
      controller.statuses.first?.capability,
      .unavailable(.rejected("fake monitor refused VCP 0x10")))
    XCTAssertNil(controller.adjust(displayID: display.displayID, up: false, divisor: 1))
    XCTAssertTrue(fake.writtenLevels.isEmpty)
  }

  func testRejectedWriteMakesLaterKeysFallThrough() async {
    let fake = FakeExternalBrightnessBackend()
    let controller = ExternalBrightnessController(
      backend: fake.backend,
      deadlineScheduler: ManualBrightnessDeadlineScheduler().scheduler)

    controller.refresh(displays: [display], disabledDisplayIDs: [])
    fake.completeRead(.success(0.5))
    await settleMainActorTasks()
    XCTAssertNotNil(controller.adjust(displayID: display.displayID, up: true, divisor: 1))

    fake.completeWrite(.failure(.rejected("fake monitor refused the write")))
    await settleMainActorTasks()

    XCTAssertEqual(
      controller.statuses.first?.capability,
      .unavailable(.rejected("fake monitor refused the write")))
    XCTAssertNil(controller.adjust(displayID: display.displayID, up: true, divisor: 1))
  }

  func testRepeatedKeysCoalesceBehindTheInFlightWrite() async throws {
    let fake = FakeExternalBrightnessBackend()
    let controller = ExternalBrightnessController(
      backend: fake.backend,
      deadlineScheduler: ManualBrightnessDeadlineScheduler().scheduler)

    controller.refresh(displays: [display], disabledDisplayIDs: [])
    fake.completeRead(.success(0.5))
    await settleMainActorTasks()

    let first = try XCTUnwrap(
      controller.adjust(displayID: display.displayID, up: true, divisor: 1))
    let second = try XCTUnwrap(
      controller.adjust(displayID: display.displayID, up: true, divisor: 1))
    XCTAssertEqual(fake.writtenLevels, [first])

    fake.completeWrite(.success(first))
    await settleMainActorTasks()
    XCTAssertEqual(fake.writtenLevels, [first, second])

    fake.completeWrite(.success(second))
    await settleMainActorTasks()
    XCTAssertEqual(controller.statuses.first?.capability, .available(level: second))
  }

  func testPerDisplayDisablementSkipsProbeAndFallsBack() {
    let fake = FakeExternalBrightnessBackend()
    let controller = ExternalBrightnessController(
      backend: fake.backend,
      deadlineScheduler: ManualBrightnessDeadlineScheduler().scheduler)

    controller.refresh(displays: [display], disabledDisplayIDs: [display.id])

    XCTAssertEqual(controller.statuses.first?.capability, .disabled)
    XCTAssertEqual(fake.readCount, 0)
    XCTAssertNil(controller.adjust(displayID: display.displayID, up: true, divisor: 1))
  }

  private func settleMainActorTasks() async {
    await Task.yield()
    await Task.yield()
  }
}

private final class FakeExternalBrightnessBackend: @unchecked Sendable {
  private let lock = NSLock()
  private var readCompletions: [ExternalBrightnessBackend.Completion] = []
  private var writeCompletions: [ExternalBrightnessBackend.Completion] = []
  private var levels: [Float] = []
  private var reads = 0

  var backend: ExternalBrightnessBackend {
    ExternalBrightnessBackend(
      read: { [self] _, completion in
        lock.withLock {
          reads += 1
          readCompletions.append(completion)
        }
      },
      write: { [self] _, level, completion in
        lock.withLock {
          levels.append(level)
          writeCompletions.append(completion)
        }
      })
  }

  var writtenLevels: [Float] { lock.withLock { levels } }
  var readCount: Int { lock.withLock { reads } }

  func completeRead(_ result: Result<Float, ExternalBrightnessFailure>) {
    let completion = lock.withLock { readCompletions.removeFirst() }
    completion(result)
  }

  func completeWrite(_ result: Result<Float, ExternalBrightnessFailure>) {
    let completion = lock.withLock { writeCompletions.removeFirst() }
    completion(result)
  }
}

private final class ManualBrightnessDeadlineScheduler: @unchecked Sendable {
  private let lock = NSLock()
  private var operations: [UUID: @Sendable () -> Void] = [:]

  var scheduler: BrightnessDeadlineScheduler {
    BrightnessDeadlineScheduler { [self] _, operation in
      let id = UUID()
      lock.withLock { operations[id] = operation }
      return BrightnessDeadlineCancellation { [weak self] in
        _ = self?.lock.withLock { self?.operations.removeValue(forKey: id) }
      }
    }
  }

  func fireAll() {
    let pending = lock.withLock {
      let pending = Array(operations.values)
      operations.removeAll()
      return pending
    }
    for operation in pending { operation() }
  }
}
