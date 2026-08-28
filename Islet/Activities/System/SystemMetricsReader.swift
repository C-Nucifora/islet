import Darwin
import Foundation
import IOKit
import SystemConfiguration

struct MemorySnapshot: Equatable, Sendable {
  var usedBytes: UInt64
  var totalBytes: UInt64
  var wiredBytes: UInt64
  var compressedBytes: UInt64
}

struct DiskCounters: Equatable, Sendable {
  var readBytes: UInt64
  var writeBytes: UInt64
}

struct NetworkCounters: Equatable, Sendable {
  var inBytes: UInt64
  var outBytes: UInt64
  var interface: String
}

/// One un-differenced read of every source. Sendable and actor-free so the monitor can gather it
/// on a background task and hand it back to the main actor.
struct RawCounters: Equatable, Sendable {
  var cpu: [CPUTicks] = []
  var memory: MemorySnapshot?
  var memoryPressureLevel: Int?
  var swapUsedBytes: UInt64?
  var loadAverage: Double?
  var gpu: Double?
  var disk: DiskCounters?
  var diskFreeBytes: UInt64?
  var network: NetworkCounters?
  var thermalState: Int = 0
  var batteryTemperatureC: Double?

  /// Measured at ~0.10 ms total on M3 Pro. Safe to call off the main thread.
  static func read() -> RawCounters {
    RawCounters(
      cpu: SystemMetricsReader.cpuTicks(),
      memory: SystemMetricsReader.memory(),
      memoryPressureLevel: SystemMetricsReader.memoryPressureLevel(),
      swapUsedBytes: SystemMetricsReader.swapUsedBytes(),
      loadAverage: SystemMetricsReader.loadAverage(),
      gpu: SystemMetricsReader.gpuUtilisation(),
      disk: SystemMetricsReader.diskCounters(),
      diskFreeBytes: SystemMetricsReader.diskFreeBytes(),
      network: SystemMetricsReader.networkCounters(),
      thermalState: SystemMetricsReader.thermalState(),
      batteryTemperatureC: SystemMetricsReader.batteryTemperatureC())
  }
}

/// Raw kernel reads. No state, no isolation, no differencing — every rate is derived elsewhere.
enum SystemMetricsReader {

  // MARK: - CPU

  static func cpuTicks() -> [CPUTicks] {
    var count: natural_t = 0
    var info: processor_info_array_t?
    var infoCount: mach_msg_type_number_t = 0
    guard
      host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount)
        == KERN_SUCCESS,
      let info
    else { return [] }
    // MANDATORY. The kernel vm_allocate's this array on every call. Measured on M3 Pro:
    // infoCount = 48 integer_t = 192 bytes a sample, ~11 MB a day at 1 Hz if this is skipped.
    defer {
      vm_deallocate(
        mach_task_self_, vm_address_t(UInt(bitPattern: info)),
        vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
    }
    var out: [CPUTicks] = []
    out.reserveCapacity(Int(count))
    for core in 0..<Int(count) {
      let base = core * Int(CPU_STATE_MAX)
      // The array is integer_t (Int32) but the counters are unsigned; reinterpret the bits so a
      // counter past 2^31 does not read as negative.
      out.append(
        CPUTicks(
          user: UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]),
          system: UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]),
          idle: UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]),
          nice: UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)])))
    }
    return out
  }

  static func loadAverage() -> Double? {
    var loads = [Double](repeating: 0, count: 3)
    guard getloadavg(&loads, 3) == 3 else { return nil }
    return loads[0]
  }

  // MARK: - Memory

  static func memory() -> MemorySnapshot? {
    var size = mach_msg_type_number_t(
      MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
    var stats = vm_statistics64_data_t()
    let result = withUnsafeMutablePointer(to: &stats) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
        host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &size)
      }
    }
    guard result == KERN_SUCCESS else { return nil }
    // `vm_kernel_page_size` is a mutable Darwin global, which Swift 6 rejects as shared mutable
    // state. `host_page_size` is the call it is populated from and returns the same 16 KB here.
    var rawPageSize: vm_size_t = 0
    guard host_page_size(mach_host_self(), &rawPageSize) == KERN_SUCCESS, rawPageSize > 0 else {
      return nil
    }
    let page = UInt64(rawPageSize)
    let wired = UInt64(stats.wire_count) * page
    let compressed = UInt64(stats.compressor_page_count) * page
    let active = UInt64(stats.active_count) * page
    // active + wired + compressed is the figure Activity Monitor calls "Memory Used".
    return MemorySnapshot(
      usedBytes: active + wired + compressed,
      totalBytes: ProcessInfo.processInfo.physicalMemory,
      wiredBytes: wired,
      compressedBytes: compressed)
  }

  /// 1 = normal, 2 = warning, 4 = critical.
  static func memoryPressureLevel() -> Int? { sysctlInt32("kern.memorystatus_vm_pressure_level") }

  static func swapUsedBytes() -> UInt64? {
    var usage = xsw_usage()
    var size = MemoryLayout<xsw_usage>.size
    guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return nil }
    return usage.xsu_used
  }

  // MARK: - GPU

  /// `IOAccelerator` → `PerformanceStatistics` → `Device Utilization %`. Verified against
  /// `ioreg -r -c IOAccelerator`, which reports one `AGXAcceleratorG15X` node on M3 Pro.
  static func gpuUtilisation() -> Double? {
    guard let properties = IORegistryReader.properties(matching: "IOAccelerator"),
      let statistics = properties["PerformanceStatistics"] as? [String: Any],
      let value = statistics["Device Utilization %"] as? NSNumber
    else { return nil }
    return min(max(value.doubleValue / 100, 0), 1)
  }

  // MARK: - Disk

  /// Sums `Bytes (Read)` / `Bytes (Write)` across every `IOBlockStorageDriver` node.
  ///
  /// Deliberate choice: SUM, do not filter. `ioreg -r -c IOBlockStorageDriver` returns four nodes
  /// on this machine — one all-zero placeholder, the internal SSD, and two small read-only images.
  /// The all-zero node contributes nothing to a delta by construction, and the read-only images
  /// are real I/O that belongs in the total. Filtering by "biggest node" would silently drop a
  /// second physical drive.
  static func diskCounters() -> DiskCounters? {
    let nodes = IORegistryReader.allProperties(matching: "IOBlockStorageDriver")
    var read: UInt64 = 0
    var write: UInt64 = 0
    var found = false
    for node in nodes {
      guard let statistics = node["Statistics"] as? [String: Any] else { continue }
      found = true
      read &+= (statistics["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
      write &+= (statistics["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
    }
    return found ? DiskCounters(readBytes: read, writeBytes: write) : nil
  }

  static func diskFreeBytes() -> UInt64? {
    guard
      let values = try? URL(fileURLWithPath: "/").resourceValues(
        forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
      let available = values.volumeAvailableCapacityForImportantUsage, available > 0
    else { return nil }
    return UInt64(available)
  }

  // MARK: - Network

  /// The interface holding the default IPv4 route, via public SystemConfiguration. Verified to
  /// return "en6" on this machine.
  static func primaryInterfaceName() -> String? {
    guard let store = SCDynamicStoreCreate(nil, "dev.islet" as CFString, nil, nil),
      let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString)
        as? [String: Any],
      let name = global["PrimaryInterface"] as? String
    else { return nil }
    return name
  }

  static func networkCounters() -> NetworkCounters? {
    guard let name = primaryInterfaceName() ?? fallbackInterfaceName() else { return nil }
    var addresses: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&addresses) == 0, let first = addresses else { return nil }
    defer { freeifaddrs(addresses) }
    var cursor: UnsafeMutablePointer<ifaddrs>? = first
    while let node = cursor {
      let entry = node.pointee
      defer { cursor = entry.ifa_next }
      guard entry.ifa_addr?.pointee.sa_family == UInt8(AF_LINK),
        String(cString: entry.ifa_name) == name,
        let data = entry.ifa_data
      else { continue }
      let stats = data.assumingMemoryBound(to: if_data.self).pointee
      // ifi_ibytes / ifi_obytes are UInt32 and wrap. Widen here; difference at 32 bits later.
      return NetworkCounters(
        inBytes: UInt64(stats.ifi_ibytes), outBytes: UInt64(stats.ifi_obytes), interface: name)
    }
    return nil
  }

  /// Used only when SystemConfiguration has no primary interface (no route, or a captive setup):
  /// the busiest `en*` link that is up and running.
  private static func fallbackInterfaceName() -> String? {
    var addresses: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&addresses) == 0, let first = addresses else { return nil }
    defer { freeifaddrs(addresses) }
    var best: (name: String, bytes: UInt32)?
    var cursor: UnsafeMutablePointer<ifaddrs>? = first
    while let node = cursor {
      let entry = node.pointee
      defer { cursor = entry.ifa_next }
      let name = String(cString: entry.ifa_name)
      guard entry.ifa_addr?.pointee.sa_family == UInt8(AF_LINK), name.hasPrefix("en"),
        entry.ifa_flags & UInt32(IFF_UP) != 0, entry.ifa_flags & UInt32(IFF_RUNNING) != 0,
        let data = entry.ifa_data
      else { continue }
      let bytes = data.assumingMemoryBound(to: if_data.self).pointee.ifi_ibytes
      if let current = best {
        if bytes > current.bytes { best = (name, bytes) }
      } else {
        best = (name, bytes)
      }
    }
    return best?.name
  }

  // MARK: - Thermal

  /// 0 nominal, 1 fair, 2 serious, 3 critical.
  static func thermalState() -> Int { ProcessInfo.processInfo.thermalState.rawValue }

  /// `AppleSmartBattery` → `Temperature`, in centi-degrees. Verified: 3056 → 30.56 °C.
  static func batteryTemperatureC() -> Double? {
    guard let properties = IORegistryReader.properties(matching: "AppleSmartBattery"),
      let raw = (properties["Temperature"] as? NSNumber)?.doubleValue, raw > 0
    else { return nil }
    return raw / 100
  }
}
