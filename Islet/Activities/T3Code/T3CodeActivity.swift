import AppKit
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
  private var workspaceCancellables: Set<AnyCancellable> = []
  private var isMonitoring = false
  private var isSystemSuspended = false
  private var lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled

  var agents: [T3AgentSnapshot] {
    environments.flatMap(\.agents).sorted {
      if $0.phase.rank != $1.phase.rank { return $0.phase.rank < $1.phase.rank }
      return $0.updatedAt > $1.updatedAt
    }
  }

  var isActive: Bool { Defaults[.t3CodeEnabled] && !agents.isEmpty }

  func start() {
    guard !isMonitoring else { return }
    isMonitoring = true
    lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
    Defaults.publisher(.t3RemoteEnvironments)
      .dropFirst()
      .sink { [weak self] _ in Task { @MainActor in self?.restartMonitors() } }
      .store(in: &cancellables)
    Defaults.publisher(.energyMode)
      .dropFirst()
      .sink { [weak self] _ in
        Task { @MainActor in self?.restartMonitors(clearSnapshots: false) }
      }
      .store(in: &cancellables)
    NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in
        guard let self else { return }
        let next = ProcessInfo.processInfo.isLowPowerModeEnabled
        guard next != self.lowPowerMode else { return }
        self.lowPowerMode = next
        self.restartMonitors(clearSnapshots: false)
      }
      .store(in: &cancellables)

    let workspace = NSWorkspace.shared.notificationCenter
    workspace.publisher(for: NSWorkspace.willSleepNotification)
      .merge(with: workspace.publisher(for: NSWorkspace.sessionDidResignActiveNotification))
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in self?.setSystemSuspended(true) }
      .store(in: &workspaceCancellables)
    workspace.publisher(for: NSWorkspace.didWakeNotification)
      .merge(with: workspace.publisher(for: NSWorkspace.sessionDidBecomeActiveNotification))
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in self?.setSystemSuspended(false) }
      .store(in: &workspaceCancellables)
    restartMonitors()
  }

  func stop() {
    guard isMonitoring else { return }
    isMonitoring = false
    cancelMonitorTasks()
    cancellables.removeAll()
    workspaceCancellables.removeAll()
    // A session-resign notification may have been the last event before the feature was disabled.
    // Do not carry that stale suspension into a later start after the Mac has already unlocked —
    // there would be no new didBecomeActive notification to wake the restarted monitor.
    isSystemSuspended = false
    environments = []
    activationDate = nil
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

  private func restartMonitors(clearSnapshots: Bool = true) {
    cancelMonitorTasks()
    if clearSnapshots {
      environments.removeAll()
      activationDate = nil
    }
    guard isMonitoring, Defaults[.t3CodeEnabled], !isSystemSuspended else { return }

    monitorTasks["local"] = Task { [weak self] in await self?.monitorLocal() }
    // Remote polling is optional work and can keep radios awake. Leave the last snapshot visible
    // in Low Power Mode and reconnect when normal power policy resumes.
    if energyPolicy.allowsRemotePolling {
      for profile in Self.enabledRemoteProfiles(Defaults[.t3RemoteEnvironments]) {
        // Namespace the key: an imported/corrupt remote id of "local" must not overwrite the only
        // handle capable of cancelling the local monitor.
        monitorTasks["remote:\(profile.id)"] = Task { [weak self] in
          await self?.monitorRemote(profile)
        }
      }
    }
  }

  private func cancelMonitorTasks() {
    for task in monitorTasks.values { task.cancel() }
    monitorTasks.removeAll()
  }

  private func setSystemSuspended(_ suspended: Bool) {
    guard suspended != isSystemSuspended else { return }
    isSystemSuspended = suspended
    restartMonitors(clearSnapshots: false)
  }

  private func monitorLocal() async {
    var failures = 0
    while !Task.isCancelled {
      let endpoint = await T3LocalDiscovery.endpoint()
      do {
        let descriptor = try await T3Client(endpoint: endpoint, token: nil).fetchDescriptor()
        var token = T3CredentialStore.load(
          environmentID: descriptor.environmentId, migrateLegacy: false)
        if token == nil {
          let pairingCredential = try await T3LocalPairingMinting.mint()
          token = try await T3Client(endpoint: endpoint, token: nil)
            .exchange(pairingCredential: pairingCredential).accessToken
          try T3CredentialStore.save(token!, environmentID: descriptor.environmentId)
        }
        try await poll(
          descriptor: descriptor, endpoint: endpoint, token: token, isLocal: true,
          onConnected: { failures = 0 })
      } catch is CancellationError {
        return
      } catch T3ClientError.unauthorized {
        failures += 1
        if let descriptor = try? await T3Client(endpoint: endpoint, token: nil).fetchDescriptor() {
          T3CredentialStore.delete(environmentID: descriptor.environmentId)
        }
      } catch {
        guard !Task.isCancelled else { return }
        failures += 1
        upsert(
          T3EnvironmentSnapshot(
            id: "local", label: "This Mac", baseURL: endpoint.baseURL.absoluteString,
            isLocal: true, platform: nil, serverVersion: nil,
            state: .offline(error.localizedDescription), agents: []))
      }
      let delay = Self.reconnectDelay(failureCount: failures, remote: false)
      try? await Task.sleep(for: .seconds(Self.jitter(delay)))
    }
  }

  private func monitorRemote(_ profile: T3EnvironmentProfile) async {
    guard
      let url = URL(string: profile.baseURL),
      let endpoint = try? T3Endpoint(url, allowInsecureRemoteHTTP: true)
    else { return }
    var failures = 0
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
          fallbackLabel: profile.label, onConnected: { failures = 0 })
      } catch is CancellationError {
        return
      } catch T3ClientError.unauthorized {
        failures += 1
        upsert(snapshot(profile, descriptor: nil, state: .needsPairing, agents: []))
      } catch {
        guard !Task.isCancelled else { return }
        failures += 1
        upsert(
          snapshot(
            profile, descriptor: nil, state: .offline(error.localizedDescription), agents: []))
      }
      let delay = Self.reconnectDelay(failureCount: failures, remote: true)
      try? await Task.sleep(for: .seconds(Self.jitter(delay)))
    }
  }

  private func poll(
    descriptor: T3EnvironmentDescriptor,
    endpoint: T3Endpoint,
    token: String?,
    isLocal: Bool,
    fallbackLabel: String? = nil,
    onConnected: () -> Void = {}
  ) async throws {
    let client = T3Client(endpoint: endpoint, token: token)
    while !Task.isCancelled {
      let shell = try await client.fetchShell()
      // A successful response ends the outage. Without this callback, a later unrelated failure
      // resumed at the old exponential-backoff ceiling even after days of healthy polling.
      onConnected()
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
      let busy = active.contains {
        [.working, .monitoring, .needsInput, .needsApproval].contains($0.phase)
      }
      let expanded = ScreenManager.shared.viewModel?.state.isExpanded ?? false
      let interval = Self.pollInterval(
        busy: busy, expanded: expanded, lowPowerMode: lowPowerMode,
        energyMode: Defaults[.energyMode])
      try await Task.sleep(for: .seconds(Self.jitter(interval)))
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
    let next = Self.upserting(snapshot, into: environments)
    guard next != environments else { return }
    environments = next
    activationDate = agents.isEmpty ? nil : (activationDate ?? Date())
  }

  nonisolated static func upserting(
    _ snapshot: T3EnvironmentSnapshot, into current: [T3EnvironmentSnapshot]
  ) -> [T3EnvironmentSnapshot] {
    var next = current
    // Once the real local environment id is known, replace the provisional "local" row.
    if snapshot.isLocal { next.removeAll { $0.id == "local" && $0.id != snapshot.id } }
    if let index = next.firstIndex(where: { $0.id == snapshot.id }) {
      next[index] = snapshot
    } else {
      next.append(snapshot)
    }
    next.sort {
      if $0.isLocal != $1.isLocal { return $0.isLocal }
      return $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
    }
    return next
  }

  nonisolated static func pollInterval(
    busy: Bool, expanded: Bool, lowPowerMode: Bool, energyMode: EnergyMode = .automatic
  ) -> TimeInterval {
    EnergyPolicy(mode: energyMode, systemLowPowerMode: lowPowerMode)
      .t3PollInterval(busy: busy, expanded: expanded)
  }

  /// Defaults can be hand-edited or carried across versions. Preserve first occurrence order but
  /// never launch two infinite polling tasks for the same environment id: storing the second under
  /// the same dictionary key loses the first cancellation handle while the first task keeps alive.
  nonisolated static func enabledRemoteProfiles(
    _ profiles: [T3EnvironmentProfile]
  ) -> [T3EnvironmentProfile] {
    var seen: Set<String> = []
    return profiles.filter { $0.enabled && seen.insert($0.id).inserted }
  }

  nonisolated static func reconnectDelay(failureCount: Int, remote: Bool) -> TimeInterval {
    let floor: TimeInterval = remote ? 5 : 3
    let ceiling: TimeInterval = remote ? 5 * 60 : 60
    return min(floor * pow(2, Double(max(0, failureCount - 1))), ceiling)
  }

  nonisolated private static func jitter(_ interval: TimeInterval) -> TimeInterval {
    interval * Double.random(in: 0.9...1.1)
  }

  private var energyPolicy: EnergyPolicy {
    EnergyPolicy(mode: Defaults[.energyMode], systemLowPowerMode: lowPowerMode)
  }
}
