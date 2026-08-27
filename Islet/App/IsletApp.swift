import SwiftUI

/// Islet's menu-bar mark: the hardware-notch shoulders flow into a compact rounded island.
/// The open dip at the top keeps the silhouette legible when macOS renders it at menu-bar scale.
struct IsletMenuBarIconShape: Shape {
  func path(in rect: CGRect) -> Path {
    let xScale = rect.width / 18
    let yScale = rect.height / 16
    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
      CGPoint(x: rect.minX + x * xScale, y: rect.minY + y * yScale)
    }

    var path = Path()
    path.move(to: point(1, 6))
    path.addCurve(
      to: point(5, 2), control1: point(1, 3.7), control2: point(2.8, 2))
    path.addLine(to: point(7.4, 2))
    path.addCurve(
      to: point(9, 5.2), control1: point(7.8, 2), control2: point(7.8, 5.2))
    path.addCurve(
      to: point(10.6, 2), control1: point(10.2, 5.2), control2: point(10.2, 2))
    path.addLine(to: point(13, 2))
    path.addCurve(
      to: point(17, 6), control1: point(15.2, 2), control2: point(17, 3.7))
    path.addLine(to: point(17, 9.5))
    path.addCurve(
      to: point(12.5, 14), control1: point(17, 12.2), control2: point(15.2, 14))
    path.addLine(to: point(5.5, 14))
    path.addCurve(
      to: point(1, 9.5), control1: point(2.8, 14), control2: point(1, 12.2))
    path.closeSubpath()
    return path
  }
}

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
  static let t3Code = T3CodeActivity()
  static let pulse = PulseActivity()

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
    MenuBarExtra {
      Button("Quick Actions…") { QuickActionsOpener.open() }
        .keyboardShortcut("k")
      Button("Show Islet") { ScreenManager.shared.viewModel?.apply(.clickedNotch) }
      Divider()
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
      Menu("Pulse") {
        Picker("Delivery", selection: PulseProfileBinding.profile) {
          ForEach(PulseDeliveryProfile.allCases) { profile in
            Text(profile.title).tag(profile)
          }
        }
        Divider()
        Button("Dismiss All") { PulseCenter.shared.removeAll() }
          .disabled(PulseCenter.shared.items.isEmpty)
        Button("Open Support Folder") { NSWorkspace.shared.open(PulsePaths.supportDirectory) }
      }
      #if DEBUG
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
      #endif
      Divider()
      Button("Quit Islet") { NSApplication.shared.terminate(nil) }
        .keyboardShortcut("q")
    } label: {
      IsletMenuBarIconShape()
        .fill(.primary)
        .frame(width: 18, height: 16)
        .accessibilityLabel("Islet")
    }
  }
}

/// A small binding keeps the menu declarative without introducing a second owner for Pulse state.
/// MenuBarExtra rebuilds when opened, so its checkmark reflects the current session profile.
@MainActor
private enum PulseProfileBinding {
  static var profile: Binding<PulseDeliveryProfile> {
    Binding(
      get: { PulseCenter.shared.deliveryProfile },
      set: { PulseCenter.shared.deliveryProfile = $0 })
  }
}
