import AppKit
import Combine
import Darwin
import Defaults
import Foundation
import Security

struct ClipboardApplicationIdentity: Equatable {
  let bundleIdentifier: String
  let name: String

  init?(bundleIdentifier: String?, name: String?) {
    guard let bundleIdentifier = ClipboardIdentifierPolicy.bundleIdentifier(bundleIdentifier)
    else { return nil }
    self.bundleIdentifier = bundleIdentifier
    self.name =
      name?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
      ?? bundleIdentifier
  }
}

extension String {
  fileprivate var nonEmpty: String? { isEmpty ? nil : self }
}

enum ClipboardIdentifierPolicy {
  static let maximumBundleIdentifierCount = 128
  static let maximumBundleIdentifierBytes = 255
  static let maximumFocusIdentifierCount = 64
  static let maximumFocusIdentifierBytes = 128

  static func bundleIdentifier(_ value: String?) -> String? {
    normalize(value, maximumBytes: maximumBundleIdentifierBytes, allowsSpaces: false)
  }

  static func focusIdentifier(_ value: String?) -> String? {
    normalize(value, maximumBytes: maximumFocusIdentifierBytes, allowsSpaces: true)
  }

  static func bundleIdentifiers(_ values: [String]) -> [String] {
    normalizedList(
      values, maximumCount: maximumBundleIdentifierCount, transform: bundleIdentifier)
  }

  static func focusIdentifiers(_ values: [String]) -> [String] {
    normalizedList(values, maximumCount: maximumFocusIdentifierCount, transform: focusIdentifier)
  }

  private static func normalize(
    _ value: String?, maximumBytes: Int, allowsSpaces: Bool
  ) -> String? {
    guard let value else { return nil }
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !normalized.isEmpty, normalized.lengthOfBytes(using: .utf8) <= maximumBytes else {
      return nil
    }
    let separators = allowsSpaces ? " ._-" : "._-"
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: separators))
    guard normalized.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
    return normalized
  }

  private static func normalizedList(
    _ values: [String], maximumCount: Int, transform: (String?) -> String?
  ) -> [String] {
    var seen = Set<String>()
    var result: [String] = []
    for value in values {
      guard result.count < maximumCount, let normalized = transform(value),
        seen.insert(normalized).inserted
      else { continue }
      result.append(normalized)
    }
    return result
  }
}

struct ClipboardPrivacyConfiguration: Equatable {
  var excludedBundleIdentifiers: [String] = []
  var pausedFocusIdentifiers: [String] = []
  var clearHistoryOnPause = true
  var manuallyPaused = false
  var pausedUntil: Date?
  var pausedLoginSession: String?

  var normalized: Self {
    var result = self
    result.excludedBundleIdentifiers = ClipboardIdentifierPolicy.bundleIdentifiers(
      excludedBundleIdentifiers)
    result.pausedFocusIdentifiers = ClipboardIdentifierPolicy.focusIdentifiers(
      pausedFocusIdentifiers)
    if let pausedLoginSession,
      pausedLoginSession.isEmpty || pausedLoginSession.lengthOfBytes(using: .utf8) > 64
    {
      result.pausedLoginSession = nil
    }
    return result
  }
}

enum ClipboardPauseReason: Equatable {
  case manual
  case timed(Date)
  case untilNextLogin
  case excludedApplication(ClipboardApplicationIdentity)
  case focusMode(String)
  case unidentifiedApplication

  var summary: String {
    switch self {
    case .manual: "Paused until you resume"
    case .timed(let date): "Paused until \(date.formatted(date: .omitted, time: .shortened))"
    case .untilNextLogin: "Paused until the next login"
    case .excludedApplication(let application): "Paused while \(application.name) is active"
    case .focusMode(let identifier): "Paused for Focus: \(identifier)"
    case .unidentifiedApplication: "Paused because the active app is unknown"
    }
  }
}

struct ClipboardCaptureContext: Equatable {
  var application: ClipboardApplicationIdentity?
  var focusIdentifier: String?
}

struct ClipboardPrivacyEvaluation: Equatable {
  let reason: ClipboardPauseReason?
  let configuration: ClipboardPrivacyConfiguration
}

enum ClipboardPrivacyEvaluator {
  static func evaluate(
    configuration: ClipboardPrivacyConfiguration, context: ClipboardCaptureContext,
    now: Date, loginSession: String?
  ) -> ClipboardPrivacyEvaluation {
    var configuration = configuration.normalized
    if let pausedUntil = configuration.pausedUntil, pausedUntil <= now {
      configuration.pausedUntil = nil
    }
    if let pausedSession = configuration.pausedLoginSession,
      loginSession == nil || pausedSession != loginSession
    {
      configuration.pausedLoginSession = nil
    }

    let reason: ClipboardPauseReason?
    if configuration.manuallyPaused {
      reason = .manual
    } else if let pausedUntil = configuration.pausedUntil {
      reason = .timed(pausedUntil)
    } else if configuration.pausedLoginSession != nil {
      reason = .untilNextLogin
    } else if let application = context.application,
      configuration.excludedBundleIdentifiers.contains(application.bundleIdentifier)
    {
      reason = .excludedApplication(application)
    } else if let focus = ClipboardIdentifierPolicy.focusIdentifier(context.focusIdentifier),
      configuration.pausedFocusIdentifiers.contains(focus)
    {
      reason = .focusMode(focus)
    } else if context.application == nil {
      reason = .unidentifiedApplication
    } else {
      reason = nil
    }
    return ClipboardPrivacyEvaluation(reason: reason, configuration: configuration)
  }
}

@MainActor
protocol ClipboardPrivacyStoring: AnyObject {
  var onChange: (() -> Void)? { get set }
  func load() -> ClipboardPrivacyConfiguration
  func save(_ configuration: ClipboardPrivacyConfiguration)
}

@MainActor
final class DefaultsClipboardPrivacyStore: ClipboardPrivacyStoring {
  var onChange: (() -> Void)?
  private var observations: [Defaults.Observation] = []
  private var isSaving = false

  init() {
    observations = [
      Defaults.observe(.clipboardExcludedBundleIdentifiers) { [weak self] _ in self?.changed() },
      Defaults.observe(.clipboardPausedFocusIdentifiers) { [weak self] _ in self?.changed() },
      Defaults.observe(.clipboardClearHistoryOnPause) { [weak self] _ in self?.changed() },
      Defaults.observe(.clipboardManuallyPaused) { [weak self] _ in self?.changed() },
      Defaults.observe(.clipboardPausedUntil) { [weak self] _ in self?.changed() },
      Defaults.observe(.clipboardPausedLoginSession) { [weak self] _ in self?.changed() },
    ]
  }

  func load() -> ClipboardPrivacyConfiguration {
    ClipboardPrivacyConfiguration(
      excludedBundleIdentifiers: Defaults[.clipboardExcludedBundleIdentifiers],
      pausedFocusIdentifiers: Defaults[.clipboardPausedFocusIdentifiers],
      clearHistoryOnPause: Defaults[.clipboardClearHistoryOnPause],
      manuallyPaused: Defaults[.clipboardManuallyPaused],
      pausedUntil: Defaults[.clipboardPausedUntil],
      pausedLoginSession: Defaults[.clipboardPausedLoginSession]
    )
  }

  func save(_ configuration: ClipboardPrivacyConfiguration) {
    let configuration = configuration.normalized
    isSaving = true
    Defaults[.clipboardExcludedBundleIdentifiers] = configuration.excludedBundleIdentifiers
    Defaults[.clipboardPausedFocusIdentifiers] = configuration.pausedFocusIdentifiers
    Defaults[.clipboardClearHistoryOnPause] = configuration.clearHistoryOnPause
    Defaults[.clipboardManuallyPaused] = configuration.manuallyPaused
    Defaults[.clipboardPausedUntil] = configuration.pausedUntil
    Defaults[.clipboardPausedLoginSession] = configuration.pausedLoginSession
    isSaving = false
  }

  private func changed() {
    guard !isSaving else { return }
    Task { @MainActor [weak self] in self?.onChange?() }
  }
}

enum ClipboardLoginSession {
  static func currentIdentifier() -> String? {
    var sessionID: SecuritySessionId = 0
    var attributes = SessionAttributeBits()
    guard SessionGetInfo(callerSecuritySession, &sessionID, &attributes) == errSecSuccess else {
      return nil
    }
    return String(sessionID)
  }
}

@MainActor
protocol ClipboardContextMonitoring: AnyObject {
  var context: ClipboardCaptureContext { get }
  var onChange: ((ClipboardCaptureContext) -> Void)? { get set }
  func start()
  func stop()
  @discardableResult func refreshApplication() -> Bool
}

@MainActor
final class WorkspaceClipboardContextMonitor: ClipboardContextMonitoring {
  private(set) var context = ClipboardCaptureContext()
  var onChange: ((ClipboardCaptureContext) -> Void)?

  private let workspace: NSWorkspace
  private let focusMonitor: ClipboardFocusMonitor
  private var applicationCancellable: AnyCancellable?

  init(
    workspace: NSWorkspace = .shared,
    focusMonitor: ClipboardFocusMonitor = ClipboardFocusMonitor()
  ) {
    self.workspace = workspace
    self.focusMonitor = focusMonitor
  }

  func start() {
    guard applicationCancellable == nil else { return }
    context.application = Self.identity(for: workspace.frontmostApplication)
    focusMonitor.onChange = { [weak self] identifier in
      guard let self else { return }
      self.context.focusIdentifier = identifier
      self.onChange?(self.context)
    }
    context.focusIdentifier = focusMonitor.start()
    applicationCancellable = workspace.notificationCenter
      .publisher(for: NSWorkspace.didActivateApplicationNotification)
      .sink { [weak self] _ in self?.applicationDidActivate() }
  }

  func stop() {
    applicationCancellable = nil
    focusMonitor.stop()
    focusMonitor.onChange = nil
    context = ClipboardCaptureContext()
  }

  @discardableResult
  func refreshApplication() -> Bool {
    let application = Self.identity(for: workspace.frontmostApplication)
    guard application != context.application else { return false }
    context.application = application
    onChange?(context)
    return true
  }

  private func applicationDidActivate() {
    context.application = Self.identity(for: workspace.frontmostApplication)
    // Notify even if the same app is frontmost again. Another app may have activated and copied
    // between two main-queue callbacks, and every activation is a privacy boundary.
    onChange?(context)
  }

  private static func identity(for application: NSRunningApplication?)
    -> ClipboardApplicationIdentity?
  {
    ClipboardApplicationIdentity(
      bundleIdentifier: application?.bundleIdentifier, name: application?.localizedName)
  }
}

@MainActor
final class ClipboardFocusMonitor {
  private enum ReadResult {
    case unavailable
    case known(String?)
  }

  var onChange: ((String?) -> Void)?
  private let assertionsURL: URL
  private var fileSource: DispatchSourceFileSystemObject?
  private var directorySource: DispatchSourceFileSystemObject?
  private var activeIdentifier: String?

  init(assertionsURL: URL? = nil) {
    self.assertionsURL =
      assertionsURL
      ?? FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/DoNotDisturb/DB/Assertions.json")
  }

  @discardableResult
  func start() -> String? {
    if case .known(let identifier) = read() { activeIdentifier = identifier }
    watchFileOrDirectory()
    return activeIdentifier
  }

  func stop() {
    fileSource?.cancel()
    fileSource = nil
    directorySource?.cancel()
    directorySource = nil
    activeIdentifier = nil
  }

  private func watchFileOrDirectory() {
    if !watchFile() { watchDirectory() }
  }

  @discardableResult
  private func watchFile() -> Bool {
    guard fileSource == nil else { return true }
    let descriptor = open(assertionsURL.path, O_EVTONLY)
    guard descriptor >= 0 else { return false }
    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: descriptor, eventMask: [.write, .delete, .rename], queue: .main)
    source.setEventHandler { [weak self, weak source] in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.refresh()
        guard let source, source.data.contains(.delete) || source.data.contains(.rename) else {
          return
        }
        self.fileSource?.cancel()
        self.fileSource = nil
        self.watchFileOrDirectory()
      }
    }
    source.setCancelHandler { close(descriptor) }
    fileSource = source
    source.resume()
    return true
  }

  private func watchDirectory() {
    guard directorySource == nil else { return }
    let descriptor = open(assertionsURL.deletingLastPathComponent().path, O_EVTONLY)
    guard descriptor >= 0 else { return }
    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: descriptor, eventMask: [.write, .delete, .rename], queue: .main)
    source.setEventHandler { [weak self] in
      MainActor.assumeIsolated {
        guard let self, FileManager.default.fileExists(atPath: self.assertionsURL.path) else {
          return
        }
        self.directorySource?.cancel()
        self.directorySource = nil
        self.refresh()
        self.watchFileOrDirectory()
      }
    }
    source.setCancelHandler { close(descriptor) }
    directorySource = source
    source.resume()
  }

  private func refresh() {
    guard case .known(let identifier) = read() else { return }
    guard identifier != activeIdentifier else { return }
    activeIdentifier = identifier
    onChange?(identifier)
  }

  private func read() -> ReadResult {
    guard let data = try? Data(contentsOf: assertionsURL) else { return .unavailable }
    let inspection = FocusEventSource.inspect(data: data)
    guard inspection.isRecognised else { return .unavailable }
    return .known(ClipboardIdentifierPolicy.focusIdentifier(inspection.activeIdentifier))
  }
}
