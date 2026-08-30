import AppKit
import Foundation

enum MediaCommand: Equatable, Sendable {
  case toggleShuffle
  case skipBackward15
  case previous
  case togglePlayPause
  case skipForward15
  case next
  case cycleRepeat
  case seek(to: Double)

  fileprivate var commandCode: Int? {
    switch self {
    case .togglePlayPause: 2
    case .next: 4
    case .previous: 5
    case .toggleShuffle: 6
    case .cycleRepeat: 7
    case .skipBackward15: 12
    case .skipForward15: 13
    case .seek: nil
    }
  }

  var feedbackName: String {
    switch self {
    case .toggleShuffle: "change shuffle"
    case .skipBackward15: "skip back 15 seconds"
    case .previous: "go to the previous track"
    case .togglePlayPause: "change playback"
    case .skipForward15: "skip forward 15 seconds"
    case .next: "go to the next track"
    case .cycleRepeat: "change repeat"
    case .seek: "seek"
    }
  }
}

enum MediaCommandResult: Equatable, Sendable {
  case sent(target: SourceID, sourceScoped: Bool)
  case sourceNotControllable(SourceID)
  case sourceTargetingUnavailable(SourceID)
  case rejected(target: SourceID)
}

/// A short explanation shown beside the media controls when the attempted action did not run.
/// Source identities stay out of this copy because the card itself already names the app.
enum MediaControlFeedback {
  static func message(for command: MediaCommand, result: MediaCommandResult) -> String? {
    let action = command.feedbackName
    switch result {
    case .sent:
      return nil
    case .sourceNotControllable:
      return "Can't \(action): this audio source has no media controls"
    case .sourceTargetingUnavailable:
      return "Can't \(action): Islet can't target this player safely"
    case .rejected:
      return "Can't \(action): the player rejected it"
    }
  }

  static func logReason(for result: MediaCommandResult) -> String? {
    switch result {
    case .sent:
      return nil
    case .sourceNotControllable: return "source-not-controllable"
    case .sourceTargetingUnavailable: return "source-targeting-unavailable"
    case .rejected: return "rejected"
    }
  }
}

enum MediaCommandTargeting: Equatable, Sendable {
  case sourceScoped
  case verifiedGlobal
  case unavailable

  var controlsAvailable: Bool { self != .unavailable }
}

/// Resolves the live MediaRemote source immediately before a global command and fails closed unless
/// its full bundle, parent, and process identity still matches the card the user acted on. The
/// enclosing command queue keeps that check adjacent to the send and prevents local command races.
enum MediaCommandRouter {
  typealias Send = @Sendable (MediaCommand, SourceID?) async -> Bool
  typealias ResolveCurrentTarget = @Sendable () async -> SourceID?

  static func perform(
    _ command: MediaCommand,
    shownSource: SourceID,
    sourceIsAdapterBacked: Bool,
    targeting: MediaCommandTargeting,
    resolveCurrentTarget: ResolveCurrentTarget,
    send: Send
  ) async -> MediaCommandResult {
    guard sourceIsAdapterBacked else { return .sourceNotControllable(shownSource) }
    let target: SourceID?
    let sourceScoped: Bool
    switch targeting {
    case .sourceScoped:
      target = shownSource
      sourceScoped = true
    case .verifiedGlobal:
      guard await resolveCurrentTarget() == shownSource else {
        return .sourceTargetingUnavailable(shownSource)
      }
      target = nil
      sourceScoped = false
    case .unavailable:
      return .sourceTargetingUnavailable(shownSource)
    }
    return await send(command, target)
      ? .sent(target: shownSource, sourceScoped: sourceScoped)
      : .rejected(target: shownSource)
  }
}

actor MediaCommandQueue {
  private var isRunning = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func enqueue(
    _ operation: @escaping @Sendable () async -> MediaCommandResult
  ) async -> MediaCommandResult {
    if isRunning {
      await withCheckedContinuation { continuation in
        waiters.append(continuation)
      }
    } else {
      isRunning = true
    }
    let result = await operation()
    if waiters.isEmpty {
      isRunning = false
    } else {
      waiters.removeFirst().resume()
    }
    return result
  }
}

enum MediaControlPresentation {
  static func scopeLabel(appName: String, targeting: MediaCommandTargeting) -> String {
    switch targeting {
    case .sourceScoped: "Controls \(appName)"
    case .verifiedGlobal: "Global controls for \(appName)"
    case .unavailable: "Controls unavailable for \(appName)"
    }
  }

  static func help(action: String, appName: String, targeting: MediaCommandTargeting) -> String {
    switch targeting {
    case .sourceScoped: "\(action) in \(appName)"
    case .verifiedGlobal: "\(action) in \(appName) after verifying the global media target"
    case .unavailable: "\(action) unavailable because Islet cannot target \(appName) safely"
    }
  }

  static func accessibilityLabel(action: String, targeting: MediaCommandTargeting) -> String {
    switch targeting {
    case .sourceScoped: action
    case .verifiedGlobal: "\(action), verified global media control"
    case .unavailable: "\(action) unavailable"
    }
  }
}

/// Send-side MediaRemote still works in-process on macOS 15.4+; reads require the entitled helper.
/// Command codes match MRMediaRemoteCommand: toggle=2, next=4, previous=5.
final class MediaRemoteCommands: @unchecked Sendable {
  static let shared = MediaRemoteCommands()

  private typealias SendCommand = @convention(c) (Int, AnyObject?) -> Bool
  private typealias SetElapsed = @convention(c) (Double) -> Void
  private typealias SetPlayerIfPossible = @convention(c) (AnyObject?) -> Bool
  private let sendCommand: SendCommand?
  private let setElapsed: SetElapsed?
  private let setPlayerIfPossible: SetPlayerIfPossible?
  private let queue = MediaCommandQueue()

  /// MediaRemoteAdapter 0.1.0 exports global send and seek functions. Islet checks the live adapter
  /// target inside the serialized command operation before using those global functions.
  let targeting = MediaCommandTargeting.verifiedGlobal

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
  /// only. See `promote(_:)` for why it is not called.
  var canPromoteDirectly: Bool { setPlayerIfPossible != nil }

  /// Brings the source's application forward. This does not make a CoreAudio observation into a
  /// controllable MediaRemote player.
  ///
  /// `MRMediaRemoteSetNowPlayingPlayerIfPossible` takes an `MRPlayerPath` object, and the only
  /// calls that produce one are the entitled reads macOS 15.4 locked down. Islet cannot hand it a
  /// player from this process. Passing nil into a private framework is undefined behaviour, so the
  /// symbol is resolved for diagnostics but never invoked.
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

  func perform(
    _ command: MediaCommand,
    shownSource: SourceID,
    sourceIsAdapterBacked: Bool,
    resolveCurrentTarget: @escaping MediaCommandRouter.ResolveCurrentTarget
  ) async -> MediaCommandResult {
    await queue.enqueue { [self] in
      await MediaCommandRouter.perform(
        command,
        shownSource: shownSource,
        sourceIsAdapterBacked: sourceIsAdapterBacked,
        targeting: targeting,
        resolveCurrentTarget: resolveCurrentTarget,
        send: { [self] command, source in await send(command, to: source) })
    }
  }

  private func send(_ command: MediaCommand, to source: SourceID?) async -> Bool {
    // The current transport cannot address a source. Refuse rather than silently treating a
    // scoped request as global if the capability declaration and implementation diverge.
    guard source == nil else { return false }
    if case .seek(let seconds) = command {
      guard seconds.isFinite, seconds >= 0, let setElapsed else { return false }
      setElapsed(seconds)
      return true
    }
    guard let code = command.commandCode, let sendCommand else { return false }
    return sendCommand(code, nil)
  }

}
