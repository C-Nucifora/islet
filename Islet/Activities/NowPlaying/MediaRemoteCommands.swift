import AppKit
import Foundation

/// Send-side MediaRemote still works in-process on macOS 15.4+ (only reads were locked down).
/// Command codes match MRMediaRemoteCommand: play=0, pause=1, toggle=2, next=4, previous=5.
final class MediaRemoteCommands: @unchecked Sendable {
  static let shared = MediaRemoteCommands()

  private typealias SendCommand = @convention(c) (Int, AnyObject?) -> Bool
  private typealias SetElapsed = @convention(c) (Double) -> Void
  private typealias SetPlayerIfPossible = @convention(c) (AnyObject?) -> Bool
  private let sendCommand: SendCommand?
  private let setElapsed: SetElapsed?
  private let setPlayerIfPossible: SetPlayerIfPossible?

  private init() {
    guard
      let bundle = CFBundleCreate(
        kCFAllocatorDefault,
        NSURL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework"))
    else {
      sendCommand = nil
      setElapsed = nil
      setPlayerIfPossible = nil
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
    setPlayerIfPossible = CFBundleGetFunctionPointerForName(
      bundle, "MRMediaRemoteSetNowPlayingPlayerIfPossible" as CFString
    )
    .map { unsafeBitCast($0, to: SetPlayerIfPossible.self) }
  }

  /// Whether `MRMediaRemoteSetNowPlayingPlayerIfPossible` resolved in this process. Diagnostic
  /// only — see `promote(_:)` for why it is not called.
  var canPromoteDirectly: Bool { setPlayerIfPossible != nil }

  /// Makes `source` the player the user is looking at.
  ///
  /// `MRMediaRemoteSetNowPlayingPlayerIfPossible` takes an `MRPlayerPath` object, and the only
  /// calls that produce one are the entitled reads macOS 15.4 locked down — the reason
  /// `MediaWatcher` shells out to /usr/bin/perl at all. Islet cannot hand it a player from
  /// in-process, and passing nil into a private framework is undefined behaviour, so the symbol is
  /// resolved (the fork described in the design spec's "Upgrade path — fork the MediaRemote adapter
  /// for true per-source media" section will use it) but never invoked. Activating the owning app
  /// is the fallback that works today, and is what tapping a chip means anyway.
  @MainActor @discardableResult
  func promote(_ source: SourceID) -> Bool {
    if !canPromoteDirectly {
      Log.media.notice("MRMediaRemoteSetNowPlayingPlayerIfPossible did not resolve")
    }
    return Self.activateApp(pid: source.pid, bundleID: source.displayBundleIdentifier)
  }

  @MainActor
  private static func activateApp(pid: Int32, bundleID: String) -> Bool {
    if let app = NSRunningApplication(processIdentifier: pid),
      app.bundleIdentifier == bundleID
    {
      return app.activate()
    }
    if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
      return app.activate()
    }
    Log.media.notice("No running application for \(bundleID, privacy: .public); promote is a no-op")
    return false
  }

  func play() { _ = sendCommand?(0, nil) }
  func pause() { _ = sendCommand?(1, nil) }
  func togglePlayPause() { _ = sendCommand?(2, nil) }
  func next() { _ = sendCommand?(4, nil) }
  func previous() { _ = sendCommand?(5, nil) }
  func toggleShuffle() { _ = sendCommand?(6, nil) }
  func cycleRepeat() { _ = sendCommand?(7, nil) }
  func skipBackward15() { _ = sendCommand?(12, nil) }
  func skipForward15() { _ = sendCommand?(13, nil) }
  func seek(to seconds: Double) { setElapsed?(seconds) }
}
