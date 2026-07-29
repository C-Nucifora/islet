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
    source = s
    s.resume()
  }

  func stop() {
    source?.cancel()
    source = nil
    if descriptor >= 0 { close(descriptor) }
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
