import AppKit
import Defaults
import SwiftUI

enum OnboardingState {
  static let currentVersion = 1
  static var isComplete: Bool { Defaults[.onboardingVersion] >= currentVersion }
}

enum OnboardingPreferences {
  static let knownActivityIDs = Set(ActivityCatalog.defaultOrder)

  static func disabledActivities(
    preserving existing: [String], selected: Set<String>
  ) -> [String] {
    let unknown = existing.filter { !knownActivityIDs.contains($0) }
    let disabledKnown = ActivityCatalog.defaultOrder.filter { !selected.contains($0) }
    return unknown + disabledKnown
  }

  @MainActor
  static func apply(
    selectedActivities: Set<String>, remindersEnabled: Bool, bluetoothEventsEnabled: Bool
  ) {
    Defaults[.disabledActivities] = disabledActivities(
      preserving: Defaults[.disabledActivities], selected: selectedActivities)
    Defaults[.batteryEnabled] = selectedActivities.contains("battery")
    Defaults[.calendarEnabled] = selectedActivities.contains("calendar")
    Defaults[.clipboardEnabled] = selectedActivities.contains("clipboard")
    Defaults[.portsEnabled] = selectedActivities.contains("ports")
    Defaults[.systemEnabled] = selectedActivities.contains("system")
    Defaults[.continuityEnabled] = selectedActivities.contains("continuity")
    Defaults[.t3CodeEnabled] = selectedActivities.contains("t3Code")
    Defaults[.pulseEnabled] = selectedActivities.contains("pulse")
    Defaults[.remindersEnabled] = remindersEnabled
    SystemEventBus.shared.setEnabled(bluetoothEventsEnabled, for: "bluetooth")
  }

  @MainActor
  static func isActivityEnabled(_ id: String) -> Bool {
    guard !Defaults[.disabledActivities].contains(id) else { return false }
    switch id {
    case "battery": return Defaults[.batteryEnabled]
    case "calendar": return Defaults[.calendarEnabled]
    case "clipboard": return Defaults[.clipboardEnabled]
    case "ports": return Defaults[.portsEnabled]
    case "system": return Defaults[.systemEnabled]
    case "continuity": return Defaults[.continuityEnabled]
    case "t3Code": return Defaults[.t3CodeEnabled]
    case "pulse": return Defaults[.pulseEnabled]
    default: return true
    }
  }
}

@MainActor
enum OnboardingOpener {
  private static var window: NSWindow?

  static func openIfNeeded() {
    guard !OnboardingState.isComplete else { return }
    open()
  }

  static func open() {
    NSApp.activate(ignoringOtherApps: true)
    if let window {
      window.contentViewController = NSHostingController(rootView: OnboardingView())
      window.makeKeyAndOrderFront(nil)
      return
    }

    let hosting = NSHostingController(rootView: OnboardingView())
    let onboardingWindow = NSWindow(contentViewController: hosting)
    onboardingWindow.title = "Set up Islet"
    onboardingWindow.styleMask = [.titled, .closable]
    onboardingWindow.setContentSize(NSSize(width: 720, height: 560))
    onboardingWindow.isReleasedWhenClosed = false
    onboardingWindow.center()
    onboardingWindow.makeKeyAndOrderFront(nil)
    onboardingWindow.standardWindowButton(.miniaturizeButton)?.isEnabled = false
    onboardingWindow.standardWindowButton(.zoomButton)?.isEnabled = false
    window = onboardingWindow
  }

  fileprivate static func close() {
    window?.orderOut(nil)
  }
}

private enum OnboardingPage: Int, CaseIterable {
  case welcome
  case interaction
  case activities
  case permissions
  case ready

  var title: String {
    switch self {
    case .welcome: "Meet Islet"
    case .interaction: "Open the notch"
    case .activities: "Choose activities"
    case .permissions: "Allow access"
    case .ready: "Ready"
    }
  }
}

private struct OnboardingActivity: Identifiable {
  let id: String
  let detail: String

  static let all: [Self] = [
    .init(id: "timer", detail: "Countdowns"),
    .init(id: "nowPlaying", detail: "Media controls and active players"),
    .init(id: "battery", detail: "Charge, power flow and peripherals"),
    .init(id: "calendar", detail: "Next event and today's agenda"),
    .init(id: "shelf", detail: "Files for quick access or AirDrop"),
    .init(id: "ports", detail: "Connected USB devices"),
    .init(id: "system", detail: "CPU, GPU, memory and temperature"),
    .init(id: "continuity", detail: "Apps with iPhone Live Activities"),
    .init(id: "t3Code", detail: "Active agents on T3 Code machines"),
    .init(id: "pulse", detail: "Updates from local scripts and tools"),
    .init(id: "clipboard", detail: "In-memory copy history"),
  ]
}

private struct OnboardingView: View {
  @Default(.interactionMode) private var interactionMode
  @Default(.hapticsEnabled) private var hapticsEnabled
  @Default(.launchAtLogin) private var launchAtLogin
  @ObservedObject private var calendar = AppState.calendar
  @ObservedObject private var reminders = RemindersProvider.shared
  @ObservedObject private var permissions = PermissionCenter.shared

  @State private var page = OnboardingPage.welcome
  @State private var selectedActivities: Set<String>
  @State private var remindersEnabled: Bool
  @State private var bluetoothEventsEnabled: Bool

  init() {
    _selectedActivities = State(
      initialValue: Set(
        ActivityCatalog.defaultOrder.filter { OnboardingPreferences.isActivityEnabled($0) }))
    _remindersEnabled = State(initialValue: Defaults[.remindersEnabled])
    _bluetoothEventsEnabled = State(
      initialValue: OnboardingState.isComplete
        && !Defaults[.disabledEventSources].contains("bluetooth"))
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      pageContent
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      Divider()
      controls
    }
    .frame(width: 720, height: 560)
  }

  private var header: some View {
    HStack {
      VStack(alignment: .leading, spacing: 3) {
        Text(page.title).font(.title2.weight(.semibold))
        Text("Step \(page.rawValue + 1) of \(OnboardingPage.allCases.count)")
          .font(.caption).foregroundStyle(.secondary)
      }
      Spacer()
      HStack(spacing: 7) {
        ForEach(OnboardingPage.allCases, id: \.rawValue) { item in
          Capsule()
            .fill(item.rawValue <= page.rawValue ? Color.accentColor : Color.secondary.opacity(0.2))
            .frame(width: item == page ? 28 : 9, height: 7)
        }
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Step \(page.rawValue + 1) of \(OnboardingPage.allCases.count)")
    }
    .padding(.horizontal, 28)
    .padding(.vertical, 18)
  }

  @ViewBuilder private var pageContent: some View {
    switch page {
    case .welcome: welcomePage
    case .interaction: interactionPage
    case .activities: activitiesPage
    case .permissions: permissionsPage
    case .ready: readyPage
    }
  }

  private var welcomePage: some View {
    VStack(spacing: 22) {
      ZStack {
        RoundedRectangle(cornerRadius: 22).fill(.black)
        IsletNotchMarkShape().fill(.white).frame(width: 72, height: 64)
      }
      .frame(width: 132, height: 112)
      VStack(spacing: 8) {
        Text("Islet puts timers, media controls and live system information around the MacBook notch.")
          .font(.title3.weight(.medium))
          .multilineTextAlignment(.center)
        Text("It has no Dock or menu-bar icon. Everything starts at the notch.")
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      }
      .frame(maxWidth: 500)
    }
    .padding(36)
  }

  private var interactionPage: some View {
    Form {
      Section("How Islet opens") {
        Picker("At the notch", selection: $interactionMode) {
          Text("Push past the top edge").tag(InteractionMode.hover)
          Text("Click to open and pin").tag(InteractionMode.clickToPin)
        }
        .pickerStyle(.radioGroup)
        Text(interactionMode == .hover
          ? "Move the pointer into the notch, then keep pushing upward until Islet opens."
          : "Click the notch to open Islet. Click outside it to close.")
          .font(.caption).foregroundStyle(.secondary)
      }
      Section("Startup") {
        Toggle("Launch Islet at login", isOn: $launchAtLogin)
        Toggle("Use haptic feedback", isOn: $hapticsEnabled)
      }
    }
    .formStyle(.grouped)
    .padding(.horizontal, 70)
  }

  private var activitiesPage: some View {
    ScrollView {
      LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
        ForEach(OnboardingActivity.all) { activity in
          activityToggle(activity)
        }
      }
      .padding(28)
    }
  }

  private func activityToggle(_ activity: OnboardingActivity) -> some View {
    Toggle(isOn: Binding(
      get: { selectedActivities.contains(activity.id) },
      set: { enabled in
        if enabled { selectedActivities.insert(activity.id) }
        else { selectedActivities.remove(activity.id) }
      }
    )) {
      HStack(spacing: 11) {
        Image(systemName: ActivityCatalog.icon(for: activity.id))
          .frame(width: 24).foregroundStyle(.tint)
        VStack(alignment: .leading, spacing: 2) {
          Text(ActivityCatalog.name(for: activity.id)).font(.body.weight(.medium))
          Text(activity.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
      }
    }
    .toggleStyle(.checkbox)
    .padding(12)
    .frame(maxWidth: .infinity, minHeight: 66, alignment: .leading)
    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
  }

  private var permissionsPage: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        Text("Islet asks only for access used by the activities you chose. You can skip any request.")
          .foregroundStyle(.secondary)

        if selectedActivities.contains("calendar") {
          permissionRow(
            title: "Calendar", detail: "Shows your agenda, meeting links and event countdowns.",
            status: calendar.authorization.summary,
            actionTitle: calendar.authorization.canRead ? nil : "Allow"
          ) {
            Task {
              await calendar.recoverAccess()
              permissions.refresh()
            }
          }
        }

        Toggle(isOn: $remindersEnabled) {
          permissionLabel(
            title: "Reminders", detail: "Shows incomplete reminders on Home and lets you complete them.",
            status: reminders.authorization.summary)
        }
        .toggleStyle(.checkbox)
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))

        if remindersEnabled, !reminders.authorization.canRead {
          Button("Allow Reminders access") {
            Task {
              await reminders.recoverAccess()
              permissions.refresh()
            }
          }
        }

        if selectedActivities.contains("continuity") {
          permissionRow(
            title: "Accessibility",
            detail: "Reads the app names macOS shows for iPhone Live Activities. Islet cannot read their contents.",
            status: permissions.diagnostics.accessibilityGranted ? "Allowed" : "Not allowed",
            actionTitle: permissions.diagnostics.accessibilityGranted ? nil : "Allow"
          ) {
            AccessibilityPermission.prompt()
          }
        }

        permissionRow(
          title: "Wi-Fi network names",
          detail: "Adds the network name to Wi-Fi connection alerts. The alert still works without access.",
          status: permissions.diagnostics.location.summary,
          actionTitle: permissions.diagnostics.location == .notDetermined ? "Allow" : nil
        ) {
          permissions.requestLocationAccess()
        }

        Toggle(isOn: $bluetoothEventsEnabled) {
          permissionLabel(
            title: "Bluetooth alerts",
            detail: "Shows when Bluetooth devices connect or disconnect. macOS may ask for access after setup.",
            status: bluetoothEventsEnabled ? "On" : "Off")
        }
        .toggleStyle(.checkbox)
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
      }
      .padding(28)
      .frame(maxWidth: 620)
      .frame(maxWidth: .infinity)
    }
  }

  private func permissionRow(
    title: String, detail: String, status: String, actionTitle: String?, action: @escaping () -> Void
  ) -> some View {
    HStack(spacing: 16) {
      permissionLabel(title: title, detail: detail, status: status)
      Spacer()
      if let actionTitle { Button(actionTitle, action: action) }
    }
    .padding(14)
    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
  }

  private func permissionLabel(title: String, detail: String, status: String) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: 7) {
        Text(title).font(.body.weight(.medium))
        Text(status).font(.caption).foregroundStyle(.secondary)
      }
      Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
  }

  private var readyPage: some View {
    VStack(spacing: 22) {
      Image(systemName: "checkmark.circle.fill")
        .font(.system(size: 58)).foregroundStyle(.green)
      VStack(spacing: 8) {
        Text("Islet will show \(selectedActivities.count) activities.")
          .font(.title3.weight(.medium))
      }
      VStack(alignment: .leading, spacing: 10) {
        Label("Open Islet from the notch.", systemImage: "macbook")
        Label("Change activities and permissions in Settings.", systemImage: "gearshape")
        Label("Run setup again from Settings.", systemImage: "arrow.counterclockwise")
      }
      .frame(maxWidth: 420, alignment: .leading)
    }
    .padding(36)
  }

  private var controls: some View {
    HStack {
      if page != .welcome {
        Button("Back") { move(by: -1) }
      }
      Spacer()
      if page == .ready {
        Button("Finish setup") { finish() }.buttonStyle(.borderedProminent)
      } else {
        Button("Continue") { move(by: 1) }.buttonStyle(.borderedProminent)
      }
    }
    .padding(.horizontal, 24)
    .padding(.vertical, 16)
  }

  private func move(by offset: Int) {
    let next = min(max(page.rawValue + offset, 0), OnboardingPage.allCases.count - 1)
    if let resolved = OnboardingPage(rawValue: next) { page = resolved }
  }

  private func finish() {
    OnboardingPreferences.apply(
      selectedActivities: selectedActivities,
      remindersEnabled: remindersEnabled,
      bluetoothEventsEnabled: bluetoothEventsEnabled)
    Defaults[.onboardingVersion] = OnboardingState.currentVersion
    SystemEventBus.shared.startEnabled()
    OnboardingOpener.close()
  }
}
