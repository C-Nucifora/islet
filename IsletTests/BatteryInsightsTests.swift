import Defaults
import XCTest

@testable import Islet

final class BatteryInsightsTests: XCTestCase {
  private final class TestClock: BatteryInsightClock, @unchecked Sendable {
    var date: Date

    init(_ date: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
      self.date = date
    }

    func now() -> Date { date }
    func advance(_ seconds: TimeInterval) { date.addTimeInterval(seconds) }
  }

  private func batterySample(
    watts: Double?, capacity: Int? = nil,
    status: BatteryTelemetryStatus? = .available
  ) -> BatteryInsightSample {
    BatteryInsightSample(
      state: BatteryState(percent: 70, isCharging: false, onAC: false),
      batteryPowerWatts: watts.map { -$0 }, reportedCapacityMAh: capacity,
      batteryPowerStatus: status)
  }

  private func chargerSample(
    batteryWatts: Double?, inputWatts: Double? = 30, percent: Int = 60,
    fullyCharged: Bool = false, isCharging: Bool = true
  ) -> BatteryInsightSample {
    BatteryInsightSample(
      state: BatteryState(percent: percent, isCharging: isCharging, onAC: true),
      batteryPowerWatts: batteryWatts, systemInputWatts: inputWatts,
      fullyCharged: fullyCharged, batteryPowerStatus: .available,
      systemInputStatus: inputWatts == nil ? .unsupported : .available)
  }

  private func learnedAnalyzer(clock: TestClock, normalWatts: Double = 10)
    -> BatteryInsightAnalyzer
  {
    let points = (0..<BatteryInsightAnalyzer.minimumBaselinePoints).map { index in
      BatteryDrainBaselinePoint(
        date: clock.date.addingTimeInterval(Double(index - 10) * 60), watts: normalWatts)
    }
    return BatteryInsightAnalyzer(baseline: points, clock: clock)
  }

  func testNormalLoadBuildsALocalBaselineWithoutAlerts() {
    let clock = TestClock()
    var analyzer = BatteryInsightAnalyzer(clock: clock)
    var alerts: [BatteryInsightAlert] = []

    for _ in 0..<8 {
      alerts += analyzer.ingest(batterySample(watts: 9.5)).alerts
      clock.advance(61)
    }

    XCTAssertTrue(alerts.isEmpty)
    XCTAssertEqual(analyzer.baseline.count, 8)
    let update = analyzer.ingest(batterySample(watts: 10))
    XCTAssertEqual(update.snapshot.baselineWatts, 9.5)
    XCTAssertEqual(update.snapshot.status, .normal(baselineWatts: 9.5))
  }

  func testSustainedDrainAlertsOnlyAfterThreeMinutes() {
    let clock = TestClock()
    var analyzer = learnedAnalyzer(clock: clock)

    XCTAssertTrue(analyzer.ingest(batterySample(watts: 30)).alerts.isEmpty)
    clock.advance(BatteryInsightAnalyzer.unusualDrainEvidence - 1)
    XCTAssertTrue(analyzer.ingest(batterySample(watts: 31)).alerts.isEmpty)
    clock.advance(1)
    XCTAssertEqual(
      analyzer.ingest(batterySample(watts: 32)).alerts,
      [.unusualDrain(currentWatts: 32, baselineWatts: 10)])
    clock.advance(60)
    XCTAssertTrue(analyzer.ingest(batterySample(watts: 33)).alerts.isEmpty)
  }

  func testIsolatedAndNoisyDrainSamplesDoNotAlertOrPolluteBaseline() {
    let clock = TestClock()
    var analyzer = learnedAnalyzer(clock: clock)

    for watts in [35.0, 10, 38, 9, 34, 11] {
      XCTAssertTrue(analyzer.ingest(batterySample(watts: watts)).alerts.isEmpty)
      clock.advance(70)
    }

    XCTAssertEqual(analyzer.ingest(batterySample(watts: 10)).snapshot.baselineWatts, 10)
    XCTAssertLessThan(analyzer.baseline.count, 12, "outliers entered the learned baseline")
  }

  func testLongSamplingGapRestartsSustainedEvidence() {
    let clock = TestClock()
    var analyzer = learnedAnalyzer(clock: clock)

    _ = analyzer.ingest(batterySample(watts: 30))
    clock.advance(BatteryInsightAnalyzer.maximumEvidenceGap + 1)
    XCTAssertTrue(analyzer.ingest(batterySample(watts: 30)).alerts.isEmpty)
    clock.advance(BatteryInsightAnalyzer.unusualDrainEvidence)
    XCTAssertEqual(analyzer.ingest(batterySample(watts: 30)).alerts.count, 1)
  }

  func testDisablingDrainWarningsClearsALatchedWarning() {
    let clock = TestClock()
    var analyzer = learnedAnalyzer(clock: clock)
    _ = analyzer.ingest(batterySample(watts: 30))
    clock.advance(BatteryInsightAnalyzer.unusualDrainEvidence)
    XCTAssertEqual(analyzer.ingest(batterySample(watts: 30)).alerts.count, 1)

    let disabled = analyzer.ingest(
      batterySample(watts: 30),
      policy: BatteryInsightPolicy(
        unusualDrainEnabled: false, chargerWarningsEnabled: true))
    XCTAssertTrue(disabled.alerts.isEmpty)
    XCTAssertEqual(disabled.snapshot.status, .normal(baselineWatts: 10))
  }

  func testRecoveryAndCooldownPreventAlertStorms() {
    let clock = TestClock()
    var analyzer = learnedAnalyzer(clock: clock)

    _ = analyzer.ingest(batterySample(watts: 30))
    clock.advance(BatteryInsightAnalyzer.unusualDrainEvidence)
    XCTAssertEqual(analyzer.ingest(batterySample(watts: 30)).alerts.count, 1)
    clock.advance(60)
    XCTAssertTrue(analyzer.ingest(batterySample(watts: 30)).alerts.isEmpty)

    _ = analyzer.ingest(batterySample(watts: 10))
    clock.advance(BatteryInsightAnalyzer.recoveryEvidence)
    _ = analyzer.ingest(batterySample(watts: 10))
    _ = analyzer.ingest(batterySample(watts: 30))
    clock.advance(BatteryInsightAnalyzer.unusualDrainEvidence)
    XCTAssertTrue(analyzer.ingest(batterySample(watts: 30)).alerts.isEmpty)

    _ = analyzer.ingest(batterySample(watts: 10))
    clock.advance(BatteryInsightAnalyzer.recoveryEvidence)
    _ = analyzer.ingest(batterySample(watts: 10))
    clock.advance(BatteryInsightAnalyzer.alertCooldown)
    _ = analyzer.ingest(batterySample(watts: 30))
    clock.advance(BatteryInsightAnalyzer.unusualDrainEvidence)
    XCTAssertEqual(analyzer.ingest(batterySample(watts: 30)).alerts.count, 1)
  }

  func testTemporaryChargerWorkloadSpikeIsInformational() {
    let clock = TestClock()
    var analyzer = BatteryInsightAnalyzer(clock: clock)

    let spike = analyzer.ingest(chargerSample(batteryWatts: -5))
    XCTAssertTrue(spike.alerts.isEmpty)
    XCTAssertEqual(spike.snapshot.status, .workloadSpike(batteryWatts: 5))
    clock.advance(BatteryInsightAnalyzer.chargerDischargeEvidence - 1)
    XCTAssertTrue(analyzer.ingest(chargerSample(batteryWatts: 8)).alerts.isEmpty)
  }

  func testSustainedChargerShortfallReportsBatteryDischarge() {
    let clock = TestClock()
    var analyzer = BatteryInsightAnalyzer(clock: clock)

    _ = analyzer.ingest(chargerSample(batteryWatts: -4))
    clock.advance(BatteryInsightAnalyzer.chargerDischargeEvidence)
    let update = analyzer.ingest(chargerSample(batteryWatts: -6))
    XCTAssertEqual(update.alerts, [.chargerDischarging(batteryWatts: 6)])
    XCTAssertEqual(update.snapshot.status, .chargerDischarging(batteryWatts: 6))
  }

  func testSustainedSlowChargingRequiresInputTelemetry() {
    let clock = TestClock()
    var analyzer = BatteryInsightAnalyzer(clock: clock)

    _ = analyzer.ingest(chargerSample(batteryWatts: 1))
    for _ in 0..<3 {
      clock.advance(2 * 60)
      XCTAssertTrue(analyzer.ingest(chargerSample(batteryWatts: 1)).alerts.isEmpty)
    }
    clock.advance(2 * 60)
    XCTAssertEqual(
      analyzer.ingest(chargerSample(batteryWatts: 0.8)).alerts,
      [.slowCharging(chargeWatts: 0.8)])

    var unavailable = BatteryInsightAnalyzer(clock: clock)
    XCTAssertEqual(
      unavailable.ingest(chargerSample(batteryWatts: 0.5, inputWatts: nil)).snapshot.status,
      .telemetryUnavailable(reason: "System input: Not reported by this Mac"))
    for _ in 0..<4 {
      clock.advance(2 * 60)
      XCTAssertTrue(
        unavailable.ingest(chargerSample(batteryWatts: 0.5, inputWatts: nil)).alerts.isEmpty)
    }
  }

  func testOnACButNotChargingDoesNotBecomeASlowChargeWarning() {
    let clock = TestClock()
    var analyzer = BatteryInsightAnalyzer(clock: clock)

    for _ in 0..<6 {
      let update = analyzer.ingest(
        chargerSample(
          batteryWatts: 0, inputWatts: nil, percent: 80, isCharging: false))
      XCTAssertTrue(update.alerts.isEmpty)
      XCTAssertEqual(update.snapshot.status, .normal(baselineWatts: nil))
      clock.advance(2 * 60)
    }
  }

  @MainActor func testIdenticalCompletedRefreshesAdvanceSustainedEvidence() {
    let savedBaseline = Defaults[.batteryDrainBaseline]
    let savedCapacity = Defaults[.batteryCapacityHistory]
    let savedAlerts = Defaults[.batteryInsightLastAlertDates]
    let savedDrainEnabled = Defaults[.unusualBatteryDrainWarnings]
    let savedDisabledActivities = Defaults[.disabledActivities]
    defer {
      Defaults[.batteryDrainBaseline] = savedBaseline
      Defaults[.batteryCapacityHistory] = savedCapacity
      Defaults[.batteryInsightLastAlertDates] = savedAlerts
      Defaults[.unusualBatteryDrainWarnings] = savedDrainEnabled
      Defaults[.disabledActivities] = savedDisabledActivities
    }

    let clock = TestClock()
    Defaults[.batteryDrainBaseline] = (0..<BatteryInsightAnalyzer.minimumBaselinePoints).map {
      BatteryDrainBaselinePoint(
        date: clock.date.addingTimeInterval(Double($0 - 10) * 60), watts: 10)
    }
    Defaults[.batteryCapacityHistory] = []
    Defaults[.batteryInsightLastAlertDates] = [:]
    Defaults[.unusualBatteryDrainWarnings] = true
    Defaults[.disabledActivities] = ActivityEnablement.updating(
      savedDisabledActivities, activityID: "battery", enabled: true)

    var metrics = BatteryMetrics()
    metrics.batteryPowerWatts = -30
    metrics.telemetryStatus[.batteryPower] = .available
    let monitor = BatteryMonitor(
      state: BatteryState(percent: 70, isCharging: false, onAC: false), metrics: metrics)
    let activity = BatteryActivity(
      insightClock: clock, monitor: monitor, managesMonitorLifecycle: false)
    activity.start()
    defer { activity.stop() }

    for _ in 0..<3 {
      monitor.publishCompletedRefresh(at: clock.date)
      XCTAssertNotEqual(
        activity.batteryInsightSummary.status,
        .unusualDrain(currentWatts: 30, baselineWatts: 10))
      clock.advance(60)
    }
    monitor.publishCompletedRefresh(at: clock.date)
    XCTAssertEqual(
      activity.batteryInsightSummary.status,
      .unusualDrain(currentWatts: 30, baselineWatts: 10))
  }

  func testMissingAndStaleTelemetryExplainWhyAnalysisIsUnavailable() {
    let clock = TestClock()
    var analyzer = learnedAnalyzer(clock: clock)

    XCTAssertEqual(
      analyzer.ingest(batterySample(watts: nil, status: .unavailable(.stale))).snapshot.status,
      .telemetryUnavailable(reason: "Last sample is stale"))
    XCTAssertEqual(
      analyzer.ingest(batterySample(watts: nil, status: .unsupported)).snapshot.status,
      .telemetryUnavailable(reason: "Not reported by this Mac"))
    XCTAssertEqual(
      BatteryInsightStatus.telemetryUnavailable(reason: "No sample yet").shortText,
      "Warning analysis unavailable: No sample yet")
    XCTAssertEqual(
      BatteryInsightStatus.learningBaseline(sampleCount: 4).shortText,
      "Learning from 4 battery samples")
  }

  func testDerivedBatteryPowerRemainsUsableWhenPrivateTelemetryIsUnsupported() {
    var metrics = BatteryMetrics()
    metrics.powerWatts = -10
    metrics.telemetryStatus[.batteryPower] = .unsupported
    let sample = BatteryInsightSample(
      state: BatteryState(percent: 70, isCharging: false, onAC: false), metrics: metrics)
    var analyzer = BatteryInsightAnalyzer(clock: TestClock())

    let update = analyzer.ingest(sample)

    XCTAssertEqual(update.snapshot.status, .learningBaseline(sampleCount: 1))
    XCTAssertEqual(analyzer.baseline.map(\.watts), [10])
  }

  func testCapacityTrendUsesReportedReadingWording() {
    let clock = TestClock()
    var analyzer = BatteryInsightAnalyzer(clock: clock)
    _ = analyzer.ingest(batterySample(watts: 10, capacity: 5_500))
    clock.advance(8 * 24 * 60 * 60)
    let trend = analyzer.ingest(batterySample(watts: 10, capacity: 5_350)).snapshot.capacityTrend

    XCTAssertEqual(trend?.wording, "Reported capacity is 150 mAh lower over 8 days")
    XCTAssertTrue(trend?.explanation.contains("not a battery-health diagnosis") == true)

    let increase = BatteryCapacityTrend(changeMAh: 150, days: 30)
    XCTAssertEqual(increase.wording, "Reported capacity is 150 mAh higher over 30 days")
  }

  func testHistoriesAreBoundedAndResettable() {
    let clock = TestClock()
    let pointCount = BatteryInsightAnalyzer.maximumBaselinePoints + 50
    let points = (0..<pointCount).map { index in
      BatteryDrainBaselinePoint(
        date: clock.date.addingTimeInterval(Double(index - pointCount)), watts: 10)
    }
    var analyzer = BatteryInsightAnalyzer(baseline: points, clock: clock)
    XCTAssertEqual(analyzer.baseline.count, BatteryInsightAnalyzer.maximumBaselinePoints)

    analyzer.reset()
    XCTAssertTrue(analyzer.baseline.isEmpty)
    XCTAssertTrue(analyzer.capacityHistory.isEmpty)
    XCTAssertTrue(analyzer.lastAlertDates.isEmpty)
  }

  func testMinuteCadenceRetainsTheFullInclusiveSevenDayWindow() {
    let clock = TestClock()
    let points = (0...Int(BatteryInsightAnalyzer.baselineLifetime / 60)).map { minute in
      BatteryDrainBaselinePoint(
        date: clock.date.addingTimeInterval(
          -BatteryInsightAnalyzer.baselineLifetime + Double(minute * 60)),
        watts: 10)
    }

    let analyzer = BatteryInsightAnalyzer(baseline: points, clock: clock)

    XCTAssertEqual(analyzer.baseline.count, BatteryInsightAnalyzer.maximumBaselinePoints)
    XCTAssertEqual(
      analyzer.baseline.first?.date,
      clock.date.addingTimeInterval(-BatteryInsightAnalyzer.baselineLifetime))
    XCTAssertEqual(analyzer.baseline.last?.date, clock.date)
  }
}
