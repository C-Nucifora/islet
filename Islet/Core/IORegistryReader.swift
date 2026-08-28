import Foundation
import IOKit

/// Bulk IORegistry reads.
///
/// `IORegistryEntryCreateCFProperty` is one kernel round trip per key; a monitor reading a dozen
/// keys at 1 Hz pays for all twelve every tick. `IORegistryEntryCreateCFProperties` returns the
/// whole property dictionary in one call, which is what every caller here actually wanted.
enum IORegistryReader {
  /// The full property dictionary of the first service matching `serviceName`, or nil when no such
  /// service exists (a desktop Mac has no AppleSmartBattery, for instance).
  static func properties(matching serviceName: String) -> [String: Any]? {
    let service = IOServiceGetMatchingService(
      kIOMainPortDefault, IOServiceMatching(serviceName))
    guard service != 0 else { return nil }
    defer { IOObjectRelease(service) }
    return properties(of: service)
  }

  /// A deliberately narrow property read for registry nodes that expose very large diagnostic
  /// blobs. `AppleSmartBattery`, for example, includes calibration tables and controller dumps
  /// that Islet never displays. Fetching only the requested keys avoids bridging and allocating
  /// those blobs on every live telemetry sample.
  static func properties(matching serviceName: String, keys: [String]) -> [String: Any]? {
    let service = IOServiceGetMatchingService(
      kIOMainPortDefault, IOServiceMatching(serviceName))
    guard service != 0 else { return nil }
    defer { IOObjectRelease(service) }

    var result: [String: Any] = [:]
    result.reserveCapacity(keys.count)
    for key in keys {
      guard
        let value = IORegistryEntryCreateCFProperty(
          service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
      else { continue }
      result[key] = value
    }
    return result
  }

  /// The same, for every matching service node. `IOBlockStorageDriver` returns several, so the
  /// caller has to decide whether to filter or sum them.
  static func allProperties(matching serviceName: String) -> [[String: Any]] {
    var iterator: io_iterator_t = 0
    guard
      IOServiceGetMatchingServices(
        kIOMainPortDefault, IOServiceMatching(serviceName), &iterator) == KERN_SUCCESS
    else { return [] }
    defer { IOObjectRelease(iterator) }

    var out: [[String: Any]] = []
    var service = IOIteratorNext(iterator)
    while service != 0 {
      if let props = properties(of: service) { out.append(props) }
      IOObjectRelease(service)
      service = IOIteratorNext(iterator)
    }
    return out
  }

  private static func properties(of service: io_service_t) -> [String: Any]? {
    var unmanaged: Unmanaged<CFMutableDictionary>?
    guard
      IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0)
        == KERN_SUCCESS,
      let dict = unmanaged?.takeRetainedValue() as? [String: Any]
    else { return nil }
    return dict
  }

  /// AppleSmartBattery reports amperage as an unsigned 64-bit register: values above `Int32.max`
  /// are the two's-complement encoding of a negative current (discharging).
  static func signedInt(_ raw: Int?) -> Int? {
    guard let raw else { return nil }
    if raw > Int(Int32.max) { return raw - Int(UInt32.max) - 1 }
    return raw
  }
}
