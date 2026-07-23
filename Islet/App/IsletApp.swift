import SwiftUI

@MainActor
enum AppState {
  static let demoActivity = DemoActivity()
  static let nowPlaying = NowPlayingActivity()
  static let battery = BatteryActivity()
  static let calendar = CalendarActivity()
  static let timer = TimerActivity()
  static let shelf = ShelfActivity()
}

@main
struct IsletApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

  var body: some Scene {
    MenuBarExtra("Islet", systemImage: "capsule.fill") {
      Button("Settings…") { SettingsOpener.open() }
        .keyboardShortcut(",")
      Menu("Start Timer") {
        Button("1 minute") { AppState.timer.start(60) }
        Button("5 minutes") { AppState.timer.start(5 * 60) }
        Button("10 minutes") { AppState.timer.start(10 * 60) }
        Button("25 minutes") { AppState.timer.start(25 * 60) }
        Divider()
        Button("Pomodoro (25 min focus)") { AppState.timer.start(25 * 60, label: "Focus") }
        Button("Short break (5 min)") { AppState.timer.start(5 * 60, label: "Break") }
        Divider()
        Button("Cancel timer") { AppState.timer.cancel() }
      }
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
  }
}
