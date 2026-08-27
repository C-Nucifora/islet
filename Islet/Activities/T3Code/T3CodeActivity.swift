import Combine
import Defaults
import SwiftUI

@MainActor
final class T3CodeActivity: NotchActivity, ObservableObject {
  let id = "t3Code"
  let priority = ActivityPriority.agent
  let tabIcon = "terminal.fill"
  let preferredExpandedHeight = Metrics.tallExpandedHeight

  @Published private(set) var environments: [T3EnvironmentSnapshot] = []
  private(set) var activationDate: Date?

  private var monitorTasks: [String: Task<Void, Never>] = [:]
  private var cancellables: Set<AnyCancellable> = []

  var agents: [T3AgentSnapshot] {
    environments.flatMap(\.agents).sorted {
      if $0.phase.rank != $1.phase.rank { return $0.phase.rank < $1.phase.rank }
      return $0.updatedAt > $1.updatedAt
    }
  }

  var isActive: Bool { Defaults[.t3CodeEnabled] && !agents.isEmpty }

  func start() {
    Defaults.publisher(.t3CodeEnabled)
      .sink { [weak self] _ in Task { @MainActor in self?.restartMonitors() } }
      .store(in: &cancellables)
    Defaults.publisher(.t3RemoteEnvironments)
      .sink { [weak self] _ in Task { @MainActor in self?.restartMonitors() } }
      .store(in: &cancellables)
    restartMonitors()
  }

  func reconnect() { restartMonitors() }

  func addRemote(pairingLink: String, allowInsecureHTTP: Bool = false) async throws {
    let target = try T3PairingTarget.parse(
      pairingLink, allowInsecureRemoteHTTP: allowInsecureHTTP)
    let unauthenticated = T3Client(endpoint: target.endpoint, token: nil)
    let descriptor = try await unauthenticated.fetchDescriptor()
    let exchange = try await unauthenticated.exchange(pairingCredential: target.credential)
    let authenticated = T3Client(endpoint: target.endpoint, token: exchange.accessToken)
    _ = try await authenticated.fetchShell()
    try T3CredentialStore.save(exchange.accessToken, environmentID: descriptor.environmentId)

    var profiles = Defaults[.t3RemoteEnvironments]
    let profile = T3EnvironmentProfile(
      id: descriptor.environmentId,
      label: descriptor.label,
      baseURL: target.endpoint.baseURL.absoluteString)
    if let index = profiles.firstIndex(where: { $0.id == descriptor.environmentId }) {
      profiles[index] = profile
    } else {
      profiles.append(profile)
    }
    Defaults[.t3RemoteEnvironments] = profiles
  }

  func setRemoteEnabled(_ enabled: Bool, environmentID: String) {
    var profiles = Defaults[.t3RemoteEnvironments]
    guard let index = profiles.firstIndex(where: { $0.id == environmentID }) else { return }
    profiles[index].enabled = enabled
    Defaults[.t3RemoteEnvironments] = profiles
  }

  func removeRemote(environmentID: String) {
    var profiles = Defaults[.t3RemoteEnvironments]
    profiles.removeAll { $0.id == environmentID }
    Defaults[.t3RemoteEnvironments] = profiles
    T3CredentialStore.delete(environmentID: environmentID)
  }

  var compactLeading: AnyView {
    AnyView(
      Image(systemName: "terminal.fill")
        .foregroundStyle(compactColor)
        .font(.caption2)
        .accessibilityHidden(true))
  }

  var compactTrailing: AnyView {
    AnyView(T3CompactStatusView(activity: self))
  }

  var expandedView: AnyView {
    AnyView(T3CodeExpandedView(activity: self))
  }

  var compactColor: Color {
    if agents.contains(where: { $0.phase == .needsInput || $0.phase == .needsApproval }) {
      return .orange
    }
    if agents.contains(where: { $0.phase == .failed }) { return .red }
    if agents.contains(where: { $0.phase == .working || $0.phase == .monitoring }) {
      return .purple
    }
    return .green
  }

  private func restartMonitors() {
    monitorTasks.values.forEach { $0.cancel() }
    monitorTasks.removeAll()
    environments.removeAll()
    activationDate = nil
    guard Defaults[.t3CodeEnabled] else { return }

    monitorTasks["local"] = Task { [weak self] in await self?.monitorLocal() }
    for profile in Defaults[.t3RemoteEnvironments] where profile.enabled {
      monitorTasks[profile.id] = Task { [weak self] in await self?.monitorRemote(profile) }
    }
  }

  private func monitorLocal() async {
    while !Task.isCancelled {
      let endpoint = await T3LocalDiscovery.endpoint()
      do {
        let descriptor = try await T3Client(endpoint: endpoint, token: nil).fetchDescriptor()
        var token = T3CredentialStore.load(environmentID: descriptor.environmentId)
        if token == nil {
          let pairingCredential = try await T3LocalPairingMinting.mint()
          token = try await T3Client(endpoint: endpoint, token: nil)
            .exchange(pairingCredential: pairingCredential).accessToken
          try T3CredentialStore.save(token!, environmentID: descriptor.environmentId)
        }
        try await poll(
          descriptor: descriptor, endpoint: endpoint, token: token, isLocal: true)
      } catch is CancellationError {
        return
      } catch T3ClientError.unauthorized {
        if let descriptor = try? await T3Client(endpoint: endpoint, token: nil).fetchDescriptor() {
          T3CredentialStore.delete(environmentID: descriptor.environmentId)
        }
      } catch {
        guard !Task.isCancelled else { return }
        upsert(
          T3EnvironmentSnapshot(
            id: "local", label: "This Mac", baseURL: endpoint.baseURL.absoluteString,
            isLocal: true, platform: nil, serverVersion: nil,
            state: .offline(error.localizedDescription), agents: []))
      }
      try? await Task.sleep(for: .seconds(3))
    }
  }

  private func monitorRemote(_ profile: T3EnvironmentProfile) async {
    guard let url = URL(string: profile.baseURL), let endpoint = try? T3Endpoint(
      url, allowInsecureRemoteHTTP: true)
    else { return }
    while !Task.isCancelled {
      do {
        let descriptor = try await T3Client(endpoint: endpoint, token: nil).fetchDescriptor()
        guard let token = T3CredentialStore.load(environmentID: profile.id) else {
          upsert(snapshot(profile, descriptor: descriptor, state: .needsPairing, agents: []))
          try? await Task.sleep(for: .seconds(10))
          continue
        }
        try await poll(
          descriptor: descriptor, endpoint: endpoint, token: token, isLocal: false,
          fallbackLabel: profile.label)
      } catch is CancellationError {
        return
      } catch T3ClientError.unauthorized {
        upsert(snapshot(profile, descriptor: nil, state: .needsPairing, agents: []))
      } catch {
        guard !Task.isCancelled else { return }
        upsert(
          snapshot(
            profile, descriptor: nil, state: .offline(error.localizedDescription), agents: []))
      }
      try? await Task.sleep(for: .seconds(5))
    }
  }

  private func poll(
    descriptor: T3EnvironmentDescriptor,
    endpoint: T3Endpoint,
    token: String?,
    isLocal: Bool,
    fallbackLabel: String? = nil
  ) async throws {
    let client = T3Client(endpoint: endpoint, token: token)
    while !Task.isCancelled {
      let shell = try await client.fetchShell()
      let active = T3AgentSnapshot.activeAgents(
        in: shell, environmentID: descriptor.environmentId)
      let platform = [descriptor.platform?.os, descriptor.platform?.arch]
        .compactMap { $0 }.joined(separator: " · ")
      upsert(
        T3EnvironmentSnapshot(
          id: descriptor.environmentId,
          label: descriptor.label.isEmpty ? (fallbackLabel ?? "T3 Code") : descriptor.label,
          baseURL: endpoint.baseURL.absoluteString,
          isLocal: isLocal,
          platform: platform.isEmpty ? nil : platform,
          serverVersion: descriptor.serverVersion,
          state: .connected,
          agents: active))
      let busy = active.contains { [.working, .monitoring, .needsInput, .needsApproval].contains($0.phase) }
      try await Task.sleep(for: .milliseconds(busy ? 1_500 : 4_000))
    }
  }

  private func snapshot(
    _ profile: T3EnvironmentProfile,
    descriptor: T3EnvironmentDescriptor?,
    state: T3ConnectionState,
    agents: [T3AgentSnapshot]
  ) -> T3EnvironmentSnapshot {
    let platform = [descriptor?.platform?.os, descriptor?.platform?.arch]
      .compactMap { $0 }.joined(separator: " · ")
    return T3EnvironmentSnapshot(
      id: profile.id,
      label: descriptor?.label ?? profile.label,
      baseURL: profile.baseURL,
      isLocal: false,
      platform: platform.isEmpty ? nil : platform,
      serverVersion: descriptor?.serverVersion,
      state: state,
      agents: agents)
  }

  private func upsert(_ snapshot: T3EnvironmentSnapshot) {
    // Once the real local environment id is known, replace the provisional "local" row.
    if snapshot.isLocal { environments.removeAll { $0.id == "local" && $0.id != snapshot.id } }
    if let index = environments.firstIndex(where: { $0.id == snapshot.id }) {
      environments[index] = snapshot
    } else {
      environments.append(snapshot)
    }
    environments.sort {
      if $0.isLocal != $1.isLocal { return $0.isLocal }
      return $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
    }
    activationDate = agents.isEmpty ? nil : (activationDate ?? Date())
  }
}
