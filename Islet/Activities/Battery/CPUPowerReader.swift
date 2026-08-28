import Darwin
import Foundation

/// Converts an IOReport energy delta into average power. Energy Model's simple counters are
/// millijoules, so mJ / seconds / 1,000 is watts.
enum CPUPowerMath {
  static func watts(millijoules: Int, elapsedSeconds: TimeInterval) -> Double? {
    guard millijoules >= 0, elapsedSeconds > 0 else { return nil }
    let watts = Double(millijoules) / elapsedSeconds / 1000
    return watts.isFinite ? watts : nil
  }
}

/// Reads Apple's estimated aggregate CPU energy on Apple Silicon without invoking the root-only
/// `powermetrics` process.
///
/// IOReport is private and its channels differ between chips, so every lookup is dynamic and every
/// result is optional. Failure simply leaves the existing whole-Mac branch intact. The subscription
/// is retained for this process's lifetime; sampling is serialized because IOReport subscriptions
/// are stateful and battery refreshes can be requested while an earlier read is still finishing.
final class CPUPowerReader: @unchecked Sendable {
  static let shared = CPUPowerReader()

  private static let sampleDuration: TimeInterval = 0.25

  private let lock = NSLock()
  private let library: IOReportLibrary?
  private let subscription: UnsafeRawPointer?
  private let subscribedChannels: CFMutableDictionary?

  private init() {
    guard let library = IOReportLibrary() else {
      self.library = nil
      subscription = nil
      subscribedChannels = nil
      return
    }

    guard
      let desired = library.copyChannelsInGroup(
        "Energy Model" as CFString, nil, 0, 0, 0)?.takeRetainedValue()
    else {
      self.library = library
      subscription = nil
      subscribedChannels = nil
      return
    }

    var unmanagedChannels: Unmanaged<CFMutableDictionary>?
    let subscription = library.createSubscription(
      nil, desired, &unmanagedChannels, 0, nil)

    self.library = library
    self.subscription = subscription
    subscribedChannels = unmanagedChannels?.takeRetainedValue()
  }

  /// Average CPU watts over a short window. Normal monitoring calls this inside BatteryMonitor's
  /// detached utility task, so the deliberate wait does not block the UI.
  func readWatts() -> Double? {
    lock.lock()
    defer { lock.unlock() }

    guard let library, let subscription, let subscribedChannels,
      let first = library.createSamples(subscription, subscribedChannels, nil)?.takeRetainedValue()
    else { return nil }

    let started = DispatchTime.now().uptimeNanoseconds
    Thread.sleep(forTimeInterval: Self.sampleDuration)
    guard
      let second = library.createSamples(subscription, subscribedChannels, nil)?.takeRetainedValue()
    else { return nil }
    let finished = DispatchTime.now().uptimeNanoseconds
    let elapsed = Double(finished - started) / 1_000_000_000

    guard
      let delta = library.createSamplesDelta(first, second, nil)?.takeRetainedValue(),
      let millijoules = cpuEnergyMillijoules(in: delta, using: library)
    else { return nil }
    return CPUPowerMath.watts(millijoules: millijoules, elapsedSeconds: elapsed)
  }

  /// Newer Apple Silicon publishes one `CPU Energy` total. The exact ECPU/PCPU totals are used
  /// only as a fallback for a chip that omits that aggregate; per-core, SRAM and fabric siblings
  /// are deliberately ignored because summing them would count the same CPU work twice.
  private func cpuEnergyMillijoules(
    in samples: CFDictionary, using library: IOReportLibrary
  ) -> Int? {
    let dictionary = samples as NSDictionary
    guard
      let channels = dictionary["IOReportChannels"] as? [NSDictionary]
    else { return nil }

    var efficiencyCluster: Int?
    var performanceCluster: Int?
    for channel in channels {
      guard
        let legend = channel["LegendChannel"] as? [Any], legend.count >= 3,
        let name = legend[2] as? String
      else { continue }

      let sample = unsafeBitCast(channel, to: CFDictionary.self)
      let value = library.simpleGetIntegerValue(sample, 0)
      guard value >= 0 else { continue }

      if matchesUnit(name, "CPU Energy") { return value }
      if matchesUnit(name, "ECPU") { efficiencyCluster = value }
      if matchesUnit(name, "PCPU") { performanceCluster = value }
    }
    guard let efficiencyCluster, let performanceCluster else { return nil }
    return efficiencyCluster + performanceCluster
  }

  private func matchesUnit(_ name: String, _ unit: String) -> Bool {
    name == unit || name.hasSuffix(" \(unit)")
  }
}

/// Runtime bindings keep the private library out of Islet's link contract. A macOS update can
/// remove any symbol without preventing the app from launching; the CPU split then disappears.
private final class IOReportLibrary: @unchecked Sendable {
  typealias CopyChannelsInGroup =
    @convention(c) (CFString, CFString?, UInt64, UInt64, UInt64) ->
    Unmanaged<CFMutableDictionary>?
  typealias CreateSubscription =
    @convention(c) (
      UnsafeMutableRawPointer?, CFMutableDictionary,
      UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>, UInt64, UnsafeRawPointer?
    ) -> UnsafeRawPointer?
  typealias CreateSamples =
    @convention(c) (UnsafeRawPointer, CFMutableDictionary, UnsafeRawPointer?) ->
    Unmanaged<CFDictionary>?
  typealias CreateSamplesDelta =
    @convention(c) (CFDictionary, CFDictionary, UnsafeRawPointer?) -> Unmanaged<CFDictionary>?
  typealias SimpleGetIntegerValue = @convention(c) (CFDictionary, Int32) -> Int

  private let handle: UnsafeMutableRawPointer
  let copyChannelsInGroup: CopyChannelsInGroup
  let createSubscription: CreateSubscription
  let createSamples: CreateSamples
  let createSamplesDelta: CreateSamplesDelta
  let simpleGetIntegerValue: SimpleGetIntegerValue

  init?() {
    guard let libraryHandle = dlopen("/usr/lib/libIOReport.dylib", RTLD_LAZY | RTLD_LOCAL) else {
      return nil
    }
    guard
      let copyChannelsInGroup: CopyChannelsInGroup = Self.symbol(
        "IOReportCopyChannelsInGroup", in: libraryHandle),
      let createSubscription: CreateSubscription = Self.symbol(
        "IOReportCreateSubscription", in: libraryHandle),
      let createSamples: CreateSamples = Self.symbol("IOReportCreateSamples", in: libraryHandle),
      let createSamplesDelta: CreateSamplesDelta = Self.symbol(
        "IOReportCreateSamplesDelta", in: libraryHandle),
      let simpleGetIntegerValue: SimpleGetIntegerValue = Self.symbol(
        "IOReportSimpleGetIntegerValue", in: libraryHandle)
    else {
      dlclose(libraryHandle)
      return nil
    }

    self.handle = libraryHandle
    self.copyChannelsInGroup = copyChannelsInGroup
    self.createSubscription = createSubscription
    self.createSamples = createSamples
    self.createSamplesDelta = createSamplesDelta
    self.simpleGetIntegerValue = simpleGetIntegerValue
  }

  deinit { dlclose(handle) }

  private static func symbol<T>(_ name: String, in handle: UnsafeMutableRawPointer) -> T? {
    guard let pointer = dlsym(handle, name) else { return nil }
    return unsafeBitCast(pointer, to: T.self)
  }
}
