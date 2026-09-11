import Combine
import CryptoKit
import Darwin
import Foundation

enum FocusEventSourceHealth: Equatable {
  case stopped
  case missingFile
  case permissionDenied
  case parseFailed
  case watching
  case healthyEmpty

  var summary: String {
    switch self {
    case .stopped: String(localized: "Stopped")
    case .missingFile: String(localized: "Assertions file missing")
    case .permissionDenied: String(localized: "Cannot read assertions file")
    case .parseFailed: String(localized: "Assertions format not recognised")
    case .watching: String(localized: "Watching")
    case .healthyEmpty: String(localized: "Watching, no Focus active")
    }
  }

  var isFailure: Bool {
    switch self {
    case .missingFile, .permissionDenied, .parseFailed: true
    case .stopped, .watching, .healthyEmpty: false
    }
  }
}

/// The signature contains only JSON key paths and value types. It never includes Focus names,
/// identifiers, or any other assertion value.
struct FocusAssertionsInspection: Equatable {
  let activeIdentifier: String?
  let isRecognised: Bool
  let schemaSignature: String?
}

private enum FocusReadResult {
  case unavailable
  case parsed(String?)
}

/// Focus / Do Not Disturb.
///
/// **Heuristic.** There is no public API to read the current Focus. The App Intents route
/// (`SetFocusFilterIntent`) would need a whole new extension target in `project.yml`, so this reads
/// `~/Library/DoNotDisturb/DB/Assertions.json` — the file the system writes when a Focus is
/// asserted. That format is undocumented and has changed between macOS releases, so every read is
/// defensive: an unrecognised shape emits nothing rather than guessing.
@MainActor
final class FocusEventSource: SystemEventSource, ObservableObject {
  let id = "focus"
  let displayName = String(localized: "Focus mode")
  let tier = SystemEventTier.heuristic

  @Published private(set) var health: FocusEventSourceHealth = .stopped
  @Published private(set) var lastSuccessfulParse: Date?
  @Published private(set) var schemaSignature: String?

  private var source: DispatchSourceFileSystemObject?
  private var directorySource: DispatchSourceFileSystemObject?
  private var lastActive: String?
  private var running = false
  private let assertionsURL: URL

  init(assertionsURL: URL? = nil) {
    self.assertionsURL =
      assertionsURL
      ?? FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/DoNotDisturb/DB/Assertions.json")
  }

  func start() {
    guard !running else { return }
    running = true
    if case .parsed(let active) = inspectCurrentFile() { lastActive = active }
    watchFileOrDirectory()
  }

  func stop() {
    running = false
    // The fd is closed by the source's cancellation handler, never here: cancel() is asynchronous,
    // and closing the descriptor while the source may still be draining is a documented fd-reuse
    // race — a recycled descriptor number could belong to anyone by the time the source lets go.
    source?.cancel()
    source = nil
    directorySource?.cancel()
    directorySource = nil
    lastActive = nil
    health = .stopped
  }

  /// Re-read the source and re-open its vnode watches after macOS restores the file or changes
  /// its permissions.
  func retry() {
    // A disabled event source must not claim to be watching merely because a one-off read worked.
    // Its owning lifecycle starts it again when the user enables the source.
    guard running else { return }

    source?.cancel()
    source = nil
    directorySource?.cancel()
    directorySource = nil
    check()
    watchFileOrDirectory()
  }

  private func watchFileOrDirectory() {
    guard running else { return }
    if !watchFile() { watchDirectory() }
  }

  /// Returns false when the file is not present yet. In that case the parent directory is watched
  /// without polling, so enabling Focus for the first time after Islet launches starts working.
  @discardableResult
  private func watchFile() -> Bool {
    let fd = open(assertionsURL.path, O_EVTONLY)
    guard fd >= 0 else {
      recordOpenFailure(errno)
      return false
    }
    let s = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: .main)
    s.setEventHandler { [weak self] in
      MainActor.assumeIsolated {
        guard let self else { return }
        guard self.running else { return }
        // A rewrite replaces the file, which invalidates the descriptor — re-arm on the new inode.
        self.check()
        self.rearmIfReplaced(s)
      }
    }
    // Owns the close. `fd` is captured by value, so cancellation closes exactly the descriptor
    // this source was watching even after a replacement watch has opened another one.
    s.setCancelHandler { close(fd) }
    source = s
    s.resume()
    return true
  }

  private func rearmIfReplaced(_ s: DispatchSourceFileSystemObject) {
    guard s.data.contains(.delete) || s.data.contains(.rename) else { return }
    source?.cancel()  // its cancellation handler closes the old fd
    source = nil
    watchFileOrDirectory()
  }

  /// Atomic rewrites briefly remove `Assertions.json`; watching only its old inode made that brief
  /// gap permanent. A vnode watch on the directory is callback-driven and adds no polling wake-up.
  private func watchDirectory() {
    guard directorySource == nil else { return }
    let directory = assertionsURL.deletingLastPathComponent()
    let fd = open(directory.path, O_EVTONLY)
    guard fd >= 0 else {
      recordOpenFailure(errno)
      Log.app.notice("Focus assertions directory is unavailable; Focus events cannot watch it")
      return
    }
    let s = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: .main)
    s.setEventHandler { [weak self] in
      MainActor.assumeIsolated {
        guard let self, self.running,
          FileManager.default.fileExists(atPath: self.assertionsURL.path)
        else { return }
        self.directorySource?.cancel()
        self.directorySource = nil
        self.check()
        self.watchFileOrDirectory()
      }
    }
    s.setCancelHandler { close(fd) }
    directorySource = s
    s.resume()
  }

  private func check() {
    guard case .parsed(let active) = inspectCurrentFile() else { return }
    guard active != lastActive else { return }
    let previous = lastActive
    lastActive = active

    if let active {
      SystemEventBus.shared.emit(
        SystemEvent(
          sourceID: id, icon: "moon.circle.fill", title: String(localized: "Focus on"),
          subtitle: active,
          accentHex: EventAccent.info, motion: .focus, urgency: .ambient,
          announcement: String(localized: "Focus on, \(active)")))
    } else if previous != nil {
      SystemEventBus.shared.emit(
        SystemEvent(
          sourceID: id, icon: "moon.circle", title: String(localized: "Focus off"),
          accentHex: EventAccent.neutral, motion: .focus, urgency: .ambient,
          announcement: String(localized: "Focus off")))
    }
  }

  private func inspectCurrentFile() -> FocusReadResult {
    let data: Data
    do {
      data = try Data(contentsOf: assertionsURL)
    } catch {
      health = Self.health(forReadError: error)
      return .unavailable
    }

    let inspection = Self.inspect(data: data)
    schemaSignature = inspection.schemaSignature
    guard inspection.isRecognised else {
      health = .parseFailed
      return .unavailable
    }

    lastSuccessfulParse = Date()
    health = inspection.activeIdentifier == nil ? .healthyEmpty : .watching
    return .parsed(inspection.activeIdentifier)
  }

  private func recordOpenFailure(_ code: Int32) {
    switch code {
    case ENOENT: health = .missingFile
    case EACCES, EPERM: health = .permissionDenied
    default: health = .parseFailed
    }
  }

  static func health(forReadError error: Error) -> FocusEventSourceHealth {
    let error = error as NSError
    if error.domain == NSCocoaErrorDomain {
      if error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError {
        return .missingFile
      }
      if error.code == NSFileReadNoPermissionError { return .permissionDenied }
    }
    if error.domain == NSPOSIXErrorDomain {
      if error.code == Int(EACCES) || error.code == Int(EPERM) { return .permissionDenied }
      if error.code == Int(ENOENT) { return .missingFile }
    }
    return .parseFailed
  }

  static func inspect(data: Data) -> FocusAssertionsInspection {
    guard let root = try? JSONSerialization.jsonObject(with: data) else {
      return FocusAssertionsInspection(
        activeIdentifier: nil, isRecognised: false, schemaSignature: nil)
    }
    let schemaSignature = schemaSignature(for: root)
    guard let root = root as? [String: Any], let records = assertionRecords(in: root) else {
      return FocusAssertionsInspection(
        activeIdentifier: nil, isRecognised: false, schemaSignature: schemaSignature)
    }
    guard !records.isEmpty else {
      return FocusAssertionsInspection(
        activeIdentifier: nil, isRecognised: true, schemaSignature: schemaSignature)
    }
    guard let details = records.first?["assertionDetails"] as? [String: Any],
      let identifier = details["assertionDetailsModeIdentifier"] as? String
    else {
      return FocusAssertionsInspection(
        activeIdentifier: nil, isRecognised: false, schemaSignature: schemaSignature)
    }

    // The identifier is a reverse-DNS mode id; the trailing component is the closest thing to a
    // friendly name that is available without private frameworks.
    let activeIdentifier = identifier.split(separator: ".").last.map(String.init) ?? identifier
    return FocusAssertionsInspection(
      activeIdentifier: activeIdentifier, isRecognised: true, schemaSignature: schemaSignature)
  }

  private static func assertionRecords(in root: [String: Any]) -> [[String: Any]]? {
    if let stores = root["data"] as? [[String: Any]] {
      var records: [[String: Any]] = []
      for store in stores {
        guard let storeRecords = store["storeAssertionRecords"] as? [[String: Any]] else {
          return nil
        }
        records.append(contentsOf: storeRecords)
      }
      return records
    }
    if let store = root["data"] as? [String: Any] {
      return store["storeAssertionRecords"] as? [[String: Any]]
    }
    return root["storeAssertionRecords"] as? [[String: Any]]
  }

  private static func schemaSignature(for value: Any) -> String {
    var descriptors = Set<String>()
    collectSchema(from: value, at: "$", into: &descriptors)
    let canonicalSchema = descriptors.sorted().joined(separator: "\n")
    let digest = SHA256.hash(data: Data(canonicalSchema.utf8))
    return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
  }

  private static func collectSchema(
    from value: Any, at path: String, into descriptors: inout Set<String>
  ) {
    switch value {
    case let dictionary as [String: Any]:
      descriptors.insert("\(path):object")
      for key in dictionary.keys.sorted() {
        collectSchema(from: dictionary[key]!, at: "\(path).\(key)", into: &descriptors)
      }
    case let array as [Any]:
      descriptors.insert("\(path):array")
      for item in array { collectSchema(from: item, at: "\(path)[]", into: &descriptors) }
    case is String: descriptors.insert("\(path):string")
    case is Bool: descriptors.insert("\(path):bool")
    case is NSNumber: descriptors.insert("\(path):number")
    case is NSNull: descriptors.insert("\(path):null")
    default: descriptors.insert("\(path):unknown")
    }
  }
}
