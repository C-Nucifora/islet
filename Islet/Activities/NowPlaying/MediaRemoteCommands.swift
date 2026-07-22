import Foundation

/// Send-side MediaRemote still works in-process on macOS 15.4+ (only reads were locked down).
/// Command codes match MRMediaRemoteCommand: play=0, pause=1, toggle=2, next=4, previous=5.
final class MediaRemoteCommands: @unchecked Sendable {
  static let shared = MediaRemoteCommands()

  private typealias SendCommand = @convention(c) (Int, AnyObject?) -> Bool
  private typealias SetElapsed = @convention(c) (Double) -> Void
  private let sendCommand: SendCommand?
  private let setElapsed: SetElapsed?

  private init() {
    guard
      let bundle = CFBundleCreate(
        kCFAllocatorDefault,
        NSURL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework"))
    else {
      sendCommand = nil
      setElapsed = nil
      return
    }
    sendCommand = CFBundleGetFunctionPointerForName(
      bundle, "MRMediaRemoteSendCommand" as CFString
    )
    .map { unsafeBitCast($0, to: SendCommand.self) }
    setElapsed = CFBundleGetFunctionPointerForName(
      bundle, "MRMediaRemoteSetElapsedTime" as CFString
    )
    .map { unsafeBitCast($0, to: SetElapsed.self) }
  }

  func play() { _ = sendCommand?(0, nil) }
  func pause() { _ = sendCommand?(1, nil) }
  func togglePlayPause() { _ = sendCommand?(2, nil) }
  func next() { _ = sendCommand?(4, nil) }
  func previous() { _ = sendCommand?(5, nil) }
  func seek(to seconds: Double) { setElapsed?(seconds) }
}
