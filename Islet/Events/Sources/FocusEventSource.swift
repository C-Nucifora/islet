import Combine
import Foundation

/// Focus / Do Not Disturb.
///
/// **Heuristic.** There is no public API to read the current Focus. The App Intents route
/// (`SetFocusFilterIntent`) would need a whole new extension target in `project.yml`, so this reads
/// `~/Library/DoNotDisturb/DB/Assertions.json` — the file the system writes when a Focus is
/// asserted. That format is undocumented and has changed between macOS releases, so every read is
/// defensive: an unrecognised shape emits nothing rather than guessing.
@MainActor
final class FocusEventSource: SystemEventSource {
  let id = "focus"
  let displayName = "Focus mode"
  let tier = SystemEventTier.heuristic

  private var source: DispatchSourceFileSystemObject?
  private var descriptor: CInt = -1
  private var lastActive: String?

  private var assertionsURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/DoNotDisturb/DB/Assertions.json")
  }

  func start() {
    guard source == nil else { return }
    lastActive = Self.activeFocus(at: assertionsURL)
    watch()
  }

  func stop() {
    source?.cancel()
    source = nil
    if descriptor >= 0 { close(descriptor) }
    descriptor = -1
    lastActive = nil
  }

  private func watch() {
    let fd = open(assertionsURL.path, O_EVTONLY)
    guard fd >= 0 else {
      // The file only exists once a Focus has been used at least once. Nothing to watch yet —
      // fail quiet rather than retrying on a timer.
      Log.app.notice("Focus assertions file not present; Focus events unavailable")
      return
    }
    descriptor = fd
    let s = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: .main)
    s.setEventHandler { [weak self] in
      MainActor.assumeIsolated {
        guard let self else { return }
        // A rewrite replaces the file, which invalidates the descriptor — re-arm on the new inode.
        self.check()
        self.rearmIfReplaced(s)
      }
    }
    source = s
    s.resume()
  }

  private func rearmIfReplaced(_ s: DispatchSourceFileSystemObject) {
    guard s.data.contains(.delete) || s.data.contains(.rename) else { return }
    source?.cancel()
    source = nil
    if descriptor >= 0 { close(descriptor) }
    descriptor = -1
    watch()
  }

  private func check() {
    let active = Self.activeFocus(at: assertionsURL)
    guard active != lastActive else { return }
    let previous = lastActive
    lastActive = active

    if let active {
      SystemEventBus.shared.emit(
        SystemEvent(
          sourceID: id, icon: "moon.circle.fill", title: "Focus on", subtitle: active,
          accentHex: EventAccent.info, motion: .focus, urgency: .ambient,
          announcement: "Focus on, \(active)"))
    } else if previous != nil {
      SystemEventBus.shared.emit(
        SystemEvent(
          sourceID: id, icon: "moon.circle", title: "Focus off",
          accentHex: EventAccent.neutral, motion: .focus, urgency: .ambient,
          announcement: "Focus off"))
    }
  }

  /// Returns the active Focus identifier, or nil when none is asserted or the file's shape is not
  /// what this version of macOS wrote last time anyone looked.
  static func activeFocus(at url: URL) -> String? {
    guard let data = try? Data(contentsOf: url),
      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let store = root["data"] as? [[String: Any]],
      let first = store.first,
      let records = first["storeAssertionRecords"] as? [[String: Any]],
      let record = records.first,
      let details = record["assertionDetails"] as? [String: Any],
      let identifier = details["assertionDetailsModeIdentifier"] as? String
    else { return nil }
    // The identifier is a reverse-DNS mode id; the trailing component is the closest thing to a
    // friendly name that is available without private frameworks.
    return identifier.split(separator: ".").last.map(String.init) ?? identifier
  }
}
