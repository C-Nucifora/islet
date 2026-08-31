import Foundation

/// One core's cumulative CPU_STATE counters, exactly as `host_processor_info` reports them.
/// Held at their native 32-bit width so deltas can be taken in the domain they wrap in.
struct CPUTicks: Equatable, Sendable {
  var user: UInt32
  var system: UInt32
  var idle: UInt32
  var nice: UInt32
}

/// Fraction of elapsed ticks one core spent busy. Nil when no ticks elapsed — a duplicate read is
/// not a 0% measurement, it is the absence of one.
func cpuUtilisation(from old: CPUTicks, to new: CPUTicks) -> Double? {
  let user = UInt64(new.user &- old.user)
  let system = UInt64(new.system &- old.system)
  let nice = UInt64(new.nice &- old.nice)
  let idle = UInt64(new.idle &- old.idle)
  let busy = user + system + nice
  let total = busy + idle
  guard total > 0 else { return nil }
  return Double(busy) / Double(total)
}

/// Fraction of elapsed ticks a contiguous run of cores spent busy. Nil when the two snapshots
/// cannot be differenced (different core counts, an out-of-bounds or empty range, no ticks).
func cpuUtilisation(from old: [CPUTicks], to new: [CPUTicks], indices: Range<Int>) -> Double? {
  guard old.count == new.count, !indices.isEmpty,
    indices.lowerBound >= 0, indices.upperBound <= new.count
  else { return nil }
  var busy: UInt64 = 0
  var total: UInt64 = 0
  for i in indices {
    // Subtract at 32 bits so a wrapped counter still yields the true elapsed count.
    let user = UInt64(new[i].user &- old[i].user)
    let system = UInt64(new[i].system &- old[i].system)
    let nice = UInt64(new[i].nice &- old[i].nice)
    let idle = UInt64(new[i].idle &- old[i].idle)
    busy += user + system + nice
    total += user + system + nice + idle
  }
  guard total > 0 else { return nil }
  return Double(busy) / Double(total)
}

/// Longest gap between two counter reads that still produces a rate. The slowest normal System
/// cadence is 45 seconds, so this admits every energy-policy interval but still drops a sleep/wake
/// or stalled run loop instead of rendering it as a spike.
let metricsMaxSampleGap: TimeInterval = 60

/// The native width of a cumulative counter, which is the width its wraparound happens at.
enum CounterWidth: Sendable {
  /// Legacy 32-bit counters, retained for rollover arithmetic tests.
  case bits32
  /// Current disk counters and `if_data64` network counters.
  case bits64
}

/// Units per second between two cumulative counter reads.
/// Nil when `elapsed` is not positive, or when the gap exceeds `metricsMaxSampleGap`.
func ratePerSecond(
  from old: UInt64, to new: UInt64, elapsed: TimeInterval, width: CounterWidth
) -> Double? {
  guard elapsed > 0, elapsed <= metricsMaxSampleGap else { return nil }
  let delta: UInt64
  switch width {
  case .bits32:
    delta = UInt64(UInt32(truncatingIfNeeded: new) &- UInt32(truncatingIfNeeded: old))
  case .bits64:
    delta = new &- old
  }
  return Double(delta) / elapsed
}

/// The time span displayed by System sparklines. Samples can arrive at different cadences, but a
/// chart always represents this much wall-clock time ending at its newest sample.
enum SystemChartHistory {
  static let timeWindow: TimeInterval = 5 * 60
  static let maximumRenderedSamples = 60
  static let maximumRetainedSamples = 300
  static let maximumContiguousGap: TimeInterval = 60

  static let timeSpanLabel = "5m"
}

/// A single value plus the instant it was measured. The chart must retain this information: a
/// sample count has no stable relationship to elapsed time while the monitor changes cadence.
struct TimedMetricSample: Equatable, Sendable {
  let timestamp: Date
  let value: Double
}

/// A bounded, oldest-first history of one series.
///
/// The ring retains at most five minutes of measurements and 300 entries. The sample cap is a
/// safety backstop for a bursty source. A gap longer than one minute clears the series so sleep,
/// a suspended app, and a stalled run loop never draw a line that implies unmeasured activity.
struct MetricRing: Equatable, Sendable {
  let capacity: Int
  let timeWindow: TimeInterval
  let maximumContiguousGap: TimeInterval
  private(set) var samples: [TimedMetricSample] = []

  init(
    capacity: Int,
    timeWindow: TimeInterval = SystemChartHistory.timeWindow,
    maximumContiguousGap: TimeInterval = SystemChartHistory.maximumContiguousGap
  ) {
    self.capacity = max(1, capacity)
    self.timeWindow = max(0, timeWindow)
    self.maximumContiguousGap = max(0, maximumContiguousGap)
  }

  mutating func push(_ value: Double) {
    push(value, at: Date())
  }

  mutating func push(_ value: Double, at timestamp: Date) {
    guard value.isFinite else { return }
    advance(to: timestamp)
    // A wall-clock adjustment can move backwards. Do not put an out-of-order reading on a chart.
    guard samples.last?.timestamp ?? timestamp <= timestamp else { return }
    samples.append(TimedMetricSample(timestamp: timestamp, value: value))
    trimToBounds(referenceDate: timestamp)
  }

  /// Ages existing history even when a source has no usable value on this tick. That matters for
  /// counter-derived disk and network rates, which are intentionally nil after a sleep gap.
  mutating func advance(to timestamp: Date) {
    if let newest = samples.last,
      timestamp.timeIntervalSince(newest.timestamp) > maximumContiguousGap
    {
      samples.removeAll()
      return
    }
    trimToBounds(referenceDate: timestamp)
  }

  var values: [Double] { samples.map(\.value) }
  var latest: Double? { samples.last?.value }
  var latestTimestamp: Date? { samples.last?.timestamp }

  private mutating func trimToBounds(referenceDate: Date) {
    let cutoff = referenceDate.addingTimeInterval(-timeWindow)
    samples.removeAll { $0.timestamp < cutoff }
    if samples.count > capacity {
      samples.removeFirst(samples.count - capacity)
    }
  }
}
