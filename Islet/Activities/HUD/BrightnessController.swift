import CoreGraphics
import Foundation

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

  static var isAvailable: Bool { getFn != nil && setFn != nil }

  static func currentBrightness() -> Float {
    guard let getFn else { return 0 }
    var value: Float = 0
    return getFn(CGMainDisplayID(), &value) == 0 ? max(0, min(1, value)) : 0
  }

  static func setBrightness(_ value: Float) {
    guard let setFn else { return }
    _ = setFn(CGMainDisplayID(), max(0, min(1, value)))
  }
}
