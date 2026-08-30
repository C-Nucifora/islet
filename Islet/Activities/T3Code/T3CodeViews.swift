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
                T3AgentRow(agent: agent, environmentLabel: environmentLabel)
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
    let connected = visibleEnvironments.filter { $0.state == .connected }.count
    return connected == 0
      ? "Open T3 Code or add a machine in Settings"
      : "Connected to \(connected) machine\(connected == 1 ? "" : "s")"
  }

  private var visibleEnvironments: [T3EnvironmentSnapshot] {
    T3CodeActivity.visibleEnvironments(snapshots: activity.environments, profiles: profiles)
  }

  private var expandedRows: [T3ExpandedRow] {
    T3CodeActivity.expandedRows(snapshots: activity.environments, profiles: profiles)
  }

  private func environmentGroup(_ environment: T3EnvironmentSnapshot) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 5) {
        Image(systemName: environment.isLocal ? "laptopcomputer" : "network")
        Text(environment.label).lineLimit(1)
        Spacer()
        T3ConnectionIndicatorView(state: environment.state, isStale: environment.isStale)
      }
      .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)

      HStack(spacing: 5) {
        T3ConnectionIndicatorView(state: environment.state, isStale: environment.isStale)
          .font(.caption2)
        if let detail = environment.state.detail {
          Text(detail).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
        }
        Spacer(minLength: 0)
        environmentActions(for: environment)
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
      }
      Spacer(minLength: 4)
      Text(agent.phase.label)
        .font(.system(size: 9, weight: .semibold)).foregroundStyle(phaseColor)
        .lineLimit(1)
    }
    .padding(.vertical, 4).padding(.horizontal, 7)
    .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(0.06)))
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
  @Default(.disabledActivities) private var disabledActivities
  @Default(.t3RemoteEnvironments) private var profiles
  @State private var pairingForm = T3PairingFormState()
  @FocusState private var focusedField: T3PairingFormField?
  @State private var pendingRemoval: T3EnvironmentProfile?

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
    Section("T3 Code agents") {
      Toggle("Monitor T3 Code", isOn: activityEnabled)
      Text(
        "Shows active agents from each explicitly paired T3 Code machine. Islet cannot control agents, and pairing credentials stay in Keychain."
      )
      .font(.caption2).foregroundStyle(.secondary)
      machineRows
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
      }
      if let statusMessage = pairingForm.statusMessage {
        Text(statusMessage).font(.caption2)
          .foregroundStyle(
            statusMessage.hasPrefix("Added") || statusMessage.hasPrefix("Removed")
              ? .green : .orange)
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
    if let local = activity.environments.first(where: \.isLocal) {
      machineRow(local)
    } else {
      LabeledContent("This Mac") {
        Text(isActivityEnabled ? "Discovering…" : "Off").foregroundStyle(.secondary)
      }
    }
    ForEach(profiles) { profile in
      let snapshot = activity.environments.first {
        $0.id
          == T3CodeActivity.remoteSnapshotID(
            environmentID: profile.id, baseURL: profile.baseURL)
      }
      HStack {
        Toggle(
          profile.label,
          isOn: Binding(
            get: { profile.enabled },
            set: { activity.setRemoteEnabled($0, environmentID: profile.id) }))
        Spacer()
        if let snapshot {
          T3ConnectionIndicatorView(state: snapshot.state, isStale: snapshot.isStale)
            .font(.caption)
        } else if profile.enabled {
          T3ConnectionIndicatorView(state: .connecting).font(.caption)
        } else {
          Text("Off").font(.caption).foregroundStyle(.secondary)
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

  private func machineRow(_ snapshot: T3EnvironmentSnapshot) -> some View {
    LabeledContent {
      T3ConnectionIndicatorView(state: snapshot.state, isStale: snapshot.isStale)
        .font(.caption)
    } label: {
      Label(snapshot.label, systemImage: snapshot.isLocal ? "laptopcomputer" : "network")
    }
  }

  private func pair() {
    guard let submission = pairingForm.begin() else { return }
    Task { @MainActor in
      do {
        try await activity.addRemote(
          pairingLink: submission.pairingLink, allowInsecureHTTP: submission.allowInsecureHTTP)
        if pairingForm.finish(submission, result: .success) == .succeeded {
          Haptics.perform(.levelChange)
        }
      } catch {
        _ = pairingForm.finish(submission, result: .failure(error.localizedDescription))
      }
      focusFailedPairingLinkIfNeeded()
    }
  }

  private func focusFailedPairingLinkIfNeeded() {
    guard pairingForm.focusedField == .pairingLink else {
      focusedField = nil
      return
    }
    focusedField = .pairingLink
    Task { @MainActor in
      // Focus state takes effect on the next update. Select after it has made this secure field
      // the responder so a retry can replace the rejected link without exposing its credential.
      await Task.yield()
      guard focusedField == .pairingLink,
        let text = NSApp.keyWindow?.firstResponder as? NSText
      else { return }
      text.selectAll(nil)
    }
  }

  private func remove(_ profile: T3EnvironmentProfile) {
    do {
      try activity.removeRemote(environmentID: profile.id)
      pairingForm.statusMessage = "Removed T3 Code machine."
    } catch {
      pairingForm.statusMessage = "Machine was not removed: \(error.localizedDescription)"
    }
  }
}
