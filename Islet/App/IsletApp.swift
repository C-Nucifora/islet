import SwiftUI

@MainActor
enum AppState {
  static let demoActivity = DemoActivity()
  static let nowPlaying = NowPlayingActivity()
  static let battery = BatteryActivity()
  static let calendar = CalendarActivity()
  static let timer = TimerActivity()
  static let shelf = ShelfActivity()
  static let clipboard = ClipboardActivity()
  static let ports = PortsActivity()
  static let system = SystemActivity()

  /// Every system-event source, in catalogue order. Sources that only re-shape an existing
  /// producer's output — battery, timer, track change, audio device — are not listed: those emit
  /// from the activity that already owns the observation, and appear in Settings through
  /// `SourceCatalog` regardless.
  /// Named so the shelf's share observer can report completions into it.
  static let airdropOut = AirDropOutEventSource()

  static let eventSources: [any SystemEventSource] = [
    PortEventSource(),
    VolumeEventSource(),
    DisplayEventSource(),
    PowerEventSource(),
    SleepEventSource(),
    PeripheralEventSource(),
    WiFiEventSource(),
    BluetoothEventSource(),
    SessionEventSource(),
    ScreenshotEventSource(),
    airdropOut,
    AirDropInEventSource(),
    FocusEventSource(),
    VPNEventSource(),
  ]
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
        Divider()
        // Generated from the catalogue so every source is exercisable without the hardware —
        // you cannot unplug a display or receive an AirDrop on demand while testing motion.
        Menu("Fire event") {
          ForEach(SourceCatalog.all, id: \.id) { entry in
            Button(entry.name) {
              SystemEventBus.shared.emit(
                SystemEvent(
                  sourceID: entry.id,
                  icon: entry.icon,
                  title: entry.name,
                  subtitle: "Debug",
                  accentHex: EventAccent.info,
                  motion: SourceCatalog.debugMotion(for: entry.id)))
            }
          }
        }
        Button("Fire a docking burst") {
          let names = ["Studio Display", "Keyboard", "Hub", "Backup", "Mouse"]
          let sources = ["display", "usb", "usb", "volume", "usb"]
          for (i, name) in names.enumerated() {
            SystemEventBus.shared.emit(
              SystemEvent(
                sourceID: sources[i], icon: "cable.connector", title: name,
                accentHex: EventAccent.info, motion: .usb))
          }
        }
        Divider()
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
