import AppKit
import Defaults
import SwiftUI

private enum SettingsCategory: String, CaseIterable, Identifiable {
  case general = "General"
  case activities = "Activities"
  case notifications = "Notifications"
  case integrations = "Integrations"
  case privacy = "Privacy & Permissions"
  case advanced = "Advanced"

  var id: Self { self }

  init(destination: SettingsDestination) {
    switch destination {
    case .overview, .appearance: self = .general
    case .activities: self = .activities
    case .events: self = .notifications
    case .permissions: self = .privacy
    case .integrations: self = .integrations
    case .advanced: self = .advanced
    }
  }
  var icon: String {
    switch self {
    case .general: "gear"
    case .activities: "rectangle.stack"
    case .notifications: "bell.badge"
    case .integrations: "point.3.connected.trianglepath.dotted"
    case .privacy: "lock.shield"
    case .advanced: "gearshape.2"
    }
  }
  var searchTerms: String {
    switch self {
    case .general: "launch login displays fullscreen recording hover click haptics energy"
    case .activities: "tabs order battery calendar reminders clipboard ports airpods audio hud timer shelf system media iphone continuity live activities"
    case .notifications: "events usb wifi bluetooth airdrop vpn focus screenshot sleep power volume display"
    case .integrations: "t3 code agents remote media spotify music pulse api cli providers history rules focus shortcuts"
    case .privacy: "calendar reminders accessibility privacy grant denied restricted clipboard"
    case .advanced: "diagnostics identity version defaults reset"
    }
  }
}

private enum SettingsDetailPage: String, CaseIterable, Identifiable {
  case startupDisplays
  case interaction
  case energy
  case activityOrder
  case calendarReminders
  case nowPlaying
  case systemMetrics
  case clipboard
  case systemHUD
  case eventSources
  case t3Code
  case pulse
  case permissions
  case diagnostics
  case reset

  var id: Self { self }

  var title: String {
    switch self {
    case .startupDisplays: "Startup & Displays"
    case .interaction: "Interaction"
    case .energy: "Energy"
    case .activityOrder: "Activity Lineup"
    case .calendarReminders: "Calendar & Reminders"
    case .nowPlaying: "Now Playing"
    case .systemMetrics: "System Metrics"
    case .clipboard: "Clipboard"
    case .systemHUD: "System HUD"
    case .eventSources: "Event Sources"
    case .t3Code: "T3 Code"
    case .pulse: "Pulse Providers"
    case .permissions: "App Permissions"
    case .diagnostics: "Diagnostics"
    case .reset: "Reset"
    }
  }

  var icon: String {
    switch self {
    case .startupDisplays: "macwindow.on.rectangle"
    case .interaction: "cursorarrow.motionlines"
    case .energy: "leaf"
    case .activityOrder: "list.number"
    case .calendarReminders: "calendar.badge.clock"
    case .nowPlaying: "music.note"
    case .systemMetrics: "cpu"
    case .clipboard: "doc.on.clipboard"
    case .systemHUD: "slider.horizontal.3"
    case .eventSources: "bell.badge"
    case .t3Code: "terminal.fill"
    case .pulse: "waveform.path.ecg"
    case .permissions: "lock.shield"
    case .diagnostics: "stethoscope"
    case .reset: "arrow.counterclockwise"
    }
  }

  var category: SettingsCategory {
    switch self {
    case .startupDisplays, .interaction, .energy: .general
    case .activityOrder, .calendarReminders, .nowPlaying, .systemMetrics, .clipboard, .systemHUD:
      .activities
    case .eventSources: .notifications
    case .t3Code, .pulse: .integrations
    case .permissions: .privacy
    case .diagnostics, .reset: .advanced
    }
  }

  var searchTerms: String {
    switch self {
    case .startupDisplays: "launch login screen display fullscreen recording multiple monitors"
    case .interaction: "hover push squeeze snap distance click pin collapse haptic strength notch"
    case .energy: "battery low power live polling performance"
    case .activityOrder: "enable disable stop hide tabs priority reorder"
    case .calendarReminders: "agenda countdown meetings due snooze permission"
    case .nowPlaying: "music spotify player bundle priority media"
    case .systemMetrics: "cpu gpu memory disk network thermal sparkline"
    case .clipboard: "history secrets pause privacy copy"
    case .systemHUD: "volume brightness media keys accessibility bar gauge"
    case .eventSources: "usb wifi bluetooth airdrop vpn focus screenshot sleep power display"
    case .t3Code: "agents provider remote pairing machine"
    case .pulse: "api cli providers token history delivery"
    case .permissions: "calendar reminders accessibility privacy diagnostics"
    case .diagnostics: "bundle signing version copy support"
    case .reset: "restore defaults layout presentation"
    }
  }
}

private enum PulseHistoryFilter: String, CaseIterable, Identifiable {
  case all = "All"
  case accepted = "Accepted"
  case filtered = "Filtered"
  case rejected = "Rejected"

  var id: Self { self }

  func includes(_ entry: PulseHistoryEntry) -> Bool {
    switch self {
    case .all: true
    case .accepted:
      [.shown, .updated, .ended, .dismissed, .expired].contains(entry.result)
    case .filtered: [.suppressed, .evicted].contains(entry.result)
    case .rejected: entry.result == .rejected
    }
  }
}

struct SettingsView: View {
  @ObservedObject private var calendar = AppState.calendar
  @ObservedObject private var reminders = RemindersProvider.shared
  @ObservedObject private var pulse = PulseCenter.shared
  @ObservedObject private var pulseServer = PulseServer.shared
  @ObservedObject private var permissions = PermissionCenter.shared
  @ObservedObject private var hud = HUDController.shared
  @ObservedObject private var continuity = ContinuityMonitor.shared
  @ObservedObject private var clipboard = ClipboardModel.shared
  @ObservedObject private var nowPlaying = AppState.nowPlaying
  @ObservedObject private var t3Code = AppState.t3Code

  @Default(.interactionMode) private var mode
  @Default(.hoverCollapseTimeout) private var collapseTimeout
  @Default(.hapticsEnabled) private var haptics
  @Default(.hapticStrength) private var hapticStrength
  @Default(.barrierPushDistance) private var barrierPushDistance
  @Default(.hideFromScreenRecording) private var hideFromRecording
  @Default(.mediaSourceMode) private var sourceMode
  @Default(.mediaPriorityList) private var priorityList
  @Default(.batteryEnabled) private var batteryEnabled
  @Default(.hudEnabled) private var hudEnabled
  @Default(.hudStyle) private var hudStyle
  @Default(.calendarEnabled) private var calendarEnabled
  @Default(.calendarLeadMinutes) private var calendarLeadMinutes
  @Default(.remindersEnabled) private var remindersEnabled
  @Default(.airpodsEnabled) private var airpodsEnabled
  @Default(.showOnAllDisplays) private var showOnAllDisplays
  @Default(.hideInFullscreen) private var hideInFullscreen
  @Default(.launchAtLogin) private var launchAtLogin
  @Default(.activityOrder) private var activityOrder
  @Default(.disabledActivities) private var disabledActivities
  @Default(.clipboardEnabled) private var clipboardEnabled
  @Default(.portsEnabled) private var portsEnabled
  @Default(.systemEnabled) private var systemEnabled
  @Default(.systemAlwaysVisible) private var systemAlwaysVisible
  @Default(.metricStyles) private var metricStyles
  @Default(.disabledEventSources) private var disabledEventSources
  @Default(.continuityEnabled) private var continuityEnabled
  @Default(.continuityAlwaysVisible) private var continuityAlwaysVisible
  @Default(.continuitySneaks) private var continuitySneaks
  @Default(.pulseEnabled) private var pulseEnabled
  @Default(.t3CodeEnabled) private var t3CodeEnabled
  @Default(.energyMode) private var energyMode

  @State private var selection: SettingsCategory?
  @State private var detailPage: SettingsDetailPage?
  @State private var searchText = ""
  @State private var newBundleID = ""
  @State private var confirmingRestore = false
  @State private var confirmingPulseTokenRotation = false
  @State private var pulseTokenRotationResult: String?
  @State private var showPulseHistory = false
  @State private var pulseHistoryFilter: PulseHistoryFilter = .all

  init(destination: SettingsDestination = .overview) {
    _selection = State(initialValue: SettingsCategory(destination: destination))
    _detailPage = State(initialValue: Self.defaultDetailPage(for: destination))
  }

  private var filteredCategories: [SettingsCategory] {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !query.isEmpty else { return SettingsCategory.allCases }
    return SettingsCategory.allCases.filter {
      $0.rawValue.lowercased().contains(query) || $0.searchTerms.contains(query)
    }
  }

  private var filteredDetailPages: [SettingsDetailPage] {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !query.isEmpty else { return [] }
    return SettingsDetailPage.allCases.filter {
      $0.title.lowercased().contains(query) || $0.searchTerms.contains(query)
    }
  }

  private var filteredPulseHistory: [PulseHistoryEntry] {
    pulse.history.filter(pulseHistoryFilter.includes)
  }

  private func activityEnabled(_ id: String) -> Binding<Bool> {
    Binding(
      get: { !disabledActivities.contains(id) && featureEnabled(id) },
      set: { on in
        if on { disabledActivities.removeAll { $0 == id } }
        else if !disabledActivities.contains(id) { disabledActivities.append(id) }
        setFeatureEnabled(on, id: id)
      })
  }

  private func featureEnabled(_ id: String) -> Bool {
    switch id {
    case "battery": batteryEnabled
    case "calendar": calendarEnabled
    case "clipboard": clipboardEnabled
    case "ports": portsEnabled
    case "system": systemEnabled
    case "t3Code": t3CodeEnabled
    case "pulse": pulseEnabled
    default: true
    }
  }

  private func setFeatureEnabled(_ enabled: Bool, id: String) {
    switch id {
    case "battery": batteryEnabled = enabled
    case "calendar": calendarEnabled = enabled
    case "clipboard": clipboardEnabled = enabled
    case "ports": portsEnabled = enabled
    case "system": systemEnabled = enabled
    case "t3Code": t3CodeEnabled = enabled
    case "pulse": pulseEnabled = enabled
    default: break
    }
  }

  private var hapticStrengthBinding: Binding<HapticStrength> {
    Binding(
      get: { haptics ? hapticStrength : .off },
      set: { value in
        hapticStrength = value == .off ? .medium : value
        haptics = value != .off
      })
  }

  private var hapticStrengthLevelBinding: Binding<Double> {
    Binding(
      get: {
        let value = hapticStrengthBinding.wrappedValue
        return Double(HapticStrength.allCases.firstIndex(of: value) ?? 0)
      },
      set: { level in
        let index = min(max(Int(level.rounded()), 0), HapticStrength.allCases.count - 1)
        hapticStrengthBinding.wrappedValue = HapticStrength.allCases[index]
      })
  }

  private func styleBinding(_ kind: SystemMetricKind) -> Binding<MetricDisplayStyle> {
    Binding(
      get: { MetricDisplayStyle.resolve(metricStyles[kind.rawValue]) },
      set: { metricStyles[kind.rawValue] = $0.rawValue })
  }

  private func eventSourceEnabled(_ id: String) -> Binding<Bool> {
    Binding(
      get: { !disabledEventSources.contains(id) },
      set: { on in SystemEventBus.shared.setEnabled(on, for: id) })
  }

  private func sourcePolicyBinding(_ source: String) -> Binding<PulseSourcePolicy> {
    Binding(
      get: { pulse.policy(for: source) },
      set: { pulse.setPolicy($0, for: source) })
  }

  var body: some View {
    NavigationSplitView {
      List(selection: $selection) {
        ForEach(filteredCategories) { category in
          Label(category.rawValue, systemImage: category.icon).tag(category)
        }
        if !filteredDetailPages.isEmpty {
          Section("Settings") {
            ForEach(filteredDetailPages) { page in
              Button {
                selection = page.category
                detailPage = page
                searchText = ""
              } label: {
                Label(page.title, systemImage: page.icon)
              }
              .buttonStyle(.plain)
            }
          }
        }
      }
      .navigationTitle("Islet")
      .navigationSplitViewColumnWidth(min: 190, ideal: 215, max: 260)
      .searchable(text: $searchText, placement: .sidebar, prompt: "Search settings")
      .overlay {
        if filteredCategories.isEmpty, filteredDetailPages.isEmpty {
          ContentUnavailableView.search(text: searchText)
        }
      }
    } detail: {
      Group {
        if let detailPage { detailView(detailPage) } else { categoryView }
      }
      .navigationTitle(detailPage?.title ?? (selection ?? .general).rawValue)
      .toolbar {
        if detailPage != nil {
          ToolbarItem(placement: .navigation) {
            Button {
              detailPage = nil
            } label: {
              Label("Back", systemImage: "chevron.left")
            }
          }
        }
      }
    }
    .frame(minWidth: 760, minHeight: 560)
    .onChange(of: searchText) { _, _ in
      if let current = selection, !filteredCategories.contains(current),
        let first = filteredCategories.first
      {
        selection = first
      }
    }
    .onChange(of: selection) { _, _ in
      if detailPage?.category != selection { detailPage = nil }
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) {
      _ in refreshPermissionState()
    }
    .onReceive(NotificationCenter.default.publisher(for: .isletSettingsDestination)) {
      notification in
      guard let rawValue = notification.object as? String,
        let destination = SettingsDestination(rawValue: rawValue)
      else { return }
      selection = SettingsCategory(destination: destination)
      detailPage = Self.defaultDetailPage(for: destination)
      searchText = ""
    }
    .confirmationDialog(
      "Restore interface defaults?", isPresented: $confirmingRestore, titleVisibility: .visible
    ) {
      Button("Restore Interface Defaults", role: .destructive) { restoreInterfaceDefaults() }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This resets layout and presentation. Permissions, paired machines and activity data are kept.")
    }
    .confirmationDialog(
      "Rotate the Pulse provider token?", isPresented: $confirmingPulseTokenRotation,
      titleVisibility: .visible
    ) {
      Button("Rotate Token and Disconnect Providers", role: .destructive) { rotatePulseToken() }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Every connected provider will be disconnected immediately. Existing scripts must read the new token before they can publish again. Per-source Revoke cannot provide this guarantee because source names are self-declared.")
    }
    .alert(
      "Pulse authentication", isPresented: Binding(
        get: { pulseTokenRotationResult != nil },
        set: { if !$0 { pulseTokenRotationResult = nil } })
    ) {
      Button("OK") { pulseTokenRotationResult = nil }
    } message: {
      Text(pulseTokenRotationResult ?? "")
    }
  }

  @ViewBuilder private var categoryView: some View {
    switch selection ?? .general {
    case .general:
      settingsLanding(
        "Control how Islet starts, appears, responds, and balances freshness with battery life.",
        pages: [.startupDisplays, .interaction, .energy])
    case .activities:
      settingsLanding(
        "Choose what belongs in the island, then configure only the activities that need extra options.",
        pages: [.activityOrder, .calendarReminders, .nowPlaying, .systemMetrics, .clipboard, .systemHUD])
    case .notifications:
      settingsLanding(
        "Choose which system changes deserve a brief island notification. Disabled sources stop observing.",
        pages: [.eventSources])
    case .integrations:
      settingsLanding(
        "Connect external tools without mixing their credentials and operational controls into everyday settings.",
        pages: [.t3Code, .pulse])
    case .privacy:
      settingsLanding(
        "Review every macOS permission Islet can request and recover access without enabling background monitoring.",
        pages: [.permissions])
    case .advanced:
      settingsLanding(
        "Support information and narrowly scoped reset actions live here.",
        pages: [.diagnostics, .reset])
    }
  }

  @ViewBuilder private func detailView(_ page: SettingsDetailPage) -> some View {
    switch page {
    case .startupDisplays: startupDisplaysForm
    case .interaction: interactionForm
    case .energy: energyForm
    case .activityOrder: activityOrderForm
    case .calendarReminders: calendarRemindersForm
    case .nowPlaying: nowPlayingForm
    case .systemMetrics: systemMetricsForm
    case .clipboard: clipboardForm
    case .systemHUD: systemHUDForm
    case .eventSources: eventsForm
    case .t3Code: t3Form
    case .pulse: pulseForm
    case .permissions: permissionsForm
    case .diagnostics: diagnosticsForm
    case .reset: resetForm
    }
  }

  private static func defaultDetailPage(for destination: SettingsDestination) -> SettingsDetailPage? {
    switch destination {
    case .overview: nil
    case .activities: .activityOrder
    case .events: .eventSources
    case .appearance: .interaction
    case .permissions: .permissions
    case .integrations: nil
    case .advanced: .diagnostics
    }
  }

  private func settingsLanding(
    _ introduction: String, pages: [SettingsDetailPage]
  ) -> some View {
    Form {
      Section { Text(introduction).foregroundStyle(.secondary) }
      Section {
        ForEach(pages) { page in
          Button { detailPage = page } label: {
            HStack(spacing: 12) {
              Image(systemName: page.icon)
                .font(.title3).foregroundStyle(.tint).frame(width: 28)
              Text(page.title).foregroundStyle(.primary)
              Spacer()
              Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
        }
      }
    }
    .formStyle(.grouped)
  }

  private var startupDisplaysForm: some View {
    Form {
      Section("Startup") {
        Toggle("Launch at login", isOn: $launchAtLogin)
      }
      Section("Displays") {
        Toggle("Show on all displays", isOn: $showOnAllDisplays)
        Toggle("Hide when an app is fullscreen", isOn: $hideInFullscreen)
        Toggle("Hide from screen recordings", isOn: $hideFromRecording)
      }
      Section {
        Text("Screen-recording privacy hides Islet's panels from capture; it does not change what activities collect while enabled.")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
  }

  private var activityOrderForm: some View {
    Form {
      Section("Activity lineup") {
        Text("Drag to set priority. Turning an activity off removes it from the island and stops its monitor or local server when it owns one.")
          .font(.caption).foregroundStyle(.secondary)
        List {
          ForEach(ActivityCatalog.mergedOrder(activityOrder), id: \.self) { id in
            Toggle(isOn: activityEnabled(id)) {
              Label(ActivityCatalog.name(for: id), systemImage: ActivityCatalog.icon(for: id))
            }
          }
          .onMove { offsets, target in
            var merged = ActivityCatalog.mergedOrder(activityOrder)
            merged.move(fromOffsets: offsets, toOffset: target)
            activityOrder = merged
          }
        }
        .frame(minHeight: 210, idealHeight: 260)
      }
      Section("Related services") {
        Toggle("Reminders", isOn: $remindersEnabled)
        Text("Reminders appear on Home rather than as a separate tab, so their switch lives here instead of the lineup.")
          .font(.caption).foregroundStyle(.secondary)
        Toggle("AirPods & audio devices", isOn: $airpodsEnabled)
        Toggle("iPhone Live Activities", isOn: $continuityEnabled)
        if continuityEnabled {
          Toggle("Always show iPhone tab", isOn: $continuityAlwaysVisible)
          Toggle("Announce when an activity starts or ends", isOn: $continuitySneaks)
          Text(continuity.availability.explanation)
            .font(.caption2).foregroundStyle(.secondary)
          Text(
            "Shows the Live Activities macOS exposes in Control Center. Available detail varies by app."
          )
          .font(.caption2).foregroundStyle(.secondary)
        }
      }
    }
    .formStyle(.grouped)
  }

  private var eventsForm: some View {
    Form {
      Section {
        Text("Event sources show a brief animation when something happens. Turning one off stops its observer entirely.")
          .foregroundStyle(.secondary)
      }
      ForEach(SystemEventTier.allCases, id: \.rawValue) { tier in
        let ids = SourceCatalog.ids(in: tier)
        if !ids.isEmpty {
          Section(tier.label) {
            if tier == .heuristic {
              Text("These events are inferred. An AirDrop arrival is detected after transfer, and a tunnel may be iCloud Private Relay.")
                .font(.caption).foregroundStyle(.orange)
            }
            ForEach(ids, id: \.self) { id in
              Toggle(isOn: eventSourceEnabled(id)) {
                Label(SourceCatalog.name(for: id), systemImage: SourceCatalog.icon(for: id))
              }
            }
          }
        }
      }
    }
    .formStyle(.grouped)
  }

  private var interactionForm: some View {
    Form {
      Section("Open the island") {
        Picker("Expand", selection: $mode) {
          Text("Push through").tag(InteractionMode.hover)
          Text("Click to pin").tag(InteractionMode.clickToPin)
        }
        if mode == .hover {
          Text("Move upward into the notch and keep pushing against the top edge until the island snaps open.")
            .font(.caption).foregroundStyle(.secondary)
          LabeledContent("Push distance") {
            HStack(spacing: 10) {
              Text("Short").font(.caption).foregroundStyle(.secondary)
              Slider(value: $barrierPushDistance, in: 80...480, step: 16)
                .frame(minWidth: 220)
              Text("Long").font(.caption).foregroundStyle(.secondary)
            }
          }
          Text("Current push distance: \(Int(barrierPushDistance)) points")
            .font(.caption).foregroundStyle(.secondary)
          LabeledContent("Collapse after: \(collapseTimeout, format: .number.precision(.fractionLength(1)))s") {
            Slider(value: $collapseTimeout, in: 0.2...3.0, step: 0.1).frame(minWidth: 180)
          }
        }
      }
      Section("Haptic feedback") {
        LabeledContent("Strength") {
          HStack(spacing: 10) {
            Text("Off").font(.caption).foregroundStyle(.secondary)
            Slider(
              value: hapticStrengthLevelBinding, in: 0...3, step: 1,
              onEditingChanged: { editing in
                if !editing, hapticStrengthBinding.wrappedValue != .off {
                  Haptics.perform(.levelChange)
                }
              })
              .frame(minWidth: 220)
            Text("Strong").font(.caption).foregroundStyle(.secondary)
          }
        }
        Text("Current strength: \(hapticStrengthBinding.wrappedValue.title)")
          .font(.caption).foregroundStyle(.secondary)
        Text("macOS exposes semantic haptic patterns rather than raw motor amplitude. Light, Medium, and Strong choose progressively firmer system patterns.")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
  }

  private var nowPlayingForm: some View {
    Form {
      Section("Primary player") {
        Picker("Primary player", selection: $sourceMode) {
          Text("Whatever is playing").tag(MediaSourceMode.auto)
          Text("My order").tag(MediaSourceMode.prioritized)
        }
        Text("Every player remains available. This only chooses the large player when several are active.")
          .font(.caption).foregroundStyle(.secondary)
        if sourceMode == .prioritized {
          List {
            ForEach(priorityList, id: \.self) { Text($0).font(.callout.monospaced()) }
              .onMove { priorityList.move(fromOffsets: $0, toOffset: $1) }
              .onDelete { priorityList.remove(atOffsets: $0) }
          }
          .frame(height: 120)
          HStack {
            TextField("Bundle ID (for example, com.spotify.client)", text: $newBundleID)
            Button("Add") {
              priorityList.append(newBundleID.trimmingCharacters(in: .whitespacesAndNewlines))
              newBundleID = ""
            }
            .disabled(newBundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          }
        }
      }
      Section("Status") {
        LabeledContent("Media adapter") {
          Text(nowPlaying.adapterStatus).foregroundStyle(.secondary)
        }
        Text("Now Playing uses a private MediaRemote compatibility adapter and may need updates after major macOS releases.")
          .font(.caption).foregroundStyle(.orange)
      }
    }
    .formStyle(.grouped)
  }

  private var calendarRemindersForm: some View {
    Form {
      Section("Calendar") {
        LabeledContent("Activity") {
          Text(calendarEnabled ? "On" : "Off").foregroundStyle(.secondary)
        }
        Text("Enable or disable Calendar from Activity Lineup so visibility and EventKit monitoring stay in sync.")
          .font(.caption).foregroundStyle(.secondary)
        if calendarEnabled {
          Stepper(
            "Show countdown \(calendarLeadMinutes) minutes before",
            value: $calendarLeadMinutes, in: 5...60, step: 5)
        }
        Button("Manage Calendar permission…") {
          selection = .privacy
          detailPage = .permissions
        }
      }
      Section("Reminders") {
        Toggle("Show incomplete reminders on Home", isOn: $remindersEnabled)
        Text("Reminder monitoring stops when this is off. Permission can still be reviewed separately.")
          .font(.caption).foregroundStyle(.secondary)
        Button("Manage Reminders permission…") {
          selection = .privacy
          detailPage = .permissions
        }
      }
    }
    .formStyle(.grouped)
  }

  private var systemMetricsForm: some View {
    Form {
      Section("Visibility") {
        LabeledContent("System activity") {
          Text(systemEnabled ? "On" : "Off").foregroundStyle(.secondary)
        }
        Text("Enable or disable System from Activity Lineup. When enabled, it can appear only under sustained load or stay available at all times.")
          .font(.caption).foregroundStyle(.secondary)
        if systemEnabled {
          Toggle("Always show System in the activity switcher", isOn: $systemAlwaysVisible)
        }
      }
      if systemEnabled {
        Section("Metric presentation") {
          ForEach(SystemMetricKind.allCases, id: \.self) { kind in
            Picker(kind.displayName, selection: styleBinding(kind)) {
              ForEach(MetricDisplayStyle.allCases, id: \.self) { style in
                Text(style.displayName).tag(style)
              }
            }
          }
          Text("Thermal has no numeric history; sparkline styles render its current state as text.")
            .font(.caption).foregroundStyle(.secondary)
        }
      }
    }
    .formStyle(.grouped)
  }

  private var clipboardForm: some View {
    Form {
      Section("Clipboard history") {
        LabeledContent("Activity") {
          Text(clipboardEnabled ? "On" : "Off").foregroundStyle(.secondary)
        }
        Text("Enable or disable Clipboard from Activity Lineup. Turning it off stops polling and immediately clears retained history.")
          .font(.caption).foregroundStyle(.secondary)
        if clipboardEnabled {
          Toggle(
            "Pause capture", isOn: Binding(
              get: { clipboard.isPaused },
              set: { clipboard.setPaused($0) }))
          Button("Clear clipboard history") { clipboard.clear() }
        }
      }
      Section("Privacy") {
        Label(
          "History remains in memory and is cleared at quit. Concealed and transient items plus common credential formats are filtered on a best-effort basis.",
          systemImage: "lock.shield")
          .font(.caption).foregroundStyle(.orange)
      }
    }
    .formStyle(.grouped)
  }

  private var systemHUDForm: some View {
    Form {
      Section("Media-key HUD") {
        Toggle("Replace the volume and brightness HUD", isOn: $hudEnabled)
        if hudEnabled {
          Picker("Style", selection: $hudStyle) {
            Text("Bar").tag(HUDStyle.bar)
            Text("Gauge").tag(HUDStyle.gauge)
          }
          PermissionStatusRow(
            title: "Accessibility", icon: "accessibility",
            status: hud.eventTapStatus.summary,
            color: hud.eventTapStatus == .active ? .green : .orange)
          if !hud.accessibilityTrusted {
            Button("Review Accessibility permission…") {
              selection = .privacy
              detailPage = .permissions
            }
          }
        }
      }
      Section {
        Text("If Islet cannot safely change the active device or display, it passes the media key back to macOS and leaves the system HUD intact.")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
  }

  private var energyForm: some View {
    Form {
      Section("Energy policy") {
        Picker("Mode", selection: $energyMode) {
          Text("Automatic").tag(EnergyMode.automatic)
          Text("Low Energy").tag(EnergyMode.lowEnergy)
          Text("Live").tag(EnergyMode.live)
        }
        Text(energyModeDetail)
          .font(.caption)
          .foregroundStyle(energyMode == .live ? .orange : .secondary)
      }
    }
    .formStyle(.grouped)
  }

  private var permissionsForm: some View {
    Form {
      Section("Calendar") {
        PermissionStatusRow(title: "Calendar access", icon: "calendar", status: eventStatusText, color: eventStatusColor)
        Text("Used to show today's agenda, countdowns and meeting links.").font(.caption).foregroundStyle(.secondary)
        permissionButtons(status: permissions.diagnostics.calendar, pane: .calendars) {
          Task {
            await calendar.recoverAccess()
            permissions.refresh()
          }
        }
      }
      Section("Reminders") {
        PermissionStatusRow(title: "Reminders access", icon: "checklist", status: reminderStatusText, color: reminderStatusColor)
        Text("Used to show and complete your incomplete reminders.").font(.caption).foregroundStyle(.secondary)
        permissionButtons(status: permissions.diagnostics.reminders, pane: .reminders) {
          Task {
            await reminders.requestAccess()
            permissions.refresh()
          }
        }
      }
      Section("Accessibility") {
        PermissionStatusRow(
          title: "Media-key HUD", icon: "keyboard",
          status: hud.accessibilityTrusted ? hud.eventTapStatus.summary : "Not allowed",
          color: hud.accessibilityTrusted ? (hud.eventTapStatus == .active ? .green : .orange) : .red)
        Text("Required only when Islet replaces the system volume and brightness HUD.")
          .font(.caption).foregroundStyle(.secondary)
        HStack {
          if !hud.accessibilityTrusted { Button("Request access") { hud.promptForAccessibility() } }
          Button("Open Accessibility Settings") { permissions.open(.accessibility) }
        }
      }
      Section { Button("Refresh permission status") { refreshPermissionState() } }
    }
    .formStyle(.grouped)
  }

  private var t3Form: some View {
    Form {
      T3SettingsSection(activity: t3Code)
      if let error = t3Code.lastCredentialError {
        Section("Credential error") {
          Label(error, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
        }
      }
      Section {
        Text("Enable or disable the T3 Code activity from Activity Lineup. Pairing and machine controls remain here so credentials are never mixed with presentation settings.")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
  }

  private var pulseForm: some View {
    Form {
      Section("Pulse providers") {
        PermissionStatusRow(
          title: "Local activity API", icon: "waveform.path.ecg",
          status: pulseServer.lastError ?? (pulseServer.isRunning ? "Listening on 127.0.0.1:47717" : "Stopped"),
          color: pulseServer.lastError == nil ? (pulseServer.isRunning ? .green : .secondary) : .red)
        LabeledContent("Activity stack") {
          Text(
            pulse.hiddenItemCount == 0
              ? "\(pulse.items.count) visible"
              : "\(pulse.items.count) visible, \(pulse.hiddenItemCount) filtered"
          )
          .monospacedDigit().foregroundStyle(.secondary)
        }
        LabeledContent("Authentication") {
          Text("Shared bearer token").foregroundStyle(.secondary)
        }
        Picker("Delivery profile", selection: $pulse.deliveryProfile) {
          ForEach(PulseDeliveryProfile.allCases) { profile in
            Text(profile.title).tag(profile)
          }
        }
        Text(pulse.deliveryProfile.detail)
          .font(.caption).foregroundStyle(.secondary)
        Text("Pulse lets local scripts and tools publish bounded progress, alerts and actions. Connections are loopback-only and authenticated with a private token. Delivery profiles last until Islet quits.")
          .font(.caption).foregroundStyle(.secondary)
        Text("Enable or disable Pulse from Activity Lineup. Turning it off closes the listener and disconnects providers.")
          .font(.caption).foregroundStyle(.secondary)
        HStack {
          Button("Quick Actions…") { QuickActionsOpener.open() }
          Button("Reveal token folder") { NSWorkspace.shared.open(PulsePaths.supportDirectory) }
            .help("The token is a provider credential. Do not share it.")
          if !pulse.items.isEmpty {
            Button("Dismiss visible") { pulse.dismissVisible() }
          }
          Button("Rotate provider token…", role: .destructive) {
            confirmingPulseTokenRotation = true
          }
        }
      }
      Section("Provider gallery") {
        Text("Providers run as separate processes. The capabilities below describe the bounded data they may send; providers cannot load code into Islet or read activity data back.")
          .font(.caption).foregroundStyle(.secondary)
        Text("Allow, Mute, and Revoke apply to the source name declared on the wire for this session. A provider holding the shared token can choose another source name, so Revoke is a routing rule—not credential revocation. Rotate the provider token above to invalidate every client.")
          .font(.caption).foregroundStyle(.orange)
        ForEach(pulse.providerStatuses) { status in
          PulseProviderRow(status: status, center: pulse)
        }
        if !pulse.unlistedSources.isEmpty {
          Text("Other sources seen this session").font(.caption.weight(.medium))
          ForEach(pulse.unlistedSources, id: \.self) { source in
            LabeledContent {
              Picker("Policy", selection: sourcePolicyBinding(source)) {
                ForEach(PulseSourcePolicy.allCases) { policy in
                  Text(policy.title).tag(policy)
                }
              }
              .labelsHidden()
              .frame(width: 110)
            } label: {
              Text(source).font(.caption.monospaced()).textSelection(.enabled)
            }
          }
        }
      }
      Section("Pulse session history") {
        Toggle("Show payload-free history", isOn: $showPulseHistory)
        Text("Kept only in memory. Payload IDs, titles, details, web links, authentication tokens, and error text are never recorded. Source routing names and state metadata are retained for provider health.")
          .font(.caption).foregroundStyle(.secondary)
        if showPulseHistory {
          Picker("History filter", selection: $pulseHistoryFilter) {
            ForEach(PulseHistoryFilter.allCases) { filter in Text(filter.rawValue).tag(filter) }
          }
          .pickerStyle(.segmented)
          if filteredPulseHistory.isEmpty {
            Text(pulse.history.isEmpty ? "No provider activity this session." : "No matching history entries.")
              .foregroundStyle(.secondary)
          } else {
            ForEach(filteredPulseHistory.prefix(30)) { entry in
              PulseHistoryRow(entry: entry)
            }
            HStack {
              Text("Showing \(min(30, filteredPulseHistory.count)) of \(filteredPulseHistory.count)")
                .font(.caption).foregroundStyle(.secondary)
              Spacer()
              Button("Clear history") { pulse.clearHistory() }
            }
          }
        }
      }
    }
    .formStyle(.grouped)
  }

  private var diagnosticsForm: some View {
    Form {
      Section("Diagnostics") {
        LabeledContent("Bundle identifier") {
          Text(Bundle.main.bundleIdentifier ?? "Unknown").textSelection(.enabled)
        }
        LabeledContent("Version") { Text(versionText).foregroundStyle(.secondary) }
        Button("Copy diagnostics") { copyDiagnostics() }
      }
      Section("Integration health") {
        PermissionStatusRow(
          title: "T3 Code credentials", icon: "key.fill",
          status: t3Code.lastCredentialError ?? "Available",
          color: t3Code.lastCredentialError == nil ? .green : .orange)
        PermissionStatusRow(
          title: "Pulse", icon: "waveform.path.ecg",
          status: pulseServer.lastError ?? (pulseServer.isRunning ? "Listening" : "Stopped"),
          color: pulseServer.lastError == nil ? (pulseServer.isRunning ? .green : .secondary) : .red)
      }
    }
    .formStyle(.grouped)
  }

  private var resetForm: some View {
    Form {
      Section("Interface defaults") {
        Button("Restore interface defaults…", role: .destructive) { confirmingRestore = true }
        Text("Resets interaction, haptics, presentation styles, player priority, and activity order. Enabled activities, permissions, paired machines, and activity data are kept.")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
  }

  @ViewBuilder private func permissionButtons(
    status: EventKitPermissionState, pane: SystemSettingsPrivacyPane,
    request: @escaping () -> Void
  ) -> some View {
    HStack {
      if status == .notDetermined { Button("Request access", action: request) }
      if status != .fullAccess { Button("Open System Settings") { permissions.open(pane) } }
    }
  }

  private var eventStatusText: String { permissions.diagnostics.calendar.summary }
  private var reminderStatusText: String { permissions.diagnostics.reminders.summary }
  private var eventStatusColor: Color { authorizationColor(permissions.diagnostics.calendar) }
  private var reminderStatusColor: Color { authorizationColor(permissions.diagnostics.reminders) }

  private func authorizationColor(_ status: EventKitPermissionState) -> Color {
    switch status {
    case .fullAccess: .green
    case .notDetermined, .writeOnly: .orange
    case .restricted, .denied: .red
    case .unknown: .secondary
    }
  }

  private func refreshPermissionState() {
    hud.refreshPermissionStatus()
    permissions.refresh()
  }

  private var versionText: String {
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    return build.map { "\(version) (\($0))" } ?? version
  }

  private var energyModeDetail: String {
    switch energyMode {
    case .automatic:
      "Follows macOS Low Power Mode and slows hidden activity automatically."
    case .lowEnergy:
      "Always uses conservative refresh rates and disables optional remote T3 polling."
    case .live:
      "Prioritises fresh metrics and remote status, including while macOS Low Power Mode is on."
    }
  }

  private func copyDiagnostics() {
    let text = permissions.diagnostics.text
      + "\nHUD event tap: \(hud.eventTapStatus.summary)"
      + "\nPulse: \(pulseServer.isRunning ? "Running" : "Stopped")"
      + "\nPulse stack: \(pulse.items.count) visible, \(pulse.hiddenItemCount) filtered"
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }

  private func rotatePulseToken() {
    do {
      try pulseServer.rotateToken()
      pulseTokenRotationResult = "The token was replaced and all provider connections were disconnected. Providers must read the new token before reconnecting."
    } catch {
      pulseTokenRotationResult = "The token could not be rotated: \(error.localizedDescription)"
    }
  }

  private func restoreInterfaceDefaults() {
    mode = .hover
    collapseTimeout = 0.5
    haptics = true
    hapticStrength = .medium
    barrierPushDistance = 288
    sourceMode = .auto
    priorityList = ["com.spotify.client", "com.apple.Music"]
    activityOrder = ActivityCatalog.defaultOrder
    systemAlwaysVisible = false
    metricStyles = [:]
    hudStyle = .bar
  }
}

private struct PermissionStatusRow: View {
  let title: String
  let icon: String
  let status: String
  let color: Color

  var body: some View {
    LabeledContent {
      HStack(spacing: 6) {
        Circle().fill(color).frame(width: 7, height: 7).accessibilityHidden(true)
        Text(status).foregroundStyle(.secondary)
      }
    } label: {
      Label(title, systemImage: icon)
    }
    .accessibilityElement(children: .combine)
  }
}

private struct PulseProviderRow: View {
  let status: PulseProviderStatus
  let center: PulseCenter

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack(spacing: 8) {
        Image(systemName: status.descriptor.symbol)
          .frame(width: 22)
          .foregroundStyle(healthColor)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 1) {
          Text(status.descriptor.name).font(.body.weight(.medium))
          Text(status.descriptor.summary).font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        HStack(spacing: 5) {
          Circle().fill(healthColor).frame(width: 7, height: 7).accessibilityHidden(true)
          Text(status.health.summary).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        Picker("Policy", selection: policyBinding) {
          ForEach(PulseSourcePolicy.allCases) { policy in
            Text(policy.title).tag(policy)
          }
        }
        .labelsHidden()
        .frame(width: 110)
        .help(policyBinding.wrappedValue.detail)
      }
      HStack(spacing: 12) {
        ForEach(status.descriptor.capabilities.sorted { $0.rawValue < $1.rawValue }) { capability in
          Label(capability.title, systemImage: capability.symbol)
        }
      }
      .font(.caption2)
      .foregroundStyle(.secondary)
      Text(status.descriptor.setupHint)
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }
    .padding(.vertical, 4)
    .accessibilityElement(children: .contain)
  }

  private var healthColor: Color {
    switch status.health {
    case .active: .green
    case .seen: .blue
    case .neverSeen: .secondary
    }
  }

  private var policyBinding: Binding<PulseSourcePolicy> {
    Binding(
      get: { center.policy(for: status.descriptor) },
      set: { center.setPolicy($0, for: status.descriptor) })
  }
}

private struct PulseHistoryRow: View {
  let entry: PulseHistoryEntry

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: symbol).foregroundStyle(color).frame(width: 18)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 1) {
        HStack(spacing: 5) {
          Text(entry.result.title).font(.caption.weight(.medium))
          if let source = entry.source {
            Text(source).font(.caption.monospaced()).foregroundStyle(.secondary)
          }
        }
        Text(metadata).font(.caption2).foregroundStyle(.tertiary)
      }
      Spacer()
      Text(entry.date, style: .time).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .combine)
  }

  private var metadata: String {
    [entry.operation.rawValue, entry.state?.rawValue, entry.priority?.rawValue]
      .compactMap { $0 }
      .joined(separator: " • ")
  }

  private var symbol: String {
    switch entry.result {
    case .shown, .updated: "waveform.path.ecg"
    case .ended, .dismissed, .expired: "checkmark.circle"
    case .suppressed: "line.3.horizontal.decrease.circle"
    case .rejected: "exclamationmark.triangle"
    case .evicted: "arrow.down.circle"
    }
  }

  private var color: Color {
    switch entry.result {
    case .rejected: .red
    case .suppressed, .evicted: .orange
    case .shown, .updated: .blue
    case .ended, .dismissed, .expired: .secondary
    }
  }
}
