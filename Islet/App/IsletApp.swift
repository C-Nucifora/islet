import SwiftUI

@MainActor
enum AppState {
  static let demoActivity = DemoActivity()
  static let nowPlaying = NowPlayingActivity()
  static let battery = BatteryActivity()
  static let calendar = CalendarActivity()
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
        Button("Sneak: charger") {
          SneakQueue.shared.submit(BatteryActivity.sneak(for: .acConnected(percent: 64)))
        }
        Button("Sneak: low battery") {
          SneakQueue.shared.submit(
            BatteryActivity.sneak(for: .lowBattery(threshold: 20, percent: 18)))
        }
        Button("Sneak: track change") {
          var fake = PlaybackState()
          fake.title = "Paranoid Android"
          fake.artist = "Radiohead"
          SneakQueue.shared.submit(NowPlayingActivity.trackChangeSneak(for: fake))
        }
        Button("HUD: volume") {
          HUDController.shared.debugPresent(.init(kind: .volume, level: 0.6, isMuted: false))
        }
        Button("HUD: brightness") {
          HUDController.shared.debugPresent(.init(kind: .brightness, level: 0.35, isMuted: false))
        }
      }
      Divider()
      Button("Quit Islet") { NSApplication.shared.terminate(nil) }
        .keyboardShortcut("q")
    }

    Settings { SettingsView() }
  }
}
