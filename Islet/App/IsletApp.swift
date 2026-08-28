import SwiftUI

/// Islet's menu-bar mark: a thin display horizon interrupted by its hanging hardware notch.
/// The sparse silhouette stays crisp when macOS renders it at menu-bar scale.
struct IsletMenuBarIconShape: Shape {
  func path(in rect: CGRect) -> Path {
    let xScale = rect.width / 18
    let yScale = rect.height / 16
    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
      CGPoint(x: rect.minX + x * xScale, y: rect.minY + y * yScale)
    }

    var path = Path()
    path.addRoundedRect(
      in: CGRect(
        x: point(1.5, 2.5).x,
        y: point(1.5, 2.5).y,
        width: 15 * xScale,
        height: 1.5 * yScale),
      cornerSize: CGSize(width: 0.75 * xScale, height: 0.75 * yScale))

    path.move(to: point(6.25, 2.5))
    path.addLine(to: point(11.75, 2.5))
    path.addLine(to: point(11.75, 5.75))
    path.addCurve(
      to: point(9, 8.5), control1: point(11.75, 7.27), control2: point(10.52, 8.5))
    path.addCurve(
      to: point(6.25, 5.75), control1: point(7.48, 8.5), control2: point(6.25, 7.27))
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
  static let continuity = ContinuityActivity()
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
        Button("Dismiss All Retained Items") { PulseCenter.shared.removeAll() }
          .disabled(PulseCenter.shared.retainedItemCount == 0)
        Button("Provider Settings…") { SettingsOpener.open(destination: .integrations) }
        Button("Reveal Token Folder") { NSWorkspace.shared.open(PulsePaths.supportDirectory) }
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
