import AppKit
import Defaults
import SwiftUI

private enum SettingsCategory: String, CaseIterable, Identifiable {
  case overview = "Overview"
  case activities = "Activities"
  case events = "Events"
  case appearance = "Appearance & Interaction"
  case permissions = "Permissions"
  case integrations = "Integrations"
  case advanced = "Advanced"

  var id: Self { self }

  init(destination: SettingsDestination) {
    switch destination {
    case .overview: self = .overview
    case .activities: self = .activities
    case .events: self = .events
    case .appearance: self = .appearance
    case .permissions: self = .permissions
    case .integrations: self = .integrations
    case .advanced: self = .advanced
    }
  }
  var icon: String {
    switch self {
    case .overview: "house"
    case .activities: "rectangle.stack"
    case .events: "sparkles"
    case .appearance: "paintbrush"
    case .permissions: "lock.shield"
    case .integrations: "point.3.connected.trianglepath.dotted"
    case .advanced: "gearshape.2"
    }
  }
  var searchTerms: String {
    switch self {
    case .overview: "general launch login displays fullscreen recording health status"
    case .activities: "tabs order battery calendar reminders clipboard ports airpods audio hud timer shelf system iphone continuity live activities"
    case .events: "usb wifi bluetooth airdrop vpn focus screenshot sleep power volume display notifications"
    case .appearance: "hover click expand collapse haptics media player order menu interaction"
    case .permissions: "calendar reminders accessibility privacy grant denied restricted"
    case .integrations: "t3 code agents remote media spotify music pulse api cli providers history rules focus shortcuts"
    case .advanced: "cpu gpu memory disk network thermal metrics clipboard diagnostics defaults reset"
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

  @Default(.interactionMode) private var mode
  @Default(.hoverCollapseTimeout) private var collapseTimeout
  @Default(.hapticsEnabled) private var haptics
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
  @Default(.energyMode) private var energyMode

  @State private var selection: SettingsCategory?
  @State private var searchText = ""
  @State private var newBundleID = ""
  @State private var confirmingRestore = false
  @State private var confirmingPulseTokenRotation = false
  @State private var pulseTokenRotationResult: String?
  @State private var showPulseHistory = false
  @State private var pulseHistoryFilter: PulseHistoryFilter = .all

  init(destination: SettingsDestination = .overview) {
    _selection = State(initialValue: SettingsCategory(destination: destination))
  }

  private var filteredCategories: [SettingsCategory] {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !query.isEmpty else { return SettingsCategory.allCases }
    return SettingsCategory.allCases.filter {
      $0.rawValue.lowercased().contains(query) || $0.searchTerms.contains(query)
    }
  }

  private var filteredPulseHistory: [PulseHistoryEntry] {
    pulse.history.filter(pulseHistoryFilter.includes)
  }

  private func enabled(_ id: String) -> Binding<Bool> {
    Binding(
      get: { !disabledActivities.contains(id) },
      set: { on in
        if on { disabledActivities.removeAll { $0 == id } }
        else if !disabledActivities.contains(id) { disabledActivities.append(id) }
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
      }
      .navigationTitle("Islet")
      .navigationSplitViewColumnWidth(min: 190, ideal: 215, max: 260)
      .searchable(text: $searchText, placement: .sidebar, prompt: "Search settings")
      .overlay {
        if filteredCategories.isEmpty { ContentUnavailableView.search(text: searchText) }
      }
    } detail: {
      categoryView
        .navigationTitle((selection ?? .overview).rawValue)
    }
    .frame(minWidth: 760, minHeight: 560)
    .onChange(of: searchText) { _, _ in
      if let current = selection, !filteredCategories.contains(current),
        let first = filteredCategories.first
      {
        selection = first
      }
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
    switch selection ?? .overview {
    case .overview: overviewForm
    case .activities: activitiesForm
    case .events: eventsForm
    case .appearance: appearanceForm
    case .permissions: permissionsForm
    case .integrations: integrationsForm
    case .advanced: advancedForm
    }
  }

  private var overviewForm: some View {
    Form {
      Section("Setup health") {
        PermissionStatusRow(
          title: "Calendar", icon: "calendar", status: calendarEnabled ? eventStatusText : "Off",
          color: calendarEnabled ? eventStatusColor : .secondary)
        PermissionStatusRow(
          title: "Reminders", icon: "checklist",
          status: remindersEnabled ? reminderStatusText : "Off",
          color: remindersEnabled ? reminderStatusColor : .secondary)
        PermissionStatusRow(
          title: "HUD replacement", icon: "slider.horizontal.3",
          status: hudEnabled ? hud.eventTapStatus.summary : "Off",
          color: !hudEnabled ? .secondary : (hud.eventTapStatus == .active ? .green : .orange))
        PermissionStatusRow(
          title: "Pulse", icon: "waveform.path.ecg",
          status: pulseServer.isRunning ? "Listening locally" : "Stopped",
          color: pulseServer.isRunning ? .green : .secondary)
      }
      Section("General") {
        Toggle("Launch at login", isOn: $launchAtLogin)
        Toggle("Show on all displays", isOn: $showOnAllDisplays)
        Toggle("Hide when an app is fullscreen", isOn: $hideInFullscreen)
        Toggle("Hide from screen recordings", isOn: $hideFromRecording)
      }
      Section {
        Text("Use the sidebar to manage activities, permissions, integrations and advanced metrics without one long scrolling page.")
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
  }

  private var activitiesForm: some View {
    Form {
      Section("Activity visibility") {
        Text("Drag to choose priority order. Disabled activities are hidden from the island.")
          .font(.caption).foregroundStyle(.secondary)
        List {
          ForEach(ActivityCatalog.mergedOrder(activityOrder), id: \.self) { id in
            Toggle(isOn: enabled(id)) {
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
      Section("Built-in activities") {
        Toggle("Battery & charging", isOn: $batteryEnabled)
        Toggle("Calendar", isOn: $calendarEnabled)
        if calendarEnabled {
          Stepper("Countdown lead: \(calendarLeadMinutes) min", value: $calendarLeadMinutes, in: 5...60, step: 5)
        }
        Toggle("Reminders", isOn: $remindersEnabled)
        Toggle("Clipboard history", isOn: $clipboardEnabled)
        Toggle("Ports", isOn: $portsEnabled)
        Toggle("AirPods & audio devices", isOn: $airpodsEnabled)
        Toggle("System stats", isOn: $systemEnabled)
        if systemEnabled { Toggle("Always show System tab", isOn: $systemAlwaysVisible) }
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
      Section("System HUD") {
        Toggle("Replace volume and brightness HUD", isOn: $hudEnabled)
        if hudEnabled {
          Picker("Style", selection: $hudStyle) {
            Text("Bar").tag(HUDStyle.bar)
            Text("Gauge").tag(HUDStyle.gauge)
          }
          if !hud.accessibilityTrusted {
            Label("Accessibility permission is required", systemImage: "exclamationmark.triangle")
              .foregroundStyle(.orange)
            Button("Review permission…") { selection = .permissions }
          }
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

  private var appearanceForm: some View {
    Form {
      Section("Open the island") {
        Picker("Expand", selection: $mode) {
          Text("Push through").tag(InteractionMode.hover)
          Text("Click to pin").tag(InteractionMode.clickToPin)
        }
        if mode == .hover {
          Text("Move upward into the notch until the island snaps open.")
            .font(.caption).foregroundStyle(.secondary)
          LabeledContent("Collapse after: \(collapseTimeout, format: .number.precision(.fractionLength(1)))s") {
            Slider(value: $collapseTimeout, in: 0.2...3.0, step: 0.1).frame(minWidth: 180)
          }
        }
        Toggle("Haptic feedback", isOn: $haptics)
      }
      Section("Now Playing priority") {
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
    }
    .formStyle(.grouped)
  }

  private var permissionsForm: some View {
    Form {
      Section("Calendar") {
        PermissionStatusRow(title: "Calendar access", icon: "calendar", status: eventStatusText, color: eventStatusColor)
        Text("Used to show today's agenda, countdowns and meeting links.").font(.caption).foregroundStyle(.secondary)
        permissionButtons(status: calendar.authorization, pane: .calendars) {
          Task { await calendar.recoverAccess() }
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

  private var integrationsForm: some View {
    Form {
      T3SettingsSection(activity: AppState.t3Code)
      Section("Pulse providers") {
        Toggle("Enable local Pulse providers", isOn: $pulseEnabled)
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
      Section("Media") {
        LabeledContent("Media adapter") {
          Text(AppState.nowPlaying.adapterStatus).foregroundStyle(.secondary)
        }
        Text("Player priority and bundle IDs are configured in Appearance & Interaction.")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
  }

  private var advancedForm: some View {
    Form {
      Section("System metric presentation") {
        Toggle("System stats tab", isOn: $systemEnabled)
        if systemEnabled {
          Toggle("Always show the tab", isOn: $systemAlwaysVisible)
          Text("When off, System appears only after sustained high CPU or thermal pressure.")
            .font(.caption).foregroundStyle(.secondary)
          ForEach(SystemMetricKind.allCases, id: \.self) { kind in
            Picker(kind.displayName, selection: styleBinding(kind)) {
              ForEach(MetricDisplayStyle.allCases, id: \.self) { style in
                Text(style.displayName).tag(style)
              }
            }
          }
          Text("Thermal has no history; sparkline styles show its state as text.")
            .font(.caption).foregroundStyle(.secondary)
        }
      }
      Section("Clipboard privacy") {
        Toggle("Clipboard history", isOn: $clipboardEnabled)
        if clipboardEnabled {
          Label("Concealed and transient pasteboard items plus common secret formats are filtered on a best-effort basis. History stays in memory only and is cleared when Islet quits.", systemImage: "lock.shield")
            .font(.caption).foregroundStyle(.orange)
        }
      }
      Section("Diagnostics") {
        LabeledContent("Bundle identifier") {
          Text(Bundle.main.bundleIdentifier ?? "Unknown").textSelection(.enabled)
        }
        LabeledContent("Version") { Text(versionText).foregroundStyle(.secondary) }
        Button("Copy diagnostics") { copyDiagnostics() }
      }
      Section("Energy & responsiveness") {
        Picker("Energy mode", selection: $energyMode) {
          Text("Automatic").tag(EnergyMode.automatic)
          Text("Low Energy").tag(EnergyMode.lowEnergy)
          Text("Live").tag(EnergyMode.live)
        }
        Text(energyModeDetail)
          .font(.caption)
          .foregroundStyle(energyMode == .live ? .orange : .secondary)
      }
      Section("Defaults") {
        Button("Restore interface defaults…", role: .destructive) { confirmingRestore = true }
        Text("Keeps permissions, paired T3 machines, feature enablement and activity data.")
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

  private var eventStatusText: String { calendar.authorization.summary }
  private var reminderStatusText: String { permissions.diagnostics.reminders.summary }
  private var eventStatusColor: Color { authorizationColor(calendar.authorization) }
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
    Task { await calendar.refreshAuthorization() }
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
    sourceMode = .auto
    priorityList = ["com.spotify.client", "com.apple.Music"]
    activityOrder = ActivityCatalog.defaultOrder
    disabledActivities = []
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
