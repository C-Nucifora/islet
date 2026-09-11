import AppKit
import Defaults
import SwiftUI
import UniformTypeIdentifiers

enum SettingsCategory: String, CaseIterable, Identifiable {
  case general = "General"
  case activities = "Activities"
  case notifications = "Notifications"
  case integrations = "Integrations"
  case privacy = "Privacy"
  case advanced = "Advanced"

  var id: Self { self }

  var title: String {
    switch self {
    case .general: String(localized: "General")
    case .activities: String(localized: "Activities")
    case .notifications: String(localized: "Notifications")
    case .integrations: String(localized: "Integrations")
    case .privacy: String(localized: "Privacy")
    case .advanced: String(localized: "Advanced")
    }
  }

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
    case .general:
      "launch login displays fullscreen recording hover click haptics energy keep awake sleep battery updates version channel"
    case .activities:
      "tabs order battery calendar reminders clipboard ports audio hud timer shelf system media iphone continuity live activities process spike attribution threshold CPU memory disk network Activity Monitor"
    case .notifications:
      "events usb wifi bluetooth airdrop vpn focus screenshot sleep power volume display"
    case .integrations:
      "t3 code agents remote media spotify music pulse api cli providers history rules focus shortcuts"
    case .privacy: "calendar reminders accessibility privacy grant denied restricted clipboard"
    case .advanced: "diagnostics identity version defaults reset about github contributors"
    }
  }
}

private enum SystemMetricPreset: String, CaseIterable, Identifiable {
  case compact = "Compact"
  case balanced = "Balanced"
  case detailed = "Detailed"
  case custom = "Custom"

  var id: Self { self }

  var title: String {
    switch self {
    case .compact: String(localized: "Compact")
    case .balanced: String(localized: "Balanced")
    case .detailed: String(localized: "Detailed")
    case .custom: String(localized: "Custom")
    }
  }
}

enum SettingsDetailPage: String, CaseIterable, Identifiable {
  case startupDisplays
  case updates
  case appearance
  case interaction
  case energy
  case contextRules
  case batteryWarnings
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
  case settingsTransfer
  case reset

  var id: Self { self }

  var title: String {
    switch self {
    case .startupDisplays: String(localized: "Startup and displays")
    case .updates: String(localized: "Updates")
    case .appearance: String(localized: "Appearance")
    case .interaction: String(localized: "Interaction")
    case .energy: String(localized: "Energy")
    case .contextRules: String(localized: "Context rules")
    case .batteryWarnings: String(localized: "Battery warnings")
    case .activityOrder: String(localized: "Activity order")
    case .calendarReminders: String(localized: "Calendar and reminders")
    case .nowPlaying: String(localized: "Now playing")
    case .continuity: String(localized: "iPhone Live Activities")
    case .systemMetrics: String(localized: "System metrics")
    case .clipboard: String(localized: "Clipboard")
    case .systemHUD: String(localized: "System HUD")
    case .eventSources: String(localized: "Event sources")
    case .t3Code: String(localized: "T3 Code")
    case .pulse: String(localized: "Pulse providers")
    case .permissions: String(localized: "App permissions")
    case .diagnostics: String(localized: "Diagnostics")
    case .settingsTransfer: String(localized: "Import and export")
    case .reset: String(localized: "Reset")
    }
  }

  var subtitle: String {
    switch self {
    case .startupDisplays: String(localized: "Login item and display placement")
    case .updates: String(localized: "Signed automatic and manual updates")
    case .appearance: String(localized: "Choose the colours used across Islet")
    case .interaction: String(localized: "How the notch opens and closes")
    case .energy: String(localized: "Refresh rates, sleep and battery protection")
    case .contextRules: String(localized: "Adapt Islet to your current context")
    case .batteryWarnings: String(localized: "Drain, charger and peripheral alerts")
    case .activityOrder: String(localized: "Show, hide and reorder activities")
    case .calendarReminders: String(localized: "Agenda, countdown and reminder options")
    case .nowPlaying: String(localized: "Choose which active player opens first")
    case .continuity: String(localized: "App names from iPhone Live Activities")
    case .systemMetrics: String(localized: "Choose metrics and chart styles")
    case .clipboard: String(localized: "History, storage and filtering")
    case .systemHUD: String(localized: "Volume and brightness controls")
    case .eventSources: String(localized: "Brief alerts for system changes")
    case .t3Code: String(localized: "Pair T3 Code machines")
    case .pulse: String(localized: "Local API, providers and credentials")
    case .permissions: String(localized: "macOS access used by each feature")
    case .diagnostics: String(localized: "App identity and integration status")
    case .settingsTransfer: String(localized: "Back up or move portable preferences")
    case .reset: String(localized: "Restore interface defaults")
    }
  }

  var icon: String {
    switch self {
    case .startupDisplays: "macwindow.on.rectangle"
    case .updates: "arrow.triangle.2.circlepath.circle"
    case .appearance: "paintpalette"
    case .interaction: "cursorarrow.motionlines"
    case .energy: "leaf"
    case .contextRules: "switch.2"
    case .batteryWarnings: "battery.100percent.bolt"
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
    case .settingsTransfer: "arrow.up.arrow.down.document"
    case .reset: "arrow.counterclockwise"
    }
  }

  var category: SettingsCategory {
    switch self {
    case .startupDisplays, .updates, .appearance, .interaction, .energy, .contextRules: .general
    case .activityOrder, .batteryWarnings, .calendarReminders, .nowPlaying, .continuity,
      .systemMetrics, .clipboard, .systemHUD:
      .activities
    case .eventSources: .notifications
    case .t3Code, .pulse: .integrations
    case .permissions: .privacy
    case .diagnostics, .settingsTransfer, .reset: .advanced
    }
  }

  var searchableContent: [String] {
    let pageContent = [title, subtitle]
    return switch self {
    case .startupDisplays:
      pageContent + [
        "Startup", "Launch Islet at login", "Login item status", "Run setup again",
        "Displays", "Show Islet on every display", "Preferred display",
        "Hide Islet while an app is fullscreen",
        "screen multiple monitors external dock clamshell closed lid reconnect pointer active app quick actions shelf",
      ]
    case .updates:
      pageContent + [
        "Updates", "Current version", "Channel", "Stable", "Last check", "Status",
        "Automatically check for updates", "Check for Updates", "release notes", "download",
        "restart install Sparkle signed feed package verification",
      ]
    case .appearance:
      pageContent + [
        "Theme", "Classic", "Mono", "Ocean", "Violet", "Sunset", "Forest", "Catppuccin",
        "icons text controls buttons selected tabs battery graph colour color palette tint",
      ]
    case .interaction:
      pageContent + [
        "Open the island", "Expand", "Push through", "Click to pin", "Push distance",
        "Collapse after", "Haptic feedback", "Strength", "Test haptics",
        "Command palette shortcut", "Record shortcut", "Reset shortcut", "Disable shortcut",
        "global hotkey keyboard quick actions hover squeeze snap top edge notch",
      ]
    case .energy:
      pageContent + [
        "Energy use", "Mode", "Automatic", "Low Energy", "Live", "Low Power Mode",
        "Keep awake", "Allow the display to sleep", "Keep awake with lid closed",
        "Power Protect", "Stop on low battery", "Indefinitely",
        "prevent idle system sleep display sleep assertions closed clamshell session timer",
        "refresh rates hidden activity remote T3 polling performance battery",
      ]
    case .contextRules:
      pageContent + [
        "Context rules", "Focus mode", "power source", "AC battery", "Low Power Mode",
        "frontmost app", "fullscreen presentation", "time range", "active display",
        "Wi-Fi network", "Pulse delivery", "activity visibility", "manual override",
        "precedence active rule match reason expiry local deterministic",
      ]
    case .batteryWarnings:
      pageContent + [
        "Battery warnings", "Unusual battery drain", "Learned rolling baseline",
        "Reset learned battery data", "Charger capacity", "Charger cannot meet demand",
        "Slow charging", "Temporary workload spike", "Peripheral early warnings",
        "Mouse Trackpad Keyboard Pencil Other devices", "threshold off critical 10 percent",
      ]
    case .activityOrder:
      pageContent + [
        "Activities", "Drag to reorder", "Home", "Reminders",
        "show hide enable disable stop tabs priority activity switcher",
      ] + ActivityCatalog.orderable.flatMap { [$0.id, $0.name] }
    case .calendarReminders:
      pageContent + [
        "Calendar", "Activity", "Upcoming-event countdown", "Calendars shown in Islet",
        "Manage Calendar permission", "Reminders", "Show incomplete reminders on Home",
        "Manage Reminders permission", "three day agenda add event title time location conference",
        "meetings due snooze complete meeting links",
      ]
    case .nowPlaying:
      pageContent + [
        "Primary player", "Whatever is playing", "My order", "Add Detected Player",
        "Add Other App by Bundle Identifier", "Audio-only sources", "Include", "Exclude",
        "CoreAudio", "music Spotify Apple Music media priority",
      ]
    case .continuity:
      pageContent + [
        "iPhone Live Activities", "Show iPhone Live Activities", "Availability", "Detected now",
        "Keep iPhone in the activity switcher when idle",
        "Announce when a Live Activity starts or ends", "Request Accessibility access",
        "Open Accessibility Settings", "Retry Continuity", "Control Centre remote app names",
      ]
    case .systemMetrics:
      pageContent + [
        "Visibility", "System activity", "Always show System in the activity switcher",
        "Automatic presence", "High CPU", "Thermal pressure", "Memory pressure",
        "Low disk space", "Heavy disk activity", "High network traffic",
        "Metric presentation", "Presentation", "Compact", "Balanced", "Detailed", "Custom",
        "Customize individual metrics", "Process attribution", "Identify processes after a spike",
        "CPU Memory Disk Network threshold Activity Monitor one second estimates unavailable",
        "current value recent graph state labels",
      ] + SystemMetricKind.allCases.map(\.displayName)
        + MetricDisplayStyle.allCases.map(\.displayName)
    case .clipboard:
      pageContent + [
        "Clipboard history", "Activity", "Pause and Clear", "Quick Actions", "Privacy pause",
        "5 minutes", "30 minutes", "next login", "excluded applications", "Focus modes",
        "history stays in memory", "concealed items credential formats sensitive text secrets copy",
      ]
    case .systemHUD:
      pageContent + [
        "Media-key HUD", "Replace the volume and brightness HUD", "Style", "Bar", "Gauge",
        "Test Volume", "Test Brightness", "Accessibility", "Review Accessibility permission",
        "active device display media keys",
      ]
    case .eventSources:
      pageContent + [
        "Activity notifications", "brief alerts system changes", "enable disable source observing",
      ] + SourceCatalog.all.flatMap { [$0.id, $0.name] }
        + SystemEventTier.allCases.map(\.label)
    case .t3Code:
      pageContent + [
        "T3 Code agents", "Monitor T3 Code", "Paste a T3 Code pairing link", "Add machine",
        "Allow plain HTTP for this pairing", "Reconnect now", "Remove machine", "This Mac",
        "T3 Connect", "Link T3 Connect account", "Link again", "Sign out", "Retry cleanup",
        "remote paired machines pairing credentials Keychain HTTPS Tailscale credential error",
      ]
    case .pulse:
      pageContent + [
        "Pulse providers", "Local activity API", "Pulse items", "Authentication",
        "Mark silent work stale after provider timeout",
        "provider credentials permissions rotation revocation age last use", "Quick Actions",
        "Reveal credential folder", "Dismiss visible",
        "Rotate provider credential", "Provider examples", "Allow Mute Revoke Policy",
        "Trusted web destinations host origin allowlist loopback revoke",
        "Other sources seen this session", "Pulse history", "Show session history",
        "Keep history after quitting", "Retention period", "Maximum entries", "Export history",
        "History filter", "All Accepted Filtered Rejected", "Clear history",
        "source result priority state operation time local scripts CLI access token delivery privacy",
      ]
    case .permissions:
      pageContent + [
        "Screen recording", "Hide Islet from screen recordings", "Request capture exclusion",
        "Capture exclusion", "Unsupported", "Unverified",
        "screenshots recordings shared screens ScreenCaptureKit QuickTime conferencing",
        "Calendar access",
        "Reminders access", "Accessibility access", "Request access", "Open System Settings",
        "Nearby devices and networks", "Location for Wi-Fi names", "Open Location Settings",
        "Bluetooth devices", "Open Bluetooth Privacy Settings", "Local network",
        "Open Local Network Settings", "Refresh permission status",
        "agenda countdowns meeting links media keys HUD iPhone Live Activities privacy diagnostics",
      ]
    case .diagnostics:
      pageContent + [
        "Diagnostics", "Bundle identifier", "Version", "Energy mode", "Copy diagnostics",
        "Open logs folder", "Restart Islet", "Quit Islet", "Integration health", "Media adapter",
        "T3 Code credentials", "Pulse", "Media-key HUD", "Continuity reader",
        "Last successful read", "Retry Continuity",
        "Focus event source", "Focus last parsed", "Focus schema", "Retry Focus source",
        "USB reader", "Retry USB enumeration",
        "signing support status", "About",
        "GitHub contributors C-Nucifora nedlane",
      ]
    case .settingsTransfer:
      pageContent + [
        "Settings backup", "Export settings", "Import settings", "Preview changes",
        "portable preferences JSON backup move another Mac privacy secrets credentials permissions",
      ]
    case .reset:
      pageContent + [
        "Appearance and interaction", "Restore appearance and interaction", "Reset defaults",
        "theme colours notch haptics HUD style player order activity order metric styles layout presentation",
      ]
    }
  }

  var paletteControls: [String] {
    switch self {
    case .startupDisplays:
      [
        "Launch Islet at login", "Run setup again", "Show Islet on every display",
        "Hide Islet while an app is fullscreen",
      ]
    case .updates:
      ["Automatically check for updates", "Check for Updates"]
    case .appearance:
      ["Choose theme", "Use coloured battery graph", "Use monochrome battery graph"]
    case .interaction:
      [
        "Choose how to open the island", "Set push distance", "Set collapse delay",
        "Configure command palette shortcut", "Toggle haptic feedback", "Test haptics",
      ]
    case .energy:
      ["Choose energy mode", "Follow macOS Low Power Mode", "Use Low Energy mode", "Use Live mode"]
    case .contextRules:
      [
        "Create context rule", "Edit context rule", "Reorder context rules",
        "Set a temporary context override",
      ]
    case .batteryWarnings:
      [
        "Toggle unusual battery drain warnings", "Toggle charger capacity warnings",
        "Set peripheral battery warning thresholds", "Reset learned battery data",
      ]
    case .activityOrder:
      ["Show, hide, or reorder activities"]
        + ActivityCatalog.orderable.map { "Configure \($0.name) activity" }
    case .calendarReminders:
      [
        "Show Calendar activity", "Set upcoming-event countdown", "Choose calendars",
        "Show reminders on Home", "Manage Calendar permission", "Manage Reminders permission",
      ]
    case .nowPlaying:
      ["Choose primary player", "Add detected player", "Add player by bundle identifier"]
    case .continuity:
      [
        "Show iPhone Live Activities", "Keep iPhone activity visible when idle",
        "Announce iPhone Live Activity changes", "Request Accessibility access",
      ]
    case .systemMetrics:
      ["Always show System activity", "Choose metric presentation", "Customize individual metrics"]
        + SystemMetricKind.allCases.map { "Configure \($0.displayName) metric" }
    case .clipboard:
      ["Pause clipboard history", "Clear clipboard history", "Open clipboard Quick Actions"]
    case .systemHUD:
      [
        "Replace volume and brightness HUD", "Choose HUD style", "Test Volume", "Test Brightness",
        "Review Accessibility permission",
      ]
    case .eventSources:
      ["Configure activity notifications"]
        + SourceCatalog.all.map { "Configure \($0.name) notifications" }
    case .t3Code:
      [
        "Monitor T3 Code", "Add T3 Code machine", "Paste T3 Code pairing link", "Reconnect T3 Code",
        "Remove T3 Code machine",
      ]
    case .pulse:
      [
        "Open Pulse Quick Actions", "Reveal Pulse token folder", "Dismiss visible Pulse items",
        "Rotate Pulse provider token", "Configure Pulse providers", "Configure Pulse source policy",
        "Show Pulse history", "Clear Pulse history",
      ]
    case .permissions:
      [
        "Hide Islet from screen recordings", "Request screen capture exclusion",
        "Manage Calendar access", "Manage Reminders access", "Manage Accessibility access",
        "Manage Location access for Wi-Fi names", "Manage Bluetooth access",
        "Manage Local Network access",
        "Refresh permission status",
      ]
    case .diagnostics:
      [
        "Copy diagnostics", "Open logs folder", "Restart Islet", "Quit Islet", "Retry Focus source",
        "View integration health",
      ]
    case .settingsTransfer:
      ["Export settings", "Import settings"]
    case .reset:
      ["Restore appearance and interaction defaults"]
    }
  }

  func matchesSearch(_ query: String) -> Bool {
    SettingsSearch.matches(query, in: searchableContent)
  }
}

enum SettingsSearch {
  static func matches(_ query: String, in content: [String]) -> Bool {
    let queryTokens = words(in: query)
    guard !queryTokens.isEmpty else { return true }

    let searchableText = content.joined(separator: " ")
    let searchableWords = words(in: searchableText).joined(separator: " ")
    let compactSearchableText = searchableText.unicodeScalars
      .filter { CharacterSet.alphanumerics.contains($0) }
      .map(String.init)
      .joined()
      .lowercased()

    return queryTokens.allSatisfy {
      searchableWords.contains($0) || compactSearchableText.contains($0)
    }
  }

  static func words(in text: String) -> [String] {
    text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
      .lowercased()
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { !$0.isEmpty }
  }

  static func compact(_ text: String) -> String {
    text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
      .unicodeScalars
      .filter { CharacterSet.alphanumerics.contains($0) }
      .map(String.init)
      .joined()
      .lowercased()
  }
}

private enum PulseHistoryFilter: String, CaseIterable, Identifiable {
  case all = "All"
  case accepted = "Accepted"
  case filtered = "Filtered"
  case rejected = "Rejected"

  var id: Self { self }

  var title: String {
    switch self {
    case .all: String(localized: "All")
    case .accepted: String(localized: "Accepted")
    case .filtered: String(localized: "Filtered")
    case .rejected: String(localized: "Rejected")
    }
  }

  func includes(_ entry: PulseHistoryEntry) -> Bool {
    switch self {
    case .all: true
    case .accepted:
      [.shown, .updated, .ended, .dismissed, .expired, .stale, .kept].contains(entry.result)
    case .filtered: [.suppressed, .evicted].contains(entry.result)
    case .rejected: entry.result == .rejected
    }
  }
}

private struct SettingsTransferNotice: Identifiable {
  let id = UUID()
  let title: String
  let message: String
}

struct SettingsView: View {
  @Environment(\.colorScheme) private var colorScheme

  @ObservedObject private var calendar = AppState.calendar
  @ObservedObject private var reminders = RemindersProvider.shared
  @ObservedObject private var pulse = PulseCenter.shared
  @ObservedObject private var pulseServer = PulseServer.shared
  @ObservedObject private var pulseCredentials = PulseServer.shared.credentialStore
  @ObservedObject private var pulseActionTrust = PulseServer.shared.actionTrustStore
  @ObservedObject private var permissions = PermissionCenter.shared
  @ObservedObject private var hud = HUDController.shared
  @ObservedObject private var continuity = ContinuityMonitor.shared
  @ObservedObject private var nowPlaying = AppState.nowPlaying
  @ObservedObject private var t3Code = AppState.t3Code
  @ObservedObject private var focus = AppState.focus
  @ObservedObject private var clipboard = ClipboardModel.shared
  @ObservedObject private var battery = AppState.battery
  @ObservedObject private var launchAtLoginStatus = LaunchAtLoginStatus.shared
  @ObservedObject private var screenManager = ScreenManager.shared
  @ObservedObject private var eventSourcePreferences = EventSourcePreferences.shared
  @ObservedObject private var ports = PortMonitor.shared
  @ObservedObject private var keepAwake = KeepAwakeManager.shared
  @ObservedObject private var shortcutManager = GlobalShortcutManager.shared
  @ObservedObject private var updates = AppUpdateController.shared

  @Default(.appTheme) private var appTheme
  @Default(.batteryGraphStyle) private var batteryGraphStyle
  @Default(.interactionMode) private var mode
  @Default(.hoverCollapseTimeout) private var collapseTimeout
  @Default(.hapticsEnabled) private var haptics
  @Default(.hapticStrength) private var hapticStrength
  @Default(.barrierPushDistance) private var barrierPushDistance
  @Default(.hideFromScreenRecording) private var hideFromRecording
  @Default(.mediaSourceMode) private var sourceMode
  @Default(.mediaPriorityList) private var priorityList
  @Default(.excludedAudioOnlySourceBundleIdentifiers) private var excludedAudioOnlySourceBundleIDs
  @Default(.unusualBatteryDrainWarnings) private var unusualBatteryDrainWarnings
  @Default(.chargerCapacityWarnings) private var chargerCapacityWarnings
  @Default(.peripheralBatteryWarningThresholds) private var peripheralBatteryWarningThresholds
  @Default(.hudEnabled) private var hudEnabled
  @Default(.hudStyle) private var hudStyle
  @Default(.calendarEnabled) private var calendarEnabled
  @Default(.calendarLeadMinutes) private var calendarLeadMinutes
  @Default(.hiddenCalendarIDs) private var hiddenCalendarIDs
  @Default(.remindersEnabled) private var remindersEnabled
  @Default(.showOnAllDisplays) private var showOnAllDisplays
  @Default(.preferredDisplayID) private var preferredDisplayID
  @Default(.preferredDisplayName) private var preferredDisplayName
  @Default(.hideInFullscreen) private var hideInFullscreen
  @Default(.launchAtLogin) private var launchAtLogin
  @Default(.activityOrder) private var activityOrder
  @Default(.disabledActivities) private var disabledActivities
  @Default(.systemAlwaysVisible) private var systemAlwaysVisible
  @Default(.systemAutoPresentCPU) private var systemAutoPresentCPU
  @Default(.systemAutoPresentThermal) private var systemAutoPresentThermal
  @Default(.systemAutoPresentMemoryPressure) private var systemAutoPresentMemoryPressure
  @Default(.systemAutoPresentLowDiskSpace) private var systemAutoPresentLowDiskSpace
  @Default(.systemAutoPresentDiskThroughput) private var systemAutoPresentDiskThroughput
  @Default(.systemAutoPresentNetworkThroughput) private var systemAutoPresentNetworkThroughput
  @Default(.metricStyles) private var metricStyles
  @Default(.pulseStaleTimeout) private var pulseStaleTimeout
  @Default(.processAttributionEnabled) private var processAttributionEnabled
  @Default(.processCPUThreshold) private var processCPUThreshold
  @Default(.processMemoryThreshold) private var processMemoryThreshold
  @Default(.processDiskThresholdMBPerSecond) private var processDiskThreshold
  @Default(.processNetworkThresholdMBPerSecond) private var processNetworkThreshold
  @Default(.energyMode) private var energyMode
  @Default(.allowDisplaySleep) private var allowDisplaySleep
  @Default(.keepAwakeWithLidClosed) private var keepAwakeWithLidClosed
  @Default(.keepAwakeLowBatteryThreshold) private var keepAwakeLowBatteryThreshold
  @Default(.continuityAlwaysVisible) private var continuityAlwaysVisible
  @Default(.continuitySneaks) private var continuitySneaks
  @Default(.clipboardExcludedBundleIdentifiers) private var clipboardExcludedBundleIdentifiers
  @Default(.clipboardPausedFocusIdentifiers) private var clipboardPausedFocusIdentifiers
  @Default(.clipboardClearHistoryOnPause) private var clipboardClearHistoryOnPause
  @Default(.commandPaletteShortcut) private var commandPaletteShortcut
  @Default(.pulseHistoryPersistenceEnabled) private var pulseHistoryPersistenceEnabled
  @Default(.pulseHistoryRetentionDays) private var pulseHistoryRetentionDays
  @Default(.pulseHistoryMaximumEntries) private var pulseHistoryMaximumEntries

  @State private var selection: SettingsCategory?
  @State private var detailPage: SettingsDetailPage?
  @State private var forwardDetailPage: SettingsDetailPage?
  @State private var searchText = ""
  @State private var newBundleID = ""
  @State private var newClipboardBundleIdentifier = ""
  @State private var newClipboardFocusIdentifier = ""
  @State private var clipboardPrivacyError: String?
  @State private var confirmingRestore = false
  @State private var showingPulseCredentialEditor = false
  @State private var pulseCredentialResult: String?
  @State private var confirmingBatteryDataReset = false
  @State private var showPulseHistory = false
  @State private var pulseHistoryFilter: PulseHistoryFilter = .all
  @State private var settingsImportPreview: SettingsTransferPreview?
  @State private var settingsTransferNotice: SettingsTransferNotice?
  @State private var isRecordingShortcut = false
  @State private var shortcutValidationMessage: String?

  init(destination: SettingsDestination = .overview) {
    _selection = State(initialValue: SettingsCategory(destination: destination))
    _detailPage = State(initialValue: Self.defaultDetailPage(for: destination))
  }

  init(page: SettingsDetailPage) {
    _selection = State(initialValue: page.category)
    _detailPage = State(initialValue: page)
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
    return SettingsDetailPage.allCases.filter { $0.matchesSearch(query) }
  }

  private var filteredPulseHistory: [PulseHistoryEntry] {
    pulse.history.filter(pulseHistoryFilter.includes)
  }

  private var unprioritizedDetectedPlayers: [String] {
    nowPlaying.knownBundleIdentifiers.filter { !priorityList.contains($0) }
  }

  private func activityEnabled(_ id: String) -> Binding<Bool> {
    Binding(
      get: { ActivityEnablement.isEnabled(id, disabledActivities: disabledActivities) },
      set: { enabled in
        disabledActivities = ActivityEnablement.updating(
          disabledActivities, activityID: id, enabled: enabled)
      })
  }

  private func isActivityEnabled(_ id: String) -> Bool {
    ActivityEnablement.isEnabled(id, disabledActivities: disabledActivities)
  }

  private var hapticStrengthBinding: Binding<HapticStrength> {
    Binding(
      get: { haptics ? hapticStrength : .off },
      set: { value in
        hapticStrength = value == .off ? .medium : value
        haptics = value != .off
      })
  }

  private var automaticallyChecksForUpdatesBinding: Binding<Bool> {
    Binding(
      get: { updates.automaticallyChecksForUpdates },
      set: { updates.setAutomaticallyChecksForUpdates($0) })
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
            uniqueKeysWithValues: SystemMetricKind.allCases.map {
              ($0.rawValue, MetricDisplayStyle.number.rawValue)
            })
        case .balanced:
          metricStyles = [:]
        case .detailed:
          metricStyles = Dictionary(
            uniqueKeysWithValues: SystemMetricKind.allCases.map {
              ($0.rawValue, MetricDisplayStyle.combined.rawValue)
            })
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
      get: { eventSourcePreferences.isEnabled(id) },
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

  private func calendarChoiceLabel(_ choice: CalendarChoice) -> String {
    let duplicateCount = calendar.availableCalendars.filter { $0.title == choice.title }.count
    return duplicateCount > 1 ? "\(choice.title) · \(choice.sourceTitle)" : choice.title
  }

  private func sourcePolicyBinding(_ source: String) -> Binding<PulseSourcePolicy> {
    Binding(
      get: { pulse.policy(for: source) },
      set: { pulse.setPolicy($0, for: source) })
  }

  private var pulseHistoryPersistenceBinding: Binding<Bool> {
    Binding(
      get: { pulseHistoryPersistenceEnabled },
      set: { enabled in
        pulseHistoryPersistenceEnabled = enabled
        applyPulseHistoryConfiguration()
      })
  }

  private var pulseHistoryRetentionBinding: Binding<Int> {
    Binding(
      get: {
        PulseHistoryConfiguration.allowedRetentionDays.contains(pulseHistoryRetentionDays)
          ? pulseHistoryRetentionDays : PulseHistoryConfiguration.defaultRetentionDays
      },
      set: { days in
        pulseHistoryRetentionDays = days
        applyPulseHistoryConfiguration()
      })
  }

  private var pulseHistoryMaximumEntriesBinding: Binding<Int> {
    Binding(
      get: {
        PulseHistoryConfiguration.allowedEntryCounts.contains(pulseHistoryMaximumEntries)
          ? pulseHistoryMaximumEntries : PulseHistoryConfiguration.defaultMaximumEntries
      },
      set: { count in
        pulseHistoryMaximumEntries = count
        applyPulseHistoryConfiguration()
      })
  }

  var body: some View {
    NavigationSplitView {
      List(selection: $selection) {
        ForEach(filteredCategories) { category in
          Label(category.title, systemImage: category.icon).tag(category)
        }
        if !filteredDetailPages.isEmpty {
          Section("Settings") {
            ForEach(filteredDetailPages) { page in
              Button {
                selection = page.category
                navigate(to: page)
                searchText = ""
              } label: {
                Label {
                  VStack(alignment: .leading, spacing: 1) {
                    Text(page.title)
                    Text(page.subtitle).font(.caption).foregroundStyle(.secondary)
                  }
                } icon: {
                  Image(systemName: page.icon)
                }
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
      .navigationTitle(detailPage?.title ?? (selection ?? .general).title)
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
    .tint(appTheme.settingsAccentColor(for: colorScheme))
    .environment(\.appTheme, appTheme)
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
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
    {
      _ in refreshPermissionState()
    }
    .onAppear {
      updateWindowTitle()
      updates.refresh()
    }
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
    .onReceive(NotificationCenter.default.publisher(for: .isletSettingsPage)) { notification in
      guard let rawValue = notification.object as? String,
        let page = SettingsDetailPage(rawValue: rawValue)
      else { return }
      navigate(to: page)
      searchText = ""
    }
    .confirmationDialog(
      "Reset learned battery data?", isPresented: $confirmingBatteryDataReset,
      titleVisibility: .visible
    ) {
      Button("Reset learned battery data", role: .destructive) {
        battery.resetLearnedBatteryData()
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "Clears the local drain baseline, reported-capacity history and warning cooldowns. Islet will learn a new baseline from future battery use."
      )
    }
    .confirmationDialog(
      "Restore appearance and interaction defaults?", isPresented: $confirmingRestore,
      titleVisibility: .visible
    ) {
      Button("Restore appearance and interaction", role: .destructive) {
        restoreInterfaceDefaults()
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "Resets the theme, notch interaction, haptics, HUD style, player order, activity order and metric styles. It keeps enabled activities, permissions, paired machines and activity data."
      )
    }
    .sheet(isPresented: $showingPulseCredentialEditor) {
      PulseCredentialEditor { name, source, permissions in
        do {
          _ = try pulseServer.createProvider(
            name: name, source: source, permissions: permissions)
          showingPulseCredentialEditor = false
          NSWorkspace.shared.open(pulseCredentials.credentialDirectory)
        } catch {
          pulseCredentialResult = error.localizedDescription
        }
      }
    }
    .alert(
      "Pulse authentication",
      isPresented: Binding(
        get: { pulseCredentialResult != nil },
        set: { if !$0 { pulseCredentialResult = nil } })
    ) {
      Button("OK") { pulseCredentialResult = nil }
    } message: {
      Text(pulseCredentialResult ?? "")
    }
    .sheet(item: $settingsImportPreview) { preview in
      SettingsImportPreviewSheet(
        preview: preview,
        cancel: { settingsImportPreview = nil },
        apply: {
          SettingsTransfer.apply(preview) { SettingsTransferDefaults.apply($0) }
          settingsImportPreview = nil
          settingsTransferNotice = SettingsTransferNotice(
            title: String(localized: "Settings imported"),
            message: String(
              localized: "Applied \(preview.changes.count) setting.",
              comment: "Number of imported settings that were applied"))
        })
    }
    .alert(item: $settingsTransferNotice) { notice in
      Alert(
        title: Text(notice.title), message: Text(notice.message),
        dismissButton: .default(Text("OK")))
    }
  }

  @ViewBuilder private var categoryView: some View {
    switch selection ?? .general {
    case .general:
      settingsLanding(pages: [
        .startupDisplays, .updates, .appearance, .interaction, .energy, .contextRules,
      ])
    case .activities:
      settingsLanding(pages: [
        .activityOrder, .batteryWarnings, .calendarReminders, .nowPlaying, .continuity,
        .systemMetrics,
        .clipboard, .systemHUD,
      ])
    case .notifications:
      settingsLanding(pages: [.eventSources])
    case .integrations:
      settingsLanding(pages: [.t3Code, .pulse])
    case .privacy:
      settingsLanding(pages: [.permissions])
    case .advanced:
      settingsLanding(pages: [.diagnostics, .settingsTransfer, .reset])
    }
  }

  @ViewBuilder private func detailView(_ page: SettingsDetailPage) -> some View {
    switch page {
    case .startupDisplays: startupDisplaysForm
    case .updates: updatesForm
    case .appearance: appearanceForm
    case .interaction: interactionForm
    case .energy: energyForm
    case .contextRules: ContextRulesSettingsView()
    case .batteryWarnings: batteryWarningsForm
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
    case .settingsTransfer: settingsTransferForm
    case .reset: resetForm
    }
  }

  private static func defaultDetailPage(for destination: SettingsDestination) -> SettingsDetailPage?
  {
    switch destination {
    case .overview: nil
    case .activities: .activityOrder
    case .events: .eventSources
    case .appearance: .appearance
    case .permissions: .permissions
    case .integrations: nil
    case .pulse: .pulse
    case .advanced: .diagnostics
    }
  }

  private func settingsLanding(pages: [SettingsDetailPage]) -> some View {
    ScrollView {
      VStack(spacing: 0) {
        VStack(spacing: 0) {
          ForEach(Array(pages.enumerated()), id: \.element.id) { index, page in
            SettingsNavigationLink(page: page) { navigate(to: page) }
            if index < pages.count - 1 {
              Divider().padding(.leading, 62)
            }
          }
        }
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
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
        Button("Run setup again…") { OnboardingOpener.open() }
      }
      Section("Displays") {
        Toggle("Show Islet on every display", isOn: $showOnAllDisplays)
        if !showOnAllDisplays {
          Picker("Preferred display", selection: preferredDisplayBinding) {
            Text("Automatic").tag("")
            ForEach(screenManager.displayChoices) { display in
              Text(display.name).tag(display.id)
            }
            if !preferredDisplayID.isEmpty,
              !screenManager.displayChoices.contains(where: { $0.id == preferredDisplayID })
            {
              Text("\(unavailablePreferredDisplayName) (not connected)")
                .tag(preferredDisplayID)
            }
          }
          .accessibilityHint(
            "Chooses which display hosts Islet when it is not shown on every display")
        }
        Toggle("Hide Islet while an app is fullscreen", isOn: $hideInFullscreen)
        Text(
          "Automatic uses the built-in display, then the main display. A disconnected preference returns when that display reconnects."
        )
        .font(.caption).foregroundStyle(.secondary)
        if showOnAllDisplays {
          Text(
            "Show Islet and Open File Shelf target the display under the pointer, then the frontmost app's display, your preference, and the main display."
          )
          .font(.caption).foregroundStyle(.secondary)
        }
      }
    }
    .formStyle(.grouped)
  }

  private var preferredDisplayBinding: Binding<String> {
    Binding(
      get: { preferredDisplayID },
      set: { id in
        preferredDisplayID = id
        preferredDisplayName =
          screenManager.displayChoices.first(where: { $0.id == id })?.name ?? ""
      })
  }

  private var unavailablePreferredDisplayName: String {
    preferredDisplayName.isEmpty ? String(localized: "Preferred display") : preferredDisplayName
  }

  private var updatesForm: some View {
    Form {
      Section("Installed version") {
        LabeledContent("Current version") {
          Text(updates.currentVersion.text).foregroundStyle(.secondary)
        }
        LabeledContent("Channel") {
          Text(updates.channel.title).foregroundStyle(.secondary)
        }
        LabeledContent("Last check") {
          if let lastCheckDate = updates.lastCheckDate {
            Text(lastCheckDate.formatted(date: .abbreviated, time: .shortened))
              .foregroundStyle(.secondary)
          } else {
            Text("Never").foregroundStyle(.secondary)
          }
        }
        LabeledContent("Status") {
          Text(updates.state.summary)
            .foregroundStyle(updates.state.isFailure ? .orange : .secondary)
            .textSelection(.enabled)
        }
      }
      Section("Update checks") {
        Toggle(
          "Automatically check for updates",
          isOn: automaticallyChecksForUpdatesBinding
        )
        .disabled(!updates.isConfigured)
        Button("Check for Updates…") { updates.checkForUpdates() }
          .disabled(!updates.canCheckForUpdates)
        Text(
          "Islet asks before enabling automatic checks. Sparkle shows signed release notes, download and verification progress, then offers to restart and install."
        )
        .font(.caption).foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
  }

  private var appearanceForm: some View {
    Form {
      Section("Theme") {
        AppThemePicker(selection: $appTheme)
        Text("Themes colour icons, key text, selected tabs and controls. The island stays black.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Section("Battery graph") {
        Picker("Power-flow colours", selection: $batteryGraphStyle) {
          ForEach(BatteryGraphStyle.allCases) { style in
            Text(style.title).tag(style)
          }
        }
        .pickerStyle(.segmented)
        Text(
          "Coloured distinguishes external power, battery flow, Mac load and USB output. Monochrome keeps the graph white."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
  }

  private var activityOrderForm: some View {
    Form {
      Section("Activities") {
        Text("Drag to reorder. Turning an activity off also stops its observer or server.")
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
      Section("Home") {
        Toggle("Reminders", isOn: $remindersEnabled)
        Text("Reminders appear on Home, not in a separate tab.")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
  }

  private var eventsForm: some View {
    Form {
      Section {
        Text(
          "Enabled sources show a brief alert when something changes. Disabled sources stop observing."
        )
        .foregroundStyle(.secondary)
      }
      Section("Activity notifications") {
        ForEach(["battery", "timer", "nowPlaying"], id: \.self) { id in
          Toggle(isOn: eventSourceEnabled(id)) {
            Label(SourceCatalog.name(for: id), systemImage: SourceCatalog.icon(for: id))
          }
        }
        Text("These switches hide alerts but do not stop the activity.")
          .font(.caption).foregroundStyle(.secondary)
      }
      ForEach(SystemEventTier.allCases, id: \.rawValue) { tier in
        let ids = SourceCatalog.ids(in: tier).filter {
          !["battery", "timer", "nowPlaying"].contains($0)
        }
        if !ids.isEmpty {
          Section(tier.label) {
            if tier == .heuristic {
              Text(
                "These start off. AirDrop is detected after transfer, and a network tunnel may be iCloud Private Relay."
              )
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
          Text(
            "Move upward into the notch and keep pushing against the top edge until the island snaps open."
          )
          .font(.caption).foregroundStyle(.secondary)
          LabeledContent("Push distance") {
            HStack(spacing: 10) {
              Text("20 pt").font(.caption).foregroundStyle(.secondary)
              Slider(value: pushDistanceSliderBinding, in: 0...1)
                .frame(minWidth: 220)
              Text("1,000 pt").font(.caption).foregroundStyle(.secondary)
            }
          }
          Text("Current distance: \(Int(barrierPushDistance)) points")
            .font(.caption).foregroundStyle(.secondary)
          LabeledContent(
            "Collapse after: \(collapseTimeout, format: .number.precision(.fractionLength(1)))s"
          ) {
            Slider(value: $collapseTimeout, in: 0.2...3.0, step: 0.1).frame(minWidth: 180)
          }
        }
      }
      Section("Command palette") {
        LabeledContent("Global shortcut") {
          Button(
            isRecordingShortcut
              ? String(localized: "Press shortcut…")
              : commandPaletteShortcut?.displayName ?? String(localized: "Off")
          ) {
            shortcutValidationMessage = nil
            isRecordingShortcut = true
          }
          .frame(minWidth: 130)
        }
        ShortcutCaptureView(
          isActive: isRecordingShortcut,
          onShortcut: { shortcut in
            isRecordingShortcut = false
            if let error = GlobalShortcutValidator.validate(shortcut) {
              shortcutValidationMessage = error.localizedDescription
              return
            }
            shortcutValidationMessage = nil
            commandPaletteShortcut = shortcut
            shortcutManager.register(shortcut)
          },
          onCancel: { isRecordingShortcut = false }
        )
        .frame(width: 0, height: 0)
        HStack {
          Button("Reset") {
            shortcutValidationMessage = nil
            commandPaletteShortcut = .default
            shortcutManager.register(.default)
          }
          Button("Disable") {
            shortcutValidationMessage = nil
            commandPaletteShortcut = nil
            shortcutManager.register(nil)
          }
          .disabled(commandPaletteShortcut == nil)
        }
        Text(shortcutValidationMessage ?? shortcutManager.status.message)
          .font(.caption)
          .foregroundStyle(shortcutStatusColor)
        Text("Islet registers only this shortcut with macOS. It does not record other keystrokes.")
          .font(.caption)
          .foregroundStyle(.secondary)
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
              }
            )
            .frame(minWidth: 220)
            Button("Test") { Haptics.performDelayedTest() }
              .disabled(hapticStrengthBinding.wrappedValue == .off)
            Text("Strong").font(.caption).foregroundStyle(.secondary)
          }
        }
        Text("Current strength: \(hapticStrengthBinding.wrappedValue.title)")
          .font(.caption).foregroundStyle(.secondary)
        Text("Push-through uses one pulse at the top edge and one when Islet opens.")
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
        Text("This only changes which player opens first when several are active.")
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
                      newBundleID.trimmingCharacters(in: .whitespacesAndNewlines))
                )
            }
          }
        }
      }
      Section("Audio-only sources") {
        Text(
          "CoreAudio detects any app making sound, including calls, games and helpers. These choices only affect audio-only source chips, not media players from the adapter."
        )
        .font(.caption).foregroundStyle(.secondary)
        if nowPlaying.manageableAudioOnlyBundleIdentifiers.isEmpty {
          Text("Audio-only apps appear here while they are making sound.")
            .font(.caption).foregroundStyle(.secondary)
        } else {
          ForEach(nowPlaying.manageableAudioOnlyBundleIdentifiers, id: \.self) { bundleID in
            Toggle(isOn: audioOnlySourceIncludedBinding(bundleID)) {
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
                Spacer()
                Text(
                  excludedAudioOnlySourceBundleIDs.contains(bundleID)
                    ? String(localized: "Excluded") : String(localized: "Included")
                )
                .font(.caption)
                .foregroundStyle(.secondary)
              }
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
          Text(isActivityEnabled("calendar") ? String(localized: "On") : String(localized: "Off"))
            .foregroundStyle(.secondary)
        }
        Toggle("Read calendar events", isOn: $calendarEnabled)
        Text("Calendar data also supplies the Home agenda when its activity is off.")
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
                Toggle(calendarChoiceLabel(choice), isOn: calendarEnabledBinding(choice.id))
              }
            }
            Text(
              "Deleted calendars are removed from this saved filter. Renaming one keeps its setting."
            )
            .font(.caption).foregroundStyle(.secondary)
          }
          Text(
            "The agenda covers three local calendar days. Add events from the Calendar activity."
          )
          .font(.caption).foregroundStyle(.secondary)
        }
        Button("Manage Calendar permission…") {
          navigate(to: .permissions)
        }
      }
      Section("Reminders") {
        Toggle("Show incomplete reminders on Home", isOn: $remindersEnabled)
        Text("Turning this off stops reading reminders.")
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
          Text(isActivityEnabled("system") ? String(localized: "On") : String(localized: "Off"))
            .foregroundStyle(.secondary)
        }
        Text("By default, System appears only during sustained load.")
          .font(.caption).foregroundStyle(.secondary)
        if isActivityEnabled("system") {
          Toggle("Always show System in the activity switcher", isOn: $systemAlwaysVisible)
        }
      }
      if isActivityEnabled("system") {
        Section("Automatic presence") {
          Toggle("High CPU", isOn: $systemAutoPresentCPU)
          Toggle("Thermal pressure", isOn: $systemAutoPresentThermal)
          Toggle("Memory pressure", isOn: $systemAutoPresentMemoryPressure)
          Toggle("Low disk space", isOn: $systemAutoPresentLowDiskSpace)
          Toggle("Heavy disk activity", isOn: $systemAutoPresentDiskThroughput)
          Toggle("High network traffic", isOn: $systemAutoPresentNetworkThroughput)
          Text(
            "Islet waits for sustained conditions and a clear recovery margin. Disk and network rates show unusually heavy traffic, not measured saturation, because device and link capacity are unavailable."
          )
          .font(.caption).foregroundStyle(.secondary)
        }
        Section("Metric presentation") {
          Picker("Presentation", selection: metricPresetBinding) {
            ForEach(SystemMetricPreset.allCases) { preset in
              Text(preset.title).tag(preset)
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
          Text(
            "Balanced shows the current value with a recent graph. Thermal uses state labels instead of a sparkline."
          )
          .font(.caption).foregroundStyle(.secondary)
        }
        Section("Process attribution") {
          Toggle("Identify processes after a spike", isOn: $processAttributionEnabled)
          if processAttributionEnabled {
            thresholdSlider(
              "CPU", value: $processCPUThreshold, range: 0.5...1, step: 0.05,
              valueText: "\(Int((processCPUThreshold * 100).rounded()))%")
            thresholdSlider(
              "Memory", value: $processMemoryThreshold, range: 0.5...1, step: 0.05,
              valueText: "\(Int((processMemoryThreshold * 100).rounded()))%")
            thresholdSlider(
              "Disk", value: $processDiskThreshold, range: 5...500, step: 5,
              valueText: "\(Int(processDiskThreshold)) MB/s")
            thresholdSlider(
              "Network", value: $processNetworkThreshold, range: 1...500, step: 5,
              valueText: "\(Int(processNetworkThreshold)) MB/s")
          }
          Text(
            "Islet reads process counters for one second after a threshold crossing, only while the System view is open. CPU, memory and disk values are estimates. macOS does not provide reliable per-process network totals to Islet."
          )
          .font(.caption).foregroundStyle(.secondary)
        }
      }
    }
    .formStyle(.grouped)
  }

  private func thresholdSlider(
    _ label: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double,
    valueText: String
  ) -> some View {
    LabeledContent(label) {
      HStack {
        Slider(value: value, in: range, step: step)
          .frame(width: 180)
        Text(valueText)
          .monospacedDigit()
          .foregroundStyle(.secondary)
          .frame(width: 62, alignment: .trailing)
      }
    }
  }

  private var continuityForm: some View {
    Form {
      Section("iPhone Live Activities") {
        Toggle("Show iPhone Live Activities", isOn: activityEnabled("continuity"))
        Text("Islet reads app names from Control Centre. macOS does not share the activity text.")
          .font(.caption).foregroundStyle(.secondary)
        if isActivityEnabled("continuity") {
          PermissionStatusRow(
            title: String(localized: "Availability"), icon: "iphone.gen3",
            status: continuityStatusText, color: continuityStatusColor)
          Text(continuity.availability.explanation)
            .font(.caption).foregroundStyle(.secondary)
          LabeledContent("Detected now") {
            Text("\(continuity.cards.count)").monospacedDigit().foregroundStyle(.secondary)
          }
          LabeledContent("Last successful read") {
            Text(continuityLastSuccessfulReadText).foregroundStyle(.secondary)
          }
          if let detail = continuity.lastCompatibilityError?.diagnosticSummary {
            Text(detail).font(.caption).foregroundStyle(.orange)
          }
          Toggle("Keep iPhone in the activity switcher when idle", isOn: $continuityAlwaysVisible)
          Toggle("Announce when a Live Activity starts or ends", isOn: $continuitySneaks)
          if continuity.availability == .needsAccessibility {
            HStack {
              Button("Request Accessibility access") { AccessibilityPermission.prompt() }
              Button("Open Accessibility Settings") { permissions.open(.accessibility) }
            }
          } else if continuity.availability == .controlCenterUnavailable
            || continuity.availability == .incompatibleSchema
          {
            Button("Retry Continuity") { continuity.retry() }
          }
        }
      }
    }
    .formStyle(.grouped)
  }

  private var clipboardForm: some View {
    Form {
      Section("Clipboard history") {
        LabeledContent("Activity") {
          Text(isActivityEnabled("clipboard") ? String(localized: "On") : String(localized: "Off"))
            .foregroundStyle(.secondary)
        }
        Text("Turning Clipboard off stops polling and clears its history.")
          .font(.caption).foregroundStyle(.secondary)
        LabeledContent("Capture") {
          Text(clipboardCaptureStatus).foregroundStyle(clipboard.isPaused ? .orange : .secondary)
        }
        HStack {
          Menu("Privacy pause") {
            Button("5 minutes") { clipboard.pause(for: 5 * 60) }
            Button("30 minutes") { clipboard.pause(for: 30 * 60) }
            Button("Until next login") { clipboard.pauseUntilNextLogin() }
            Button("Until I resume") { clipboard.setPaused(true) }
          }
          if clipboard.canResumeManualPause {
            Button("Resume now") { clipboard.setPaused(false) }
          }
          Button("Clear history") { clipboard.clear() }
            .disabled(clipboard.items.isEmpty)
        }
        Toggle("Clear current history when capture pauses", isOn: $clipboardClearHistoryOnPause)
        Text(
          "Turning this off keeps existing in-memory entries. Copies made during a pause are never backfilled."
        )
        .font(.caption).foregroundStyle(.secondary)
      }
      Section("Excluded applications") {
        if clipboardExcludedBundleIdentifiers.isEmpty {
          Text("No applications excluded").foregroundStyle(.secondary)
        } else {
          ForEach(clipboardExcludedBundleIdentifiers, id: \.self) { bundleIdentifier in
            HStack(spacing: 10) {
              if let icon = clipboardApplicationIcon(bundleIdentifier) {
                Image(nsImage: icon).resizable().frame(width: 24, height: 24)
              } else {
                Image(systemName: "app.dashed").frame(width: 24, height: 24)
              }
              VStack(alignment: .leading, spacing: 1) {
                Text(clipboardApplicationName(bundleIdentifier))
                Text(bundleIdentifier).font(.caption.monospaced()).foregroundStyle(.secondary)
              }
              Spacer()
              Button {
                clipboardExcludedBundleIdentifiers.removeAll { $0 == bundleIdentifier }
              } label: {
                Image(systemName: "minus.circle")
              }
              .buttonStyle(.plain).accessibilityLabel("Remove \(bundleIdentifier)")
            }
          }
        }
        Button("Add application…") { chooseClipboardApplication() }
        DisclosureGroup("Add by bundle identifier") {
          HStack {
            TextField("com.example.application", text: $newClipboardBundleIdentifier)
            Button("Add") { addClipboardApplication(newClipboardBundleIdentifier) }
          }
        }
        Text(
          "Islet can only see the app that is frontmost when it checks the pasteboard. macOS does not reliably identify the app that wrote a copy. Islet skips copies around app switches rather than guessing."
        )
        .font(.caption).foregroundStyle(.orange)
      }
      Section("Focus rules") {
        if clipboardPausedFocusIdentifiers.isEmpty {
          Text("No Focus modes pause capture").foregroundStyle(.secondary)
        } else {
          ForEach(clipboardPausedFocusIdentifiers, id: \.self) { identifier in
            HStack {
              Label(identifier, systemImage: "moon.circle.fill")
              Spacer()
              Button {
                clipboardPausedFocusIdentifiers.removeAll { $0 == identifier }
              } label: {
                Image(systemName: "minus.circle")
              }
              .buttonStyle(.plain).accessibilityLabel("Remove Focus \(identifier)")
            }
          }
        }
        if let currentFocusIdentifier = clipboard.currentFocusIdentifier,
          !clipboardPausedFocusIdentifiers.contains(currentFocusIdentifier)
        {
          Button("Pause for current Focus: \(currentFocusIdentifier)") {
            addClipboardFocus(currentFocusIdentifier)
          }
        }
        HStack {
          TextField("Focus name or identifier", text: $newClipboardFocusIdentifier)
          Button("Add") { addClipboardFocus(newClipboardFocusIdentifier) }
        }
        Text(
          "Focus detection uses an undocumented macOS state file. If its format is unknown, Islet does not guess that a Focus is active."
        )
        .font(.caption).foregroundStyle(.secondary)
      }
      Section("Privacy") {
        Label(
          "History stays in memory and clears when Islet quits. Islet filters concealed items and common credential formats, but it may miss sensitive text.",
          systemImage: "lock.shield"
        )
        .font(.caption).foregroundStyle(.orange)
        if let clipboardPrivacyError {
          Label(clipboardPrivacyError, systemImage: "exclamationmark.triangle")
            .font(.caption).foregroundStyle(.red)
        }
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
            title: String(localized: "Accessibility"), icon: "accessibility",
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
        Text(
          "If Islet cannot change the active device or display, macOS handles the key and shows its own HUD."
        )
        .font(.caption).foregroundStyle(.secondary)
      }
      if !hud.externalBrightnessDisplays.isEmpty {
        Section("External display brightness") {
          ForEach(hud.externalBrightnessDisplays) { status in
            VStack(alignment: .leading, spacing: 3) {
              Toggle(
                status.display.name,
                isOn: Binding(
                  get: {
                    if case .disabled = status.capability { return false }
                    return true
                  },
                  set: { enabled in
                    hud.setExternalBrightnessEnabled(enabled, displayID: status.display.id)
                  }))
              Text(status.capability.summary)
                .font(.caption)
                .foregroundStyle(
                  status.capability.isAvailable ? Color.secondary : Color.orange)
            }
          }
          Text(
            "Islet probes DDC/CI without changing brightness. Disable a display here if its monitor firmware behaves poorly."
          )
          .font(.caption).foregroundStyle(.secondary)
        }
      }
    }
    .formStyle(.grouped)
  }

  private var energyForm: some View {
    Form {
      Section("Energy use") {
        Picker("Mode", selection: $energyMode) {
          Text("Automatic").tag(EnergyMode.automatic)
          Text("Low Energy").tag(EnergyMode.lowEnergy)
          Text("Live").tag(EnergyMode.live)
        }
        Text(energyModeDetail)
          .font(.caption)
          .foregroundStyle(energyMode == .live ? .orange : .secondary)
      }
      Section("Keep awake") {
        Toggle("Allow the display to sleep", isOn: $allowDisplaySleep)
        Text(
          "An active session always prevents idle system sleep. Turn this off to keep the display awake too."
        )
        .font(.caption).foregroundStyle(.secondary)
        Toggle("Keep awake with the lid closed", isOn: $keepAwakeWithLidClosed)
        if keepAwakeWithLidClosed {
          if keepAwake.powerProtectInstalled {
            Label("Power Protect ready", systemImage: "checkmark.circle.fill")
              .font(.caption)
              .foregroundStyle(.secondary)
          } else {
            Text(
              "Closed-display mode needs a one-time administrator-approved helper. It changes only the system SleepDisabled setting while an Islet session is active."
            )
            .font(.caption).foregroundStyle(.secondary)
            Button(
              keepAwake.isInstallingPowerProtect
                ? String(localized: "Installing...") : String(localized: "Install Power Protect")
            ) {
              Task { await keepAwake.installPowerProtect() }
            }
            .disabled(keepAwake.isInstallingPowerProtect)
            if let error = keepAwake.lastError {
              Text(error).font(.caption).foregroundStyle(.orange)
            }
          }
        }
        Picker("Stop on low battery", selection: $keepAwakeLowBatteryThreshold) {
          Text("Off").tag(0)
          Text("10%").tag(10)
          Text("20%").tag(20)
          Text("30%").tag(30)
        }
        Text("Battery protection only stops a session while the Mac is unplugged.")
          .font(.caption).foregroundStyle(.secondary)
        if keepAwake.needsAssertionRecovery {
          Text(keepAwake.lastError ?? "A power assertion is still awaiting release.")
            .font(.caption).foregroundStyle(.orange)
          Button("Retry power assertion change") {
            keepAwake.retryUnreleasedAssertions()
          }
        }
      }
    }
    .formStyle(.grouped)
    .onAppear { keepAwake.refreshPowerProtectInstallation() }
  }

  private var batteryWarningsForm: some View {
    Form {
      Section("Mac battery") {
        Toggle("Warn about unusual battery drain", isOn: $unusualBatteryDrainWarnings)
        Text(
          "Islet compares sustained battery use with a seven-day rolling baseline stored on this Mac. A single high or noisy reading does not trigger an alert."
        )
        .font(.caption).foregroundStyle(.secondary)
        Toggle("Warn when the charger cannot meet demand", isOn: $chargerCapacityWarnings)
        Text(
          "Brief workload spikes remain informational. Alerts require sustained battery discharge or slow charging while power is connected."
        )
        .font(.caption).foregroundStyle(.secondary)
        LabeledContent("Learned baseline") {
          Text(batteryBaselineDescription).foregroundStyle(.secondary)
        }
        Button("Reset learned battery data…", role: .destructive) {
          confirmingBatteryDataReset = true
        }
      }
      Section("Peripheral early warnings") {
        ForEach(PeripheralDeviceType.allCases) { type in
          Picker(type.title, selection: peripheralThresholdBinding(for: type)) {
            Text("Off").tag(0)
            ForEach([15, 20, 25, 30, 40, 50], id: \.self) { threshold in
              Text("\(threshold)%").tag(threshold)
            }
          }
        }
        Text(
          "Off disables the early warning for that device type. The existing critical alert at 10% remains enabled."
        )
        .font(.caption).foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
  }

  private var batteryBaselineDescription: String {
    let summary = battery.batteryInsightSummary
    guard let watts = summary.baselineWatts else {
      return
        "Learning, \(summary.baselineSampleCount)/\(BatteryInsightAnalyzer.minimumBaselinePoints) samples"
    }
    return String(format: "%.1f W from %d samples", watts, summary.baselineSampleCount)
  }

  private func peripheralThresholdBinding(for type: PeripheralDeviceType) -> Binding<Int> {
    Binding(
      get: { peripheralBatteryWarningThresholds[type.rawValue] ?? 20 },
      set: { threshold in
        peripheralBatteryWarningThresholds[type.rawValue] = threshold
      })
  }

  private var permissionsForm: some View {
    Form {
      Section("Screen recording") {
        let policy = ScreenCaptureExclusionPolicy.current
        Toggle("Request capture exclusion", isOn: $hideFromRecording)
        PermissionStatusRow(
          title: String(localized: "Capture exclusion"), icon: "rectangle.dashed.badge.record",
          status: policy.status.summary, color: screenCaptureStatusColor)
        Text(policy.status.detail)
          .font(.caption).foregroundStyle(.secondary)
      }
      Section("Calendar") {
        PermissionStatusRow(
          title: String(localized: "Calendar access"), icon: "calendar", status: eventStatusText,
          color: eventStatusColor)
        Text("Shows today's agenda, event countdowns and meeting links.").font(.caption)
          .foregroundStyle(.secondary)
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
        PermissionStatusRow(
          title: String(localized: "Reminders access"), icon: "checklist",
          status: reminderStatusText,
          color: reminderStatusColor)
        Text("Shows and manages reminders from Home.").font(.caption)
          .foregroundStyle(.secondary)
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
          title: String(localized: "Accessibility access"), icon: "accessibility",
          status: permissions.diagnostics.accessibilityGranted
            ? String(localized: "Allowed") : String(localized: "Not allowed"),
          color: permissions.diagnostics.accessibilityGranted ? .green : .red)
        Text("Reads media keys for Islet's HUD and app names for iPhone Live Activities.")
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
          title: String(localized: "Location for Wi-Fi names"), icon: "location.fill",
          status: permissions.diagnostics.location.summary,
          color: platformPermissionColor(permissions.diagnostics.location))
        Text("Without location access, Wi-Fi notifications still work but omit the network name.")
          .font(.caption).foregroundStyle(.secondary)
        HStack {
          if permissions.diagnostics.location == .notDetermined {
            Button("Request access") { permissions.requestLocationAccess() }
          }
          if permissions.diagnostics.location != .granted {
            Button("Open Location Settings") { permissions.open(.location) }
          }
        }
        PermissionStatusRow(
          title: String(localized: "Bluetooth devices"), icon: "dot.radiowaves.right",
          status: permissions.diagnostics.bluetooth.summary,
          color: platformPermissionColor(permissions.diagnostics.bluetooth))
        Button("Open Bluetooth Privacy Settings") { permissions.open(.bluetooth) }
        PermissionStatusRow(
          title: String(localized: "Local network"), icon: "network",
          status: String(localized: "Managed by macOS"),
          color: .secondary)
        Text(
          "macOS asks when Islet first connects to T3 Code on another local Mac. macOS does not report this permission's status."
        )
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
    }
    .formStyle(.grouped)
  }

  private var pulseForm: some View {
    Form {
      Section("Pulse providers") {
        PermissionStatusRow(
          title: String(localized: "Local activity API"), icon: "waveform.path.ecg",
          status: pulseServer.lastError
            ?? (pulseServer.listeningAddress.map { String(localized: "Listening on \($0)") }
              ?? String(localized: "Stopped")),
          color: pulseServer.lastError == nil ? (pulseServer.isRunning ? .green : .secondary) : .red
        )
        LabeledContent("Pulse items") {
          Text(
            pulse.hiddenItemCount == 0
              ? "\(pulse.items.count) visible"
              : "\(pulse.items.count) visible, \(pulse.hiddenItemCount) filtered"
          )
          .monospacedDigit().foregroundStyle(.secondary)
        }
        LabeledContent("Authentication") {
          Text(
            "\(pulseCredentials.credentials.filter { !$0.isRevoked }.count) active provider credentials"
          )
          .foregroundStyle(.secondary)
        }
        LabeledContent("Mark silent work stale after") {
          Picker("Stale timeout", selection: $pulseStaleTimeout) {
            Text("1 minute").tag(60.0)
            Text("5 minutes").tag(300.0)
            Text("15 minutes").tag(900.0)
            Text("30 minutes").tag(1_800.0)
            Text("1 hour").tag(3_600.0)
          }
          .labelsHidden()
          .frame(width: 130)
          .onChange(of: pulseStaleTimeout) { _, timeout in
            pulse.setStaleTimeout(timeout)
          }
        }
        Text(
          "A valid provider update restarts this timer. Silent work is marked stale for one hour so you can keep or dismiss it."
        )
        .font(.caption).foregroundStyle(.secondary)
        Text(
          "Local scripts publish status and web actions over \(pulseServer.listeningAddress ?? "localhost:47717"). Each approved provider has its own source identity and permissions. Credentials stay in user-only files and are never included in diagnostics."
        )
        .font(.caption).foregroundStyle(.secondary)
        if let nextRetryAt = pulseServer.nextRetryAt {
          Text("Next retry at \(nextRetryAt.formatted(date: .omitted, time: .standard)).")
            .font(.caption).foregroundStyle(.orange)
        }
        if let recovery = pulseServer.portRecoveryMessage {
          Text(recovery)
            .font(.caption).foregroundStyle(.orange)
          Text(
            "Tools/islet-pulse.swift discovers the active port from Islet's support folder. Set other clients to \(pulseServer.activePort ?? 47_717)."
          )
          .font(.caption).foregroundStyle(.secondary)
          Button("Retry port 47717") { pulseServer.retryDefaultPort() }
        } else if pulseServer.lastError != nil {
          Button("Retry Pulse listener now") { pulseServer.retryDefaultPort() }
        }
        Text(
          "Turning Pulse off under Activity order closes the listener and disconnects providers."
        )
        .font(.caption).foregroundStyle(.secondary)
        HStack {
          Button("Quick Actions…") { QuickActionsOpener.open() }
          Button("Add provider…") { showingPulseCredentialEditor = true }
          Button("Reveal credential folder") {
            NSWorkspace.shared.open(pulseCredentials.credentialDirectory)
          }
          .help("Credential files grant Pulse access. Do not share them.")
          if !pulse.items.isEmpty {
            Button("Dismiss visible") { pulse.dismissVisible() }
          }
        }
      }
      Section("Provider credentials") {
        if pulseCredentials.credentials.isEmpty {
          ContentUnavailableView(
            "No approved providers", systemImage: "key.slash",
            description: Text("Add a provider before a local script can publish to Pulse."))
        } else {
          ForEach(pulseCredentials.credentials) { credential in
            PulseCredentialRow(
              credential: credential, server: pulseServer,
              reportError: { pulseCredentialResult = $0 })
          }
        }
      }
      Section("Trusted web destinations") {
        Text(
          "Each entry trusts one canonical origin for one credential-bound provider. Paths, queries, action titles and payload text are never stored."
        )
        .font(.caption).foregroundStyle(.secondary)
        if let error = pulseActionTrust.lastError {
          Label(error, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
        } else if pulseActionTrust.trusts.isEmpty {
          ContentUnavailableView(
            "No trusted destinations", systemImage: "link.badge.plus",
            description: Text("Opening a new Pulse web origin always asks first."))
        } else {
          ForEach(pulseActionTrust.trusts) { trust in
            PulseTrustedDestinationRow(
              trust: trust,
              providerName: pulseCredentials.credentials.first {
                $0.id == trust.provider.credentialID
              }?.name,
              revoke: {
                do {
                  try pulseActionTrust.revoke(trust)
                } catch {
                  pulseCredentialResult = error.localizedDescription
                }
              })
          }
        }
      }
      Section("Provider examples") {
        Text(
          "Providers run outside Islet. They can publish only the listed data and cannot read other activities."
        )
        .font(.caption).foregroundStyle(.secondary)
        Text(
          "These delivery controls affect credential-bound sources. Revoke a provider credential above to remove its access."
        )
        .font(.caption).foregroundStyle(.secondary)
        ForEach(pulse.providerStatuses) { status in
          PulseProviderRow(status: status, center: pulse)
        }
        if !pulse.unlistedSources.isEmpty {
          Text("Other sources in history").font(.caption.weight(.medium))
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
      Section("Pulse history") {
        Toggle("Show history", isOn: $showPulseHistory)
        Toggle("Keep history after quitting", isOn: pulseHistoryPersistenceBinding)
        Text(
          pulseHistoryPersistenceEnabled
            ? "Saved history contains source, result, priority, state, operation and time. It excludes item identifiers, payload text, progress, links, tokens and errors."
            : "History stays in memory until Islet quits. Saving is off by default. History never contains item identifiers, payload text, progress, links, tokens or errors."
        )
        .font(.caption).foregroundStyle(.secondary)
        LabeledContent("Retention period") {
          Picker("Retention period", selection: pulseHistoryRetentionBinding) {
            ForEach(PulseHistoryConfiguration.allowedRetentionDays, id: \.self) { days in
              Text(
                days == 1 ? String(localized: "1 day") : String(localized: "\(days) days")
              ).tag(days)
            }
          }
          .labelsHidden()
          .frame(width: 120)
        }
        .disabled(!pulseHistoryPersistenceEnabled)
        LabeledContent("Maximum entries") {
          Picker("Maximum entries", selection: pulseHistoryMaximumEntriesBinding) {
            ForEach(PulseHistoryConfiguration.allowedEntryCounts, id: \.self) { count in
              Text("\(count)").tag(count)
            }
          }
          .labelsHidden()
          .frame(width: 120)
        }
        if let error = pulse.historyPersistenceError {
          Label(error, systemImage: "exclamationmark.triangle.fill")
            .font(.caption).foregroundStyle(.orange)
        }
        if showPulseHistory {
          Picker("History filter", selection: $pulseHistoryFilter) {
            ForEach(PulseHistoryFilter.allCases) { filter in Text(filter.title).tag(filter) }
          }
          .pickerStyle(.segmented)
          if filteredPulseHistory.isEmpty {
            Text(
              pulse.history.isEmpty
                ? String(localized: "No provider activity recorded.")
                : String(localized: "No matching history entries.")
            )
            .foregroundStyle(.secondary)
          } else {
            ForEach(filteredPulseHistory.prefix(30)) { entry in
              PulseHistoryRow(entry: entry)
            }
            Text("Showing \(min(30, filteredPulseHistory.count)) of \(filteredPulseHistory.count)")
              .font(.caption).foregroundStyle(.secondary)
          }
        }
        HStack {
          Button("Export history…") { exportPulseHistory() }
            .disabled(pulse.history.isEmpty)
          Button("Clear history", role: .destructive) { pulse.clearHistory() }
            .disabled(pulse.history.isEmpty)
        }
      }
    }
    .formStyle(.grouped)
    .onAppear { try? pulseActionTrust.prepare() }
  }

  private var diagnosticsForm: some View {
    Form {
      Section("Diagnostics") {
        LabeledContent("Bundle identifier") {
          Text(Bundle.main.bundleIdentifier ?? "Unknown").textSelection(.enabled)
        }
        LabeledContent("Version") { Text(versionText).foregroundStyle(.secondary) }
        LabeledContent("Energy mode") { Text(energyModeTitle).foregroundStyle(.secondary) }
        HStack {
          Button("Copy diagnostics") { copyDiagnostics() }
          Button("Open logs folder") {
            NSWorkspace.shared.open(
              URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Logs"))
          }
          Button("Restart Islet") { AppRelauncher.restart() }
          Button("Quit Islet") { NSApplication.shared.terminate(nil) }
        }
      }
      Section("Integration health") {
        PermissionStatusRow(
          title: String(localized: "Continuity reader"), icon: "iphone.gen3",
          status: continuityStatusText, color: continuityStatusColor)
        LabeledContent("Continuity last successful read") {
          Text(continuityLastSuccessfulReadText).foregroundStyle(.secondary)
        }
        if let detail = continuity.lastCompatibilityError?.diagnosticSummary {
          Text(detail).font(.caption).foregroundStyle(.orange)
        }
        if continuity.availability == .needsAccessibility {
          HStack {
            Button("Request Accessibility access") { AccessibilityPermission.prompt() }
            Button("Open Accessibility Settings") { permissions.open(.accessibility) }
            Button("Retry Continuity") { continuity.retry() }
          }
        } else if continuity.availability == .controlCenterUnavailable
          || continuity.availability == .incompatibleSchema
        {
          Button("Retry Continuity") { continuity.retry() }
        }
        PermissionStatusRow(
          title: String(localized: "Focus event source"), icon: "moon.circle.fill",
          status: focus.health.summary,
          color: focus.health.isFailure ? .orange : focus.health == .stopped ? .secondary : .green)
        if let lastSuccessfulParse = focus.lastSuccessfulParse {
          LabeledContent("Focus last parsed") {
            Text(lastSuccessfulParse, style: .relative).foregroundStyle(.secondary)
          }
        }
        if let schemaSignature = focus.schemaSignature {
          LabeledContent("Focus schema") {
            Text(schemaSignature).fontDesign(.monospaced).foregroundStyle(.secondary)
          }
        }
        Button("Retry Focus source") { focus.retry() }
          .disabled(focus.health == .stopped)
        PermissionStatusRow(
          title: String(localized: "Media adapter"), icon: "music.note",
          status: nowPlaying.adapterStatus,
          color: nowPlaying.adapterStatus.localizedCaseInsensitiveContains("error")
            || nowPlaying.adapterStatus.localizedCaseInsensitiveContains("timeout")
            ? .orange : .green)
        PermissionStatusRow(
          title: String(localized: "T3 Code credentials"), icon: "key.fill",
          status: t3Code.lastCredentialError ?? String(localized: "Available"),
          color: t3Code.lastCredentialError == nil ? .green : .orange)
        PermissionStatusRow(
          title: String(localized: "Pulse"), icon: "waveform.path.ecg",
          status: pulseServer.lastError
            ?? (pulseServer.isRunning
              ? String(localized: "Listening") : String(localized: "Stopped")),
          color: pulseServer.lastError == nil ? (pulseServer.isRunning ? .green : .secondary) : .red
        )
        PermissionStatusRow(
          title: String(localized: "Media-key HUD"), icon: "keyboard",
          status: hud.lastControlFailure ?? hud.eventTapStatus.summary,
          color: hud.lastControlFailure == nil
            ? (hud.eventTapStatus == .active ? .green : .secondary) : .orange)
        PermissionStatusRow(
          title: "USB reader", icon: "cable.connector", status: ports.readerHealth.summary,
          color: usbReaderHealthColor)
        Button("Retry USB enumeration") { ports.retry() }
      }
      Section("About") {
        Link("C-Nucifora on GitHub", destination: URL(string: "https://github.com/C-Nucifora")!)
        Link("nedlane on GitHub", destination: URL(string: "https://github.com/nedlane")!)
      }
    }
    .formStyle(.grouped)
  }

  private var resetForm: some View {
    Form {
      Section("Appearance and interaction") {
        Button("Restore appearance and interaction…", role: .destructive) {
          confirmingRestore = true
        }
        Text(
          "Resets the theme, notch interaction, haptics, HUD style, player order, activity order and metric styles. It keeps enabled activities, permissions, paired machines and activity data."
        )
        .font(.caption).foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
  }

  private var settingsTransferForm: some View {
    Form {
      Section("Settings backup") {
        HStack {
          Button("Export settings…") { exportSettings() }
          Button("Import settings…") { importSettings() }
        }
        Text(
          "Exports portable interface and activity preferences as readable JSON. Import shows every change before anything is applied."
        )
        .font(.caption).foregroundStyle(.secondary)
      }
      Section("Never included") {
        Text(
          "Keychain credentials, Pulse tokens, paired T3 Code machines, permission grants, calendar account identifiers, activity data and session history stay on this Mac."
        )
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

  private var screenCaptureStatusColor: Color {
    switch ScreenCaptureExclusionPolicy.current.status {
    case .active: .green
    case .unsupported: .red
    case .unverified: .orange
    }
  }

  private var continuityStatusText: String {
    switch continuity.availability {
    case .needsAccessibility: String(localized: "Needs Accessibility")
    case .controlCenterUnavailable: String(localized: "Control Centre unavailable")
    case .incompatibleSchema: String(localized: "Unsupported AX layout")
    case .systemDisabled: String(localized: "Off in macOS")
    case .waiting: String(localized: "Waiting")
    case .active: String(localized: "Active")
    }
  }

  private var continuityStatusColor: Color {
    switch continuity.availability {
    case .active: .green
    case .waiting: .secondary
    case .needsAccessibility, .systemDisabled: .orange
    case .controlCenterUnavailable, .incompatibleSchema: .red
    }
  }

  private var continuityLastSuccessfulReadText: String {
    guard let date = continuity.lastSuccessfulRead else { return String(localized: "Never") }
    return date.formatted(date: .abbreviated, time: .standard)
  }

  private var shortcutStatusColor: Color {
    if shortcutValidationMessage != nil { return .red }
    return switch shortcutManager.status {
    case .registered: Color.green
    case .disabled: Color.secondary
    case .conflict, .invalid, .failed: Color.red
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

  private func audioOnlySourceIncludedBinding(_ bundleIdentifier: String) -> Binding<Bool> {
    Binding(
      get: { !excludedAudioOnlySourceBundleIDs.contains(bundleIdentifier) },
      set: { included in
        if included {
          excludedAudioOnlySourceBundleIDs.removeAll { $0 == bundleIdentifier }
        } else if !excludedAudioOnlySourceBundleIDs.contains(bundleIdentifier) {
          excludedAudioOnlySourceBundleIDs.append(bundleIdentifier)
          if excludedAudioOnlySourceBundleIDs.count > SourceFilter.maximumAudioOnlyExclusions {
            excludedAudioOnlySourceBundleIDs.removeFirst()
          }
        }
      })
  }

  private var clipboardCaptureStatus: String {
    guard isActivityEnabled("clipboard") else {
      return String(localized: "Stopped with the activity")
    }
    return clipboard.pauseReason?.summary ?? String(localized: "Capturing new copies")
  }

  private func addClipboardApplication(_ rawBundleIdentifier: String) {
    guard let bundleIdentifier = ClipboardIdentifierPolicy.bundleIdentifier(rawBundleIdentifier)
    else {
      clipboardPrivacyError = String(
        localized: "Enter a valid application bundle identifier up to 255 bytes.")
      return
    }
    let updated = ClipboardIdentifierPolicy.bundleIdentifiers(
      clipboardExcludedBundleIdentifiers + [bundleIdentifier])
    guard updated.contains(bundleIdentifier) else {
      clipboardPrivacyError = String(
        localized: "The exclusion list is limited to 128 applications.")
      return
    }
    clipboardExcludedBundleIdentifiers = updated
    newClipboardBundleIdentifier = ""
    clipboardPrivacyError = nil
  }

  private func chooseClipboardApplication() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.applicationBundle]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
    panel.title = String(localized: "Exclude an application from clipboard history")
    panel.prompt = String(localized: "Exclude")
    guard panel.runModal() == .OK, let url = panel.url else { return }
    guard let bundleIdentifier = Bundle(url: url)?.bundleIdentifier else {
      clipboardPrivacyError = String(
        localized: "That application does not declare a bundle identifier.")
      return
    }
    addClipboardApplication(bundleIdentifier)
  }

  private func addClipboardFocus(_ rawIdentifier: String) {
    guard let identifier = ClipboardIdentifierPolicy.focusIdentifier(rawIdentifier) else {
      clipboardPrivacyError = String(
        localized: "Enter a valid Focus name or identifier up to 128 bytes.")
      return
    }
    let updated = ClipboardIdentifierPolicy.focusIdentifiers(
      clipboardPausedFocusIdentifiers + [identifier])
    guard updated.contains(identifier) else {
      clipboardPrivacyError = String(localized: "The Focus rule list is limited to 64 entries.")
      return
    }
    clipboardPausedFocusIdentifiers = updated
    newClipboardFocusIdentifier = ""
    clipboardPrivacyError = nil
  }

  private func clipboardApplicationName(_ bundleIdentifier: String) -> String {
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    else { return bundleIdentifier }
    return FileManager.default.displayName(atPath: url.path)
  }

  private func clipboardApplicationIcon(_ bundleIdentifier: String) -> NSImage? {
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    else { return nil }
    return NSWorkspace.shared.icon(forFile: url.path)
  }

  private func refreshPermissionState() {
    hud.refreshPermissionStatus()
    permissions.refresh()
    launchAtLoginStatus.refresh()
    updates.refresh()
  }

  private func navigate(to page: SettingsDetailPage) {
    selection = page.category
    detailPage = page
    forwardDetailPage = nil
  }

  private func updateWindowTitle() {
    SettingsOpener.setTitle(detailPage?.title ?? (selection ?? .general).title)
  }

  private var versionText: String {
    let version =
      Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
      ?? String(localized: "Development")
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    return build.map { "\(version) (\($0))" } ?? version
  }

  private var energyModeDetail: String {
    switch energyMode {
    case .automatic:
      String(localized: "Follows macOS Low Power Mode and slows hidden activity automatically.")
    case .lowEnergy:
      String(
        localized: "Always uses conservative refresh rates and disables optional remote T3 polling."
      )
    case .live:
      String(
        localized:
          "Prioritises fresh metrics and remote status, including while macOS Low Power Mode is on."
      )
    }
  }

  private var energyModeTitle: String {
    switch energyMode {
    case .automatic: String(localized: "Automatic")
    case .lowEnergy: String(localized: "Low Energy")
    case .live: String(localized: "Live")
    }
  }

  private func copyDiagnostics() {
    let text =
      permissions.diagnostics.text
      + "\nMedia adapter: \(nowPlaying.adapterStatus)"
      + (nowPlaying.adapterFailure.map { "\nMedia adapter failure: \($0)" } ?? "")
      + "\nHUD event tap: \(hud.eventTapStatus.summary)"
      + "\n\(hud.externalBrightnessDiagnostics)"
      + "\nContinuity: \(continuityStatusText)"
      + "\nContinuity last successful read: \(continuity.lastSuccessfulRead?.formatted(.iso8601) ?? "Never")"
      + "\nContinuity compatibility error: \(continuity.lastCompatibilityError?.diagnosticSummary ?? "None recorded")"
      + "\nFocus event source: \(focus.health.summary)"
      + "\nFocus last parsed: \(focus.lastSuccessfulParse?.formatted() ?? "Never")"
      + "\nFocus schema: \(focus.schemaSignature ?? "Unavailable")"
      + "\nPulse: \(pulseServer.isRunning ? "Running" : "Stopped")"
      + "\nPulse items: \(pulse.items.count) visible, \(pulse.hiddenItemCount) filtered"
      + "\nUSB reader: \(ports.readerHealth.summary)"
      + "\nUpdate channel: \(updates.channel.title)"
      + "\nUpdater: \(updates.state.summary)"
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }

  private var usbReaderHealthColor: Color {
    switch ports.readerHealth {
    case .current: .green
    case .awaitingFirstRead: .secondary
    case .stale: .orange
    case .failed: .red
    }
  }

  private func applyPulseHistoryConfiguration() {
    pulse.configureHistoryPersistence(
      enabled: pulseHistoryPersistenceEnabled,
      retentionDays: pulseHistoryRetentionBinding.wrappedValue,
      maximumEntries: pulseHistoryMaximumEntriesBinding.wrappedValue)
  }

  private func exportPulseHistory() {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.json]
    panel.canCreateDirectories = true
    panel.nameFieldStringValue = "Islet Pulse History.json"
    panel.title = String(localized: "Export Pulse history")
    panel.prompt = String(localized: "Export")
    guard panel.runModal() == .OK, let url = panel.url else { return }

    do {
      let count = pulse.history.count
      try pulse.exportHistoryData().write(to: url, options: .atomic)
      settingsTransferNotice = SettingsTransferNotice(
        title: String(localized: "Pulse history exported"),
        message: count == 1
          ? String(localized: "Saved 1 metadata entry.")
          : String(localized: "Saved \(count) metadata entries."))
    } catch {
      settingsTransferNotice = SettingsTransferNotice(
        title: String(localized: "Pulse history could not be exported"),
        message: error.localizedDescription)
    }
  }

  private func exportSettings() {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.json]
    panel.canCreateDirectories = true
    panel.nameFieldStringValue = "Islet Settings.json"
    panel.title = String(localized: "Export Islet settings")
    panel.prompt = String(localized: "Export")
    guard panel.runModal() == .OK, let url = panel.url else { return }

    do {
      let data = try SettingsTransfer.exportData(snapshot: SettingsTransferDefaults.snapshot())
      try data.write(to: url, options: .atomic)
      settingsTransferNotice = SettingsTransferNotice(
        title: String(localized: "Settings exported"),
        message: String(
          localized: "Saved \(SettingsTransfer.portableKeys.count) portable preference."))
    } catch {
      settingsTransferNotice = SettingsTransferNotice(
        title: String(localized: "Settings could not be exported"),
        message: error.localizedDescription)
    }
  }

  private func importSettings() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.json]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.title = String(localized: "Import Islet settings")
    panel.prompt = String(localized: "Preview")
    guard panel.runModal() == .OK, let url = panel.url else { return }

    let hasAccess = url.startAccessingSecurityScopedResource()
    defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
    do {
      let fileSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
      guard fileSize <= SettingsTransfer.maximumDocumentBytes else {
        throw SettingsTransferError.documentTooLarge
      }
      let data = try Data(contentsOf: url, options: .mappedIfSafe)
      settingsImportPreview = try SettingsTransfer.preview(
        data: data, current: SettingsTransferDefaults.snapshot())
    } catch {
      settingsTransferNotice = SettingsTransferNotice(
        title: String(localized: "Settings could not be imported"),
        message: error.localizedDescription)
    }
  }

  private func restoreInterfaceDefaults() {
    appTheme = .classic
    batteryGraphStyle = .coloured
    mode = .hover
    collapseTimeout = 0.5
    haptics = true
    hapticStrength = .medium
    barrierPushDistance = Double(Metrics.barrierPushDistance)
    sourceMode = .auto
    priorityList = ["com.spotify.client", "com.apple.Music"]
    activityOrder = ActivityCatalog.defaultOrder
    systemAlwaysVisible = false
    systemAutoPresentCPU = true
    systemAutoPresentThermal = true
    systemAutoPresentMemoryPressure = true
    systemAutoPresentLowDiskSpace = true
    systemAutoPresentDiskThroughput = true
    systemAutoPresentNetworkThroughput = true
    metricStyles = [:]
    processAttributionEnabled = true
    processCPUThreshold = 0.8
    processMemoryThreshold = 0.9
    processDiskThreshold = 50
    processNetworkThreshold = 25
    hudStyle = .bar
    Defaults[.disabledExternalBrightnessDisplays] = []
  }
}

private struct ShortcutCaptureView: NSViewRepresentable {
  let isActive: Bool
  let onShortcut: (GlobalShortcut) -> Void
  let onCancel: () -> Void

  func makeNSView(context: Context) -> ShortcutCaptureNSView {
    ShortcutCaptureNSView(onShortcut: onShortcut, onCancel: onCancel)
  }

  func updateNSView(_ view: ShortcutCaptureNSView, context: Context) {
    view.onShortcut = onShortcut
    view.onCancel = onCancel
    guard isActive else {
      if view.window?.firstResponder === view { view.window?.makeFirstResponder(nil) }
      return
    }
    DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
  }
}

private final class ShortcutCaptureNSView: NSView {
  var onShortcut: (GlobalShortcut) -> Void
  var onCancel: () -> Void

  init(onShortcut: @escaping (GlobalShortcut) -> Void, onCancel: @escaping () -> Void) {
    self.onShortcut = onShortcut
    self.onCancel = onCancel
    super.init(frame: .zero)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { nil }

  override var acceptsFirstResponder: Bool { true }

  override func keyDown(with event: NSEvent) {
    if event.keyCode == 53 {
      onCancel()
    } else {
      onShortcut(GlobalShortcut(event: event))
    }
  }
}

private struct SettingsImportPreviewSheet: View {
  let preview: SettingsTransferPreview
  let cancel: () -> Void
  let apply: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      VStack(alignment: .leading, spacing: 5) {
        Text("Preview settings import").font(.title2.weight(.semibold))
        Text(
          preview.sourceVersion < SettingsTransfer.currentVersion
            ? "Islet migrated this version \(preview.sourceVersion) export before checking it."
            : "Review the changes below. Nothing has been applied yet."
        )
        .foregroundStyle(.secondary)
      }

      if preview.changes.isEmpty {
        ContentUnavailableView(
          "No settings would change", systemImage: "checkmark.circle",
          description: Text("The imported values already match this Mac.")
        )
        .frame(maxWidth: .infinity, minHeight: 180)
      } else {
        List(preview.changes) { change in
          VStack(alignment: .leading, spacing: 5) {
            Text(change.title).font(.headline)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
              Text(change.oldValue).foregroundStyle(.secondary)
              Image(systemName: "arrow.right").foregroundStyle(.tertiary)
              Text(change.newValue)
            }
            .font(.caption)
            .textSelection(.enabled)
          }
          .padding(.vertical, 3)
        }
        .frame(minHeight: 220)
      }

      if !preview.ignoredKeys.isEmpty {
        Label(
          "Ignored unknown settings: \(preview.ignoredKeys.joined(separator: ", "))",
          systemImage: "info.circle"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
      }

      HStack {
        Text(
          "Read \(preview.importedSettingCount) portable setting\(preview.importedSettingCount == 1 ? "" : "s")."
        )
        .font(.caption).foregroundStyle(.secondary)
        Spacer()
        Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
        Button("Import settings", action: apply)
          .keyboardShortcut(.defaultAction)
          .disabled(preview.changes.isEmpty)
      }
    }
    .padding(24)
    .frame(minWidth: 620, idealWidth: 680, minHeight: 430)
  }
}

private struct AppThemePicker: View {
  @Environment(\.colorScheme) private var colorScheme
  @Binding var selection: AppTheme

  var body: some View {
    LazyVGrid(
      columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12
    ) {
      ForEach(AppTheme.allCases) { theme in
        Button {
          selection = theme
        } label: {
          VStack(spacing: 8) {
            AppThemePreview(theme: theme)
              .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                  .stroke(
                    selection == theme
                      ? theme.settingsAccentColor(for: colorScheme) : Color.secondary.opacity(0.24),
                    lineWidth: selection == theme ? 3 : 1)
              }
            HStack(spacing: 5) {
              Text(theme.title)
              if selection == theme {
                Image(systemName: "checkmark.circle.fill")
                  .foregroundStyle(theme.settingsAccentColor(for: colorScheme))
              }
            }
            .font(.callout.weight(selection == theme ? .semibold : .regular))
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(theme.title) theme")
        .accessibilityAddTraits(selection == theme ? .isSelected : [])
      }
    }
    .padding(.vertical, 4)
  }
}

private struct AppThemePreview: View {
  let theme: AppTheme

  var body: some View {
    ZStack {
      Color.black
      VStack(spacing: 9) {
        HStack(spacing: 10) {
          ForEach(previewRoles, id: \.self) { role in
            Image(systemName: symbol(for: role))
              .font(.system(size: 13, weight: .semibold))
              .foregroundStyle(theme.color(for: role))
          }
        }
        HStack(spacing: 7) {
          Capsule().fill(.white.opacity(0.82)).frame(width: 42, height: 5)
          Capsule().fill(theme.accentColor).frame(width: 26, height: 5)
        }
        HStack(spacing: 5) {
          Circle().fill(theme.color(for: .calendar)).frame(width: 6, height: 6)
          Capsule().fill(.white.opacity(0.24)).frame(width: 54, height: 4)
        }
      }
    }
    .frame(height: 76)
    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
  }

  private var previewRoles: [AppThemeRole] { [.calendar, .clipboard, .battery, .system] }

  private func symbol(for role: AppThemeRole) -> String {
    switch role {
    case .calendar: "calendar"
    case .clipboard: "doc.on.clipboard"
    case .battery: "battery.75percent"
    case .system: "cpu"
    default: "circle.fill"
    }
  }
}

private struct SettingsNavigationLink: View {
  @Environment(\.appTheme) private var appTheme
  @Environment(\.colorScheme) private var colorScheme
  let page: SettingsDetailPage
  let action: () -> Void
  @State private var isHovering = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 13) {
        Image(systemName: page.icon)
          .font(.system(size: 17, weight: .semibold))
          .foregroundStyle(appTheme.settingsAccentForegroundColor(for: colorScheme))
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
      .animation(Motion.gated(.easeOut(duration: 0.1)), value: configuration.isPressed)
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
      if !status.descriptor.documentationLinks.isEmpty {
        VStack(alignment: .leading, spacing: 3) {
          Text("Starter examples").font(.caption2).foregroundStyle(.secondary)
          ForEach(status.descriptor.documentationLinks) { link in
            Link(link.title, destination: link.url).font(.caption2)
          }
        }
      }
    }
    .padding(.vertical, 4)
    .accessibilityElement(children: .contain)
  }

  private var healthColor: Color {
    switch status.health {
    case .active: .green
    case .needsAttention: .orange
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

private struct PulseCredentialEditor: View {
  let create: (String, String, Set<PulseCredentialPermission>) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var name = ""
  @State private var source = ""
  @State private var permissions: Set<PulseCredentialPermission> = [.events]

  var body: some View {
    NavigationStack {
      Form {
        Section("Provider identity") {
          TextField("Name", text: $name, prompt: Text("Build watcher"))
          TextField("Source", text: $source, prompt: Text("build"))
          Text(
            "The source becomes part of this credential's identity. Commands cannot publish under another source."
          )
          .font(.caption).foregroundStyle(.secondary)
        }
        Section("Permissions") {
          ForEach(PulseCredentialPermission.allCases) { permission in
            Toggle(isOn: permissionBinding(permission)) {
              VStack(alignment: .leading, spacing: 2) {
                Text(permission.title)
                Text(permission.detail).font(.caption).foregroundStyle(.secondary)
              }
            }
          }
        }
      }
      .formStyle(.grouped)
      .navigationTitle("Add Pulse provider")
      .frame(width: 520, height: 510)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Add provider") { create(name, source, permissions) }
            .disabled(
              name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }
    }
  }

  private func permissionBinding(_ permission: PulseCredentialPermission) -> Binding<Bool> {
    Binding(
      get: { permissions.contains(permission) },
      set: { allowed in
        if allowed { permissions.insert(permission) } else { permissions.remove(permission) }
      })
  }
}

private struct PulseCredentialRow: View {
  let credential: PulseCredentialSummary
  let server: PulseServer
  let reportError: (String) -> Void

  @State private var confirmingRotation = false
  @State private var confirmingRevocation = false

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 6) {
            Text(credential.name).font(.body.weight(.medium))
            if credential.isLegacy {
              Text("LEGACY").font(.caption2.weight(.semibold)).foregroundStyle(.orange)
            }
          }
          Text(credential.source).font(.caption.monospaced()).foregroundStyle(.secondary)
        }
        Spacer()
        Label(
          credential.isRevoked ? String(localized: "Revoked") : String(localized: "Active"),
          systemImage: credential.isRevoked ? "xmark.shield.fill" : "checkmark.shield.fill"
        )
        .font(.caption)
        .foregroundStyle(credential.isRevoked ? .red : .green)
      }

      HStack(spacing: 16) {
        LabeledContent("Credential age") {
          Text(credential.credentialAgeDate, style: .relative)
        }
        LabeledContent("Last use") {
          if let lastUsedAt = credential.lastUsedAt {
            Text(lastUsedAt, style: .relative)
          } else {
            Text("Never")
          }
        }
      }
      .font(.caption)
      .foregroundStyle(.secondary)

      if credential.isLegacy, !credential.isRevoked {
        Text(
          "The old token may be held by several scripts. Added permissions apply to every holder. Create separate provider credentials, then revoke this entry."
        )
        .font(.caption)
        .foregroundStyle(.orange)
      }

      if !credential.isLegacy, !credential.isRevoked {
        Text(
          "Bearer credential: trusted processes running as your macOS user can use this file. Source binding separates cooperative tools, not hostile same-user processes."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      ForEach(PulseCredentialPermission.allCases) { permission in
        Toggle(permission.title, isOn: permissionBinding(permission))
          .help(permission.detail)
          .disabled(credential.isRevoked)
      }
      .font(.caption)

      HStack {
        if let url = server.credentialStore.credentialFileURL(for: credential.id) {
          Button("Reveal credential") {
            NSWorkspace.shared.activateFileViewerSelecting([url])
          }
        }
        if !credential.isLegacy, !credential.isRevoked {
          Button("Rotate credential…") { confirmingRotation = true }
        }
        if !credential.isRevoked {
          Button("Revoke…", role: .destructive) { confirmingRevocation = true }
        }
      }
    }
    .padding(.vertical, 5)
    .confirmationDialog(
      "Rotate \(credential.name)'s credential?", isPresented: $confirmingRotation,
      titleVisibility: .visible
    ) {
      Button("Rotate and disconnect provider", role: .destructive) {
        do {
          try server.rotateCredential(credential.id)
        } catch {
          reportError(error.localizedDescription)
        }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Other Pulse providers stay connected. This provider must reread its credential file.")
    }
    .confirmationDialog(
      "Revoke \(credential.name)?", isPresented: $confirmingRevocation,
      titleVisibility: .visible
    ) {
      Button("Revoke and disconnect provider", role: .destructive) {
        do {
          try server.revokeCredential(credential.id)
        } catch {
          reportError(error.localizedDescription)
        }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This removes the provider's credential file. Other providers are not affected.")
    }
  }

  private func permissionBinding(_ permission: PulseCredentialPermission) -> Binding<Bool> {
    Binding(
      get: { credential.permissions.contains(permission) },
      set: { allowed in
        var updated = credential.permissions
        if allowed { updated.insert(permission) } else { updated.remove(permission) }
        do {
          try server.setPermissions(updated, for: credential.id)
        } catch {
          reportError(error.localizedDescription)
        }
      })
  }
}

private struct PulseTrustedDestinationRow: View {
  let trust: PulseActionTrust
  let providerName: String?
  let revoke: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: trust.kind == .loopback ? "desktopcomputer" : "globe")
        .frame(width: 18)
        .foregroundStyle(trust.kind == .loopback ? .orange : .secondary)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(trust.canonicalOrigin).font(.caption.monospaced()).textSelection(.enabled)
        Text(
          providerName.map { "\($0) · \(trust.provider.sourceKey)" }
            ?? trust.provider.sourceKey
        )
        .font(.caption2)
        .foregroundStyle(.secondary)
        if trust.kind == .loopback {
          Text("Local loopback destination")
            .font(.caption2.weight(.medium))
            .foregroundStyle(.orange)
        }
      }
      Spacer()
      Button("Revoke", role: .destructive, action: revoke)
        .accessibilityLabel("Revoke trusted destination \(trust.displayHost)")
    }
    .padding(.vertical, 3)
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
          if let providerIdentifier = entry.providerIdentifier {
            Text(providerIdentifier).font(.caption.monospaced()).foregroundStyle(.tertiary)
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
    case .stale: "clock.badge.exclamationmark"
    case .kept: "pin.circle"
    case .suppressed: "line.3.horizontal.decrease.circle"
    case .rejected: "exclamationmark.triangle"
    case .evicted: "arrow.down.circle"
    }
  }

  private var color: Color {
    switch entry.result {
    case .rejected: .red
    case .suppressed, .evicted, .stale: .orange
    case .shown, .updated, .kept: .blue
    case .ended, .dismissed, .expired: .secondary
    }
  }
}
