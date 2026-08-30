import AppKit
import Defaults
import SwiftUI

enum OnboardingState {
  static let currentVersion = 1
  static var isComplete: Bool { Defaults[.onboardingVersion] >= currentVersion }
}

struct LegacyInstallMigrationResult {
  let importedPreferenceCount: Int
  let importedCredentialCount: Int

  var summary: String {
    let settings =
      importedPreferenceCount == 1 ? "1 setting" : "\(importedPreferenceCount) settings"
    let credentials =
      importedCredentialCount == 1
      ? "1 saved T3 Code pairing" : "\(importedCredentialCount) saved T3 Code pairings"
    return "Imported \(settings) and \(credentials)."
  }
}

enum LegacyInstallMigrationError: LocalizedError {
  case preferencesVerificationFailed

  var errorDescription: String? {
    switch self {
    case .preferencesVerificationFailed:
      "The imported settings could not be verified. The previous settings were left in place."
    }
  }
}

@MainActor
enum LegacyInstallMigrator {
  static let canonicalBundleIdentifier = "dev.islet"
  static let onboardingVersionKey = "onboardingVersion"

  static var currentBundleIdentifier: String {
    resolvedBundleIdentifier(Bundle.main.bundleIdentifier)
  }

  static var isAvailable: Bool {
    hasLegacyPreferences || T3CredentialStore.hasLegacyVault
  }

  static func merging(
    current: [String: Any], legacy: [[String: Any]]
  ) -> [String: Any] {
    var merged = current
    for domain in legacy {
      for (key, value) in domain
      where key != onboardingVersionKey && merged[key] == nil {
        merged[key] = value
      }
    }
    return merged
  }

  static func resolvedBundleIdentifier(_ bundleIdentifier: String?) -> String {
    bundleIdentifier ?? canonicalBundleIdentifier
  }

  static func migratePreferences(
    defaults: UserDefaults, currentBundleIdentifier: String,
    legacyDomains: [[String: Any]]
  ) throws -> Int {
    let current = defaults.persistentDomain(forName: currentBundleIdentifier) ?? [:]
    let merged = merging(current: current, legacy: legacyDomains)
    let imported = merged.filter { current[$0.key] == nil }

    // `setPersistentDomain` replaces the dictionary without producing the per-key changes that
    // Defaults publishers observe. Write each imported value through UserDefaults so the running
    // app immediately rebuilds displays, providers, login state and panel visibility as needed.
    for (key, value) in imported { defaults.set(value, forKey: key) }
    defaults.synchronize()

    let written = defaults.persistentDomain(forName: currentBundleIdentifier) ?? [:]
    guard NSDictionary(dictionary: written).isEqual(to: merged) else {
      throw LegacyInstallMigrationError.preferencesVerificationFailed
    }
    return imported.count
  }

  static func migrate(defaults: UserDefaults = .standard) throws -> LegacyInstallMigrationResult {
    let legacyDomains = LegacyInstallIdentifiers.applicationDomains.compactMap {
      defaults.persistentDomain(forName: $0)
    }
    // Startup can create these two canonical keys before first-run setup offers to import another
    // installation. They are provisional, not user choices, so they must not outrank the imported
    // visibility list. Restore them if verification fails.
    let replacesProvisionalEnablement =
      defaults.integer(forKey: onboardingVersionKey) < OnboardingState.currentVersion
      && defaults.object(forKey: ActivityEnablement.migrationVersionKey) != nil
    let provisionalDisabled = defaults.object(forKey: ActivityEnablement.disabledActivitiesKey)
    let provisionalVersion = defaults.object(forKey: ActivityEnablement.migrationVersionKey)
    if replacesProvisionalEnablement {
      defaults.removeObject(forKey: ActivityEnablement.disabledActivitiesKey)
      defaults.removeObject(forKey: ActivityEnablement.migrationVersionKey)
    }

    let importedPreferenceCount: Int
    do {
      importedPreferenceCount = try migratePreferences(
        defaults: defaults, currentBundleIdentifier: currentBundleIdentifier,
        legacyDomains: legacyDomains)
    } catch {
      if replacesProvisionalEnablement {
        if let provisionalDisabled {
          defaults.set(provisionalDisabled, forKey: ActivityEnablement.disabledActivitiesKey)
        }
        if let provisionalVersion {
          defaults.set(provisionalVersion, forKey: ActivityEnablement.migrationVersionKey)
        }
      }
      throw error
    }

    let importedCredentialCount = try T3CredentialStore.migrateLegacyVaults()

    for identifier in LegacyInstallIdentifiers.applicationDomains
    where defaults.persistentDomain(forName: identifier) != nil {
      defaults.removePersistentDomain(forName: identifier)
    }
    defaults.synchronize()
    NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)

    return LegacyInstallMigrationResult(
      importedPreferenceCount: importedPreferenceCount,
      importedCredentialCount: importedCredentialCount)
  }

  private static var hasLegacyPreferences: Bool {
    LegacyInstallIdentifiers.applicationDomains.contains {
      !(UserDefaults.standard.persistentDomain(forName: $0) ?? [:]).isEmpty
    }
  }
}

enum OnboardingPreferences {
  static let knownActivityIDs = Set(ActivityCatalog.defaultOrder)

  static func disabledActivities(
    preserving existing: [String], selected: Set<String>
  ) -> [String] {
    ActivityCatalog.defaultOrder.reduce(existing.filter { !knownActivityIDs.contains($0) }) {
      disabled, activityID in
      ActivityEnablement.updating(
        disabled, activityID: activityID, enabled: selected.contains(activityID))
    }
  }

  @MainActor
  static func apply(
    selectedActivities: Set<String>, remindersEnabled: Bool, bluetoothEventsEnabled: Bool
  ) {
    Defaults[.disabledActivities] = disabledActivities(
      preserving: Defaults[.disabledActivities], selected: selectedActivities)
    Defaults[.remindersEnabled] = remindersEnabled
    SystemEventBus.shared.setEnabled(bluetoothEventsEnabled, for: "bluetooth")
  }

  @MainActor
  static func isActivityEnabled(_ id: String) -> Bool {
    ActivityEnablement.isEnabled(id)
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

private enum LegacyMigrationState {
  case unavailable
  case available
  case migrating
  case migrated(String)
  case failed(String)

  var isMigrating: Bool {
    if case .migrating = self { return true }
    return false
  }
}

private struct OnboardingView: View {
  @Default(.appTheme) private var appTheme
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
  @State private var legacyMigrationState: LegacyMigrationState

  init() {
    _selectedActivities = State(
      initialValue: Set(
        ActivityCatalog.defaultOrder.filter { OnboardingPreferences.isActivityEnabled($0) }))
    _remindersEnabled = State(initialValue: Defaults[.remindersEnabled])
    _bluetoothEventsEnabled = State(
      initialValue: OnboardingState.isComplete
        && !Defaults[.disabledEventSources].contains("bluetooth"))
    _legacyMigrationState = State(
      initialValue: LegacyInstallMigrator.isAvailable ? .available : .unavailable)
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
    .tint(appTheme.accentColor)
    .environment(\.appTheme, appTheme)
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
    VStack(spacing: 18) {
      ZStack {
        RoundedRectangle(cornerRadius: 22).fill(.black)
        IsletNotchMarkShape().fill(.white).frame(width: 72, height: 64)
      }
      .frame(width: 118, height: 96)
      VStack(spacing: 8) {
        Text(
          "Islet puts timers, media controls and live system information around the MacBook notch."
        )
        .font(.title3.weight(.medium))
        .multilineTextAlignment(.center)
        Text("It has no Dock or menu-bar icon. Everything starts at the notch.")
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      }
      .frame(maxWidth: 500)
      legacyMigrationCard
    }
    .padding(28)
  }

  @ViewBuilder private var legacyMigrationCard: some View {
    switch legacyMigrationState {
    case .unavailable:
      EmptyView()
    case .available, .migrating:
      HStack(spacing: 14) {
        Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
          .font(.title2).foregroundStyle(.tint)
        VStack(alignment: .leading, spacing: 3) {
          Text("Previous Islet setup found").font(.body.weight(.medium))
          Text("Move its settings and saved T3 Code pairings into this installation.")
            .font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Button(legacyMigrationState.isMigrating ? "Importing…" : "Import") {
          migrateLegacyInstall()
        }
        .disabled(legacyMigrationState.isMigrating)
      }
      .padding(14)
      .frame(maxWidth: 540)
      .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    case .migrated(let summary):
      Label(summary, systemImage: "checkmark.circle.fill")
        .foregroundStyle(.green)
        .frame(maxWidth: 540, alignment: .leading)
    case .failed(let message):
      VStack(alignment: .leading, spacing: 8) {
        Label(message, systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.orange)
        Button("Try import again") { migrateLegacyInstall() }
      }
      .frame(maxWidth: 540, alignment: .leading)
    }
  }

  private var interactionPage: some View {
    Form {
      Section("How Islet opens") {
        Picker("At the notch", selection: $interactionMode) {
          Text("Push past the top edge").tag(InteractionMode.hover)
          Text("Click to open and pin").tag(InteractionMode.clickToPin)
        }
        .pickerStyle(.radioGroup)
        Text(
          interactionMode == .hover
            ? "Move the pointer into the notch, then keep pushing upward until Islet opens."
            : "Click the notch to open Islet. Click outside it to close."
        )
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
    Toggle(
      isOn: Binding(
        get: { selectedActivities.contains(activity.id) },
        set: { enabled in
          if enabled {
            selectedActivities.insert(activity.id)
          } else {
            selectedActivities.remove(activity.id)
          }
        }
      )
    ) {
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
        Text(
          "Islet asks only for access used by the activities you chose. You can skip any request."
        )
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
            title: "Reminders",
            detail: "Shows incomplete reminders on Home and lets you complete them.",
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
            detail:
              "Reads the app names macOS shows for iPhone Live Activities. Islet cannot read their contents.",
            status: permissions.diagnostics.accessibilityGranted ? "Allowed" : "Not allowed",
            actionTitle: permissions.diagnostics.accessibilityGranted ? nil : "Allow"
          ) {
            AccessibilityPermission.prompt()
          }
        }

        permissionRow(
          title: "Wi-Fi network names",
          detail:
            "Adds the network name to Wi-Fi connection alerts. The alert still works without access.",
          status: permissions.diagnostics.location.summary,
          actionTitle: permissions.diagnostics.location == .notDetermined ? "Allow" : nil
        ) {
          permissions.requestLocationAccess()
        }

        Toggle(isOn: $bluetoothEventsEnabled) {
          permissionLabel(
            title: "Bluetooth alerts",
            detail:
              "Shows when Bluetooth devices connect or disconnect. macOS may ask for access after setup.",
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
    title: String, detail: String, status: String, actionTitle: String?,
    action: @escaping () -> Void
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
      Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(
        horizontal: false, vertical: true)
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

  private func migrateLegacyInstall() {
    legacyMigrationState = .migrating
    do {
      let result = try LegacyInstallMigrator.migrate()
      // Startup may already have migrated this bundle before the user chose to import another
      // installation. Fold the just-imported legacy flags into the canonical list once more.
      ActivityEnablement.migrateLegacyPreferencesIfNeeded(force: true)
      selectedActivities = Set(
        ActivityCatalog.defaultOrder.filter { OnboardingPreferences.isActivityEnabled($0) })
      remindersEnabled = Defaults[.remindersEnabled]
      bluetoothEventsEnabled = !Defaults[.disabledEventSources].contains("bluetooth")
      legacyMigrationState = .migrated(result.summary)
    } catch {
      legacyMigrationState = .failed(error.localizedDescription)
    }
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
