import AppKit
import Combine
import Foundation
import Sparkle

enum AppUpdateChannel: String, Equatable, Sendable {
  case stable

  var title: String {
    switch self {
    case .stable: String(localized: "Stable")
    }
  }
}

enum AppUpdateConfigurationError: Error, Equatable, LocalizedError {
  case missingValue(String)
  case invalidFeedURL
  case insecureFeedURL
  case unexpectedFeedURL
  case invalidPublicKey
  case signedFeedRequired
  case preExtractionVerificationRequired
  case signedFeedFailureMayExpire
  case automaticCheckDefaultOverridden
  case automaticInstallationEnabled
  case releaseNotesRequired
  case unsupportedChannel(String)

  var errorDescription: String? {
    switch self {
    case .missingValue(let key): String(localized: "The update setting \(key) is missing.")
    case .invalidFeedURL: String(localized: "The update feed URL is invalid.")
    case .insecureFeedURL:
      String(localized: "The update feed must use HTTPS without embedded credentials.")
    case .unexpectedFeedURL:
      String(localized: "This build does not use Islet's stable update feed.")
    case .invalidPublicKey:
      String(localized: "Update signing has not been configured in this build.")
    case .signedFeedRequired: String(localized: "Signed update feeds are required.")
    case .preExtractionVerificationRequired:
      "Update archives must be verified before extraction."
    case .signedFeedFailureMayExpire:
      "Signed feed failures must never expire."
    case .automaticCheckDefaultOverridden:
      "Automatic update checks must remain an explicit user choice."
    case .automaticInstallationEnabled:
      "Automatic installation must be disabled by default."
    case .releaseNotesRequired: String(localized: "Update release notes must be shown.")
    case .unsupportedChannel(let channel):
      String(localized: "The update channel \(channel) is unsupported.")
    }
  }
}

struct AppUpdateConfiguration: Equatable, Sendable {
  static let feedURLKey = "SUFeedURL"
  static let publicKeyKey = "SUPublicEDKey"
  static let signedFeedKey = "SURequireSignedFeed"
  static let verifyBeforeExtractionKey = "SUVerifyUpdateBeforeExtraction"
  static let signedFeedFailureExpirationKey = "SUSignedFeedFailureExpirationInterval"
  static let automaticChecksKey = "SUEnableAutomaticChecks"
  static let automaticInstallationKey = "SUAutomaticallyUpdate"
  static let showReleaseNotesKey = "SUShowReleaseNotes"
  static let channelKey = "IsletUpdateChannel"
  static let stableFeedURL = URL(
    string: "https://github.com/C-Nucifora/islet/releases/latest/download/appcast.xml")!

  let feedURL: URL
  let publicKey: String
  let channel: AppUpdateChannel

  init(bundle: Bundle = .main) throws {
    try self.init(infoDictionary: bundle.infoDictionary ?? [:])
  }

  init(infoDictionary: [String: Any]) throws {
    let rawFeedURL = try Self.requiredString(Self.feedURLKey, in: infoDictionary)
    guard let components = URLComponents(string: rawFeedURL), let url = components.url,
      components.host?.isEmpty == false
    else {
      throw AppUpdateConfigurationError.invalidFeedURL
    }
    guard components.scheme?.lowercased() == "https", components.user == nil,
      components.password == nil
    else {
      throw AppUpdateConfigurationError.insecureFeedURL
    }
    guard url == Self.stableFeedURL else {
      throw AppUpdateConfigurationError.unexpectedFeedURL
    }

    let key = try Self.requiredString(Self.publicKeyKey, in: infoDictionary)
    guard key != "CONFIGURATION_REQUIRED",
      key.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
      let decodedKey = Data(base64Encoded: key), decodedKey.count == 32
    else {
      throw AppUpdateConfigurationError.invalidPublicKey
    }
    guard infoDictionary[Self.signedFeedKey] as? Bool == true else {
      throw AppUpdateConfigurationError.signedFeedRequired
    }
    guard infoDictionary[Self.verifyBeforeExtractionKey] as? Bool == true else {
      throw AppUpdateConfigurationError.preExtractionVerificationRequired
    }
    guard infoDictionary[Self.signedFeedFailureExpirationKey] as? Int == 0 else {
      throw AppUpdateConfigurationError.signedFeedFailureMayExpire
    }
    guard infoDictionary[Self.automaticChecksKey] == nil else {
      throw AppUpdateConfigurationError.automaticCheckDefaultOverridden
    }
    guard infoDictionary[Self.automaticInstallationKey] as? Bool == false else {
      throw AppUpdateConfigurationError.automaticInstallationEnabled
    }
    guard infoDictionary[Self.showReleaseNotesKey] as? Bool == true else {
      throw AppUpdateConfigurationError.releaseNotesRequired
    }

    let rawChannel = try Self.requiredString(Self.channelKey, in: infoDictionary)
    guard let channel = AppUpdateChannel(rawValue: rawChannel) else {
      throw AppUpdateConfigurationError.unsupportedChannel(rawChannel)
    }

    feedURL = url
    publicKey = key
    self.channel = channel
  }

  private static func requiredString(_ key: String, in dictionary: [String: Any]) throws -> String {
    guard let value = dictionary[key] as? String else {
      throw AppUpdateConfigurationError.missingValue(key)
    }
    guard !value.isEmpty else { throw AppUpdateConfigurationError.missingValue(key) }
    return value
  }
}

struct AppUpdateVersion: Equatable, Sendable {
  let displayVersion: String
  let build: String

  var text: String { "\(displayVersion) (\(build))" }

  init(infoDictionary: [String: Any]) {
    displayVersion = infoDictionary["CFBundleShortVersionString"] as? String ?? "Development"
    build = infoDictionary["CFBundleVersion"] as? String ?? "Unknown"
  }
}

enum AppUpdateState: Equatable, Sendable {
  case unavailable(String)
  case ready
  case checking
  case upToDate
  case updateAvailable(String)
  case downloading(String)
  case preparing(String)
  case readyToInstall(String)
  case installing(String)
  case failed(String)

  var summary: String {
    switch self {
    case .unavailable(let reason): String(localized: "Unavailable: \(reason)")
    case .ready: String(localized: "Ready")
    case .checking: String(localized: "Checking…")
    case .upToDate: String(localized: "Up to date")
    case .updateAvailable(let version): String(localized: "Version \(version) is available")
    case .downloading(let version): String(localized: "Downloading version \(version)…")
    case .preparing(let version): String(localized: "Verifying version \(version)…")
    case .readyToInstall(let version):
      String(localized: "Version \(version) is ready to install")
    case .installing(let version): String(localized: "Installing version \(version)…")
    case .failed(let message): String(localized: "Update failed: \(message)")
    }
  }

  var isFailure: Bool {
    switch self {
    case .unavailable, .failed: true
    default: false
    }
  }
}

@MainActor
final class AppUpdateController: NSObject, ObservableObject, SPUUpdaterDelegate {
  static let shared = AppUpdateController()

  @Published private(set) var state: AppUpdateState
  @Published private(set) var canCheckForUpdates = false
  @Published private(set) var automaticallyChecksForUpdates = false
  @Published private(set) var lastCheckDate: Date?

  let currentVersion: AppUpdateVersion
  let channel: AppUpdateChannel

  var isConfigured: Bool { configuration != nil }

  private let configuration: AppUpdateConfiguration?
  private var updaterController: SPUStandardUpdaterController?

  private override init() {
    let infoDictionary = Bundle.main.infoDictionary ?? [:]
    currentVersion = AppUpdateVersion(infoDictionary: infoDictionary)
    do {
      let configuration = try AppUpdateConfiguration(infoDictionary: infoDictionary)
      self.configuration = configuration
      channel = configuration.channel
      state = .ready
    } catch {
      configuration = nil
      channel = .stable
      state = .unavailable(error.localizedDescription)
    }
    super.init()
  }

  func start() {
    guard updaterController == nil, let configuration else { return }
    let controller = SPUStandardUpdaterController(
      startingUpdater: false,
      updaterDelegate: self,
      userDriverDelegate: nil)
    // Sparkle historically persisted URLs written through its deprecated setFeedURL API and
    // gives that value priority over Info.plist. Remove it during migration; the delegate below
    // also pins every check to the URL that passed AppUpdateConfiguration validation.
    controller.updater.clearFeedURLFromUserDefaults()
    guard controller.updater.feedURL == configuration.feedURL else {
      state = .unavailable(AppUpdateConfigurationError.unexpectedFeedURL.localizedDescription)
      return
    }
    updaterController = controller
    controller.startUpdater()
    refresh()
  }

  func feedURLString(for updater: SPUUpdater) -> String? {
    configuration?.feedURL.absoluteString
  }

  func checkForUpdates() {
    guard let updater = updaterController?.updater, updater.canCheckForUpdates else { return }
    NSApp.activate(ignoringOtherApps: true)
    state = .checking
    canCheckForUpdates = false
    updater.checkForUpdates()
  }

  func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
    guard let updater = updaterController?.updater else { return }
    updater.automaticallyChecksForUpdates = enabled
    refresh()
  }

  func refresh() {
    guard let updater = updaterController?.updater else { return }
    canCheckForUpdates = updater.canCheckForUpdates
    automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
    lastCheckDate = updater.lastUpdateCheckDate
  }

  func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
    state = .updateAvailable(item.displayVersionString)
    refresh()
  }

  func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
    state = Self.state(after: error)
    refresh()
  }

  func updater(
    _ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem,
    with request: NSMutableURLRequest
  ) {
    state = .downloading(item.displayVersionString)
    refresh()
  }

  func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
    state = .preparing(item.displayVersionString)
    refresh()
  }

  func updater(_ updater: SPUUpdater, willExtractUpdate item: SUAppcastItem) {
    state = .preparing(item.displayVersionString)
    refresh()
  }

  func updater(_ updater: SPUUpdater, didExtractUpdate item: SUAppcastItem) {
    state = .readyToInstall(item.displayVersionString)
    refresh()
  }

  func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
    state = .installing(item.displayVersionString)
    refresh()
  }

  func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: any Error)
  {
    state = .failed(error.localizedDescription)
    refresh()
  }

  func userDidCancelDownload(_ updater: SPUUpdater) {
    state = .ready
    refresh()
  }

  func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
    state = Self.state(after: error)
    refresh()
  }

  func updater(
    _ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
    error: (any Error)?
  ) {
    if let error {
      state = Self.state(after: error)
    } else if case .checking = state {
      state = .ready
    }
    refresh()
  }

  func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
    if case .readyToInstall(let version) = state {
      state = .installing(version)
    }
  }

  nonisolated static func state(after error: any Error) -> AppUpdateState {
    let cocoaError = error as NSError
    guard cocoaError.domain == SUSparkleErrorDomain else {
      return .failed(cocoaError.localizedDescription)
    }
    switch cocoaError.code {
    case Int(SUError.noUpdateError.rawValue): return .upToDate
    case Int(SUError.installationCanceledError.rawValue): return .ready
    default: return .failed(cocoaError.localizedDescription)
    }
  }
}
