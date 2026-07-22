import SwiftUI

@MainActor
enum AppState {
  static let demoActivity = DemoActivity()
}

@main
struct IsletApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

  var body: some Scene {
    MenuBarExtra("Islet", systemImage: "capsule.fill") {
      SettingsLink { Text("Settings…") }
        .keyboardShortcut(",")
      Menu("Debug") {
        Button("Toggle demo activity") {
          AppState.demoActivity.isActive.toggle()
        }
        Button("Expand") {
          ScreenManager.shared.viewModel?.apply(.clickedNotch)
        }
      }
      Divider()
      Button("Quit Islet") { NSApplication.shared.terminate(nil) }
        .keyboardShortcut("q")
    }

    Settings { SettingsView() }
  }
}
