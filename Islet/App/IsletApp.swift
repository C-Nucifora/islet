import SwiftUI

/// A display edge and hardware notch used in setup.
struct IsletNotchMarkShape: Shape {
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
  static let focus = FocusEventSource()

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
    focus,
    VPNEventSource(),
  ]
}

@main
struct IsletApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
  @ObservedObject private var reminderCommandHotKey = ReminderCommandHotKey.shared

  var body: some Scene {
    Settings { EmptyView() }
      .commands {
        CommandMenu("Reminders") {
          Button(
            reminderCommandHotKey.isAvailable
              ? "Open Reminder Commands (global ⌘⌥⇧R)"
              : "Open Reminder Commands (global shortcut unavailable)"
          ) {
            ReminderCommandsWindow.shared.present(provider: RemindersProvider.shared)
          }
          .keyboardShortcut("r", modifiers: [.command, .shift])
        }
      }
  }
}
