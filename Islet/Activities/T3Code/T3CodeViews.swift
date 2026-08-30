import Defaults
import SwiftUI

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
    HStack(spacing: 3) {
      if let first = activity.agents.first {
        Image(systemName: first.phase.symbol).font(.system(size: 8))
      }
      Text("\(activity.agents.count)")
        .font(.caption.weight(.semibold)).monospacedDigit()
    }
    .foregroundStyle(activity.compactColor(for: appTheme))
    .accessibilityLabel("\(activity.agents.count) active T3 Code agents")
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
            ForEach(visibleEnvironments) { environment in
              environmentGroup(environment)
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

  private func environmentGroup(_ environment: T3EnvironmentSnapshot) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 5) {
        Image(systemName: environment.isLocal ? "laptopcomputer" : "network")
        Text(environment.label).lineLimit(1)
        Spacer()
        Circle().fill(connectionColor(environment.state)).frame(width: 5, height: 5)
      }
      .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)

      if environment.agents.isEmpty {
        HStack(spacing: 5) {
          Text(environment.state.label).font(.caption2).foregroundStyle(
            connectionColor(environment.state))
          if let detail = environment.state.detail {
            Text(detail).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
          }
          Spacer(minLength: 0)
          environmentActions(for: environment)
        }
        .padding(.vertical, 4).padding(.horizontal, 7)
        .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(0.06)))
      } else {
        ForEach(environment.agents) { agent in
          T3AgentRow(agent: agent)
        }
      }
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

  private func connectionColor(_ state: T3ConnectionState) -> Color {
    switch state {
    case .connected: .green
    case .needsPairing, .reconnecting: .orange
    case .offline, .credentialError: .red
    case .connecting: .secondary
    }
  }
}

private struct T3AgentRow: View {
  let agent: T3AgentSnapshot

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
  @Default(.t3CodeEnabled) private var enabled
  @Default(.t3RemoteEnvironments) private var profiles
  @State private var pairingLink = ""
  @State private var isPairing = false
  @State private var statusMessage: String?
  @State private var allowInsecureHTTP = false
  @State private var pendingRemoval: T3EnvironmentProfile?

  var body: some View {
    Section("T3 Code agents") {
      Toggle("Monitor T3 Code", isOn: $enabled)
      Text(
        "Shows active agents from each explicitly paired T3 Code machine. Islet cannot control agents, and pairing credentials stay in Keychain."
      )
      .font(.caption2).foregroundStyle(.secondary)
      machineRows
      HStack {
        SecureField("Paste a T3 Code pairing link", text: $pairingLink)
        Button(isPairing ? "Pairing…" : "Add") { pair() }
          .disabled(
            pairingLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isPairing)
      }
      if pairingUsesPlainHTTP {
        Toggle("Allow plain HTTP for this pairing", isOn: $allowInsecureHTTP)
          .font(.caption)
        Text(
          "Plain HTTP exposes the pairing credential. Use it only on a network you trust. HTTPS and Tailscale encrypt the connection."
        )
        .font(.caption2).foregroundStyle(.orange)
      }
      if let statusMessage {
        Text(statusMessage).font(.caption2)
          .foregroundStyle(
            statusMessage.hasPrefix("Added") || statusMessage.hasPrefix("Removed")
              ? .green : .orange)
      }
      Button("Reconnect now") { activity.reconnect() }.disabled(!enabled)
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

  private var pairingUsesPlainHTTP: Bool {
    let trimmed = pairingLink.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let link = URL(string: trimmed),
      let components = URLComponents(url: link, resolvingAgainstBaseURL: false)
    else { return false }
    if link.host?.lowercased() == "app.t3.codes", link.path == "/pair",
      let host = components.queryItems?.first(where: { $0.name == "host" })?.value
    {
      return URL(string: host)?.scheme?.lowercased() == "http"
    }
    return link.scheme?.lowercased() == "http"
  }

  @ViewBuilder private var machineRows: some View {
    if let local = activity.environments.first(where: \.isLocal) {
      machineRow(local)
    } else {
      LabeledContent("This Mac") {
        Text(enabled ? "Discovering…" : "Off").foregroundStyle(.secondary)
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
        Text(snapshot?.state.label ?? (profile.enabled ? "Connecting" : "Off"))
          .font(.caption).foregroundStyle(connectionColor(snapshot?.state))
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
      Text(snapshot.state.label).font(.caption).foregroundStyle(connectionColor(snapshot.state))
    } label: {
      Label(snapshot.label, systemImage: snapshot.isLocal ? "laptopcomputer" : "network")
    }
  }

  private func connectionColor(_ state: T3ConnectionState?) -> Color {
    switch state {
    case .some(.connected): .green
    case .some(.needsPairing), .some(.reconnecting): .orange
    case .some(.offline), .some(.credentialError): .red
    default: .secondary
    }
  }

  private func pair() {
    let link = pairingLink
    pairingLink = ""
    isPairing = true
    statusMessage = nil
    Task { @MainActor in
      defer { isPairing = false }
      do {
        try await activity.addRemote(
          pairingLink: link, allowInsecureHTTP: allowInsecureHTTP)
        allowInsecureHTTP = false
        statusMessage = "Added T3 Code machine."
        Haptics.perform(.levelChange)
      } catch {
        statusMessage = error.localizedDescription
      }
    }
  }

  private func remove(_ profile: T3EnvironmentProfile) {
    do {
      try activity.removeRemote(environmentID: profile.id)
      statusMessage = "Removed T3 Code machine."
    } catch {
      statusMessage = "Machine was not removed: \(error.localizedDescription)"
    }
  }
}
