import Combine
import Defaults
import ServiceManagement

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

  static func apply(_ enabled: Bool) {
    do {
      if enabled {
        if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
      } else {
        if SMAppService.mainApp.status == .enabled {
          try SMAppService.mainApp.unregister()
        }
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
