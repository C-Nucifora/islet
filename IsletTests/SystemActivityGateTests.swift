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

  private func sample(
    cpu: Double? = 0, thermal: Int? = 0, memoryPressure: Int? = 1,
    diskFree: UInt64? = 20_000_000_000, disk: Double? = 0, network: Double? = 0
  ) -> SystemMetricsSample {
    SystemMetricsSample(
      cpuTotal: cpu, memoryPressureLevel: memoryPressure,
      diskReadBytesPerSec: disk.map { $0 / 2 }, diskWriteBytesPerSec: disk.map { $0 / 2 },
      diskFreeBytes: diskFree, netInBytesPerSec: network.map { $0 / 2 },
      netOutBytesPerSec: network.map { $0 / 2 }, thermalState: thermal)
  }

  @discardableResult
  private func update(
    _ gate: inout SystemPresenceGate, _ sample: SystemMetricsSample,
    controls: SystemPresenceGate.Controls = .init(), uptime: TimeInterval
  ) -> Bool {
    gate.update(sample: sample, controls: controls, uptime: uptime)
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

  func testCPUResumesAsTheReasonAfterThermalClears() {
    var gate = SystemPresenceGate()
    activate(&gate)
    _ = gate.update(cpuTotal: 0.9, thermalState: 1, uptime: 6)
    XCTAssertTrue(gate.update(cpuTotal: 0.9, thermalState: 0, uptime: 7))
    XCTAssertTrue(gate.isActive)
    XCTAssertEqual(gate.reason, .cpu)
  }

  func testMemoryPressureUsesTheKernelLevelAndSustainedRecovery() {
    var gate = SystemPresenceGate()
    let pressured = sample(memoryPressure: SystemPresenceGate.activateMemoryPressureLevel)
    XCTAssertFalse(update(&gate, pressured, uptime: 0))
    XCTAssertFalse(
      update(
        &gate, pressured, uptime: SystemPresenceGate.memoryActivationDuration - 0.1))
    XCTAssertTrue(update(&gate, pressured, uptime: SystemPresenceGate.memoryActivationDuration))
    XCTAssertEqual(gate.reason, .memoryPressure)

    let normal = sample(memoryPressure: SystemPresenceGate.deactivateMemoryPressureLevel)
    XCTAssertFalse(update(&gate, normal, uptime: 21))
    XCTAssertFalse(update(&gate, pressured, uptime: 50))
    XCTAssertFalse(update(&gate, normal, uptime: 51))
    XCTAssertTrue(
      update(&gate, normal, uptime: 51 + SystemPresenceGate.memoryRecoveryDuration))
    XCTAssertFalse(gate.isActive)
  }

  func testLowDiskSpaceUsesAnAbsoluteFloorAndWideHysteresisBand() {
    var gate = SystemPresenceGate()
    let low = sample(diskFree: SystemPresenceGate.activateDiskFreeBytes)
    XCTAssertFalse(update(&gate, low, uptime: 0))
    XCTAssertTrue(update(&gate, low, uptime: SystemPresenceGate.lowDiskActivationDuration))
    XCTAssertEqual(gate.reason, .lowDiskSpace)

    let band = sample(diskFree: 12_000_000_000)
    XCTAssertFalse(update(&gate, band, uptime: 61))
    XCTAssertEqual(gate.reason, .lowDiskSpace)

    let recovered = sample(diskFree: SystemPresenceGate.deactivateDiskFreeBytes)
    XCTAssertFalse(update(&gate, recovered, uptime: 62))
    XCTAssertFalse(update(&gate, recovered, uptime: 122))
    XCTAssertTrue(
      update(&gate, recovered, uptime: 62 + SystemPresenceGate.lowDiskRecoveryDuration))
    XCTAssertFalse(gate.isActive)
  }

  func testHeavyDiskThroughputIsSustainedAndHasRateHysteresis() {
    var gate = SystemPresenceGate()
    let heavy = sample(disk: SystemPresenceGate.activateDiskBytesPerSecond)
    XCTAssertFalse(update(&gate, heavy, uptime: 0))
    XCTAssertTrue(update(&gate, heavy, uptime: SystemPresenceGate.diskActivationDuration))
    XCTAssertEqual(gate.reason, .diskThroughput)

    let band = sample(disk: 400_000_000)
    XCTAssertFalse(update(&gate, band, uptime: 21))
    XCTAssertEqual(gate.reason, .diskThroughput)

    let quiet = sample(disk: SystemPresenceGate.deactivateDiskBytesPerSecond)
    XCTAssertFalse(update(&gate, quiet, uptime: 22))
    XCTAssertTrue(
      update(&gate, quiet, uptime: 22 + SystemPresenceGate.diskRecoveryDuration))
    XCTAssertFalse(gate.isActive)
  }

  func testHighNetworkThroughputIsSustainedAndHasRateHysteresis() {
    var gate = SystemPresenceGate()
    let high = sample(network: SystemPresenceGate.activateNetworkBytesPerSecond)
    XCTAssertFalse(update(&gate, high, uptime: 0))
    XCTAssertTrue(update(&gate, high, uptime: SystemPresenceGate.networkActivationDuration))
    XCTAssertEqual(gate.reason, .networkThroughput)

    let band = sample(network: 65_000_000)
    XCTAssertFalse(update(&gate, band, uptime: 21))
    XCTAssertEqual(gate.reason, .networkThroughput)

    let quiet = sample(network: SystemPresenceGate.deactivateNetworkBytesPerSecond)
    XCTAssertFalse(update(&gate, quiet, uptime: 22))
    XCTAssertTrue(
      update(&gate, quiet, uptime: 22 + SystemPresenceGate.networkRecoveryDuration))
    XCTAssertFalse(gate.isActive)
  }

  func testEveryTriggerCanBeDisabledIndependently() {
    let cases: [(SystemMetricsSample, SystemPresenceGate.Controls, TimeInterval)] = [
      (sample(cpu: 1), .init(cpu: false), SystemPresenceGate.cpuActivationDuration),
      (sample(thermal: 3), .init(thermal: false), 0),
      (
        sample(memoryPressure: 4), .init(memoryPressure: false),
        SystemPresenceGate.memoryActivationDuration
      ),
      (
        sample(diskFree: 0), .init(lowDiskSpace: false),
        SystemPresenceGate.lowDiskActivationDuration
      ),
      (
        sample(disk: 1_000_000_000), .init(diskThroughput: false),
        SystemPresenceGate.diskActivationDuration
      ),
      (
        sample(network: 1_000_000_000), .init(networkThroughput: false),
        SystemPresenceGate.networkActivationDuration
      ),
    ]

    for (triggeringSample, controls, duration) in cases {
      var gate = SystemPresenceGate()
      XCTAssertFalse(update(&gate, triggeringSample, controls: controls, uptime: 0))
      XCTAssertFalse(update(&gate, triggeringSample, controls: controls, uptime: duration))
      XCTAssertFalse(gate.isActive)
    }
  }

  func testDisablingTheActiveTriggerRemovesItImmediately() {
    var gate = SystemPresenceGate()
    let highCPU = sample(cpu: 1)
    XCTAssertFalse(update(&gate, highCPU, uptime: 0))
    XCTAssertTrue(update(&gate, highCPU, uptime: SystemPresenceGate.cpuActivationDuration))

    XCTAssertTrue(gate.update(controls: .init(cpu: false)))
    XCTAssertFalse(gate.isActive)
    XCTAssertNil(gate.reason)
  }

  func testControlOnlyUpdateDoesNotAdvancePendingActivation() {
    var gate = SystemPresenceGate()
    let highCPU = sample(cpu: 1)
    let controls = SystemPresenceGate.Controls(networkThroughput: false)

    XCTAssertFalse(update(&gate, highCPU, controls: controls, uptime: 0))
    XCTAssertFalse(gate.update(controls: controls))
    XCTAssertFalse(gate.isActive)
    XCTAssertTrue(
      update(
        &gate, highCPU, controls: controls,
        uptime: SystemPresenceGate.cpuActivationDuration))
  }

  func testControlOnlyUpdateDoesNotAdvancePendingRecovery() {
    var gate = SystemPresenceGate()
    activate(&gate)
    let lowCPU = sample(cpu: SystemPresenceGate.deactivateCPU)
    let controls = SystemPresenceGate.Controls(networkThroughput: false)

    XCTAssertFalse(update(&gate, lowCPU, controls: controls, uptime: 6))
    XCTAssertFalse(gate.update(controls: controls))
    XCTAssertTrue(gate.isActive)
    XCTAssertTrue(
      update(
        &gate, lowCPU, controls: controls,
        uptime: 6 + SystemPresenceGate.cpuRecoveryDuration))
  }

  func testSimultaneousConditionsChoosePriorityAndRecoverToTheNextReason() {
    var gate = SystemPresenceGate()
    let allHigh = sample(
      cpu: 1, thermal: 0, memoryPressure: 4,
      diskFree: SystemPresenceGate.activateDiskFreeBytes,
      disk: SystemPresenceGate.activateDiskBytesPerSecond,
      network: SystemPresenceGate.activateNetworkBytesPerSecond)

    XCTAssertFalse(update(&gate, allHigh, uptime: 0))
    XCTAssertTrue(update(&gate, allHigh, uptime: 5))
    XCTAssertEqual(gate.reason, .cpu)
    XCTAssertTrue(update(&gate, allHigh, uptime: 20))
    XCTAssertEqual(gate.reason, .memoryPressure)
    XCTAssertFalse(update(&gate, allHigh, uptime: 60))

    var thermalHigh = allHigh
    thermalHigh.thermalState = 2
    XCTAssertTrue(update(&gate, thermalHigh, uptime: 61))
    XCTAssertEqual(gate.reason, .thermal)

    var recovering = allHigh
    recovering.thermalState = 0
    recovering.memoryPressureLevel = 1
    recovering.diskReadBytesPerSec = 0
    recovering.diskWriteBytesPerSec = 0
    recovering.netInBytesPerSec = 0
    recovering.netOutBytesPerSec = 0
    XCTAssertTrue(update(&gate, recovering, uptime: 62))
    XCTAssertEqual(gate.reason, .memoryPressure)
    XCTAssertTrue(update(&gate, recovering, uptime: 122))
    XCTAssertEqual(gate.reason, .lowDiskSpace)

    recovering.diskFreeBytes = SystemPresenceGate.deactivateDiskFreeBytes
    XCTAssertFalse(update(&gate, recovering, uptime: 123))
    XCTAssertFalse(update(&gate, recovering, uptime: 183))
    XCTAssertTrue(update(&gate, recovering, uptime: 243))
    XCTAssertEqual(gate.reason, .cpu)

    recovering.cpuTotal = SystemPresenceGate.deactivateCPU
    XCTAssertFalse(update(&gate, recovering, uptime: 244))
    XCTAssertTrue(update(&gate, recovering, uptime: 249))
    XCTAssertFalse(gate.isActive)
    XCTAssertNil(gate.reason)
  }

  func testReasonPriorityIsExplicitAndStable() {
    XCTAssertEqual(
      SystemPresenceGate.Reason.allCases.sorted { $0.priority > $1.priority },
      [.thermal, .memoryPressure, .lowDiskSpace, .cpu, .diskThroughput, .networkThroughput])
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

  func testActivePressureExpiresAfterABoundedRunOfMissingSamples() {
    var gate = SystemPresenceGate()
    activate(&gate)
    let firstMissing = SystemPresenceGate.activationDuration + 1

    XCTAssertFalse(gate.update(cpuTotal: nil, thermalState: 0, uptime: firstMissing))
    XCTAssertTrue(gate.isActive)
    XCTAssertFalse(
      gate.update(
        cpuTotal: nil, thermalState: 0,
        uptime: firstMissing + SystemPresenceGate.maximumSampleGap - 0.1))
    XCTAssertTrue(gate.isActive)
    XCTAssertTrue(
      gate.update(
        cpuTotal: nil, thermalState: 0,
        uptime: firstMissing + SystemPresenceGate.maximumSampleGap))
    XCTAssertFalse(gate.isActive)
    XCTAssertNil(gate.reason)
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
