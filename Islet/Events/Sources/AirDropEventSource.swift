import AppKit
import Combine
import Foundation

/// AirDrop sends that Islet itself initiated.
///
/// **Real, but narrow.** `NSSharingService` reports its own completion reliably — but only for
/// shares Islet starts. Islet starts exactly one: the file shelf's AirDrop button. A Finder or
/// Safari AirDrop is invisible to this, and no public API changes that.
@MainActor
final class AirDropOutEventSource: SystemEventSource {
  let id = "airdropOut"
  let displayName = "AirDrop sent"
  let tier = SystemEventTier.heuristic

  private var running = false

  func start() { running = true }
  func stop() { running = false }

  /// Called by the shelf's AirDrop action once the share service reports completion.
  func report(fileCount: Int) {
    guard running else { return }
    SystemEventBus.shared.emit(
      SystemEvent(
        sourceID: id, icon: "square.and.arrow.up",
        title: fileCount == 1 ? "Sent by AirDrop" : "\(fileCount) files sent",
        accentHex: EventAccent.info, motion: .airdrop,
        announcement: "AirDrop send complete"))
  }
}

/// Files that appear to have arrived by AirDrop.
///
/// **The weakest source in Islet, and the UI says so.** There is no AirDrop receive API. This
/// watches `~/Downloads` and, when a file appears, checks whether `sharingd` is recorded as its
/// quarantine agent. That means:
///
/// - it fires **after** the transfer completes, never during, so there is no progress;
/// - it cannot name the sender, because the originating device is not recorded anywhere readable;
/// - it needs the Downloads folder TCC grant, and macOS prompts on first read.
///
/// When the grant is refused the source disables itself rather than retrying — a denied TCC read
/// returns the same error forever, and a retry loop would just burn CPU.
@MainActor
final class AirDropInEventSource: SystemEventSource {
  let id = "airdropIn"
  let displayName = "AirDrop received"
  let tier = SystemEventTier.heuristic

  private var source: DispatchSourceFileSystemObject?
  private var descriptor: CInt = -1
  private var known: Set<String> = []

  private var downloads: URL? {
    FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
  }

  func start() {
    guard source == nil, let downloads else { return }
    guard let initial = Self.contents(of: downloads) else {
      Log.app.notice("Downloads folder unreadable; AirDrop receive events unavailable")
      return
    }
    known = initial

    let fd = open(downloads.path, O_EVTONLY)
    guard fd >= 0 else { return }
    descriptor = fd
    let s = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: fd, eventMask: .write, queue: .main)
    s.setEventHandler { [weak self] in
      MainActor.assumeIsolated { self?.check() }
    }
    // Owns the close: cancel() is asynchronous, and closing the fd from stop() while the source is
    // still draining is a documented fd-reuse race.
    s.setCancelHandler { close(fd) }
    source = s
    s.resume()
  }

  func stop() {
    source?.cancel()  // its cancellation handler closes the fd
    source = nil
    descriptor = -1
    known = []
  }

  private func check() {
    guard let downloads, let now = Self.contents(of: downloads) else { return }
    let appeared = now.subtracting(known)
    known = now
    for name in appeared {
      let url = downloads.appendingPathComponent(name)
      guard Self.arrivedViaAirDrop(url) else { continue }
      SystemEventBus.shared.emit(
        SystemEvent(
          sourceID: id, icon: "square.and.arrow.down", title: "AirDrop received",
          subtitle: name, accentHex: EventAccent.info, motion: .airdrop,
          duration: 3,
          announcement: "Received \(name) by AirDrop"))
    }
  }

  private static func contents(of url: URL) -> Set<String>? {
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) else {
      return nil
    }
    return Set(names.filter { !$0.hasPrefix(".") })
  }

  /// `sharingd` is the daemon that writes AirDrop arrivals, and it records itself as the quarantine
  /// agent. Anything else in Downloads — a browser download, a file you moved there — has a
  /// different agent or none at all.
  private static func arrivedViaAirDrop(_ url: URL) -> Bool {
    guard
      let values = try? url.resourceValues(forKeys: [.quarantinePropertiesKey]),
      let quarantine = values.quarantineProperties,
      let agent = quarantine[kLSQuarantineAgentNameKey as String] as? String
    else { return false }
    return agent.localizedCaseInsensitiveContains("sharingd")
  }
}

enum AirDropShareOutcome: Equatable {
  case shared
  case cancelled
  case failed(String)

  static func from(error: Error) -> Self {
    let error = error as NSError
    if (error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled)
      || (error.domain == NSCocoaErrorDomain
        && error.code == CocoaError.Code.userCancelled.rawValue)
    {
      return .cancelled
    }
    return .failed(error.localizedDescription)
  }
}

enum AirDropShareState: Equatable {
  case ready
  case unavailable
  case sharing
  case cancelled
  case busy
  case failed(String)
}

enum AirDropShareStartResult {
  case started
  case unavailable
  case busy
}

/// Owns the visible state for one Shelf share. Its launcher is injected so the state transitions
/// can be tested without presenting the macOS AirDrop sheet.
@MainActor
final class AirDropShareController: ObservableObject {
  typealias ServiceAvailable = @MainActor () -> Bool
  typealias StartShare =
    @MainActor ([URL], @escaping @MainActor (AirDropShareOutcome) -> Void) ->
    AirDropShareStartResult

  @Published private(set) var state: AirDropShareState = .ready
  @Published private(set) var isServiceAvailable: Bool

  private let serviceAvailable: ServiceAvailable
  private let startShare: StartShare

  init(
    serviceAvailable: @escaping ServiceAvailable = AirDropShareLauncher.isAvailable,
    startShare: @escaping StartShare = AirDropShareLauncher.start
  ) {
    self.serviceAvailable = serviceAvailable
    self.startShare = startShare
    isServiceAvailable = serviceAvailable()
    if !isServiceAvailable { state = .unavailable }
  }

  var isSharing: Bool { state == .sharing }
  var isActionEnabled: Bool {
    isServiceAvailable && state != .sharing && state != .busy
  }

  func refreshAvailability() {
    isServiceAvailable = serviceAvailable()
    if !isServiceAvailable { state = .unavailable }
    if case .unavailable = state, isServiceAvailable { state = .ready }
  }

  func share(_ urls: [URL], onFinish: @escaping @MainActor () -> Void = {}) {
    guard !urls.isEmpty else {
      onFinish()
      return
    }
    refreshAvailability()
    guard isServiceAvailable else {
      onFinish()
      return
    }
    guard !isSharing else {
      onFinish()
      return
    }

    var didFinish = false
    let finishOnce: @MainActor () -> Void = {
      guard !didFinish else { return }
      didFinish = true
      onFinish()
    }
    state = .sharing
    switch startShare(
      urls,
      { [weak self] outcome in
        self?.finish(outcome)
        finishOnce()
      })
    {
    case .started:
      break
    case .unavailable:
      isServiceAvailable = false
      state = .unavailable
      finishOnce()
    case .busy:
      if isSharing { state = .busy }
      finishOnce()
    }
  }

  func retry(_ urls: [URL], onFinish: @escaping @MainActor () -> Void = {}) {
    guard state != .sharing else {
      onFinish()
      return
    }
    share(urls, onFinish: onFinish)
  }

  func dismissFeedback() {
    guard state != .sharing else { return }
    state = isServiceAvailable ? .ready : .unavailable
  }

  private func finish(_ outcome: AirDropShareOutcome) {
    guard isSharing else { return }
    switch outcome {
    case .shared: state = .ready
    case .cancelled: state = .cancelled
    case .failed(let message): state = .failed(message)
    }
  }
}

/// Adapts AppKit's weak delegate API to `AirDropShareController`.
@MainActor
enum AirDropShareLauncher {
  static func isAvailable() -> Bool {
    NSSharingService(named: .sendViaAirDrop) != nil
  }

  static func start(
    _ urls: [URL], completion: @escaping (AirDropShareOutcome) -> Void
  ) -> AirDropShareStartResult {
    guard let service = NSSharingService(named: .sendViaAirDrop) else { return .unavailable }
    guard AirDropShareObserver.begin(service, completion: completion) else { return .busy }
    service.perform(withItems: urls)
    return .started
  }
}

/// Holds one AirDrop share's weak delegate long enough to deliver exactly one outcome.
@MainActor
final class AirDropShareObserver: NSObject, NSSharingServiceDelegate {
  /// Strong reference for the share in flight. AppKit's AirDrop sheet supports one transfer here,
  /// and keeping that limit avoids losing a completion by replacing the delegate.
  private static var current: AirDropShareObserver?
  private let completion: (AirDropShareOutcome) -> Void

  private init(completion: @escaping (AirDropShareOutcome) -> Void) {
    self.completion = completion
  }

  static func begin(
    _ service: NSSharingService, completion: @escaping (AirDropShareOutcome) -> Void
  ) -> Bool {
    guard current == nil else { return false }
    let observer = AirDropShareObserver(completion: completion)
    current = observer
    service.delegate = observer
    return true
  }

  func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
    AppState.airdropOut.report(fileCount: items.count)
    finish(.shared)
  }

  func sharingService(
    _ sharingService: NSSharingService, didFailToShareItems items: [Any], error: any Error
  ) {
    finish(.from(error: error))
  }

  private func finish(_ outcome: AirDropShareOutcome) {
    guard Self.current === self else { return }
    Self.current = nil
    completion(outcome)
  }
}
