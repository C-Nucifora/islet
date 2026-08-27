import Foundation
import IOKit

struct PeripheralBattery: Identifiable, Equatable, Sendable {
  let id: String
  let name: String
  let percent: Int

  var icon: String {
    let n = name.lowercased()
    if n.contains("mouse") { return "magicmouse.fill" }
    if n.contains("trackpad") { return "trackpad.fill" }
    if n.contains("keyboard") { return "keyboard.fill" }
    if n.contains("pencil") { return "applepencil" }
    return "dot.radiowaves.right"
  }
}

/// Reads battery levels of connected Apple input peripherals (Magic Mouse/Keyboard/Trackpad, etc.)
/// from the AppleDeviceManagementHIDEventService IORegistry entries.
enum PeripheralBatteryReader {
  static func read() -> [PeripheralBattery] {
    var iterator: io_iterator_t = 0
    guard
      IOServiceGetMatchingServices(
        kIOMainPortDefault,
        IOServiceMatching("AppleDeviceManagementHIDEventService"), &iterator) == KERN_SUCCESS
    else { return [] }
    defer { IOObjectRelease(iterator) }

    var result: [PeripheralBattery] = []
    var service = IOIteratorNext(iterator)
    while service != 0 {
      if let percent = intProp(service, "BatteryPercent"), percent > 0,
        let name = strProp(service, "Product"),
        !name.localizedCaseInsensitiveContains("internal")
      {
        result.append(PeripheralBattery(id: name, name: name, percent: percent))
      }
      IOObjectRelease(service)
      service = IOIteratorNext(iterator)
    }
    return result
  }

  private static func intProp(_ service: io_service_t, _ key: String) -> Int? {
    (IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
      .takeRetainedValue() as? NSNumber)?.intValue
  }

  private static func strProp(_ service: io_service_t, _ key: String) -> String? {
    IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
      .takeRetainedValue() as? String
  }
}
