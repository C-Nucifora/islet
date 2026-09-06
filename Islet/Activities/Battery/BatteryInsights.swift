import Foundation

struct BatteryDrainBaselinePoint: Codable, Equatable, Sendable {
  let date: Date
  let watts: Double
}

struct BatteryCapacityPoint: Codable, Equatable, Sendable {
  let date: Date
  let milliampHours: Int
}

protocol BatteryInsightClock: Sendable {
  func now() -> Date
}

struct SystemBatteryInsightClock: BatteryInsightClock {
  func now() -> Date { Date() }
}

struct BatteryInsightSample: Equatable, Sendable {
  let state: BatteryState
  let batteryPowerWatts: Double?
  let systemInputWatts: Double?
  let reportedCapacityMAh: Int?
  let fullyCharged: Bool
  let batteryPowerStatus: BatteryTelemetryStatus?
  let systemInputStatus: BatteryTelemetryStatus?

  init(state: BatteryState, metrics: BatteryMetrics) {
    self.state = state
    if let measuredPower = metrics.batteryPowerWatts {
      batteryPowerWatts = measuredPower
      batteryPowerStatus = metrics.status(for: .batteryPower) ?? .available
    } else if let derivedPower = metrics.powerWatts {
      batteryPowerWatts = derivedPower
      batteryPowerStatus = .available
    } else {
      batteryPowerWatts = nil
      batteryPowerStatus = metrics.status(for: .batteryPower)
    }
    systemInputWatts = metrics.systemPowerInWatts
    reportedCapacityMAh = metrics.rawMaxCapacityMAh ?? metrics.nominalCapacityMAh
    fullyCharged = metrics.fullyCharged ?? false
    systemInputStatus = metrics.status(for: .systemInput)
  }

  init(
    state: BatteryState, batteryPowerWatts: Double?, systemInputWatts: Double? = nil,
    reportedCapacityMAh: Int? = nil, fullyCharged: Bool = false,
    batteryPowerStatus: BatteryTelemetryStatus? = nil,
    systemInputStatus: BatteryTelemetryStatus? = nil
  ) {
    self.state = state
    self.batteryPowerWatts = batteryPowerWatts
    self.systemInputWatts = systemInputWatts
    self.reportedCapacityMAh = reportedCapacityMAh
    self.fullyCharged = fullyCharged
    self.batteryPowerStatus = batteryPowerStatus
    self.systemInputStatus = systemInputStatus
  }
}

enum BatteryInsightAlert: Equatable, Sendable {
  case unusualDrain(currentWatts: Double, baselineWatts: Double)
  case chargerDischarging(batteryWatts: Double)
  case slowCharging(chargeWatts: Double)
}

enum BatteryInsightStatus: Equatable, Sendable {
  case learningBaseline(sampleCount: Int)
  case normal(baselineWatts: Double?)
  case unusualDrain(currentWatts: Double, baselineWatts: Double)
  case workloadSpike(batteryWatts: Double)
  case chargerDischarging(batteryWatts: Double)
  case slowCharging(chargeWatts: Double)
  case telemetryUnavailable(reason: String)

  var shortText: String? {
    switch self {
    case .learningBaseline(let count):
      return count == 0 ? "Learning normal battery use" : "Learning from \(count) battery samples"
    case .normal: return nil
    case .unusualDrain(let current, let baseline):
      return String(format: "Unusual drain %.1f W, usually %.1f W", current, baseline)
    case .workloadSpike:
      return "Brief workload spike; waiting before warning"
    case .chargerDischarging(let watts):
      return String(format: "Charger shortfall; battery supplying %.1f W", watts)
    case .slowCharging(let watts):
      return String(format: "Charging slowly at %.1f W", watts)
    case .telemetryUnavailable(let reason):
      return "Warning analysis unavailable: \(reason)"
    }
  }
}

struct BatteryCapacityTrend: Equatable, Sendable {
  let changeMAh: Int
  let days: Int

  var wording: String {
    if changeMAh <= -100 {
      return "Reported capacity is \(-changeMAh) mAh lower over \(days) days"
    }
    if changeMAh >= 100 {
      return "Reported capacity is \(changeMAh) mAh higher over \(days) days"
    }
    return "Reported capacity has varied by less than 100 mAh over \(days) days"
  }

  var explanation: String {
    "This compares the Mac's reported capacity readings. Temperature, charge state and calibration can move the value, so it is not a battery-health diagnosis."
  }
}

struct BatteryInsightSnapshot: Equatable, Sendable {
  var status: BatteryInsightStatus = .learningBaseline(sampleCount: 0)
  var capacityTrend: BatteryCapacityTrend?
  var baselineWatts: Double?
  var baselineSampleCount = 0
}

struct BatteryInsightPolicy: Equatable, Sendable {
  var unusualDrainEnabled = true
  var chargerWarningsEnabled = true
}

struct BatteryInsightUpdate: Equatable, Sendable {
  let alerts: [BatteryInsightAlert]
  let snapshot: BatteryInsightSnapshot
}

struct BatteryInsightAnalyzer: Sendable {
  static let baselineLifetime: TimeInterval = 7 * 24 * 60 * 60
  static let baselineSampleInterval: TimeInterval = 60
  static let maximumBaselinePoints = Int(baselineLifetime / baselineSampleInterval) + 1
  static let maximumCapacityPoints = 90
  static let minimumBaselinePoints = 6
  static let unusualDrainEvidence: TimeInterval = 3 * 60
  static let chargerDischargeEvidence: TimeInterval = 2 * 60
  static let slowChargeEvidence: TimeInterval = 8 * 60
  static let recoveryEvidence: TimeInterval = 2 * 60
  static let alertCooldown: TimeInterval = 2 * 60 * 60
  static let maximumEvidenceGap: TimeInterval = 3 * 60

  private enum Condition: String, Hashable, Sendable {
    case unusualDrain
    case chargerDischarging
    case slowCharging
  }

  private struct Evidence: Sendable {
    let condition: Condition
    let startedAt: Date
    let lastSeenAt: Date
  }

  private let clock: any BatteryInsightClock
  private(set) var baseline: [BatteryDrainBaselinePoint]
  private(set) var capacityHistory: [BatteryCapacityPoint]
  private(set) var lastAlertDates: [String: Date]
  private var evidence: Evidence?
  private var activeConditions: Set<Condition> = []
  private var recoveryEvidence: [Condition: Evidence] = [:]

  init(
    baseline: [BatteryDrainBaselinePoint] = [],
    capacityHistory: [BatteryCapacityPoint] = [],
    lastAlertDates: [String: Date] = [:],
    clock: any BatteryInsightClock = SystemBatteryInsightClock()
  ) {
    self.baseline = baseline
    self.capacityHistory = capacityHistory
    self.lastAlertDates = lastAlertDates
    self.clock = clock
    prune(at: clock.now())
  }

  mutating func reset() {
    baseline = []
    capacityHistory = []
    lastAlertDates = [:]
    evidence = nil
    activeConditions = []
    recoveryEvidence = [:]
  }

  var learnedDataSnapshot: BatteryInsightSnapshot {
    BatteryInsightSnapshot(
      status: baselineMedian.map { .normal(baselineWatts: $0) }
        ?? .learningBaseline(sampleCount: baseline.count),
      capacityTrend: capacityTrend, baselineWatts: baselineMedian,
      baselineSampleCount: baseline.count)
  }

  mutating func ingest(
    _ sample: BatteryInsightSample, policy: BatteryInsightPolicy = BatteryInsightPolicy()
  ) -> BatteryInsightUpdate {
    let now = clock.now()
    prune(at: now)
    recordCapacity(sample.reportedCapacityMAh, at: now)

    guard usable(sample.batteryPowerStatus), let signedPower = sample.batteryPowerWatts,
      signedPower.isFinite
    else {
      evidence = nil
      return update(
        alerts: [],
        status: .telemetryUnavailable(
          reason: unavailableReason(sample.batteryPowerStatus, fallback: "No battery-power sample"))
      )
    }

    if sample.state.onAC {
      recover(.unusualDrain, when: true, at: now)
      return ingestCharger(sample, signedPower: signedPower, policy: policy, at: now)
    }
    recover(.chargerDischarging, when: true, at: now)
    recover(.slowCharging, when: true, at: now)
    return ingestDrain(signedPower: signedPower, policy: policy, at: now)
  }

  private mutating func ingestDrain(
    signedPower: Double, policy: BatteryInsightPolicy, at now: Date
  ) -> BatteryInsightUpdate {
    let drainWatts = max(0, -signedPower)
    guard let typical = baselineMedian else {
      recordBaseline(drainWatts, at: now)
      evidence = nil
      return update(alerts: [], status: .learningBaseline(sampleCount: baseline.count))
    }

    let unusualThreshold = max(typical * 1.8, typical + 8)
    guard policy.unusualDrainEnabled else {
      evidence = nil
      activeConditions.remove(.unusualDrain)
      recoveryEvidence[.unusualDrain] = nil
      if drainWatts < unusualThreshold { recordBaseline(drainWatts, at: now) }
      return update(alerts: [], status: .normal(baselineWatts: typical))
    }
    let isUnusual = drainWatts >= unusualThreshold
    recover(.unusualDrain, when: drainWatts <= max(typical * 1.25, typical + 3), at: now)

    if isUnusual {
      let reached = accumulate(.unusualDrain, required: Self.unusualDrainEvidence, at: now)
      if reached {
        let wasActive = activeConditions.contains(.unusualDrain)
        activeConditions.insert(.unusualDrain)
        let alert =
          wasActive
          ? nil
          : makeAlert(
            .unusualDrain(currentWatts: drainWatts, baselineWatts: typical),
            condition: .unusualDrain, at: now)
        return update(
          alerts: alert.map { [$0] } ?? [],
          status: .unusualDrain(currentWatts: drainWatts, baselineWatts: typical))
      }
      return update(alerts: [], status: .normal(baselineWatts: typical))
    }

    if evidence?.condition == .unusualDrain { evidence = nil }
    if !activeConditions.contains(.unusualDrain) { recordBaseline(drainWatts, at: now) }
    let status: BatteryInsightStatus =
      activeConditions.contains(.unusualDrain)
      ? .unusualDrain(currentWatts: drainWatts, baselineWatts: typical)
      : .normal(baselineWatts: typical)
    return update(alerts: [], status: status)
  }

  private mutating func ingestCharger(
    _ sample: BatteryInsightSample, signedPower: Double, policy: BatteryInsightPolicy, at now: Date
  ) -> BatteryInsightUpdate {
    guard policy.chargerWarningsEnabled else {
      evidence = nil
      activeConditions.remove(.chargerDischarging)
      activeConditions.remove(.slowCharging)
      return update(alerts: [], status: .normal(baselineWatts: baselineMedian))
    }

    let isDischarging = signedPower < -1
    recover(.chargerDischarging, when: signedPower >= -0.5, at: now)
    recover(
      .slowCharging,
      when: !sample.state.isCharging || signedPower >= 4 || sample.fullyCharged
        || sample.state.percent >= 95,
      at: now)

    if isDischarging {
      if evidence?.condition == .slowCharging { evidence = nil }
      let reached = accumulate(
        .chargerDischarging, required: Self.chargerDischargeEvidence, at: now)
      if reached {
        let wasActive = activeConditions.contains(.chargerDischarging)
        activeConditions.insert(.chargerDischarging)
        let watts = -signedPower
        let alert =
          wasActive
          ? nil
          : makeAlert(
            .chargerDischarging(batteryWatts: watts), condition: .chargerDischarging, at: now)
        return update(
          alerts: alert.map { [$0] } ?? [], status: .chargerDischarging(batteryWatts: watts))
      }
      return update(alerts: [], status: .workloadSpike(batteryWatts: -signedPower))
    }

    let canAssessInput = usable(sample.systemInputStatus) && sample.systemInputWatts != nil
    let isSlowChargeCandidate =
      sample.state.isCharging && !sample.fullyCharged
      && sample.state.percent < 95 && signedPower >= -1 && signedPower <= 2
    if isSlowChargeCandidate, !canAssessInput {
      evidence = nil
      return update(
        alerts: [],
        status: .telemetryUnavailable(
          reason: "System input: "
            + unavailableReason(sample.systemInputStatus, fallback: "No sample")))
    }
    let isSlow = isSlowChargeCandidate && canAssessInput
    if isSlow {
      if evidence?.condition == .chargerDischarging { evidence = nil }
      let reached = accumulate(.slowCharging, required: Self.slowChargeEvidence, at: now)
      if reached {
        let wasActive = activeConditions.contains(.slowCharging)
        activeConditions.insert(.slowCharging)
        let chargeWatts = max(0, signedPower)
        let alert =
          wasActive
          ? nil
          : makeAlert(
            .slowCharging(chargeWatts: chargeWatts), condition: .slowCharging, at: now)
        return update(
          alerts: alert.map { [$0] } ?? [], status: .slowCharging(chargeWatts: chargeWatts))
      }
      return update(alerts: [], status: .normal(baselineWatts: baselineMedian))
    }

    evidence = nil
    let status: BatteryInsightStatus
    if activeConditions.contains(.chargerDischarging) {
      status = .chargerDischarging(batteryWatts: max(0, -signedPower))
    } else if activeConditions.contains(.slowCharging) {
      status = .slowCharging(chargeWatts: max(0, signedPower))
    } else {
      status = .normal(baselineWatts: baselineMedian)
    }
    return update(alerts: [], status: status)
  }

  private mutating func accumulate(
    _ condition: Condition, required duration: TimeInterval, at now: Date
  ) -> Bool {
    if let evidence, evidence.condition == condition {
      let gap = now.timeIntervalSince(evidence.lastSeenAt)
      if gap >= 0, gap <= Self.maximumEvidenceGap {
        self.evidence = Evidence(
          condition: condition, startedAt: evidence.startedAt, lastSeenAt: now)
        return now.timeIntervalSince(evidence.startedAt) >= duration
      }
    }
    evidence = Evidence(condition: condition, startedAt: now, lastSeenAt: now)
    return false
  }

  private mutating func recover(_ condition: Condition, when recovering: Bool, at now: Date) {
    guard activeConditions.contains(condition) else {
      recoveryEvidence[condition] = nil
      return
    }
    guard recovering else {
      recoveryEvidence[condition] = nil
      return
    }
    if let recovery = recoveryEvidence[condition] {
      let gap = now.timeIntervalSince(recovery.lastSeenAt)
      if gap < 0 || gap > Self.maximumEvidenceGap {
        recoveryEvidence[condition] = Evidence(
          condition: condition, startedAt: now, lastSeenAt: now)
      } else if now.timeIntervalSince(recovery.startedAt) >= Self.recoveryEvidence {
        activeConditions.remove(condition)
        recoveryEvidence[condition] = nil
      } else {
        recoveryEvidence[condition] = Evidence(
          condition: condition, startedAt: recovery.startedAt, lastSeenAt: now)
      }
    } else {
      recoveryEvidence[condition] = Evidence(
        condition: condition, startedAt: now, lastSeenAt: now)
    }
  }

  private mutating func makeAlert(
    _ alert: BatteryInsightAlert, condition: Condition, at now: Date
  ) -> BatteryInsightAlert? {
    if let last = lastAlertDates[condition.rawValue],
      now.timeIntervalSince(last) < Self.alertCooldown
    {
      return nil
    }
    lastAlertDates[condition.rawValue] = now
    return alert
  }

  private mutating func recordBaseline(_ watts: Double, at now: Date) {
    guard watts.isFinite, watts >= 0.5 else { return }
    if let last = baseline.last, now.timeIntervalSince(last.date) < Self.baselineSampleInterval {
      return
    }
    baseline.append(BatteryDrainBaselinePoint(date: now, watts: watts))
    prune(at: now)
  }

  private mutating func recordCapacity(_ capacity: Int?, at now: Date) {
    guard let capacity, capacity > 0 else { return }
    if let last = capacityHistory.last,
      Calendar.current.isDate(last.date, inSameDayAs: now)
    {
      guard last.milliampHours != capacity else { return }
      capacityHistory[capacityHistory.count - 1] = BatteryCapacityPoint(
        date: now, milliampHours: capacity)
    } else {
      capacityHistory.append(BatteryCapacityPoint(date: now, milliampHours: capacity))
    }
    if capacityHistory.count > Self.maximumCapacityPoints {
      capacityHistory.removeFirst(capacityHistory.count - Self.maximumCapacityPoints)
    }
  }

  private mutating func prune(at now: Date) {
    let cutoff = now.addingTimeInterval(-Self.baselineLifetime)
    baseline.removeAll {
      $0.date < cutoff || $0.date > now || !$0.watts.isFinite || $0.watts < 0
    }
    if baseline.count > Self.maximumBaselinePoints {
      baseline.removeFirst(baseline.count - Self.maximumBaselinePoints)
    }
    capacityHistory.removeAll { $0.milliampHours <= 0 }
    if capacityHistory.count > Self.maximumCapacityPoints {
      capacityHistory.removeFirst(capacityHistory.count - Self.maximumCapacityPoints)
    }
  }

  private var baselineMedian: Double? {
    guard baseline.count >= Self.minimumBaselinePoints else { return nil }
    let sorted = baseline.map(\.watts).sorted()
    let middle = sorted.count / 2
    if sorted.count.isMultiple(of: 2) {
      return (sorted[middle - 1] + sorted[middle]) / 2
    }
    return sorted[middle]
  }

  private var capacityTrend: BatteryCapacityTrend? {
    guard let first = capacityHistory.first, let last = capacityHistory.last else { return nil }
    let days = Calendar.current.dateComponents([.day], from: first.date, to: last.date).day ?? 0
    guard days >= 7 else { return nil }
    return BatteryCapacityTrend(
      changeMAh: last.milliampHours - first.milliampHours, days: days)
  }

  private func update(
    alerts: [BatteryInsightAlert], status: BatteryInsightStatus
  ) -> BatteryInsightUpdate {
    BatteryInsightUpdate(
      alerts: alerts,
      snapshot: BatteryInsightSnapshot(
        status: status, capacityTrend: capacityTrend, baselineWatts: baselineMedian,
        baselineSampleCount: baseline.count))
  }

  private func usable(_ status: BatteryTelemetryStatus?) -> Bool {
    status == nil || status == .available
  }

  private func unavailableReason(
    _ status: BatteryTelemetryStatus?, fallback: String
  ) -> String {
    status?.diagnosticReason ?? fallback
  }
}
