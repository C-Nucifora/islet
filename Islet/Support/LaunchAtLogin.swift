import Combine
import Defaults
import ServiceManagement

enum LaunchAtLoginRegistrationStatus: Equatable, Sendable {
  case enabled
  case requiresApproval
  case notRegistered
  case notFound
  case unknown

  init(_ status: SMAppService.Status) {
    switch status {
    case .enabled: self = .enabled
    case .requiresApproval: self = .requiresApproval
    case .notRegistered: self = .notRegistered
    case .notFound: self = .notFound
    @unknown default: self = .unknown
    }
  }
}

enum LaunchAtLoginRegistrationAction: Equatable, Sendable {
  case none
  case register
  case unregister
}

enum LaunchAtLoginPolicy {
  static func action(
    desiredEnabled: Bool, status: LaunchAtLoginRegistrationStatus
  ) -> LaunchAtLoginRegistrationAction {
    if desiredEnabled {
      switch status {
      case .enabled, .requiresApproval, .unknown: .none
      case .notRegistered, .notFound: .register
      }
    } else {
      switch status {
      case .enabled, .requiresApproval: .unregister
      case .notRegistered, .notFound, .unknown: .none
      }
    }
  }
}

@MainActor
final class LaunchAtLoginStatus: ObservableObject {
  static let shared = LaunchAtLoginStatus()

  @Published private(set) var summary = "Checking…"
  @Published private(set) var error: String?

  private init() { refresh() }

  func refresh(error: String? = nil) {
    self.error = error
    switch SMAppService.mainApp.status {
    case .enabled: summary = "On"
    case .requiresApproval: summary = "Needs approval in System Settings"
    case .notRegistered: summary = "Off"
    case .notFound: summary = "Unavailable"
    @unknown default: summary = "Unknown"
    }
  }
}

/// Registers/unregisters the app as a login item via SMAppService, driven by a Defaults toggle.
@MainActor
enum LaunchAtLogin {
  static func sync() {
    apply(Defaults[.launchAtLogin])
  }

  static func observe(
    apply: @escaping @MainActor (Bool) -> Void = LaunchAtLogin.apply
  ) -> AnyCancellable {
    Defaults.publisher(.launchAtLogin)
      .receive(on: DispatchQueue.main)
      .sink { change in apply(change.newValue) }
  }

  static func apply(_ enabled: Bool) {
    do {
      let status = LaunchAtLoginRegistrationStatus(SMAppService.mainApp.status)
      switch LaunchAtLoginPolicy.action(desiredEnabled: enabled, status: status) {
      case .none: break
      case .register: try SMAppService.mainApp.register()
      case .unregister: try SMAppService.mainApp.unregister()
      }
      LaunchAtLoginStatus.shared.refresh()
    } catch {
      LaunchAtLoginStatus.shared.refresh(error: error.localizedDescription)
      Log.app.error(
        "LaunchAtLogin \(enabled ? "register" : "unregister") failed: \(error.localizedDescription)"
      )
    }
  }
}
