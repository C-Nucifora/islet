import CoreGraphics
import Foundation

struct BrightnessDisplayTarget: Equatable {
  let displayID: CGDirectDisplayID
  let frame: CGRect
}

enum BrightnessTargetResolver {
  static func displayID(
    at point: CGPoint, displays: [BrightnessDisplayTarget]
  ) -> CGDirectDisplayID? {
    displays.first { $0.frame.contains(point) }?.displayID
  }
}

/// Display brightness via the private DisplayServices framework (dlopen, no linkage).
/// Degrades to no-op if the symbols are unavailable on this macOS.
enum BrightnessController {
  private typealias GetFn =
    @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) ->
    Int32
  private typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32

  nonisolated(unsafe) private static let handle: UnsafeMutableRawPointer? = {
    for path in [
      "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
      "/System/Library/PrivateFrameworks/DisplayServices.framework/Versions/Current/DisplayServices",
    ] {
      if let h = dlopen(path, RTLD_LAZY) { return h }
    }
    return nil
  }()

  private static let getFn: GetFn? =
    handle
    .flatMap { dlsym($0, "DisplayServicesGetBrightness") }
    .map { unsafeBitCast($0, to: GetFn.self) }
  private static let setFn: SetFn? =
    handle
    .flatMap { dlsym($0, "DisplayServicesSetBrightness") }
    .map { unsafeBitCast($0, to: SetFn.self) }

  static func adjustBrightness(
    displayID: CGDirectDisplayID, up: Bool, divisor: Float
  ) -> Float? {
    guard let getFn, let setFn else { return nil }
    return adjustBrightness(
      displayID: displayID, up: up, divisor: divisor,
      read: { displayID in
        var value: Float = 0
        guard getFn(displayID, &value) == 0 else { return nil }
        return max(0, min(1, value))
      },
      write: { displayID, value in
        setFn(displayID, max(0, min(1, value))) == 0
      })
  }

  static func adjustBrightness(
    displayID: CGDirectDisplayID, up: Bool, divisor: Float,
    read: (CGDirectDisplayID) -> Float?,
    write: (CGDirectDisplayID, Float) -> Bool
  ) -> Float? {
    guard let current = read(displayID) else { return nil }
    let target = HUDMath.stepped(current, up: up, divisor: divisor)
    guard write(displayID, target) else { return nil }
    return target
  }
}
