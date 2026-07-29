import Foundation

/// Turns two raw counter snapshots plus the time between them into one publishable sample.
///
/// Levels (memory, GPU, load, thermal, free space) come straight from `current` and are always
/// present. Rates (CPU, disk, network) need a usable previous snapshot: they are nil on the first
/// sample and after any gap longer than `metricsMaxSampleGap`, so a resume from sleep draws a
/// break in the series rather than a spike.
func systemMetricsSample(
  previous: RawCounters?, previousDate: Date?, current: RawCounters, currentDate: Date,
  clusters: [CPUCluster]
) -> SystemMetricsSample {
  var sample = SystemMetricsSample()
  sample.loadAverage = current.loadAverage
  sample.gpu = current.gpu
  sample.thermalState = current.thermalState
  sample.batteryTemperatureC = current.batteryTemperatureC
  sample.memoryPressureLevel = current.memoryPressureLevel
  sample.swapUsedBytes = current.swapUsedBytes
  sample.diskFreeBytes = current.diskFreeBytes
  sample.primaryInterface = current.network?.interface
  if let memory = current.memory {
    sample.memoryUsedBytes = memory.usedBytes
    sample.memoryTotalBytes = memory.totalBytes
    sample.memoryWiredBytes = memory.wiredBytes
    sample.memoryCompressedBytes = memory.compressedBytes
  }

  guard let previous, let previousDate else { return sample }
  let elapsed = currentDate.timeIntervalSince(previousDate)
  guard elapsed > 0, elapsed <= metricsMaxSampleGap else { return sample }

  if !current.cpu.isEmpty, previous.cpu.count == current.cpu.count {
    sample.cpuTotal = cpuUtilisation(
      from: previous.cpu, to: current.cpu, indices: 0..<current.cpu.count)
    for cluster in clusters {
      guard cluster.range.upperBound <= current.cpu.count else { continue }
      let value = cpuUtilisation(from: previous.cpu, to: current.cpu, indices: cluster.range)
      if cluster.isPerformance {
        sample.cpuPerformance = value
      } else {
        sample.cpuEfficiency = value
      }
    }
  }

  if let old = previous.disk, let new = current.disk {
    sample.diskReadBytesPerSec = ratePerSecond(
      from: old.readBytes, to: new.readBytes, elapsed: elapsed, width: .bits64)
    sample.diskWriteBytesPerSec = ratePerSecond(
      from: old.writeBytes, to: new.writeBytes, elapsed: elapsed, width: .bits64)
  }

  // A different NIC means the two counters are unrelated; differencing them invents traffic.
  if let old = previous.network, let new = current.network, old.interface == new.interface {
    sample.netInBytesPerSec = ratePerSecond(
      from: old.inBytes, to: new.inBytes, elapsed: elapsed, width: .bits32)
    sample.netOutBytesPerSec = ratePerSecond(
      from: old.outBytes, to: new.outBytes, elapsed: elapsed, width: .bits32)
  }

  return sample
}
