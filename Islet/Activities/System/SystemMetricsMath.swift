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

/// A bounded, oldest-first history of one series. Backed by a plain array rather than a rotating
/// index because every consumer wants the values in draw order and 60 elements is nothing.
struct MetricRing: Equatable, Sendable {
  let capacity: Int
  private(set) var values: [Double] = []

  init(capacity: Int) {
    self.capacity = max(1, capacity)
  }

  mutating func push(_ value: Double) {
    values.append(value)
    if values.count > capacity { values.removeFirst(values.count - capacity) }
  }

  var latest: Double? { values.last }
}
