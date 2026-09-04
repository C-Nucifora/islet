import AppKit
import Defaults
import SwiftUI

/// A connection status is intentionally rendered with both a symbol and a label. Colour is a
/// useful secondary cue, but it is not sufficient for users with colour-vision differences or
/// increased contrast enabled.
struct T3ConnectionIndicatorView: View {
  enum Tone: Equatable {
    case secondary
    case primary
    case green
    case orange
    case yellow
    case red
  }

  let state: T3ConnectionState
  var isStale = false
  @Environment(\.colorSchemeContrast) private var colorSchemeContrast
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    Label {
      HStack(spacing: 3) {
        Text(state.label)
        if isStale { Text("Stale").foregroundStyle(.secondary) }
      }
    } icon: {
      Image(systemName: state.icon)
    }
    .foregroundStyle(color)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityLabel)
  }

  private var accessibilityLabel: String {
    Self.accessibilityLabel(for: state, isStale: isStale)
  }

  static func accessibilityLabel(for state: T3ConnectionState, isStale: Bool) -> String {
    isStale ? "\(state.accessibilityLabel), showing the last update" : state.accessibilityLabel
  }

  private var color: Color {
    switch Self.tone(
      for: state, increasedContrast: colorSchemeContrast == .increased,
      colorScheme: colorScheme)
    {
    case .secondary: Color.secondary
    case .primary: Color.primary
    case .green: Color.green
    case .orange: Color.orange
    case .yellow: Color.yellow
    case .red: Color.red
    }
  }

  static func tone(
    for state: T3ConnectionState, increasedContrast: Bool, colorScheme: ColorScheme = .light
  ) -> Tone {
    switch state.semanticColor {
    case .neutral:
      guard increasedContrast else { return .secondary }
      switch colorScheme {
      case .light, .dark: return .primary
      @unknown default: return .primary
      }
    case .positive: return .green
    case .warning: return increasedContrast ? .yellow : .orange
    case .negative: return .red
    }
  }
}

struct T3ConnectAccountPresentation: Equatable {
  struct Action: Equatable, Identifiable {
    enum Kind: Hashable {
      case link
      case cancel
      case retry
      case retryLoad
      case signOut
      case retryCleanup
    }

    let kind: Kind
    let title: String
    let isDestructive: Bool

    var id: Kind { kind }

    init(kind: Kind, title: String, isDestructive: Bool = false) {
      self.kind = kind
      self.title = title
      self.isDestructive = isDestructive
    }
  }

  let statusText: String
  let detailText: String
  let identity: String?
  let lastSync: Date?
  let isBusy: Bool
  private(set) var actions: [Action]
  let errorMessages: [String]

  init(
    state: T3ConnectAccountState,
    lastLinkError: String?,
    lastCleanupError: String?,
    monitoringEnabled: Bool = true,
    remotePollingActive: Bool = true
  ) {
    let stateError: String?
    let canRetryCleanup: Bool
    switch state {
    case .signedOut:
      statusText = "Not linked"
      detailText = "Link an account to find T3 Code environments available through T3 Connect."
      identity = nil
      lastSync = nil
      isBusy = false
      actions = [.init(kind: .link, title: "Link T3 Connect account")]
      stateError = nil
      canRetryCleanup = true
    case .linking(let previous):
      statusText = previous == nil ? "Linking account" : "Relinking account"
      detailText =
        previous == nil
        ? "Waiting for browser…"
        : "Waiting for browser… Your current account stays linked unless this attempt succeeds."
      identity = Self.normalizedIdentity(previous?.displayIdentity)
      lastSync = nil
      isBusy = true
      actions = [.init(kind: .cancel, title: "Cancel")]
      stateError = nil
      canRetryCleanup = false
    case .linked(let account, let sync):
      statusText = "Linked"
      detailText =
        !monitoringEnabled
        ? "Monitoring is off. Your linked account remains saved."
        : !remotePollingActive
          ? "Cloud polling is paused by Energy mode. Your linked account remains saved."
          : sync == nil
            ? "Waiting for the first environment sync."
            : "T3 Connect is monitoring your available environments."
      identity = Self.normalizedIdentity(account.displayIdentity)
      lastSync = sync
      isBusy = false
      actions = [.init(kind: .signOut, title: "Sign out", isDestructive: true)]
      stateError = nil
      canRetryCleanup = false
    case .needsSignIn(let account, let error):
      statusText = "Sign-in required"
      detailText =
        account == nil
        ? "Remove the unreadable saved credentials before linking an account again."
        : "Link the account again to restore T3 Connect access."
      identity = Self.normalizedIdentity(account?.displayIdentity)
      lastSync = nil
      isBusy = false
      actions =
        account == nil
        ? [
          .init(kind: .retryLoad, title: "Try loading again"),
          .init(kind: .signOut, title: "Clean up saved credentials", isDestructive: true),
        ]
        : [
          .init(kind: .link, title: "Link again"),
          .init(kind: .signOut, title: "Sign out", isDestructive: true),
        ]
      stateError = error
      canRetryCleanup = false
    case .unavailable(let account, let error):
      statusText = "T3 Connect unavailable"
      detailText =
        !monitoringEnabled
        ? "Monitoring is off. Your linked account remains saved."
        : !remotePollingActive
          ? "Cloud polling is paused by Energy mode. Your linked account remains saved."
          : "Your last known environments stay visible while T3 Connect is unavailable."
      identity = Self.normalizedIdentity(account.displayIdentity)
      lastSync = nil
      isBusy = false
      actions = [
        .init(kind: .retry, title: "Retry"),
        .init(kind: .signOut, title: "Sign out", isDestructive: true),
      ]
      stateError = error
      canRetryCleanup = false
    }

    var errors: [String] = []
    let cleanupError = canRetryCleanup ? lastCleanupError : nil
    for error in [stateError, lastLinkError, cleanupError].compactMap({ $0 })
    where !error.isEmpty && !errors.contains(error) {
      errors.append(error)
    }
    errorMessages = errors

    if cleanupError != nil {
      actions = [.init(kind: .retryCleanup, title: "Retry cleanup")]
    }
  }

  private static func normalizedIdentity(_ identity: String?) -> String? {
    guard let identity else { return nil }
    let collapsed = identity.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    guard !collapsed.isEmpty else { return nil }
    guard collapsed.count > 80 else { return collapsed }
    return String(collapsed.prefix(79)) + "…"
  }
}

struct T3EnvironmentRowPresentation: Equatable {
  enum Control: Equatable {
    case enable
    case remove
  }

  let label: String
  let systemImage: String
  let sourceText: String
  let stateText: String
  let stateAccessibilityText: String
  let isPaused: Bool
  let isStale: Bool
  let controls: [Control]

  var accessibilityLabel: String {
    let freshness = isStale ? ", showing the last update" : ""
    return "\(label), \(sourceText), \(stateAccessibilityText)\(freshness)"
  }

  init(snapshot: T3EnvironmentSnapshot, remotePollingActive: Bool = true) {
    let isPaused = snapshot.source != .local && !remotePollingActive
    self.init(
      label: snapshot.label, source: snapshot.source,
      stateText: isPaused ? "Paused" : snapshot.state.label, isPaused: isPaused,
      stateAccessibilityText: isPaused ? "Paused" : snapshot.state.accessibilityLabel,
      isStale: snapshot.isStale)
  }

  init(
    label: String,
    source: T3EnvironmentSource,
    stateText: String,
    isPaused: Bool = false,
    stateAccessibilityText: String? = nil,
    isStale: Bool = false
  ) {
    self.label = label
    self.stateText = stateText
    self.stateAccessibilityText = stateAccessibilityText ?? stateText
    self.isPaused = isPaused
    self.isStale = isStale
    switch source {
    case .local:
      systemImage = "laptopcomputer"
      sourceText = "This Mac"
      controls = []
    case .connect:
      systemImage = "cloud.fill"
      sourceText = "T3 Connect"
      controls = []
    case .manual:
      systemImage = "network"
      sourceText = "Manually paired"
      controls = [.enable, .remove]
    }
  }

  init(
    manualLabel: String,
    profileEnabled: Bool,
    monitoringEnabled: Bool,
    remotePollingActive: Bool = true,
    state: T3ConnectionState?,
    isStale: Bool = false
  ) {
    let isPaused = monitoringEnabled && profileEnabled && !remotePollingActive
    self.init(
      label: manualLabel,
      source: .manual,
      stateText: !monitoringEnabled || !profileEnabled
        ? "Off"
        : isPaused ? "Paused" : (state?.label ?? "Connecting"),
      isPaused: isPaused,
      stateAccessibilityText: !monitoringEnabled || !profileEnabled
        ? "Off"
        : isPaused ? "Paused" : (state?.accessibilityLabel ?? "Connecting"),
      isStale: isStale)
  }
}

struct T3CompactLeadingView: View {
  @ObservedObject var activity: T3CodeActivity
  @Environment(\.appTheme) private var appTheme

  var body: some View {
    Image(systemName: "terminal.fill")
      .foregroundStyle(activity.compactColor(for: appTheme))
      .font(.caption2)
      .accessibilityHidden(true)
  }
}

struct T3CompactStatusView: View {
  @ObservedObject var activity: T3CodeActivity
  @Environment(\.appTheme) private var appTheme

  var body: some View {
    let presentation = activity.compactPresentation
    HStack(spacing: 3) {
      if let phase = presentation.leadingPhase {
        Image(systemName: phase.symbol).font(.system(size: 8))
      }
      if presentation.staleAgentCount > 0 {
        Image(systemName: "exclamationmark.triangle.fill")
          .font(.system(size: 8))
          .foregroundStyle(.orange)
      }
      Text("\(presentation.displayedAgentCount)")
        .font(.caption.weight(.semibold)).monospacedDigit()
    }
    .foregroundStyle(activity.compactColor(for: appTheme))
    .accessibilityLabel(presentation.accessibilityLabel)
  }
}

struct T3CodeExpandedView: View {
  @ObservedObject var activity: T3CodeActivity
  @Default(.t3RemoteEnvironments) private var profiles

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Label("T3 Code", systemImage: "terminal.fill")
          .font(.caption.weight(.semibold))
        Spacer()
        Text("\(activity.agents.count) agent\(activity.agents.count == 1 ? "" : "s")")
          .font(.caption2).foregroundStyle(.secondary)
      }

      if visibleEnvironments.isEmpty {
        VStack(spacing: 5) {
          Image(systemName: "checkmark.circle").font(.title3).foregroundStyle(.green)
          Text("No active agents").font(.caption)
          Text(connectionSummary).font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView(.vertical, showsIndicators: false) {
          VStack(spacing: 7) {
            if activity.agents.isEmpty {
              VStack(spacing: 3) {
                Text("No active agents").font(.caption)
                Text(connectionSummary).font(.system(size: 9)).foregroundStyle(.secondary)
              }
              .frame(maxWidth: .infinity)
              .padding(.bottom, 2)
            }
            ForEach(expandedRows) { row in
              switch row {
              case .agent(let agent, let environmentLabel):
                T3AgentRow(agent: agent, environmentLabel: environmentLabel, activity: activity)
              case .environment(let environment):
                environmentGroup(environment)
              }
            }
          }
        }
      }
    }
    .foregroundStyle(.white)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  private var connectionSummary: String {
    let connected = T3CodeActivity.connectedEnvironmentCount(
      in: visibleEnvironments, remotePollingActive: activity.remotePollingActive)
    return connected == 0
      ? "Open T3 Code, link T3 Connect, or add a machine in Settings."
      : "Connected to \(connected) machine\(connected == 1 ? "" : "s")"
  }

  private var visibleEnvironments: [T3EnvironmentSnapshot] {
    T3CodeActivity.visibleEnvironments(snapshots: activity.environments, profiles: profiles)
  }

  private var expandedRows: [T3ExpandedRow] {
    T3CodeActivity.expandedRows(
      snapshots: activity.environments, profiles: profiles,
      remotePollingActive: activity.remotePollingActive)
  }

  private func environmentGroup(_ environment: T3EnvironmentSnapshot) -> some View {
    let row = T3EnvironmentRowPresentation(
      snapshot: environment, remotePollingActive: activity.remotePollingActive)
    return VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 5) {
        Image(systemName: row.systemImage)
        Text(row.label).lineLimit(1)
        Spacer()
        if row.isPaused {
          Text(row.stateText)
        } else {
          T3ConnectionIndicatorView(state: environment.state, isStale: environment.isStale)
        }
      }
      .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
      .accessibilityElement(children: .combine)
      .accessibilityLabel(row.accessibilityLabel)

      HStack(spacing: 5) {
        if row.isPaused {
          Text(row.stateText).font(.caption2).foregroundStyle(.secondary)
        } else {
          T3ConnectionIndicatorView(state: environment.state, isStale: environment.isStale)
            .font(.caption2)
          if let detail = environment.state.detail {
            Text(detail).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
          }
        }
        Spacer(minLength: 0)
        if !row.isPaused { environmentActions(for: environment) }
      }
      .padding(.vertical, 4).padding(.horizontal, 7)
      .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(0.06)))
    }
  }

  @ViewBuilder private func environmentActions(for environment: T3EnvironmentSnapshot) -> some View
  {
    let actions = T3CodeActivity.environmentActions(
      for: environment.state, isLocal: environment.isLocal)
    HStack(spacing: 5) {
      if actions.contains(.pair) {
        Button("Pair") { SettingsOpener.open(destination: .integrations) }
      }
      if actions.contains(.retry) {
        Button("Retry") { activity.reconnect() }
      }
      if actions.contains(.openSettings) {
        Button("Open settings") { SettingsOpener.open(destination: .integrations) }
      }
      if actions.contains(.disable), let profile = remoteProfile(for: environment) {
        Button("Disable") { activity.setRemoteEnabled(false, environmentID: profile.id) }
      }
    }
    .buttonStyle(.borderless)
    .font(.system(size: 9, weight: .semibold))
  }

  private func remoteProfile(for environment: T3EnvironmentSnapshot) -> T3EnvironmentProfile? {
    profiles.first {
      environment.id
        == T3CodeActivity.remoteSnapshotID(
          environmentID: $0.id, baseURL: $0.baseURL)
    }
  }

}

private struct T3AgentRow: View {
  let agent: T3AgentSnapshot
  let environmentLabel: String?
  @ObservedObject var activity: T3CodeActivity

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: agent.phase.symbol)
        .font(.caption2).foregroundStyle(phaseColor).frame(width: 14)
      VStack(alignment: .leading, spacing: 1) {
        Text(agent.title).font(.caption.weight(.medium)).lineLimit(1)
        HStack(spacing: 4) {
          Text(agent.providerInstance).font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(Capsule().fill(.white.opacity(0.09)))
          Text(agent.model).font(.system(size: 9)).lineLimit(1)
          Text("·").foregroundStyle(.tertiary)
          Text(agent.branch.map { "\(agent.project) · \($0)" } ?? agent.project)
            .font(.system(size: 9)).lineLimit(1)
        }
        .foregroundStyle(.secondary)
        if let environmentLabel {
          Text(environmentLabel).font(.system(size: 9)).foregroundStyle(.tertiary).lineLimit(1)
        }
        if let step = agent.planStep {
          HStack(spacing: 4) {
            if let completed = agent.completedPlanSteps, let total = agent.totalPlanSteps {
              Text("\(completed)/\(total)").monospacedDigit()
            }
            Text(step).lineLimit(1)
          }
          .font(.system(size: 9)).foregroundStyle(.secondary)
        }
        if case .reconnect(let reason) = activity.sessionAvailability(for: agent) {
          Text(reason).font(.system(size: 9)).foregroundStyle(.orange).lineLimit(2)
        }
      }
      Spacer(minLength: 4)
      VStack(alignment: .trailing, spacing: 3) {
        Text(agent.phase.label)
          .font(.system(size: 9, weight: .semibold)).foregroundStyle(phaseColor)
          .lineLimit(1)
        if case .reconnect = activity.sessionAvailability(for: agent) {
          Button("Reconnect") { activity.reconnect() }
            .buttonStyle(.link).font(.system(size: 9, weight: .semibold))
        }
        if T3SessionActionPolicy.safeWorkspacePath(agent.workspacePath) != nil {
          Menu {
            Button("Copy workspace path") { activity.copyWorkspacePath(agent) }
            if agent.isLocal {
              Button("Reveal workspace") { activity.revealWorkspace(agent) }
            }
          } label: {
            Image(systemName: "ellipsis.circle").font(.caption2)
          }
          .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
          .accessibilityLabel("More actions for \(agent.title)")
        }
      }
    }
    .padding(.vertical, 4).padding(.horizontal, 7)
    .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(0.06)))
    .accessibilityElement(children: .combine)
    .accessibilityLabel(agent.accessibilityLabel)
  }

  private var phaseColor: Color {
    switch agent.phase {
    case .needsInput, .needsApproval: .orange
    case .working, .monitoring: .purple
    case .finished: .green
    case .failed: .red
    }
  }
}

struct T3SettingsSection: View {
  @ObservedObject var activity: T3CodeActivity
  @ObservedObject private var coordinator: T3ConnectCoordinator
  @Default(.disabledActivities) private var disabledActivities
  @Default(.t3RemoteEnvironments) private var profiles
  @State private var pairingForm = T3PairingFormState()
  @FocusState private var focusedField: T3PairingFormField?
  @State private var machineStatusMessage: String?
  @State private var pendingRemoval: T3EnvironmentProfile?
  @State private var pendingAccountAction: T3ConnectAccountPresentation.Action.Kind?
  @State private var confirmingSignOut = false

  init(activity: T3CodeActivity) {
    self.activity = activity
    _coordinator = ObservedObject(wrappedValue: activity.connectCoordinator)
  }

  private var activityEnabled: Binding<Bool> {
    Binding(
      get: {
        ActivityEnablement.isEnabled("t3Code", disabledActivities: disabledActivities)
      },
      set: { enabled in
        disabledActivities = ActivityEnablement.updating(
          disabledActivities, activityID: "t3Code", enabled: enabled)
      })
  }

  private var isActivityEnabled: Bool {
    ActivityEnablement.isEnabled("t3Code", disabledActivities: disabledActivities)
  }

  var body: some View {
    Group {
      agentsSection
      connectSection
      manualPairingSection
    }
  }

  private var accountPresentation: T3ConnectAccountPresentation {
    T3ConnectAccountPresentation(
      state: coordinator.state,
      lastLinkError: coordinator.lastLinkError,
      lastCleanupError: coordinator.lastCleanupError,
      monitoringEnabled: isActivityEnabled,
      remotePollingActive: activity.remotePollingActive)
  }

  private var agentsSection: some View {
    Section("T3 Code agents") {
      Toggle("Monitor T3 Code", isOn: activityEnabled)
      Text(
        "Shows active agents from T3 Code on this Mac, linked T3 Connect environments and manually paired machines. Islet can monitor agents but cannot control them."
      )
      .font(.caption2)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      machineRows
      if let machineStatusMessage {
        Text(machineStatusMessage)
          .font(.caption2)
          .foregroundStyle(
            machineStatusMessage.hasPrefix("Removed") ? .green : .orange
          )
          .fixedSize(horizontal: false, vertical: true)
      }
      Button("Reconnect now") { activity.reconnect() }.disabled(!isActivityEnabled)
    }
    .confirmationDialog(
      "Remove this T3 Code machine?",
      isPresented: Binding(
        get: { pendingRemoval != nil },
        set: { if !$0 { pendingRemoval = nil } }),
      titleVisibility: .visible
    ) {
      if let profile = pendingRemoval {
        Button("Remove \(profile.label)", role: .destructive) {
          pendingRemoval = nil
          remove(profile)
        }
      }
      Button("Cancel", role: .cancel) { pendingRemoval = nil }
    } message: {
      Text("Its saved pairing credential will also be removed from Keychain.")
    }
  }

  private var connectSection: some View {
    let presentation = accountPresentation
    return Section("T3 Connect") {
      LabeledContent {
        HStack(spacing: 6) {
          if presentation.isBusy {
            ProgressView().controlSize(.small)
          }
          Text(presentation.statusText)
        }
      } label: {
        Label("Account", systemImage: "person.crop.circle")
      }
      if let identity = presentation.identity {
        LabeledContent("Signed in as") {
          Text(identity).lineLimit(1).truncationMode(.tail)
        }
        .accessibilityLabel("Signed in as \(identity)")
      }
      if let lastSync = presentation.lastSync {
        LabeledContent("Last synced") {
          Text(lastSync, style: .relative)
        }
      }
      Text(presentation.detailText)
        .font(.caption2)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      ForEach(Array(presentation.errorMessages.enumerated()), id: \.offset) { _, message in
        Label(message, systemImage: "exclamationmark.triangle.fill")
          .font(.caption2)
          .foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityLabel("T3 Connect error: \(message)")
      }
      HStack {
        ForEach(presentation.actions) { action in
          accountButton(action)
        }
      }
    }
    .confirmationDialog(
      "Sign out of T3 Connect?", isPresented: $confirmingSignOut,
      titleVisibility: .visible
    ) {
      Button("Sign out", role: .destructive) { signOut() }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "Stops monitoring T3 Connect environments and removes this account's OAuth and proof keys. This Mac and manually paired machines stay configured."
      )
    }
  }

  private var manualPairingSection: some View {
    Section("Manual pairing") {
      Text("Pair a machine directly when it is not available through T3 Connect.")
        .font(.caption2)
        .foregroundStyle(.secondary)
      if hasBlockedSavedHTTPProfile {
        Text(
          "Saved plain-HTTP machines are blocked by this version. Pair them again with HTTPS, then remove the old entries."
        )
        .font(.caption2).foregroundStyle(.orange)
      }
      HStack {
        SecureField(
          "Paste a T3 Code pairing link",
          text: Binding(
            get: { pairingForm.pairingLink },
            set: { pairingForm.pairingLink = $0 })
        )
        .focused($focusedField, equals: .pairingLink)
        Button(pairingForm.isPairing ? "Pairing…" : "Add") { pair() }
          .disabled(
            pairingForm.pairingLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              || pairingForm.isPairing || pairingIsBlockedRemoteHTTP)
      }
      if pairingUsesPlainRemoteHTTP, pairingRemoteHTTPIsApproved {
        Toggle(
          "Allow plain HTTP for this pairing",
          isOn: Binding(
            get: { pairingForm.allowInsecureHTTP },
            set: { pairingForm.allowInsecureHTTP = $0 })
        )
        .font(.caption)
        Text(
          "Plain HTTP exposes the pairing credential. This build approves only this exact address. Use it only on a network you trust."
        )
        .font(.caption2).foregroundStyle(.orange)
      } else if pairingUsesPlainRemoteHTTP {
        Text(
          "This build blocks plain HTTP for that address. Use an HTTPS pairing link. An administrator can approve an exact HTTP address in a reviewed build."
        )
        .font(.caption2).foregroundStyle(.orange)
      } else {
        Text("Manual pairing credentials stay in Keychain.")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      if let statusMessage = pairingForm.statusMessage {
        Text(statusMessage).font(.caption2)
          .foregroundStyle(
            statusMessage.hasPrefix("Added") ? .green : .orange
          )
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var pairingEndpointURL: URL? {
    let trimmed = pairingForm.pairingLink.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let link = URL(string: trimmed),
      let components = URLComponents(url: link, resolvingAgainstBaseURL: false)
    else { return nil }
    if link.host?.lowercased() == "app.t3.codes", link.path == "/pair",
      let host = components.queryItems?.first(where: { $0.name == "host" })?.value
    {
      return URL(string: host)
    }
    return link
  }

  private var pairingUsesPlainRemoteHTTP: Bool {
    guard let url = pairingEndpointURL else { return false }
    return url.scheme?.lowercased() == "http" && !T3Endpoint.isLoopbackHost(url.host)
  }

  private var pairingRemoteHTTPIsApproved: Bool {
    guard let url = pairingEndpointURL else { return false }
    return T3TransportPolicy.app.permitsInsecureRemoteHTTP(url)
  }

  private var pairingIsBlockedRemoteHTTP: Bool {
    pairingUsesPlainRemoteHTTP
      && (!pairingRemoteHTTPIsApproved || !pairingForm.allowInsecureHTTP)
  }

  private var hasBlockedSavedHTTPProfile: Bool {
    profiles.contains { profile in
      guard let url = URL(string: profile.baseURL) else { return false }
      return T3TransportPolicy.app.requiresHTTPSMigration(url)
    }
  }

  @ViewBuilder private var machineRows: some View {
    if let local = activity.environments.first(where: { $0.source == .local }) {
      environmentRow(local)
    } else if !activity.hasLocalObservation {
      LabeledContent {
        Text(isActivityEnabled ? "Discovering…" : "Off").foregroundStyle(.secondary)
      } label: {
        Label("This Mac", systemImage: "laptopcomputer")
      }
      .accessibilityElement(children: .combine)
      .accessibilityLabel("This Mac, \(isActivityEnabled ? "Discovering" : "Off")")
    }
    ForEach(activity.environments.filter { $0.source == .connect }) { snapshot in
      environmentRow(snapshot)
    }
    ForEach(profiles) { profile in
      let snapshot = activity.manualConnectionSnapshot(
        environmentID: profile.id, baseURL: profile.baseURL)
      let state = snapshot?.state
      let row = T3EnvironmentRowPresentation(
        manualLabel: profile.label, profileEnabled: profile.enabled,
        monitoringEnabled: isActivityEnabled, remotePollingActive: activity.remotePollingActive,
        state: state, isStale: snapshot?.isStale ?? false)
      HStack {
        Toggle(
          isOn: Binding(
            get: { profile.enabled },
            set: { activity.setRemoteEnabled($0, environmentID: profile.id) })
        ) {
          VStack(alignment: .leading, spacing: 2) {
            Label(row.label, systemImage: row.systemImage)
            Text(row.sourceText).font(.caption2).foregroundStyle(.secondary)
          }
        }
        Spacer()
        if !isActivityEnabled || !profile.enabled {
          Text("Off").font(.caption).foregroundStyle(.secondary)
        } else if row.isPaused {
          Text(row.stateText).font(.caption).foregroundStyle(.secondary)
        } else {
          T3ConnectionIndicatorView(
            state: state ?? .connecting, isStale: snapshot?.isStale ?? false
          ).font(.caption)
        }
        Button(role: .destructive) {
          pendingRemoval = profile
        } label: {
          Image(systemName: "trash")
        }
        .buttonStyle(.borderless).accessibilityLabel("Remove \(profile.label)")
      }
    }
  }

  private func environmentRow(_ snapshot: T3EnvironmentSnapshot) -> some View {
    let row = T3EnvironmentRowPresentation(
      snapshot: snapshot, remotePollingActive: activity.remotePollingActive)
    return LabeledContent {
      if row.isPaused {
        Text(row.stateText).font(.caption).foregroundStyle(.secondary)
      } else {
        T3ConnectionIndicatorView(state: snapshot.state, isStale: snapshot.isStale)
          .font(.caption)
      }
    } label: {
      VStack(alignment: .leading, spacing: 2) {
        Label(row.label, systemImage: row.systemImage)
        Text(row.sourceText).font(.caption2).foregroundStyle(.secondary)
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(row.accessibilityLabel)
  }

  private func pair() {
    guard let submission = pairingForm.begin() else { return }
    Task { @MainActor in
      do {
        try await activity.addRemote(
          pairingLink: submission.pairingLink, allowInsecureHTTP: submission.allowInsecureHTTP)
        if pairingForm.finish(submission, result: .success) == .succeeded {
          focusedField = nil
          Haptics.perform(.levelChange)
        }
      } catch {
        let completion = pairingForm.finish(
          submission, result: .failure(error.localizedDescription))
        focusFailedPairingLinkIfNeeded(
          completion == .failed ? submission.pairingLink : nil)
      }
    }
  }

  private func focusFailedPairingLinkIfNeeded(_ failedPairingLink: String?) {
    guard let failedPairingLink, pairingForm.focusedField == .pairingLink,
      pairingForm.pairingLink.trimmingCharacters(in: .whitespacesAndNewlines) == failedPairingLink
    else {
      focusedField = nil
      return
    }
    focusedField = .pairingLink
    Task { @MainActor in
      // Focus state takes effect on the next update. Select after it has made this secure field
      // the responder so a retry can replace the rejected link without exposing its credential.
      await Task.yield()
      guard focusedField == .pairingLink,
        pairingForm.pairingLink.trimmingCharacters(in: .whitespacesAndNewlines)
          == failedPairingLink,
        let text = NSApp.keyWindow?.firstResponder as? NSText
      else { return }
      text.selectAll(nil)
    }
  }

  private func remove(_ profile: T3EnvironmentProfile) {
    do {
      try activity.removeRemote(environmentID: profile.id)
      machineStatusMessage = "Removed T3 Code machine."
    } catch {
      machineStatusMessage = "Machine was not removed: \(error.localizedDescription)"
    }
  }

  @ViewBuilder private func accountButton(_ action: T3ConnectAccountPresentation.Action)
    -> some View
  {
    Button(role: action.isDestructive ? .destructive : nil) {
      performAccountAction(action.kind)
    } label: {
      Text(action.title)
    }
    .disabled(
      (pendingAccountAction != nil && action.kind != .cancel)
        || (action.kind == .retry && (!isActivityEnabled || !activity.remotePollingActive)))
  }

  private func performAccountAction(_ action: T3ConnectAccountPresentation.Action.Kind) {
    switch action {
    case .link:
      guard pendingAccountAction == nil else { return }
      pendingAccountAction = .link
      Task { @MainActor in
        await coordinator.link()
        pendingAccountAction = nil
      }
    case .cancel:
      coordinator.cancelLink()
      pendingAccountAction = nil
    case .retry:
      guard pendingAccountAction == nil else { return }
      pendingAccountAction = .retry
      activity.reconnect()
      pendingAccountAction = nil
    case .retryLoad:
      guard pendingAccountAction == nil else { return }
      pendingAccountAction = .retryLoad
      Task { @MainActor in
        await coordinator.loadAccount()
        pendingAccountAction = nil
      }
    case .signOut:
      confirmingSignOut = true
    case .retryCleanup:
      signOut()
    }
  }

  private func signOut() {
    guard pendingAccountAction == nil else { return }
    pendingAccountAction = .signOut
    Task { @MainActor in
      defer { pendingAccountAction = nil }
      do {
        try await coordinator.signOut()
      } catch {
        // The coordinator publishes cleanup failures so the retry remains available.
      }
    }
  }
}
