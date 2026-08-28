import XCTest

@testable import Islet

final class SystemMetricsTests: XCTestCase {

  func testSamplingCadenceUsesASlowBackgroundBudget() {
    XCTAssertEqual(SystemMetricsMonitor.liveInterval, 1)
    XCTAssertGreaterThanOrEqual(SystemMetricsMonitor.backgroundInterval, 15)
    XCTAssertGreaterThan(
      SystemMetricsMonitor.lowPowerBackgroundInterval,
      SystemMetricsMonitor.backgroundInterval)
  }

  func testEnergyProfilesAreOrderedAndAutomaticFollowsLowPowerMode() {
    let automatic = EnergyPolicy(mode: .automatic, systemLowPowerMode: false)
    let automaticLowPower = EnergyPolicy(mode: .automatic, systemLowPowerMode: true)
    let lowEnergy = EnergyPolicy(mode: .lowEnergy, systemLowPowerMode: false)
    let live = EnergyPolicy(mode: .live, systemLowPowerMode: true)

    XCTAssertLessThan(
      live.systemInterval(viewIsLive: true), automatic.systemInterval(viewIsLive: true))
    XCTAssertGreaterThan(
      lowEnergy.systemInterval(viewIsLive: false), automatic.systemInterval(viewIsLive: false))
    XCTAssertEqual(automaticLowPower.systemInterval(viewIsLive: false), 30)
    XCTAssertTrue(automaticLowPower.isConstrained)
    XCTAssertFalse(automaticLowPower.allowsRemotePolling)
    XCTAssertTrue(live.allowsRemotePolling)
  }

  func testLowEnergySlowsBatteryAndT3EvenWhenMacOSLowPowerModeIsOff() {
    let automatic = EnergyPolicy(mode: .automatic, systemLowPowerMode: false)
    let lowEnergy = EnergyPolicy(mode: .lowEnergy, systemLowPowerMode: false)

    XCTAssertGreaterThan(
      lowEnergy.batteryInterval(viewIsLive: true),
      automatic.batteryInterval(viewIsLive: true))
    XCTAssertEqual(lowEnergy.t3PollInterval(busy: true, expanded: true), 30)
    XCTAssertGreaterThan(
      lowEnergy.tunnelPollingInterval, automatic.tunnelPollingInterval)
    XCTAssertFalse(lowEnergy.allowsRemotePolling)
  }

  // MARK: - Contract types

  func testMetricKindRawValuesAreStable() {
    // These raw values are the keys of Defaults[.metricStyles]; renaming one silently resets a
    // user's configured style, so they are locked here.
    XCTAssertEqual(
      SystemMetricKind.allCases.map(\.rawValue),
      ["cpu", "gpu", "memory", "disk", "network", "thermal"])
  }

  func testDisplayStyleRawValuesAreStable() {
    XCTAssertEqual(
      MetricDisplayStyle.allCases.map(\.rawValue),
      ["number", "numberAndBar", "sparkline", "sparklineAndNumber", "combined"])
  }

  func testResolveFallsBackForUnknownAndMissingRawValues() {
    XCTAssertEqual(MetricDisplayStyle.resolve("combined"), .combined)
    XCTAssertEqual(MetricDisplayStyle.resolve(nil), MetricDisplayStyle.fallback)
    XCTAssertEqual(MetricDisplayStyle.resolve("nonsense"), MetricDisplayStyle.fallback)
    XCTAssertEqual(MetricDisplayStyle.resolve(""), MetricDisplayStyle.fallback)
  }

  func testNeedsHistoryOnlyForSparklineStyles() {
    XCTAssertFalse(MetricDisplayStyle.number.needsHistory)
    XCTAssertFalse(MetricDisplayStyle.numberAndBar.needsHistory)
    XCTAssertTrue(MetricDisplayStyle.sparkline.needsHistory)
    XCTAssertTrue(MetricDisplayStyle.sparklineAndNumber.needsHistory)
    XCTAssertTrue(MetricDisplayStyle.combined.needsHistory)
  }

  func testThermalDegradesSparklineStylesToNumber() {
    // Thermal state is an enum with four values, not a series — a sparkline of it is noise.
    XCTAssertEqual(MetricDisplayStyle.effective(for: .thermal, requested: .sparkline), .number)
    XCTAssertEqual(
      MetricDisplayStyle.effective(for: .thermal, requested: .sparklineAndNumber), .number)
    XCTAssertEqual(
      MetricDisplayStyle.effective(for: .thermal, requested: .combined), .combined)
    XCTAssertEqual(
      MetricDisplayStyle.effective(for: .cpu, requested: .sparkline), .sparkline)
  }

  // MARK: - CPU tick deltas

  private func ticks(_ user: UInt32, _ system: UInt32, _ idle: UInt32, _ nice: UInt32 = 0)
    -> CPUTicks
  {
    CPUTicks(user: user, system: system, idle: idle, nice: nice)
  }

  func testCPUUtilisationHalfBusy() {
    let a = ticks(100, 100, 800)
    let b = ticks(150, 150, 900)  // busy +100, idle +100
    XCTAssertEqual(cpuUtilisation(from: a, to: b) ?? -1, 0.5, accuracy: 1e-9)
  }

  func testCPUUtilisationCountsNiceAsBusy() {
    let a = ticks(0, 0, 0, 0)
    let b = ticks(0, 0, 100, 100)  // 100 nice, 100 idle
    XCTAssertEqual(cpuUtilisation(from: a, to: b) ?? -1, 0.5, accuracy: 1e-9)
  }

  func testCPUUtilisationFullyIdle() {
    XCTAssertEqual(cpuUtilisation(from: ticks(5, 5, 5), to: ticks(5, 5, 105)) ?? -1, 0)
  }

  func testCPUUtilisationIsNilWhenNoTicksElapsed() {
    // A duplicate read must not render as 0% — it is not a measurement at all.
    XCTAssertNil(cpuUtilisation(from: ticks(9, 9, 9), to: ticks(9, 9, 9)))
  }

  func testCPUTickWraparoundIsHandled() {
    // The kernel hands these back as 32-bit counters. Widening before subtracting would produce a
    // ~4-billion-tick negative delta and a nonsense fraction.
    let a = ticks(UInt32.max - 49, 0, UInt32.max - 49)
    let b = ticks(50, 0, 50)  // each wrapped by 100
    XCTAssertEqual(cpuUtilisation(from: a, to: b) ?? -1, 0.5, accuracy: 1e-9)
  }

  func testCPUUtilisationOverAnIndexRange() {
    let old = [ticks(0, 0, 0), ticks(0, 0, 0), ticks(0, 0, 0), ticks(0, 0, 0)]
    let new = [ticks(100, 0, 0), ticks(100, 0, 0), ticks(0, 0, 100), ticks(0, 0, 100)]
    XCTAssertEqual(cpuUtilisation(from: old, to: new, indices: 0..<2) ?? -1, 1.0, accuracy: 1e-9)
    XCTAssertEqual(cpuUtilisation(from: old, to: new, indices: 2..<4) ?? -1, 0.0, accuracy: 1e-9)
    XCTAssertEqual(cpuUtilisation(from: old, to: new, indices: 0..<4) ?? -1, 0.5, accuracy: 1e-9)
  }

  func testCPUUtilisationIsNilForAnOutOfBoundsRange() {
    let old = [ticks(0, 0, 0)]
    let new = [ticks(100, 0, 100)]
    XCTAssertNil(cpuUtilisation(from: old, to: new, indices: 0..<2))
    XCTAssertNil(cpuUtilisation(from: old, to: new, indices: 0..<0))
  }

  func testCPUUtilisationIsNilForMismatchedArrayLengths() {
    // A core count change mid-run means the two snapshots cannot be differenced at all.
    XCTAssertNil(
      cpuUtilisation(from: [ticks(0, 0, 0)], to: [ticks(1, 1, 1), ticks(1, 1, 1)], indices: 0..<1))
  }

  // MARK: - Byte counter rates

  func testRatePerSecondForASimpleDelta() {
    XCTAssertEqual(
      ratePerSecond(from: 1000, to: 3000, elapsed: 2, width: .bits64) ?? -1, 1000,
      accuracy: 1e-9)
  }

  func testRateIsNilForZeroElapsed() {
    XCTAssertNil(ratePerSecond(from: 0, to: 100, elapsed: 0, width: .bits64))
  }

  func testRateIsNilForNegativeElapsed() {
    // A backwards clock must discard the sample, not divide by a negative.
    XCTAssertNil(ratePerSecond(from: 0, to: 100, elapsed: -1, width: .bits64))
  }

  func testRateIsNilWhenTheGapExceedsTheCeiling() {
    // Sleep/wake, or a stalled run loop. Rendering this delta would draw a huge fake spike.
    XCTAssertNil(
      ratePerSecond(
        from: 0, to: 5_000_000_000, elapsed: metricsMaxSampleGap + 0.001, width: .bits64))
  }

  func testRateAtExactlyTheGapCeilingIsAccepted() {
    XCTAssertEqual(
      ratePerSecond(from: 0, to: 100, elapsed: metricsMaxSampleGap, width: .bits64) ?? -1,
      100 / metricsMaxSampleGap, accuracy: 1e-9)
  }

  func testThirtyTwoBitCounterWraparound() {
    // getifaddrs' ifi_ibytes is UInt32 and wraps in ~34 s on a saturated 1 Gb/s link.
    // 4_294_967_000 + 1296 == 2^32 + 1000, so the true delta is 1296.
    XCTAssertEqual(
      ratePerSecond(from: 4_294_967_000, to: 1000, elapsed: 1, width: .bits32) ?? -1, 1296,
      accuracy: 1e-9)
  }

  func testSixtyFourBitCounterWraparound() {
    XCTAssertEqual(
      ratePerSecond(from: UInt64.max - 99, to: 100, elapsed: 1, width: .bits64) ?? -1, 200,
      accuracy: 1e-9)
  }

  func testThirtyTwoBitWidthTruncatesWideInputs() {
    // Inputs are widened to UInt64 at the call site; .bits32 must narrow both before subtracting.
    XCTAssertEqual(
      ratePerSecond(from: 0x1_0000_0000 + 500, to: 0x1_0000_0000 + 900, elapsed: 2, width: .bits32)
        ?? -1, 200, accuracy: 1e-9)
  }

  // MARK: - Ring buffer

  func testRingStartsEmpty() {
    let ring = MetricRing(capacity: 60)
    XCTAssertTrue(ring.values.isEmpty)
    XCTAssertNil(ring.latest)
    XCTAssertEqual(ring.capacity, 60)
  }

  func testPushKeepsInsertionOrder() {
    var ring = MetricRing(capacity: 4)
    ring.push(1)
    ring.push(2)
    ring.push(3)
    XCTAssertEqual(ring.values, [1, 2, 3])
  }

  func testPushOverwritesOldestOnceFull() {
    var ring = MetricRing(capacity: 3)
    for v in [1.0, 2, 3, 4, 5] { ring.push(v) }
    XCTAssertEqual(ring.values, [3, 4, 5])
    XCTAssertEqual(ring.values.count, ring.capacity)
  }

  func testCapacityOfOneKeepsOnlyTheNewest() {
    var ring = MetricRing(capacity: 1)
    ring.push(7)
    ring.push(8)
    XCTAssertEqual(ring.values, [8])
  }

  func testNonPositiveCapacityClampsToOne() {
    var ring = MetricRing(capacity: 0)
    XCTAssertEqual(ring.capacity, 1)
    ring.push(3)
    ring.push(4)
    XCTAssertEqual(ring.values, [4])
    XCTAssertEqual(MetricRing(capacity: -5).capacity, 1)
  }

  func testLatestIsTheMostRecentPush() {
    var ring = MetricRing(capacity: 60)
    ring.push(0.1)
    ring.push(0.9)
    XCTAssertEqual(ring.latest, 0.9)
  }

  // MARK: - Sparkline normalisation

  func testEmptySeriesHasNoPoints() {
    XCTAssertTrue(sparklinePoints([], scale: .fixed(min: 0, max: 1)).isEmpty)
    XCTAssertTrue(sparklinePoints([], scale: .auto).isEmpty)
  }

  func testSingleSampleDrawsAFlatLineAcrossTheFullWidth() {
    // One reading cannot describe a slope. Two points at the same height is the honest render;
    // a single point would draw nothing at all.
    let points = sparklinePoints([0.25], scale: .fixed(min: 0, max: 1))
    XCTAssertEqual(points.count, 2)
    XCTAssertEqual(points[0].x, 0, accuracy: 1e-9)
    XCTAssertEqual(points[1].x, 1, accuracy: 1e-9)
    XCTAssertEqual(points[0].y, 0.25, accuracy: 1e-9)
    XCTAssertEqual(points[1].y, 0.25, accuracy: 1e-9)
  }

  func testXCoordinatesSpanZeroToOne() {
    let points = sparklinePoints([0, 0.5, 1, 0.5, 0], scale: .fixed(min: 0, max: 1))
    XCTAssertEqual(points.map(\.x), [0, 0.25, 0.5, 0.75, 1])
  }

  func testFixedScaleNormalisesToTheGivenRange() {
    let points = sparklinePoints([10, 20, 30], scale: .fixed(min: 10, max: 30))
    XCTAssertEqual(points.map(\.y), [0, 0.5, 1])
  }

  func testFixedScaleClampsOutOfRangeValues() {
    let points = sparklinePoints([-5, 0.5, 42], scale: .fixed(min: 0, max: 1))
    XCTAssertEqual(points.map(\.y), [0, 0.5, 1])
  }

  func testFixedScaleWithACollapsedRangeSitsAtMidHeight() {
    let points = sparklinePoints([3, 3, 3], scale: .fixed(min: 5, max: 5))
    XCTAssertEqual(points.map(\.y), [0.5, 0.5, 0.5])
  }

  func testAutoScaleStretchesToTheSeriesExtremes() {
    let points = sparklinePoints([100, 150, 200], scale: .auto)
    XCTAssertEqual(points.map(\.y), [0, 0.5, 1])
  }

  func testAutoScaleWithAllEqualValuesSitsAtMidHeight() {
    // Auto-scaling a flat series would otherwise divide by zero or pin every point to the top.
    let points = sparklinePoints([7, 7, 7, 7], scale: .auto)
    XCTAssertEqual(points.map(\.y), [0.5, 0.5, 0.5, 0.5])
  }

  // MARK: - CPU topology

  func testTwoLevelSplitPutsEfficiencyAtTheStartOfTheArray() {
    // host_processor_info orders the LEAST performant cluster first — verified empirically on
    // M3 Pro, where a .background-QoS spin saturates indices 0...5 and hw.perflevel1 is
    // "Efficiency". Ranges are returned most-performant-first for display.
    let clusters = CPUTopology.clusters(
      perfLevels: [
        PerfLevel(name: "Performance", logicalCPUs: 6),
        PerfLevel(name: "Efficiency", logicalCPUs: 6),
      ],
      totalCores: 12)
    XCTAssertEqual(
      clusters,
      [
        CPUCluster(perfLevelIndex: 0, name: "Performance", range: 6..<12),
        CPUCluster(perfLevelIndex: 1, name: "Efficiency", range: 0..<6),
      ])
    XCTAssertTrue(clusters[0].isPerformance)
    XCTAssertFalse(clusters[1].isPerformance)
  }

  func testThreeLevelSplitAssignsFromLeastPerformant() {
    let clusters = CPUTopology.clusters(
      perfLevels: [
        PerfLevel(name: "A", logicalCPUs: 4), PerfLevel(name: "B", logicalCPUs: 4),
        PerfLevel(name: "C", logicalCPUs: 4),
      ],
      totalCores: 12)
    XCTAssertEqual(clusters.map(\.range), [8..<12, 4..<8, 0..<4])
    XCTAssertEqual(clusters.map(\.name), ["A", "B", "C"])
  }

  func testMismatchedCoreCountDegradesToNoSplit() {
    // The counts not summing to the array length means the index ranges cannot be established.
    // Degrade to total-only rather than mislabel half the cores.
    XCTAssertTrue(
      CPUTopology.clusters(
        perfLevels: [
          PerfLevel(name: "Performance", logicalCPUs: 6),
          PerfLevel(name: "Efficiency", logicalCPUs: 4),
        ],
        totalCores: 12
      ).isEmpty)
  }

  func testSingleLevelDegradesToNoSplit() {
    XCTAssertTrue(
      CPUTopology.clusters(
        perfLevels: [PerfLevel(name: "Performance", logicalCPUs: 8)], totalCores: 8
      ).isEmpty)
  }

  func testEmptyLevelsDegradeToNoSplit() {
    XCTAssertTrue(CPUTopology.clusters(perfLevels: [], totalCores: 12).isEmpty)
  }

  func testZeroSizedLevelDegradesToNoSplit() {
    XCTAssertTrue(
      CPUTopology.clusters(
        perfLevels: [
          PerfLevel(name: "Performance", logicalCPUs: 12),
          PerfLevel(name: "Efficiency", logicalCPUs: 0),
        ],
        totalCores: 12
      ).isEmpty)
  }

  // MARK: - Live reader sanity

  func testCPUTicksReturnsOnePerLogicalCore() {
    let ticks = SystemMetricsReader.cpuTicks()
    XCTAssertFalse(ticks.isEmpty)
    XCTAssertEqual(ticks.count, ProcessInfo.processInfo.processorCount)
  }

  func testMemorySnapshotIsPlausible() {
    guard let memory = SystemMetricsReader.memory() else {
      return XCTFail("host_statistics64 returned nothing")
    }
    XCTAssertGreaterThan(memory.totalBytes, 0)
    XCTAssertGreaterThan(memory.usedBytes, 0)
    XCTAssertLessThanOrEqual(memory.usedBytes, memory.totalBytes)
    XCTAssertLessThanOrEqual(memory.wiredBytes, memory.usedBytes)
  }

  func testThermalStateIsAValidRawValue() {
    XCTAssertTrue((0...3).contains(SystemMetricsReader.thermalState()))
  }

  // MARK: - Sample building

  private func raw(
    cpu: [CPUTicks] = [], disk: DiskCounters? = nil, network: NetworkCounters? = nil
  ) -> RawCounters {
    RawCounters(
      cpu: cpu,
      memory: MemorySnapshot(
        usedBytes: 8_000_000_000, totalBytes: 16_000_000_000,
        wiredBytes: 2_000_000_000, compressedBytes: 1_000_000_000),
      memoryPressureLevel: 1,
      swapUsedBytes: 12_582_912,
      loadAverage: 3.51,
      gpu: 0.12,
      disk: disk,
      diskFreeBytes: 412_000_000_000,
      network: network,
      thermalState: 0,
      batteryTemperatureC: 30.56)
  }

  func testLevelsArePresentEvenWithoutAPreviousSample() {
    let now = Date()
    let sample = systemMetricsSample(
      previous: nil, previousDate: nil, current: raw(), currentDate: now, clusters: [])
    XCTAssertEqual(sample.memoryUsedBytes, 8_000_000_000)
    XCTAssertEqual(sample.memoryTotalBytes, 16_000_000_000)
    XCTAssertEqual(sample.gpu, 0.12)
    XCTAssertEqual(sample.loadAverage, 3.51)
    XCTAssertEqual(sample.thermalState, 0)
    XCTAssertEqual(sample.diskFreeBytes, 412_000_000_000)
    XCTAssertEqual(sample.swapUsedBytes, 12_582_912)
    XCTAssertEqual(sample.memoryPressureLevel, 1)
    XCTAssertEqual(sample.batteryTemperatureC, 30.56)
  }

  func testFirstSampleHasNoRates() {
    let now = Date()
    let sample = systemMetricsSample(
      previous: nil, previousDate: nil,
      current: raw(
        cpu: [CPUTicks(user: 1, system: 1, idle: 1, nice: 0)],
        disk: DiskCounters(readBytes: 100, writeBytes: 100),
        network: NetworkCounters(inBytes: 100, outBytes: 100, interface: "en0")),
      currentDate: now, clusters: [])
    XCTAssertNil(sample.cpuTotal)
    XCTAssertNil(sample.diskReadBytesPerSec)
    XCTAssertNil(sample.netInBytesPerSec)
    XCTAssertEqual(sample.primaryInterface, "en0")
  }

  func testGapLongerThanTheCeilingDiscardsRates() {
    let then = Date()
    let now = then.addingTimeInterval(metricsMaxSampleGap + 1)
    let sample = systemMetricsSample(
      previous: raw(
        cpu: [CPUTicks(user: 0, system: 0, idle: 0, nice: 0)],
        disk: DiskCounters(readBytes: 0, writeBytes: 0),
        network: NetworkCounters(inBytes: 0, outBytes: 0, interface: "en0")),
      previousDate: then,
      current: raw(
        cpu: [CPUTicks(user: 500, system: 0, idle: 500, nice: 0)],
        disk: DiskCounters(readBytes: 9_000_000_000, writeBytes: 9_000_000_000),
        network: NetworkCounters(inBytes: 900_000, outBytes: 900_000, interface: "en0")),
      currentDate: now, clusters: [])
    XCTAssertNil(sample.cpuTotal)
    XCTAssertNil(sample.diskReadBytesPerSec)
    XCTAssertNil(sample.diskWriteBytesPerSec)
    XCTAssertNil(sample.netInBytesPerSec)
    XCTAssertNil(sample.netOutBytesPerSec)
    // Levels survive a gap — only rates are meaningless.
    XCTAssertEqual(sample.gpu, 0.12)
  }

  func testNormalDeltaProducesDiskAndNetworkRates() {
    let then = Date()
    let now = then.addingTimeInterval(2)
    let sample = systemMetricsSample(
      previous: raw(
        disk: DiskCounters(readBytes: 1_000, writeBytes: 2_000),
        network: NetworkCounters(inBytes: 4_000, outBytes: 8_000, interface: "en0")),
      previousDate: then,
      current: raw(
        disk: DiskCounters(readBytes: 3_000, writeBytes: 2_400),
        network: NetworkCounters(inBytes: 4_200, outBytes: 8_600, interface: "en0")),
      currentDate: now, clusters: [])
    XCTAssertEqual(sample.diskReadBytesPerSec ?? -1, 1000, accuracy: 1e-9)
    XCTAssertEqual(sample.diskWriteBytesPerSec ?? -1, 200, accuracy: 1e-9)
    XCTAssertEqual(sample.netInBytesPerSec ?? -1, 100, accuracy: 1e-9)
    XCTAssertEqual(sample.netOutBytesPerSec ?? -1, 300, accuracy: 1e-9)
  }

  func testInterfaceChangeDiscardsNetworkRates() {
    // Wi-Fi to Ethernet: the two counters belong to different NICs and cannot be differenced.
    let then = Date()
    let sample = systemMetricsSample(
      previous: raw(network: NetworkCounters(inBytes: 9_000, outBytes: 9_000, interface: "en0")),
      previousDate: then,
      current: raw(network: NetworkCounters(inBytes: 10, outBytes: 10, interface: "en6")),
      currentDate: then.addingTimeInterval(1), clusters: [])
    XCTAssertNil(sample.netInBytesPerSec)
    XCTAssertNil(sample.netOutBytesPerSec)
    XCTAssertEqual(sample.primaryInterface, "en6")
  }

  func testClusterUtilisationsAreSplitByRange() {
    let then = Date()
    let idle = CPUTicks(user: 0, system: 0, idle: 0, nice: 0)
    let busy = CPUTicks(user: 100, system: 0, idle: 0, nice: 0)
    let quiet = CPUTicks(user: 0, system: 0, idle: 100, nice: 0)
    let sample = systemMetricsSample(
      previous: raw(cpu: [idle, idle, idle, idle]),
      previousDate: then,
      current: raw(cpu: [quiet, quiet, busy, busy]),
      currentDate: then.addingTimeInterval(1),
      clusters: [
        CPUCluster(perfLevelIndex: 0, name: "Performance", range: 2..<4),
        CPUCluster(perfLevelIndex: 1, name: "Efficiency", range: 0..<2),
      ])
    XCTAssertEqual(sample.cpuTotal ?? -1, 0.5, accuracy: 1e-9)
    XCTAssertEqual(sample.cpuPerformance ?? -1, 1.0, accuracy: 1e-9)
    XCTAssertEqual(sample.cpuEfficiency ?? -1, 0.0, accuracy: 1e-9)
  }
}
