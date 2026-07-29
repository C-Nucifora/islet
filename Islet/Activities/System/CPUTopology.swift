import Darwin
import Foundation

/// One `hw.perflevelN` entry: its label and how many logical CPUs it owns.
struct PerfLevel: Equatable, Sendable {
  let name: String
  let logicalCPUs: Int
}

/// A perf level mapped onto a contiguous run of indices in `host_processor_info`'s array.
struct CPUCluster: Equatable, Sendable {
  /// Index into `hw.perflevelN.*`. 0 is always the most performant cluster.
  let perfLevelIndex: Int
  let name: String
  /// Indices into `host_processor_info`'s per-core array.
  let range: Range<Int>

  var isPerformance: Bool { perfLevelIndex == 0 }
}

enum CPUTopology {
  /// Reads `hw.nperflevels` and each level's name and logical CPU count.
  static func perfLevels() -> [PerfLevel] {
    guard let count = sysctlInt32("hw.nperflevels"), count > 0 else { return [] }
    var out: [PerfLevel] = []
    for index in 0..<count {
      guard let name = sysctlString("hw.perflevel\(index).name"),
        let logical = sysctlInt32("hw.perflevel\(index).logicalcpu")
      else { return [] }
      out.append(PerfLevel(name: name, logicalCPUs: logical))
    }
    return out
  }

  /// Maps perf levels onto index ranges.
  ///
  /// `hw.perflevelN` gives labels and counts but NOT the index ranges. Verified empirically on
  /// M3 Pro (see Task 8 of the Phase 4 plan): `host_processor_info` orders the LEAST performant
  /// cluster FIRST — a `.background`-QoS spin saturates indices 0...5 while `hw.perflevel1` is
  /// "Efficiency", and a `.userInteractive` spin saturates 6...11. So level N-1 occupies
  /// `[0, count(N-1))` and level 0 occupies the tail.
  ///
  /// Returns `[]` — total-only, no split — whenever the mapping cannot be established: fewer than
  /// two levels, a zero-sized level, or counts that do not sum to `totalCores`.
  static func clusters(perfLevels: [PerfLevel], totalCores: Int) -> [CPUCluster] {
    guard perfLevels.count >= 2, totalCores > 0,
      perfLevels.allSatisfy({ $0.logicalCPUs > 0 }),
      perfLevels.reduce(0, { $0 + $1.logicalCPUs }) == totalCores
    else { return [] }

    var out: [CPUCluster] = []
    var cursor = 0
    for index in stride(from: perfLevels.count - 1, through: 0, by: -1) {
      let level = perfLevels[index]
      out.append(
        CPUCluster(
          perfLevelIndex: index, name: level.name,
          range: cursor..<(cursor + level.logicalCPUs)))
      cursor += level.logicalCPUs
    }
    // Built least-performant-first to walk the array; returned most-performant-first for display.
    return out.reversed()
  }

  /// This machine's clusters, or `[]` when the split cannot be established.
  static func current() -> [CPUCluster] {
    clusters(perfLevels: perfLevels(), totalCores: ProcessInfo.processInfo.processorCount)
  }
}

/// Reads a 32-bit integer sysctl. Nil when the name does not exist on this hardware.
func sysctlInt32(_ name: String) -> Int? {
  var value: Int32 = 0
  var size = MemoryLayout<Int32>.size
  guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
  return Int(value)
}

/// Reads a string sysctl. Nil when the name does not exist on this hardware.
func sysctlString(_ name: String) -> String? {
  var size = 0
  guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
  var buffer = [CChar](repeating: 0, count: size)
  guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
  return String(cString: buffer)
}
