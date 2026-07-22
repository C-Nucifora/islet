import Defaults
import ServiceManagement

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
    } catch {
      Log.app.error(
        "LaunchAtLogin \(enabled ? "register" : "unregister") failed: \(error.localizedDescription)"
      )
    }
  }
}
