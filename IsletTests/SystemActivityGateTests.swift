import XCTest

@testable import Islet

final class SystemActivityGateTests: XCTestCase {

  private typealias Cadence = (name: String, interval: TimeInterval)

  private var systemCadences: [Cadence] {
    [
      (
        "automatic, live",
        EnergyPolicy(mode: .automatic, systemLowPowerMode: false)
          .systemInterval(viewIsLive: true)
      ),
      (
        "automatic, background",
        EnergyPolicy(mode: .automatic, systemLowPowerMode: false)
          .systemInterval(viewIsLive: false)
      ),
      (
        "automatic low power, live",
        EnergyPolicy(mode: .automatic, systemLowPowerMode: true)
          .systemInterval(viewIsLive: true)
      ),
      (
        "automatic low power, background",
        EnergyPolicy(mode: .automatic, systemLowPowerMode: true)
          .systemInterval(viewIsLive: false)
      ),
      (
        "low energy, live",
        EnergyPolicy(mode: .lowEnergy, systemLowPowerMode: false)
          .systemInterval(viewIsLive: true)
      ),
      (
        "low energy, background",
        EnergyPolicy(mode: .lowEnergy, systemLowPowerMode: false)
          .systemInterval(viewIsLive: false)
      ),
      (
        "live, live",
        EnergyPolicy(mode: .live, systemLowPowerMode: true)
          .systemInterval(viewIsLive: true)
      ),
      (
        "live, background",
        EnergyPolicy(mode: .live, systemLowPowerMode: true)
          .systemInterval(viewIsLive: false)
      ),
    ]
  }

  private func activate(_ gate: inout SystemPresenceGate, at start: TimeInterval = 0) {
    XCTAssertFalse(gate.update(cpuTotal: 0.9, thermalState: 0, uptime: start))
    XCTAssertTrue(
      gate.update(
        cpuTotal: 0.9, thermalState: 0,
        uptime: start + SystemPresenceGate.activationDuration))
  }

  func testFreshGateIsInactive() {
    let gate = SystemPresenceGate()
    XCTAssertFalse(gate.isActive)
    XCTAssertNil(gate.reason)
  }

  func testSustainedHighCPUActivatesAfterTheExplicitDuration() {
    var gate = SystemPresenceGate()
    XCTAssertFalse(gate.update(cpuTotal: 0.9, thermalState: 0, uptime: 10))
    XCTAssertFalse(
      gate.update(
        cpuTotal: 0.9, thermalState: 0,
        uptime: 10 + SystemPresenceGate.activationDuration - 0.001))
    XCTAssertTrue(
      gate.update(
        cpuTotal: 0.9, thermalState: 0,
        uptime: 10 + SystemPresenceGate.activationDuration))
    XCTAssertTrue(gate.isActive)
    XCTAssertEqual(gate.reason, .cpu)
  }

  func testActivationUsesElapsedTimeAtEveryEnergyPolicyCadence() {
    for cadence in systemCadences {
      var gate = SystemPresenceGate()
      var uptime: TimeInterval = 0
      XCTAssertFalse(
        gate.update(cpuTotal: 0.9, thermalState: 0, uptime: uptime),
        cadence.name)

      repeat {
        uptime += cadence.interval
        let changed = gate.update(cpuTotal: 0.9, thermalState: 0, uptime: uptime)
        if uptime < SystemPresenceGate.activationDuration {
          XCTAssertFalse(changed, cadence.name)
          XCTAssertFalse(gate.isActive, cadence.name)
        }
      } while uptime < SystemPresenceGate.activationDuration

      XCTAssertTrue(gate.isActive, cadence.name)
      XCTAssertEqual(gate.reason, .cpu, cadence.name)
    }
  }

  func testRecoveryUsesElapsedTimeAtEveryEnergyPolicyCadence() {
    for cadence in systemCadences {
      var gate = SystemPresenceGate()
      activate(&gate)
      var uptime = SystemPresenceGate.activationDuration
      XCTAssertFalse(gate.update(cpuTotal: 0.5, thermalState: 0, uptime: uptime), cadence.name)

      repeat {
        uptime += cadence.interval
        let changed = gate.update(cpuTotal: 0.5, thermalState: 0, uptime: uptime)
        if uptime < SystemPresenceGate.activationDuration + SystemPresenceGate.recoveryDuration {
          XCTAssertFalse(changed, cadence.name)
          XCTAssertTrue(gate.isActive, cadence.name)
        }
      } while uptime < SystemPresenceGate.activationDuration + SystemPresenceGate.recoveryDuration

      XCTAssertFalse(gate.isActive, cadence.name)
      XCTAssertNil(gate.reason, cadence.name)
    }
  }

  func testInterruptedHighDurationRestarts() {
    var gate = SystemPresenceGate()
    XCTAssertFalse(gate.update(cpuTotal: 0.9, thermalState: 0, uptime: 0))
    XCTAssertFalse(gate.update(cpuTotal: 0.7, thermalState: 0, uptime: 4))
    XCTAssertFalse(gate.update(cpuTotal: 0.9, thermalState: 0, uptime: 5))
    XCTAssertFalse(gate.update(cpuTotal: 0.9, thermalState: 0, uptime: 9.9))
    XCTAssertTrue(gate.update(cpuTotal: 0.9, thermalState: 0, uptime: 10))
  }

  func testHysteresisBandKeepsAnActiveGateActive() {
    var gate = SystemPresenceGate()
    activate(&gate)
    XCTAssertFalse(gate.update(cpuTotal: 0.7, thermalState: 0, uptime: 6))
    XCTAssertTrue(gate.isActive)
    XCTAssertEqual(gate.reason, .cpu)
  }

  func testFallingBelowReleaseThresholdDeactivatesAfterRecoveryDuration() {
    var gate = SystemPresenceGate()
    activate(&gate)
    XCTAssertFalse(gate.update(cpuTotal: 0.5, thermalState: 0, uptime: 6))
    XCTAssertTrue(gate.isActive)
    XCTAssertTrue(
      gate.update(
        cpuTotal: 0.5, thermalState: 0,
        uptime: 6 + SystemPresenceGate.recoveryDuration))
    XCTAssertFalse(gate.isActive)
    XCTAssertNil(gate.reason)
  }

  func testThermalActivatesImmediately() {
    var gate = SystemPresenceGate()
    XCTAssertTrue(gate.update(cpuTotal: 0.02, thermalState: 1, uptime: 0))
    XCTAssertTrue(gate.isActive)
    XCTAssertEqual(gate.reason, .thermal)
  }

  func testThermalClearingDeactivatesAThermalActivation() {
    var gate = SystemPresenceGate()
    _ = gate.update(cpuTotal: 0.02, thermalState: 2, uptime: 0)
    XCTAssertTrue(gate.update(cpuTotal: 0.02, thermalState: 0, uptime: 1))
    XCTAssertFalse(gate.isActive)
    XCTAssertNil(gate.reason)
  }

  func testThermalTakesOverACPUActivationAndReportsTheChange() {
    var gate = SystemPresenceGate()
    activate(&gate)
    XCTAssertTrue(gate.update(cpuTotal: 0.9, thermalState: 1, uptime: 6))
    XCTAssertTrue(gate.isActive)
    XCTAssertEqual(gate.reason, .thermal)
  }

  func testCPUMustReearnActivationAfterThermalClears() {
    var gate = SystemPresenceGate()
    activate(&gate)
    _ = gate.update(cpuTotal: 0.9, thermalState: 1, uptime: 6)
    XCTAssertTrue(gate.update(cpuTotal: 0.9, thermalState: 0, uptime: 7))
    XCTAssertFalse(gate.isActive)
    XCTAssertFalse(gate.update(cpuTotal: 0.9, thermalState: 0, uptime: 11.9))
    XCTAssertTrue(gate.update(cpuTotal: 0.9, thermalState: 0, uptime: 12))
    XCTAssertTrue(gate.isActive)
    XCTAssertEqual(gate.reason, .cpu)
  }

  func testNilCPUHoldsActiveStateButResetsPendingRecovery() {
    var gate = SystemPresenceGate()
    activate(&gate)
    _ = gate.update(cpuTotal: 0.5, thermalState: 0, uptime: 6)
    XCTAssertFalse(gate.update(cpuTotal: nil, thermalState: 0, uptime: 7))
    XCTAssertTrue(gate.isActive)
    XCTAssertFalse(gate.update(cpuTotal: 0.5, thermalState: 0, uptime: 11))
    XCTAssertTrue(gate.isActive)
    XCTAssertTrue(gate.update(cpuTotal: 0.5, thermalState: 0, uptime: 16))
    XCTAssertFalse(gate.isActive)
  }

  func testNilCPUResetsPendingActivation() {
    var gate = SystemPresenceGate()
    _ = gate.update(cpuTotal: 0.9, thermalState: 0, uptime: 0)
    _ = gate.update(cpuTotal: nil, thermalState: 0, uptime: 4)
    XCTAssertFalse(gate.update(cpuTotal: 0.9, thermalState: 0, uptime: 5))
    XCTAssertTrue(gate.update(cpuTotal: 0.9, thermalState: 0, uptime: 10))
  }

  func testLongGapClearsActiveCPUPresenceAndRestartsItsDuration() {
    var gate = SystemPresenceGate()
    activate(&gate)
    let afterGap = SystemPresenceGate.activationDuration + SystemPresenceGate.maximumSampleGap + 1
    XCTAssertTrue(gate.update(cpuTotal: 0.9, thermalState: 0, uptime: afterGap))
    XCTAssertFalse(gate.isActive)
    XCTAssertNil(gate.reason)
    XCTAssertFalse(
      gate.update(
        cpuTotal: 0.9, thermalState: 0,
        uptime: afterGap + SystemPresenceGate.activationDuration - 0.1))
    XCTAssertTrue(
      gate.update(
        cpuTotal: 0.9, thermalState: 0,
        uptime: afterGap + SystemPresenceGate.activationDuration))
  }

  func testLongGapResetsPendingActivation() {
    var gate = SystemPresenceGate()
    _ = gate.update(cpuTotal: 0.9, thermalState: 0, uptime: 0)
    let afterGap = SystemPresenceGate.maximumSampleGap + 1
    XCTAssertFalse(gate.update(cpuTotal: 0.9, thermalState: 0, uptime: afterGap))
    XCTAssertFalse(
      gate.update(
        cpuTotal: 0.9, thermalState: 0,
        uptime: afterGap + SystemPresenceGate.activationDuration - 0.1))
    XCTAssertTrue(
      gate.update(
        cpuTotal: 0.9, thermalState: 0,
        uptime: afterGap + SystemPresenceGate.activationDuration))
  }

  func testBackwardUptimeClearsActiveCPUPresenceAndRestartsItsDuration() {
    var gate = SystemPresenceGate()
    activate(&gate, at: 100)

    XCTAssertTrue(gate.update(cpuTotal: 0.9, thermalState: 0, uptime: 50))
    XCTAssertFalse(gate.isActive)
    XCTAssertNil(gate.reason)
    XCTAssertFalse(gate.update(cpuTotal: 0.9, thermalState: 0, uptime: 54.9))
    XCTAssertTrue(gate.update(cpuTotal: 0.9, thermalState: 0, uptime: 55))
    XCTAssertTrue(gate.isActive)
    XCTAssertEqual(gate.reason, .cpu)
  }
}
