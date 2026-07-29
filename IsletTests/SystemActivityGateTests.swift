import XCTest

@testable import Islet

final class SystemActivityGateTests: XCTestCase {

  /// Feeds `count` identical CPU samples with a nominal thermal state, returning the last result.
  @discardableResult
  private func feed(_ gate: inout SystemPresenceGate, cpu: Double, count: Int) -> Bool {
    var changed = false
    for _ in 0..<count { changed = gate.update(cpuTotal: cpu, thermalState: 0) }
    return changed
  }

  func testFreshGateIsInactive() {
    let gate = SystemPresenceGate()
    XCTAssertFalse(gate.isActive)
    XCTAssertNil(gate.reason)
  }

  func testSustainedHighCPUActivatesOnlyOnTheFifthSample() {
    var gate = SystemPresenceGate()
    for _ in 0..<(SystemPresenceGate.sustainSamples - 1) {
      XCTAssertFalse(gate.update(cpuTotal: 0.9, thermalState: 0))
      XCTAssertFalse(gate.isActive)
    }
    XCTAssertTrue(gate.update(cpuTotal: 0.9, thermalState: 0))
    XCTAssertTrue(gate.isActive)
    XCTAssertEqual(gate.reason, .cpu)
  }

  func testInterruptedStreakRestarts() {
    var gate = SystemPresenceGate()
    feed(&gate, cpu: 0.9, count: 4)
    gate.update(cpuTotal: 0.7, thermalState: 0)  // breaks the streak without deactivating
    feed(&gate, cpu: 0.9, count: 4)
    XCTAssertFalse(gate.isActive)
    XCTAssertTrue(gate.update(cpuTotal: 0.9, thermalState: 0))
    XCTAssertTrue(gate.isActive)
  }

  func testHysteresisBandKeepsAnActiveGateActive() {
    var gate = SystemPresenceGate()
    feed(&gate, cpu: 0.9, count: SystemPresenceGate.sustainSamples)
    XCTAssertFalse(gate.update(cpuTotal: 0.7, thermalState: 0))
    XCTAssertTrue(gate.isActive)
    XCTAssertEqual(gate.reason, .cpu)
  }

  func testFallingBelowReleaseThresholdDeactivates() {
    var gate = SystemPresenceGate()
    feed(&gate, cpu: 0.9, count: SystemPresenceGate.sustainSamples)
    gate.update(cpuTotal: 0.7, thermalState: 0)
    XCTAssertTrue(gate.update(cpuTotal: 0.5, thermalState: 0))
    XCTAssertFalse(gate.isActive)
    XCTAssertNil(gate.reason)
  }

  func testThermalActivatesImmediately() {
    var gate = SystemPresenceGate()
    XCTAssertTrue(gate.update(cpuTotal: 0.02, thermalState: 1))
    XCTAssertTrue(gate.isActive)
    XCTAssertEqual(gate.reason, .thermal)
  }

  func testThermalClearingDeactivatesAThermalActivation() {
    var gate = SystemPresenceGate()
    gate.update(cpuTotal: 0.02, thermalState: 2)
    XCTAssertTrue(gate.update(cpuTotal: 0.02, thermalState: 0))
    XCTAssertFalse(gate.isActive)
    XCTAssertNil(gate.reason)
  }

  func testThermalTakesOverACPUActivationAndReportsTheChange() {
    var gate = SystemPresenceGate()
    feed(&gate, cpu: 0.9, count: SystemPresenceGate.sustainSamples)
    // Still active, but the reason changed — the caller has to redraw the compact glyph.
    XCTAssertTrue(gate.update(cpuTotal: 0.9, thermalState: 1))
    XCTAssertTrue(gate.isActive)
    XCTAssertEqual(gate.reason, .thermal)
  }

  func testCPUMustReearnActivationAfterThermalClears() {
    var gate = SystemPresenceGate()
    feed(&gate, cpu: 0.9, count: SystemPresenceGate.sustainSamples)
    gate.update(cpuTotal: 0.9, thermalState: 1)
    XCTAssertTrue(gate.update(cpuTotal: 0.9, thermalState: 0))  // thermal cleared, drops out
    XCTAssertFalse(gate.isActive)
    feed(&gate, cpu: 0.9, count: SystemPresenceGate.sustainSamples - 2)
    XCTAssertFalse(gate.isActive)
    XCTAssertTrue(gate.update(cpuTotal: 0.9, thermalState: 0))
    XCTAssertTrue(gate.isActive)
    XCTAssertEqual(gate.reason, .cpu)
  }

  func testNilCPUHoldsCurrentState() {
    var gate = SystemPresenceGate()
    feed(&gate, cpu: 0.9, count: SystemPresenceGate.sustainSamples)
    XCTAssertFalse(gate.update(cpuTotal: nil, thermalState: 0))
    XCTAssertTrue(gate.isActive)
  }
}
