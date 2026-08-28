import AppKit
import Defaults
import SwiftUI

private enum SettingsCategory: String, CaseIterable, Identifiable {
  case general = "General"
  case activities = "Activities"
  case notifications = "Notifications"
  case integrations = "Integrations"
  case privacy = "Privacy"
  case advanced = "Advanced"

  var id: Self { self }

  init(destination: SettingsDestination) {
    switch destination {
    case .overview, .appearance: self = .general
    case .activities: self = .activities
    case .events: self = .notifications
    case .permissions: self = .privacy
    case .integrations, .pulse: self = .integrations
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
    case .activities: "tabs order battery calendar reminders clipboard ports audio hud timer shelf system media iphone continuity live activities"
    case .notifications: "events usb wifi bluetooth airdrop vpn focus screenshot sleep power volume display"
    case .integrations: "t3 code agents remote media spotify music pulse api cli providers history rules focus shortcuts"
    case .privacy: "calendar reminders accessibility privacy grant denied restricted clipboard"
    case .advanced: "diagnostics identity version defaults reset"
    }
  }
}

private enum SystemMetricPreset: String, CaseIterable, Identifiable {
  case compact = "Compact"
  case balanced = "Balanced"
  case detailed = "Detailed"
  case custom = "Custom"

  var id: Self { self }
}

private enum SettingsDetailPage: String, CaseIterable, Identifiable {
  case startupDisplays
  case interaction
  case energy
  case activityOrder
  case calendarReminders
  case nowPlaying
  case continuity
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
    case .continuity: "iPhone Live Activities"
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

  var subtitle: String {
    switch self {
    case .startupDisplays: "Login, monitors, and fullscreen behavior"
    case .interaction: "Push-through, collapse timing, and haptics"
    case .energy: "Choose the balance between freshness and battery life"
    case .activityOrder: "Choose, order, and disable island activities"
    case .calendarReminders: "Calendars, countdowns, and Home reminders"
    case .nowPlaying: "Select the primary player when several are active"
    case .continuity: "Show iPhone activity presence exposed by macOS"
    case .systemMetrics: "Visibility and metric presentation"
    case .clipboard: "Retention behavior and privacy boundaries"
    case .systemHUD: "Volume and brightness overlay replacement"
    case .eventSources: "Choose which system changes appear briefly"
    case .t3Code: "Pair and manage provider-neutral T3 machines"
    case .pulse: "Local providers, policies, credentials, and history"
    case .permissions: "Review macOS access and recording privacy"
    case .diagnostics: "Identity, integration health, and support details"
    case .reset: "Restore appearance and interaction defaults"
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
    case .continuity: "iphone.gen3"
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
    case .activityOrder, .calendarReminders, .nowPlaying, .continuity, .systemMetrics, .clipboard,
      .systemHUD:
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
    case .continuity: "iphone live activities control center accessibility announce remote"
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
  @ObservedObject private var nowPlaying = AppState.nowPlaying
  @ObservedObject private var t3Code = AppState.t3Code
  @ObservedObject private var launchAtLoginStatus = LaunchAtLoginStatus.shared

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
  @Default(.hiddenCalendarIDs) private var hiddenCalendarIDs
  @Default(.remindersEnabled) private var remindersEnabled
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
  @Default(.pulseEnabled) private var pulseEnabled
  @Default(.t3CodeEnabled) private var t3CodeEnabled
  @Default(.energyMode) private var energyMode
  @Default(.continuityEnabled) private var continuityEnabled
  @Default(.continuityAlwaysVisible) private var continuityAlwaysVisible
  @Default(.continuitySneaks) private var continuitySneaks

  @State private var selection: SettingsCategory?
  @State private var detailPage: SettingsDetailPage?
  @State private var forwardDetailPage: SettingsDetailPage?
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

  private var unprioritizedDetectedPlayers: [String] {
    nowPlaying.knownBundleIdentifiers.filter { !priorityList.contains($0) }
  }

  private func activityEnabled(_ id: String) -> Binding<Bool> {
    Binding(
      get: { !disabledActivities.contains(id) && featureEnabled(id) },
      set: { on in
        if on {
          disabledActivities.removeAll { $0 == id }
          // Recover preferences written by the previous combined visibility/lifecycle switch.
          setFeatureEnabled(true, id: id)
        } else if !disabledActivities.contains(id) {
          disabledActivities.append(id)
          if ActivityLifecyclePolicy.stopsFeatureWhenHidden(id) {
            setFeatureEnabled(false, id: id)
          }
        }
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
    case "continuity": continuityEnabled
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
    case "continuity": continuityEnabled = enabled
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

  private var pushDistanceSliderBinding: Binding<Double> {
    Binding(
      get: { PushDistanceScale.sliderPosition(for: barrierPushDistance) },
      set: { position in
        barrierPushDistance = PushDistanceScale.roundedDistance(for: position)
      })
  }

  private var metricPresetBinding: Binding<SystemMetricPreset> {
    Binding(
      get: {
        let resolved = SystemMetricKind.allCases.map { styleBinding($0).wrappedValue }
        if resolved.allSatisfy({ $0 == .number }) { return .compact }
        if resolved.allSatisfy({ $0 == .combined }) { return .detailed }
        let balanced = SystemMetricKind.allCases.map {
          $0 == .thermal ? MetricDisplayStyle.number : .sparklineAndNumber
        }
        return resolved == balanced ? .balanced : .custom
      },
      set: { preset in
        switch preset {
        case .compact:
          metricStyles = Dictionary(
            uniqueKeysWithValues: SystemMetricKind.allCases.map { ($0.rawValue, MetricDisplayStyle.number.rawValue) })
        case .balanced:
          metricStyles = [:]
        case .detailed:
          metricStyles = Dictionary(
            uniqueKeysWithValues: SystemMetricKind.allCases.map { ($0.rawValue, MetricDisplayStyle.combined.rawValue) })
        case .custom: break
        }
      })
  }

  private func styleBinding(_ kind: SystemMetricKind) -> Binding<MetricDisplayStyle> {
    Binding(
      get: {
        MetricDisplayStyle.effective(
          for: kind, requested: MetricDisplayStyle.resolve(metricStyles[kind.rawValue]))
      },
      set: { metricStyles[kind.rawValue] = $0.rawValue })
  }

  private func eventSourceEnabled(_ id: String) -> Binding<Bool> {
    Binding(
      get: { !disabledEventSources.contains(id) },
      set: { on in SystemEventBus.shared.setEnabled(on, for: id) })
  }

  private func calendarEnabledBinding(_ id: String) -> Binding<Bool> {
    Binding(
      get: { !hiddenCalendarIDs.contains(id) },
      set: { enabled in
        if enabled {
          hiddenCalendarIDs.removeAll { $0 == id }
        } else if !hiddenCalendarIDs.contains(id) {
          hiddenCalendarIDs.append(id)
        }
      })
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
                navigate(to: page)
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
      .navigationSplitViewColumnWidth(min: 220, ideal: 235, max: 280)
      .searchable(text: $searchText, placement: .sidebar, prompt: "Search")
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
        ToolbarItemGroup(placement: .navigation) {
          ControlGroup {
            Button {
              guard let detailPage else { return }
              forwardDetailPage = detailPage
              self.detailPage = nil
            } label: {
              Label("Back", systemImage: "chevron.left").labelStyle(.iconOnly)
            }
            .disabled(detailPage == nil)
            Button {
              guard let page = forwardDetailPage else { return }
              detailPage = page
              forwardDetailPage = nil
            } label: {
              Label("Forward", systemImage: "chevron.right").labelStyle(.iconOnly)
            }
            .disabled(forwardDetailPage == nil)
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
      if detailPage?.category != selection {
        detailPage = nil
        forwardDetailPage = nil
      }
      updateWindowTitle()
    }
    .onChange(of: detailPage) { _, _ in
      updateWindowTitle()
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) {
      _ in refreshPermissionState()
    }
    .onAppear { updateWindowTitle() }
    .onReceive(NotificationCenter.default.publisher(for: .isletSettingsDestination)) {
      notification in
      guard let rawValue = notification.object as? String,
        let destination = SettingsDestination(rawValue: rawValue)
      else { return }
      selection = SettingsCategory(destination: destination)
      detailPage = Self.defaultDetailPage(for: destination)
      forwardDetailPage = nil
      searchText = ""
    }
    .confirmationDialog(
      "Restore appearance and interaction defaults?", isPresented: $confirmingRestore,
      titleVisibility: .visible
    ) {
      Button("Restore Appearance & Interaction", role: .destructive) {
        restoreInterfaceDefaults()
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Resets push-through, collapse timing, haptics, HUD style, player priority, activity order, and metric presentation. Enabled activities, permissions, paired machines, and activity data are kept.")
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
        pages: [
          .activityOrder, .calendarReminders, .nowPlaying, .continuity, .systemMetrics,
          .clipboard, .systemHUD,
        ])
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
    case .continuity: continuityForm
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
    case .pulse: .pulse
    case .advanced: .diagnostics
    }
  }

  private func settingsLanding(
    _ introduction: String, pages: [SettingsDetailPage]
  ) -> some View {
    ScrollView {
      VStack(spacing: 20) {
        VStack(spacing: 10) {
          Image(systemName: (selection ?? .general).icon)
            .font(.system(size: 32, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: 62, height: 62)
            .background(
              RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.accentColor.gradient)
                .shadow(color: .black.opacity(0.18), radius: 4, y: 2))
          Text((selection ?? .general).rawValue)
            .font(.title.bold())
          Text(introduction)
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 570)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .padding(.horizontal, 28)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 16))

        VStack(spacing: 0) {
          ForEach(Array(pages.enumerated()), id: \.element.id) { index, page in
            SettingsNavigationLink(page: page) { navigate(to: page) }
            if index < pages.count - 1 {
              Divider().padding(.leading, 62)
            }
          }
        }
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 16))
        .clipShape(RoundedRectangle(cornerRadius: 16))
      }
      .padding(24)
      .frame(maxWidth: 760)
      .frame(maxWidth: .infinity, alignment: .top)
    }
    .background(Color(nsColor: .windowBackgroundColor))
  }

  private var startupDisplaysForm: some View {
    Form {
      Section("Startup") {
        Toggle("Launch Islet at login", isOn: $launchAtLogin)
        LabeledContent("Login item status") {
          Text(launchAtLoginStatus.summary).foregroundStyle(.secondary)
        }
        if let error = launchAtLoginStatus.error {
          Label(error, systemImage: "exclamationmark.triangle.fill")
            .font(.caption).foregroundStyle(.orange)
        }
      }
      Section("Displays") {
        Toggle("Show Islet on every display", isOn: $showOnAllDisplays)
        Toggle("Hide Islet while an app is fullscreen", isOn: $hideInFullscreen)
        Text("With multiple displays off, Islet follows the display that owns the active notch panel.")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
  }

  private var activityOrderForm: some View {
    Form {
      Section("Activity lineup") {
        Text("Drag to set priority. Shared Home services keep running when hidden. Turning Clipboard or Pulse off also stops its data service.")
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
      Section("Home services") {
        Toggle("Reminders", isOn: $remindersEnabled)
        Text("Reminders appear on Home rather than as a separate tab, so their switch lives here instead of the lineup.")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
  }

  private var eventsForm: some View {
    Form {
      Section {
        Text("Event sources show a brief animation when something changes. Hardware and system observers stop when disabled.")
          .foregroundStyle(.secondary)
      }
      Section("Activity notifications") {
        ForEach(["battery", "timer", "nowPlaying"], id: \.self) { id in
          Toggle(isOn: eventSourceEnabled(id)) {
            Label(SourceCatalog.name(for: id), systemImage: SourceCatalog.icon(for: id))
          }
        }
        Text("These switches suppress notifications emitted by an already-running activity; they do not stop that activity.")
          .font(.caption).foregroundStyle(.secondary)
      }
      ForEach(SystemEventTier.allCases, id: \.rawValue) { tier in
        let ids = SourceCatalog.ids(in: tier).filter {
          !["battery", "timer", "nowPlaying"].contains($0)
        }
        if !ids.isEmpty {
          Section(tier.label) {
            if tier == .heuristic {
              Text("These inferred notifications start off because they can be late or ambiguous. An AirDrop arrival is detected after transfer, and a tunnel may be iCloud Private Relay.")
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
              Text("20 pt").font(.caption).foregroundStyle(.secondary)
              Slider(value: pushDistanceSliderBinding, in: 0...1)
                .frame(minWidth: 220)
              Text("1,000 pt").font(.caption).foregroundStyle(.secondary)
            }
          }
          Text("Current push distance: \(Int(barrierPushDistance)) points. The slider gives finer control at short distances, where small changes matter most.")
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
                  Haptics.perform(.generic)
                }
              })
              .frame(minWidth: 220)
            Button("Test") { Haptics.performDelayedTest() }
              .disabled(hapticStrengthBinding.wrappedValue == .off)
            Text("Strong").font(.caption).foregroundStyle(.secondary)
          }
        }
        Text("Current strength: \(hapticStrengthBinding.wrappedValue.title)")
          .font(.caption).foregroundStyle(.secondary)
        Text("Push-through plays one contact pulse and one final snap—no middle pulse. The final snap is always one strongest single pulse, never a double pulse.")
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
            ForEach(priorityList, id: \.self) { bundleID in
              HStack(spacing: 10) {
                if let icon = nowPlaying.applicationIcon(for: bundleID) {
                  Image(nsImage: icon).resizable().frame(width: 24, height: 24)
                } else {
                  Image(systemName: "app.dashed").frame(width: 24, height: 24)
                }
                VStack(alignment: .leading, spacing: 1) {
                  Text(nowPlaying.applicationName(for: bundleID))
                  Text(bundleID).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
              }
            }
              .onMove { priorityList.move(fromOffsets: $0, toOffset: $1) }
              .onDelete { priorityList.remove(atOffsets: $0) }
          }
          .frame(minHeight: 130, idealHeight: 180)
          if !unprioritizedDetectedPlayers.isEmpty {
            Menu("Add Detected Player") {
              ForEach(unprioritizedDetectedPlayers, id: \.self) { bundleID in
                Button(nowPlaying.applicationName(for: bundleID)) { addPlayer(bundleID) }
              }
            }
          }
          DisclosureGroup("Add Other App by Bundle Identifier") {
            HStack {
              TextField("com.example.player", text: $newBundleID)
              Button("Add") { addPlayer(newBundleID) }
                .disabled(
                  newBundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || priorityList.contains(
                      newBundleID.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
          }
        }
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
        Text("Activity Lineup controls the Calendar tab. EventKit monitoring stays on because Calendar also supplies the Home agenda.")
          .font(.caption).foregroundStyle(.secondary)
        if calendarEnabled {
          Picker("Upcoming-event countdown", selection: $calendarLeadMinutes) {
            Text("Off").tag(0)
            Text("5 minutes before").tag(5)
            Text("10 minutes before").tag(10)
            Text("15 minutes before").tag(15)
            Text("30 minutes before").tag(30)
            Text("1 hour before").tag(60)
          }
          if calendar.authorization.canRead, !calendar.availableCalendars.isEmpty {
            DisclosureGroup("Calendars shown in Islet") {
              ForEach(calendar.availableCalendars) { choice in
                Toggle(choice.title, isOn: calendarEnabledBinding(choice.id))
              }
            }
          }
        }
        Button("Manage Calendar permission…") {
          navigate(to: .permissions)
        }
      }
      Section("Reminders") {
        Toggle("Show incomplete reminders on Home", isOn: $remindersEnabled)
        Text("Reminder monitoring stops when this is off. Permission can still be reviewed separately.")
          .font(.caption).foregroundStyle(.secondary)
        Button("Manage Reminders permission…") {
          navigate(to: .permissions)
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
          Picker("Presentation", selection: metricPresetBinding) {
            ForEach(SystemMetricPreset.allCases) { preset in
              Text(preset.rawValue).tag(preset)
            }
          }
          DisclosureGroup("Customize individual metrics") {
            ForEach(SystemMetricKind.allCases, id: \.self) { kind in
              Picker(kind.displayName, selection: styleBinding(kind)) {
                ForEach(
                  kind == .thermal
                    ? [MetricDisplayStyle.number, .numberAndBar, .combined]
                    : MetricDisplayStyle.allCases,
                  id: \.self
                ) { style in
                  Text(style.displayName).tag(style)
                }
              }
            }
          }
          Text("Balanced combines a current value with useful recent context. Thermal offers only presentations that match its state-based data.")
            .font(.caption).foregroundStyle(.secondary)
        }
      }
    }
    .formStyle(.grouped)
  }

  private var continuityForm: some View {
    Form {
      Section("iPhone Live Activities") {
        Toggle("Show iPhone Live Activities", isOn: $continuityEnabled)
        Text("Islet reads the Live Activity app identities that macOS already exposes through Control Centre. Activity contents remain on your iPhone.")
          .font(.caption).foregroundStyle(.secondary)
        if continuityEnabled {
          PermissionStatusRow(
            title: "Availability", icon: "iphone.gen3",
            status: continuityStatusText, color: continuityStatusColor)
          Text(continuity.availability.explanation)
            .font(.caption).foregroundStyle(.secondary)
          LabeledContent("Detected now") {
            Text("\(continuity.cards.count)").monospacedDigit().foregroundStyle(.secondary)
          }
          Toggle("Keep iPhone in the activity switcher when idle", isOn: $continuityAlwaysVisible)
          Toggle("Announce when a Live Activity starts or ends", isOn: $continuitySneaks)
          if continuity.availability == .needsAccessibility {
            HStack {
              Button("Request Accessibility access") { AccessibilityPermission.prompt() }
              Button("Open Accessibility Settings") { permissions.open(.accessibility) }
            }
          }
        }
      }
      Section("Limits") {
        Text("macOS shares which apps have Live Activities, but not the full phone-side content. Available detail therefore varies by app.")
          .font(.caption).foregroundStyle(.secondary)
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
        Text("Pause and Clear are available beside the history itself and in Quick Actions, where their effect is visible immediately.")
          .font(.caption).foregroundStyle(.secondary)
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
          HStack(spacing: 10) {
            HUDIconView(snapshot: .init(kind: .volume, level: 0.64, isMuted: false))
            HUDBarView(snapshot: .init(kind: .volume, level: 0.64, isMuted: false))
          }
          .padding(.horizontal, 16).padding(.vertical, 12)
          .background(.black, in: Capsule())
          .accessibilityLabel("HUD preview at 64 percent")
          HStack {
            Button("Test Volume") {
              hud.debugPresent(.init(kind: .volume, level: 0.64, isMuted: false))
            }
            Button("Test Brightness") {
              hud.debugPresent(.init(kind: .brightness, level: 0.42, isMuted: false))
            }
          }
          PermissionStatusRow(
            title: "Accessibility", icon: "accessibility",
            status: hud.eventTapStatus.summary,
            color: hud.eventTapStatus == .active ? .green : .orange)
          if !hud.accessibilityTrusted {
            Button("Review Accessibility permission…") {
              navigate(to: .permissions)
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
      Section("Screen recording") {
        Toggle("Hide Islet from screen recordings", isOn: $hideFromRecording)
        Text("This hides Islet's panels from capture; it does not change what enabled activities collect.")
          .font(.caption).foregroundStyle(.secondary)
      }
      Section("Calendar") {
        PermissionStatusRow(title: "Calendar access", icon: "calendar", status: eventStatusText, color: eventStatusColor)
        Text("Used to show today's agenda, countdowns and meeting links.").font(.caption).foregroundStyle(.secondary)
        permissionButtons(
          status: permissions.diagnostics.calendar, pane: .calendars,
          requestEnabled: calendarEnabled
        ) {
          Task {
            await calendar.recoverAccess()
            permissions.refresh()
          }
        }
      }
      Section("Reminders") {
        PermissionStatusRow(title: "Reminders access", icon: "checklist", status: reminderStatusText, color: reminderStatusColor)
        Text("Used to show and complete your incomplete reminders.").font(.caption).foregroundStyle(.secondary)
        permissionButtons(
          status: permissions.diagnostics.reminders, pane: .reminders,
          requestEnabled: remindersEnabled
        ) {
          Task {
            await reminders.requestAccess()
            permissions.refresh()
          }
        }
      }
      Section("Accessibility") {
        PermissionStatusRow(
          title: "Accessibility access", icon: "accessibility",
          status: permissions.diagnostics.accessibilityGranted ? "Allowed" : "Not allowed",
          color: permissions.diagnostics.accessibilityGranted ? .green : .red)
        Text("Used only when the media-key HUD or iPhone Live Activities feature is enabled.")
          .font(.caption).foregroundStyle(.secondary)
        HStack {
          if !permissions.diagnostics.accessibilityGranted {
            Button("Request access") { AccessibilityPermission.prompt() }
          }
          Button("Open Accessibility Settings") { permissions.open(.accessibility) }
        }
      }
      Section("Nearby devices and networks") {
        PermissionStatusRow(
          title: "Location for Wi-Fi names", icon: "location.fill",
          status: permissions.diagnostics.location.summary,
          color: platformPermissionColor(permissions.diagnostics.location))
        Text("Without location access, Wi-Fi notifications still work but omit the network name.")
          .font(.caption).foregroundStyle(.secondary)
        Button("Open Location Settings") { permissions.open(.location) }
        PermissionStatusRow(
          title: "Bluetooth devices", icon: "dot.radiowaves.right",
          status: permissions.diagnostics.bluetooth.summary,
          color: platformPermissionColor(permissions.diagnostics.bluetooth))
        Button("Open Bluetooth Privacy Settings") { permissions.open(.bluetooth) }
        PermissionStatusRow(
          title: "Local network", icon: "network", status: "Managed by macOS",
          color: .secondary)
        Text("Requested only when pairing a T3 Code machine on your local network. macOS does not expose a reliable read-only status for this permission.")
          .font(.caption).foregroundStyle(.secondary)
        Button("Open Local Network Settings") { permissions.open(.localNetwork) }
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
        Text("Pulse lets local scripts and tools publish bounded progress, alerts and actions. Connections are loopback-only and authenticated with a private token.")
          .font(.caption).foregroundStyle(.secondary)
        Text("Choose the temporary delivery profile from the Pulse menu or Quick Actions, close to where it takes effect.")
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
        LabeledContent("Energy policy") { Text(energyModeTitle).foregroundStyle(.secondary) }
        HStack {
          Button("Copy Diagnostics") { copyDiagnostics() }
          Button("Open Logs Folder") {
            NSWorkspace.shared.open(
              URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Logs"))
          }
        }
      }
      Section("Integration health") {
        PermissionStatusRow(
          title: "Media adapter", icon: "music.note", status: nowPlaying.adapterStatus,
          color: nowPlaying.adapterStatus.localizedCaseInsensitiveContains("error")
            ? .orange : .green)
        PermissionStatusRow(
          title: "T3 Code credentials", icon: "key.fill",
          status: t3Code.lastCredentialError ?? "Available",
          color: t3Code.lastCredentialError == nil ? .green : .orange)
        PermissionStatusRow(
          title: "Pulse", icon: "waveform.path.ecg",
          status: pulseServer.lastError ?? (pulseServer.isRunning ? "Listening" : "Stopped"),
          color: pulseServer.lastError == nil ? (pulseServer.isRunning ? .green : .secondary) : .red)
        PermissionStatusRow(
          title: "Media-key HUD", icon: "keyboard",
          status: hud.lastControlFailure ?? hud.eventTapStatus.summary,
          color: hud.lastControlFailure == nil
            ? (hud.eventTapStatus == .active ? .green : .secondary) : .orange)
      }
    }
    .formStyle(.grouped)
  }

  private var resetForm: some View {
    Form {
      Section("Appearance and interaction") {
        Button("Restore Appearance & Interaction…", role: .destructive) {
          confirmingRestore = true
        }
        Text("Resets push-through, collapse timing, haptics, HUD style, player priority, activity order, and metric presentation. Enabled activities, permissions, paired machines, and activity data are kept.")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
  }

  @ViewBuilder private func permissionButtons(
    status: EventKitPermissionState, pane: SystemSettingsPrivacyPane,
    requestEnabled: Bool = true,
    request: @escaping () -> Void
  ) -> some View {
    HStack {
      if status == .notDetermined {
        Button("Request access", action: request).disabled(!requestEnabled)
      }
      if status != .fullAccess { Button("Open System Settings") { permissions.open(pane) } }
    }
  }

  private var eventStatusText: String { permissions.diagnostics.calendar.summary }
  private var reminderStatusText: String { permissions.diagnostics.reminders.summary }
  private var eventStatusColor: Color { authorizationColor(permissions.diagnostics.calendar) }
  private var reminderStatusColor: Color { authorizationColor(permissions.diagnostics.reminders) }

  private var continuityStatusText: String {
    switch continuity.availability {
    case .needsAccessibility: "Needs Accessibility"
    case .unsupported: "Unavailable"
    case .systemDisabled: "Off in macOS"
    case .waiting: "Waiting"
    case .active: "Active"
    }
  }

  private var continuityStatusColor: Color {
    switch continuity.availability {
    case .active: .green
    case .waiting: .secondary
    case .needsAccessibility, .systemDisabled: .orange
    case .unsupported: .red
    }
  }

  private func authorizationColor(_ status: EventKitPermissionState) -> Color {
    switch status {
    case .fullAccess: .green
    case .notDetermined, .writeOnly: .orange
    case .restricted, .denied: .red
    case .unknown: .secondary
    }
  }

  private func platformPermissionColor(_ status: PlatformPermissionState) -> Color {
    switch status {
    case .granted: .green
    case .notDetermined: .orange
    case .denied, .restricted: .red
    case .unavailable: .secondary
    }
  }

  private func addPlayer(_ rawBundleID: String) {
    let bundleID = rawBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !bundleID.isEmpty, !priorityList.contains(bundleID) else { return }
    priorityList.append(bundleID)
    newBundleID = ""
  }

  private func refreshPermissionState() {
    hud.refreshPermissionStatus()
    permissions.refresh()
    launchAtLoginStatus.refresh()
  }

  private func navigate(to page: SettingsDetailPage) {
    selection = page.category
    detailPage = page
    forwardDetailPage = nil
  }

  private func updateWindowTitle() {
    SettingsOpener.setTitle(detailPage?.title ?? (selection ?? .general).rawValue)
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

  private var energyModeTitle: String {
    switch energyMode {
    case .automatic: "Automatic"
    case .lowEnergy: "Low Energy"
    case .live: "Live"
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

private struct SettingsNavigationLink: View {
  let page: SettingsDetailPage
  let action: () -> Void
  @State private var isHovering = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 13) {
        Image(systemName: page.icon)
          .font(.system(size: 17, weight: .semibold))
          .foregroundStyle(.white)
          .frame(width: 34, height: 34)
          .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
              .fill(Color.accentColor.gradient)
              .shadow(color: .black.opacity(0.14), radius: 2, y: 1))
        VStack(alignment: .leading, spacing: 2) {
          Text(page.title).font(.body.weight(.medium)).foregroundStyle(.primary)
          Text(page.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        Spacer(minLength: 12)
        Image(systemName: "chevron.right")
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(isHovering ? Color.accentColor : .secondary)
      }
      .padding(.horizontal, 14)
      .frame(minHeight: 58)
      .contentShape(Rectangle())
      .background(isHovering ? Color.accentColor.opacity(0.09) : .clear)
    }
    .buttonStyle(SettingsNavigationButtonStyle())
    .onHover { isHovering = $0 }
    .accessibilityHint("Opens \(page.title) settings")
  }
}

private struct SettingsNavigationButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .background(configuration.isPressed ? Color.accentColor.opacity(0.16) : .clear)
      .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
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
