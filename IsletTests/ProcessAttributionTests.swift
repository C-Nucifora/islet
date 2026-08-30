import Defaults
import XCTest

@testable import Islet

final class ProcessAttributionTests: XCTestCase {
  private let thresholds = ProcessAttributionThresholds(
    cpuFraction: 0.8, memoryFraction: 0.9, diskBytesPerSecond: 50_000_000,
    networkBytesPerSecond: 25_000_000)

  func testTriggerFiresOnInitialHighValueAndOnlyOnceUntilRecovery() {
    var trigger = ProcessAttributionTrigger()
    var sample = SystemMetricsSample()
    sample.cpuTotal = 0.81

    XCTAssertEqual(trigger.observe(sample, thresholds: thresholds), [.cpu])
    XCTAssertTrue(trigger.observe(sample, thresholds: thresholds).isEmpty)

    sample.cpuTotal = 0.79
    XCTAssertTrue(trigger.observe(sample, thresholds: thresholds).isEmpty)
    sample.cpuTotal = 0.8
    XCTAssertEqual(trigger.observe(sample, thresholds: thresholds), [.cpu])
  }

  func testTriggerTreatsMetricsIndependently() {
    var trigger = ProcessAttributionTrigger()
    var sample = SystemMetricsSample()
    sample.cpuTotal = 0.9
    sample.memoryUsedBytes = 90
    sample.memoryTotalBytes = 100
    sample.diskReadBytesPerSec = 30_000_000
    sample.diskWriteBytesPerSec = 20_000_000
    sample.netInBytesPerSec = 20_000_000
    sample.netOutBytesPerSec = 5_000_000

    XCTAssertEqual(trigger.observe(sample, thresholds: thresholds), Set(ProcessMetricKind.allCases))
  }

  func testMissingMetricDoesNotInventACrossingOrEraseItsState() {
    var trigger = ProcessAttributionTrigger()
    var sample = SystemMetricsSample()
    sample.cpuTotal = 0.9
    XCTAssertEqual(trigger.observe(sample, thresholds: thresholds), [.cpu])
    sample.cpuTotal = nil
    XCTAssertTrue(trigger.observe(sample, thresholds: thresholds).isEmpty)
    sample.cpuTotal = 0.9
    XCTAssertTrue(trigger.observe(sample, thresholds: thresholds).isEmpty)
  }

  func testResetLetsAVisibleViewSnapshotAnExistingSpike() {
    var trigger = ProcessAttributionTrigger()
    var sample = SystemMetricsSample()
    sample.cpuTotal = 0.9
    XCTAssertEqual(trigger.observe(sample, thresholds: thresholds), [.cpu])
    trigger.reset()
    XCTAssertEqual(trigger.observe(sample, thresholds: thresholds), [.cpu])
  }

  func testSnapshotsRankCPUAndDiskDeltasAndMemoryLevel() throws {
    let baseline = capture(
      at: 10,
      usages: [
        usage(pid: 1, cpu: 1_000_000_000, memory: 100, disk: 1_000),
        usage(pid: 2, cpu: 2_000_000_000, memory: 400, disk: 2_000),
      ])
    let final = capture(
      at: 12,
      usages: [
        usage(pid: 1, cpu: 2_000_000_000, memory: 500, disk: 5_000),
        usage(pid: 2, cpu: 2_500_000_000, memory: 200, disk: 12_000),
      ])

    let result = ProcessAttributionMath.snapshots(
      for: [.cpu, .memory, .disk], baseline: baseline, final: final,
      capturedAt: Date(timeIntervalSince1970: 20))

    XCTAssertEqual(try XCTUnwrap(result[.cpu]).entries.map(\.pid), [1, 2])
    XCTAssertEqual(try XCTUnwrap(result[.cpu]).entries[0].value, 0.5, accuracy: 1e-9)
    XCTAssertEqual(try XCTUnwrap(result[.memory]).entries.map(\.pid), [1, 2])
    XCTAssertEqual(try XCTUnwrap(result[.memory]).entries[0].value, 500)
    XCTAssertEqual(try XCTUnwrap(result[.disk]).entries.map(\.pid), [2, 1])
    XCTAssertEqual(try XCTUnwrap(result[.disk]).entries[0].value, 5_000, accuracy: 1e-9)
  }

  func testSnapshotIsCappedAndTieBreaksByPID() throws {
    let usages = (1...5).map { usage(pid: pid_t($0), memory: 100) }
    let capture = capture(at: 1, usages: usages)
    let snapshot = try XCTUnwrap(
      ProcessAttributionMath.snapshots(
        for: [.memory], baseline: capture, final: capture, capturedAt: Date())[.memory])
    XCTAssertEqual(snapshot.entries.map(\.pid), [1, 2, 3])
  }

  func testPIDReuseIsNotTreatedAsTheSameProcess() throws {
    let old = usage(pid: 42, startTime: 100, cpu: 1_000_000_000)
    let replacement = usage(pid: 42, startTime: 200, cpu: 9_000_000_000)
    let snapshot = try XCTUnwrap(
      ProcessAttributionMath.snapshots(
        for: [.cpu], baseline: capture(at: 1, usages: [old]),
        final: capture(at: 2, usages: [replacement]), capturedAt: Date())[.cpu])
    XCTAssertTrue(snapshot.entries.isEmpty)
  }

  func testCounterRegressionDoesNotProduceAHugeFalseAttribution() throws {
    let old = usage(pid: 42, cpu: 9_000_000_000, disk: 9_000)
    let reset = usage(pid: 42, cpu: 1_000_000_000, disk: 1_000)
    let snapshots = ProcessAttributionMath.snapshots(
      for: [.cpu, .disk], baseline: capture(at: 1, usages: [old]),
      final: capture(at: 2, usages: [reset]), capturedAt: Date())

    XCTAssertTrue(try XCTUnwrap(snapshots[.cpu]).entries.isEmpty)
    XCTAssertTrue(try XCTUnwrap(snapshots[.disk]).entries.isEmpty)
  }

  func testTerminatedAndUnreadableProcessesProduceAPartialResult() throws {
    let baseline = capture(
      at: 1, usages: [usage(pid: 1), usage(pid: 2)], unreadableCount: 3)
    let final = capture(at: 2, usages: [usage(pid: 1, memory: 100)], unreadableCount: 4)
    let snapshot = try XCTUnwrap(
      ProcessAttributionMath.snapshots(
        for: [.memory], baseline: baseline, final: final, capturedAt: Date())[.memory])
    XCTAssertEqual(snapshot.availability, .partial(unreadableCount: 4, exitedCount: 1))
  }

  func testNetworkAttributionExplainsWhyItIsUnavailable() throws {
    let empty = capture(at: 1, usages: [])
    let snapshot = try XCTUnwrap(
      ProcessAttributionMath.snapshots(
        for: [.network], baseline: empty, final: empty, capturedAt: Date())[.network])
    XCTAssertTrue(snapshot.entries.isEmpty)
    guard case .unsupported(let reason) = snapshot.availability else {
      return XCTFail("Expected an unsupported network snapshot")
    }
    XCTAssertTrue(reason.contains("reliable per-process network"))
  }

  @MainActor
  func testMonitorDoesNotCaptureWhileHiddenAndUsesOneBoundedWindowPerCrossing() async {
    let savedEnabled = Defaults[.processAttributionEnabled]
    let savedThreshold = Defaults[.processCPUThreshold]
    defer {
      Defaults[.processAttributionEnabled] = savedEnabled
      Defaults[.processCPUThreshold] = savedThreshold
    }
    Defaults[.processAttributionEnabled] = true
    Defaults[.processCPUThreshold] = 0.8

    let captures = ProcessCaptureStub([
      capture(at: 1, usages: [usage(pid: 1, cpu: 1_000_000_000)]),
      capture(at: 2, usages: [usage(pid: 1, cpu: 2_000_000_000)]),
    ])
    let monitor = ProcessAttributionMonitor(
      usageCapture: { await captures.next() }, sampleDelay: {})
    var sample = SystemMetricsSample()
    sample.cpuTotal = 0.9

    monitor.observe(sample)
    await Task.yield()
    let hiddenCaptureCount = await captures.count
    XCTAssertEqual(hiddenCaptureCount, 0)

    monitor.setVisible(true)
    monitor.observe(sample)
    for _ in 0..<100 {
      if await captures.count >= 2 { break }
      await Task.yield()
    }
    let completedCaptureCount = await captures.count
    XCTAssertEqual(completedCaptureCount, 2)
    XCTAssertNotNil(monitor.snapshots[.cpu])

    monitor.observe(sample)
    await Task.yield()
    let steadyHighCaptureCount = await captures.count
    XCTAssertEqual(steadyHighCaptureCount, 2)
    monitor.setVisible(false)
  }

  func testLiveProcessEnumerationPerformance() {
    measure(metrics: [XCTClockMetric(), XCTCPUMetric(), XCTMemoryMetric()]) {
      _ = ProcessUsageReader.capture()
    }
  }

  private func usage(
    pid: pid_t, startTime: UInt64 = 1, cpu: UInt64 = 0, memory: UInt64 = 0,
    disk: UInt64 = 0
  ) -> ProcessUsage {
    ProcessUsage(
      pid: pid, startTime: startTime, name: "Process \(pid)", applicationPath: nil,
      cpuNanoseconds: cpu, residentBytes: memory, diskBytes: disk)
  }

  private func capture(
    at time: TimeInterval, usages: [ProcessUsage], unreadableCount: Int = 0
  ) -> ProcessUsageCapture {
    ProcessUsageCapture(
      capturedAt: time, processes: Dictionary(uniqueKeysWithValues: usages.map { ($0.pid, $0) }),
      listedCount: usages.count + unreadableCount, unreadableCount: unreadableCount)
  }
}

private actor ProcessCaptureStub {
  private let captures: [ProcessUsageCapture]
  private var index = 0

  init(_ captures: [ProcessUsageCapture]) {
    self.captures = captures
  }

  var count: Int { index }

  func next() -> ProcessUsageCapture {
    let value = captures[min(index, captures.count - 1)]
    index += 1
    return value
  }
}
