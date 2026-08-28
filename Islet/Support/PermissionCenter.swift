import AppKit
import ApplicationServices
import Combine
import CoreBluetooth
import CoreLocation
import EventKit
import Security

enum SystemSettingsPrivacyPane: String, CaseIterable, Sendable {
  case accessibility = "Privacy_Accessibility"
  case calendars = "Privacy_Calendars"
  case reminders = "Privacy_Reminders"
  case bluetooth = "Privacy_Bluetooth"
  case location = "Privacy_LocationServices"
  case localNetwork = "Privacy_LocalNetwork"

  var url: URL {
    URL(
      string: "x-apple.systempreferences:com.apple.preference.security?\(rawValue)"
    )!
  }

  @MainActor @discardableResult
  func open() -> Bool {
    NSWorkspace.shared.open(url)
  }
}

enum EventKitPermissionState: Equatable, Sendable {
  case notDetermined
  case denied
  case restricted
  case writeOnly
  case fullAccess
  case unknown(Int)

  init(_ status: EKAuthorizationStatus) {
    switch status {
    case .notDetermined: self = .notDetermined
    case .denied: self = .denied
    case .restricted: self = .restricted
    case .writeOnly: self = .writeOnly
    case .fullAccess: self = .fullAccess
    @unknown default: self = .unknown(status.rawValue)
    }
  }

  var canRead: Bool { self == .fullAccess }

  var requiresSettingsRecovery: Bool {
    switch self {
    case .denied, .writeOnly: true
    case .notDetermined, .restricted, .fullAccess, .unknown: false
    }
  }

  var summary: String {
    switch self {
    case .notDetermined: "Not requested"
    case .denied: "Denied"
    case .restricted: "Restricted"
    case .writeOnly: "Write only"
    case .fullAccess: "Full access"
    case .unknown(let value): "Unknown (\(value))"
    }
  }
}

enum PlatformPermissionState: Equatable, Sendable {
  case notDetermined
  case granted
  case denied
  case restricted
  case unavailable

  var summary: String {
    switch self {
    case .notDetermined: "Not requested"
    case .granted: "Allowed"
    case .denied: "Denied"
    case .restricted: "Restricted"
    case .unavailable: "Unavailable"
    }
  }
}

struct PermissionDiagnosticsSnapshot: Equatable, Sendable {
  var capturedAt: Date
  var appPath: String
  var executablePath: String
  var bundleIdentifier: String
  var appVersion: String
  var buildVersion: String
  var signingIdentifier: String
  var teamIdentifier: String
  var signingIdentity: String
  var codeDirectoryHash: String
  var accessibilityGranted: Bool
  var calendar: EventKitPermissionState
  var reminders: EventKitPermissionState
  var location: PlatformPermissionState
  var bluetooth: PlatformPermissionState

  var text: String {
    [
      "Captured: \(ISO8601DateFormatter().string(from: capturedAt))",
      "App path: \(appPath)",
      "Executable: \(executablePath)",
      "Bundle identifier: \(bundleIdentifier)",
      "Version: \(appVersion) (\(buildVersion))",
      "Signing identifier: \(signingIdentifier)",
      "Team identifier: \(teamIdentifier)",
      "Signing identity: \(signingIdentity)",
      "CDHash: \(codeDirectoryHash)",
      "Accessibility: \(accessibilityGranted ? "Granted" : "Not granted")",
      "Calendars: \(calendar.summary)",
      "Reminders: \(reminders.summary)",
      "Location: \(location.summary)",
      "Bluetooth: \(bluetooth.summary)",
    ].joined(separator: "\n")
  }
}

/// Read-only permission and code-identity diagnostics for Settings and support reports. Merely
/// accessing this model never prompts for TCC access.
@MainActor
final class PermissionCenter: NSObject, ObservableObject, CLLocationManagerDelegate {
  static let shared = PermissionCenter()

  @Published private(set) var diagnostics: PermissionDiagnosticsSnapshot
  private let locationManager = CLLocationManager()
  private var activeObserver: NSObjectProtocol?

  private override init() {
    diagnostics = Self.capture()
    super.init()
    locationManager.delegate = self
    activeObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.refresh() }
    }
  }

  func refresh() {
    diagnostics = Self.capture()
  }

  func open(_ pane: SystemSettingsPrivacyPane) {
    pane.open()
  }

  func requestLocationAccess() {
    locationManager.requestWhenInUseAuthorization()
  }

  nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    Task { @MainActor [weak self] in self?.refresh() }
  }

  private static func capture() -> PermissionDiagnosticsSnapshot {
    let bundle = Bundle.main
    let signing = signingInformation()
    return PermissionDiagnosticsSnapshot(
      capturedAt: Date(),
      appPath: bundle.bundleURL.path,
      executablePath: bundle.executableURL?.path ?? "Unavailable",
      bundleIdentifier: bundle.bundleIdentifier ?? "Unavailable",
      appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        ?? "Unavailable",
      buildVersion: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        ?? "Unavailable",
      signingIdentifier: signing.identifier,
      teamIdentifier: signing.team,
      signingIdentity: signing.identity,
      codeDirectoryHash: signing.cdHash,
      accessibilityGranted: AXIsProcessTrusted(),
      calendar: EventKitPermissionState(EKEventStore.authorizationStatus(for: .event)),
      reminders: EventKitPermissionState(EKEventStore.authorizationStatus(for: .reminder)),
      location: locationPermissionState(),
      bluetooth: bluetoothPermissionState())
  }

  private static func locationPermissionState() -> PlatformPermissionState {
    switch CLLocationManager().authorizationStatus {
    case .notDetermined: .notDetermined
    case .restricted: .restricted
    case .denied: .denied
    case .authorizedAlways, .authorizedWhenInUse: .granted
    @unknown default: .unavailable
    }
  }

  private static func bluetoothPermissionState() -> PlatformPermissionState {
    switch CBManager.authorization {
    case .notDetermined: .notDetermined
    case .restricted: .restricted
    case .denied: .denied
    case .allowedAlways: .granted
    @unknown default: .unavailable
    }
  }

  private static func signingInformation() -> (
    identifier: String, team: String, identity: String, cdHash: String
  ) {
    guard let executableURL = Bundle.main.executableURL else {
      return ("Unavailable", "Unavailable", "Unavailable", "Unavailable")
    }
    let defaultFlags = SecCSFlags(rawValue: 0)
    var code: SecStaticCode?
    guard
      SecStaticCodeCreateWithPath(executableURL as CFURL, defaultFlags, &code) == errSecSuccess,
      let code
    else {
      return ("Unavailable", "Unavailable", "Unavailable", "Unavailable")
    }
    var rawInformation: CFDictionary?
    let informationFlags = SecCSFlags(rawValue: kSecCSSigningInformation)
    guard
      SecCodeCopySigningInformation(code, informationFlags, &rawInformation)
        == errSecSuccess,
      let information = rawInformation as? [String: Any]
    else {
      return ("Unavailable", "Unavailable", "Unavailable", "Unavailable")
    }

    let identifier = information[kSecCodeInfoIdentifier as String] as? String ?? "Unavailable"
    let team = information[kSecCodeInfoTeamIdentifier as String] as? String ?? "None"
    let cdHash = (information[kSecCodeInfoUnique as String] as? Data)?
      .map { String(format: "%02x", $0) }.joined() ?? "Unavailable"
    let certificate = (information[kSecCodeInfoCertificates as String] as? [SecCertificate])?.first
    let identity = certificate.flatMap { SecCertificateCopySubjectSummary($0) as String? }
      ?? "Ad hoc or unsigned"
    return (identifier, team, identity, cdHash)
  }
}
