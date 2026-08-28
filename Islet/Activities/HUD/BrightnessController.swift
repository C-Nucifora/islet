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

  /// Symbol availability is not sufficient: external displays commonly reject the operation.
  /// A successful read is the non-mutating capability probe used by diagnostics.
  static var isAvailable: Bool { readBrightness() != nil && setFn != nil }

  static func readBrightness(
    displayID: CGDirectDisplayID = CGMainDisplayID()
  ) -> Float? {
    guard let getFn else { return nil }
    var value: Float = 0
    guard getFn(displayID, &value) == 0 else { return nil }
    return max(0, min(1, value))
  }

  static func adjustBrightness(
    displayID: CGDirectDisplayID, up: Bool, divisor: Float
  ) -> Float? {
    guard
      let target = adjustBrightness(
        displayID: displayID, up: up, divisor: divisor,
        read: { displayID in readBrightness(displayID: displayID) },
        write: { displayID, value in
          setBrightness(value, displayID: displayID)
        })
    else { return nil }
    return readBrightness(displayID: displayID) ?? target
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

  static func currentBrightness() -> Float { readBrightness() ?? 0 }

  /// Applies brightness and verifies the current display accepted it. A false result tells the
  /// event tap to pass the key to macOS, preserving the system OSD and native device handling.
  @discardableResult
  static func setBrightness(
    _ value: Float, displayID: CGDirectDisplayID = CGMainDisplayID()
  ) -> Bool {
    guard let setFn, let original = readBrightness(displayID: displayID) else { return false }
    let clamped = max(0, min(1, value))
    guard setFn(displayID, clamped) == 0 else { return false }
    guard
      let readback = readBrightness(displayID: displayID),
      abs(readback - clamped) <= 0.02
    else {
      // Avoid sending a second adjustment through macOS after a partially accepted write.
      _ = setFn(displayID, original)
      return false
    }
    return true
  }
}
