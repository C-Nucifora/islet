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
  @Published private(set) var lastCredentialError: String?
  private(set) var activationDate: Date?

  private var credentialErrors: [String: String] = [:]
  private var environmentCandidates: [T3EnvironmentSnapshot] = []
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

  var isActive: Bool { !agents.isEmpty }

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
    environmentCandidates = []
    environments = []
    activationDate = nil
  }

  func reconnect() { restartMonitors() }

  func addRemote(pairingLink: String, allowInsecureHTTP: Bool = false) async throws {
    let target = try T3PairingTarget.parse(
      pairingLink, allowInsecureRemoteHTTP: allowInsecureHTTP)
    if target.endpoint.isLoopback, !T3LocalDiscovery.isTrusted(target.endpoint) {
      throw T3ClientError.untrustedLocalEndpoint
    }
    let unauthenticated = T3Client(endpoint: target.endpoint, token: nil)
    let descriptor = try await unauthenticated.fetchDescriptor()
    let isLocal = target.endpoint.isLoopback
    if !isLocal,
      let local = environmentCandidates.first(where: {
        $0.source == .local && $0.id != Self.provisionalLocalSnapshotID
      }),
      local.logicalEnvironmentID == descriptor.environmentId
    {
      throw T3ClientError.environmentIdentityConflict
    }
    let incomingCredentialID =
      isLocal
      ? Self.localCredentialID(
        environmentID: descriptor.environmentId,
        baseURL: target.endpoint.baseURL.absoluteString)
      : Self.remoteCredentialID(
        environmentID: descriptor.environmentId,
        baseURL: target.endpoint.baseURL.absoluteString)
    if let existing = Defaults[.t3RemoteEnvironments].first(where: {
      $0.id == descriptor.environmentId
        && (isLocal
          || Self.remoteCredentialID(environmentID: $0.id, baseURL: $0.baseURL)
            != incomingCredentialID)
    }) {
      Log.app.error(
        "Rejected duplicate T3 environment id from \(target.endpoint.baseURL.absoluteString, privacy: .public); already paired with \(existing.baseURL, privacy: .public)"
      )
      throw T3ClientError.environmentIdentityConflict
    }
    if isLocal, !T3LocalDiscovery.isTrusted(target.endpoint) {
      throw T3ClientError.untrustedLocalEndpoint
    }
    let exchange = try await unauthenticated.exchange(pairingCredential: target.credential)
    let authenticated = T3Client(endpoint: target.endpoint, token: exchange.accessToken)
    _ = try await authenticated.fetchShell()
    let credentialKey = isLocal ? "local" : Self.remoteMonitorKey(descriptor.environmentId)
    do {
      if isLocal {
        try T3CredentialStore.saveLocal(
          exchange.accessToken, credentialID: incomingCredentialID,
          environmentID: descriptor.environmentId)
      } else {
        try T3CredentialStore.save(
          exchange.accessToken,
          credentialID: incomingCredentialID)
      }
      updateCredentialError(nil, for: credentialKey)
    } catch {
      updateCredentialError(error, for: credentialKey)
      throw error
    }

    if isLocal {
      restartMonitors()
      return
    }

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

  func removeRemote(environmentID: String) throws {
    var profiles = Defaults[.t3RemoteEnvironments]
    guard let profile = profiles.first(where: { $0.id == environmentID }) else { return }
    let credentialKey = Self.remoteMonitorKey(profile.id)
    do {
      try T3CredentialStore.delete(credentialIDs: [
        Self.remoteCredentialID(environmentID: profile.id, baseURL: profile.baseURL),
        profile.id,
      ])
      updateCredentialError(nil, for: credentialKey)
    } catch {
      updateCredentialError(error, for: credentialKey)
      throw error
    }
    profiles.removeAll { $0.id == environmentID }
    Defaults[.t3RemoteEnvironments] = profiles
  }

  var compactLeading: AnyView {
    AnyView(T3CompactLeadingView(activity: self))
  }

  var compactTrailing: AnyView {
    AnyView(T3CompactStatusView(activity: self))
  }

  var expandedView: AnyView {
    AnyView(T3CodeExpandedView(activity: self))
  }

  func compactColor(for theme: AppTheme) -> Color {
    if agents.contains(where: { $0.phase == .needsInput || $0.phase == .needsApproval }) {
      return .orange
    }
    if agents.contains(where: { $0.phase == .failed }) { return .red }
    return theme.color(for: .t3Code)
  }

  private func restartMonitors(clearSnapshots: Bool = true) {
    cancelMonitorTasks()
    if clearSnapshots {
      environmentCandidates.removeAll()
      environments.removeAll()
      activationDate = nil
    }
    guard isMonitoring, !isSystemSuspended else { return }

    monitorTasks["local"] = Task { [weak self] in await self?.monitorLocal() }
    // Remote polling is optional work and can keep radios awake. Leave the last snapshot visible
    // in Low Power Mode and reconnect when normal power policy resumes.
    if energyPolicy.allowsRemotePolling {
      for profile in Self.enabledRemoteProfiles(Defaults[.t3RemoteEnvironments]) {
        // Namespace the key: an imported/corrupt remote id of "local" must not overwrite the only
        // handle capable of cancelling the local monitor.
        monitorTasks[Self.remoteMonitorKey(profile.id)] = Task { [weak self] in
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
      guard let endpoint = await T3LocalDiscovery.endpoint() else {
        failures += 1
        let error = T3ClientError.untrustedLocalEndpoint
        updateCredentialError(error, for: "local")
        upsert(
          T3EnvironmentSnapshot(
            id: Self.provisionalLocalSnapshotID,
            logicalEnvironmentID: Self.provisionalLocalSnapshotID, source: .local,
            label: "This Mac", baseURL: "http://127.0.0.1/", platform: nil,
            serverVersion: nil,
            state: .offline(error.localizedDescription), agents: []))
        let delay = Self.reconnectDelay(failureCount: failures, remote: false)
        try? await Task.sleep(for: .seconds(Self.jitter(delay)))
        continue
      }
      do {
        let descriptor = try await T3Client(endpoint: endpoint, token: nil).fetchDescriptor()
        let credentialID = Self.localCredentialID(
          environmentID: descriptor.environmentId, baseURL: endpoint.baseURL.absoluteString)
        guard let token = try T3CredentialStore.load(credentialID: credentialID) else {
          try Task.checkCancellation()
          updateCredentialError(nil, for: "local")
          upsert(
            T3EnvironmentSnapshot(
              id: Self.localSnapshotID(descriptor.environmentId),
              logicalEnvironmentID: descriptor.environmentId, source: .local,
              label: descriptor.label.isEmpty ? "This Mac" : descriptor.label,
              baseURL: endpoint.baseURL.absoluteString, platform: nil,
              serverVersion: descriptor.serverVersion,
              state: .needsPairing, agents: []))
          try? await Task.sleep(for: .seconds(10))
          continue
        }
        updateCredentialError(nil, for: "local")
        try await poll(
          descriptor: descriptor, endpoint: endpoint, token: token, source: .local,
          onConnected: { failures = 0 })
      } catch is CancellationError {
        return
      } catch T3ClientError.unauthorized {
        guard !Task.isCancelled else { return }
        failures += 1
        if let descriptor = try? await T3Client(endpoint: endpoint, token: nil).fetchDescriptor() {
          do {
            try T3CredentialStore.delete(
              credentialID: Self.localCredentialID(
                environmentID: descriptor.environmentId,
                baseURL: endpoint.baseURL.absoluteString))
            updateCredentialError(nil, for: "local")
          } catch {
            updateCredentialError(error, for: "local")
            Log.app.error(
              "Could not remove rejected local T3 credential: \(error.localizedDescription)")
          }
        }
      } catch let error as T3CredentialStoreError {
        guard !Task.isCancelled else { return }
        updateCredentialError(error, for: "local")
        failures += 1
        upsert(
          T3EnvironmentSnapshot(
            id: "local", label: "This Mac", baseURL: endpoint.baseURL.absoluteString,
            isLocal: true, platform: nil, serverVersion: nil,
            state: .credentialError(error.localizedDescription), agents: []))
      } catch {
        guard !Task.isCancelled else { return }
        updateCredentialError(error, for: "local")
        failures += 1
        upsert(
          T3EnvironmentSnapshot(
            id: Self.provisionalLocalSnapshotID,
            logicalEnvironmentID: Self.provisionalLocalSnapshotID, source: .local,
            label: "This Mac", baseURL: endpoint.baseURL.absoluteString, platform: nil,
            serverVersion: nil,
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
    else {
      upsert(snapshot(profile, descriptor: nil, state: .offline("Invalid endpoint"), agents: []))
      return
    }
    var failures = 0
    let monitorKey = Self.remoteMonitorKey(profile.id)
    while !Task.isCancelled {
      do {
        let descriptor = try await T3Client(endpoint: endpoint, token: nil).fetchDescriptor()
        try Task.checkCancellation()
        guard descriptor.environmentId == profile.id else {
          throw T3ClientError.environmentIdentityConflict
        }
        let credentialID = Self.remoteCredentialID(
          environmentID: profile.id, baseURL: profile.baseURL)
        // ID-only legacy credentials have no trustworthy endpoint origin. Never send one to a
        // saved remote; the user must pair that endpoint again to establish a scoped credential.
        let token = try T3CredentialStore.load(credentialID: credentialID)
        updateCredentialError(nil, for: monitorKey)
        guard let token else {
          try Task.checkCancellation()
          upsert(snapshot(profile, descriptor: descriptor, state: .needsPairing, agents: []))
          try? await Task.sleep(for: .seconds(10))
          continue
        }
        try await poll(
          descriptor: descriptor, endpoint: endpoint, token: token, source: .manual,
          fallbackLabel: profile.label, onConnected: { failures = 0 })
      } catch is CancellationError {
        return
      } catch T3ClientError.unauthorized {
        guard !Task.isCancelled else { return }
        failures += 1
        upsert(snapshot(profile, descriptor: nil, state: .needsPairing, agents: []))
      } catch let error as T3CredentialStoreError {
        guard !Task.isCancelled else { return }
        failures += 1
        updateCredentialError(error, for: monitorKey)
        upsert(
          snapshot(
            profile, descriptor: nil, state: .credentialError(error.localizedDescription),
            agents: []))
      } catch {
        guard !Task.isCancelled else { return }
        updateCredentialError(error, for: monitorKey)
        failures += 1
        let state: T3ConnectionState =
          failures == 1
          ? .offline(error.localizedDescription)
          : .reconnecting(error.localizedDescription)
        upsert(
          snapshot(
            profile, descriptor: nil, state: state, agents: []))
      }
      let delay = Self.reconnectDelay(failureCount: failures, remote: true)
      try? await Task.sleep(for: .seconds(Self.jitter(delay)))
    }
  }

  private func poll(
    descriptor: T3EnvironmentDescriptor,
    endpoint: T3Endpoint,
    token: String?,
    source: T3EnvironmentSource,
    fallbackLabel: String? = nil,
    onConnected: () -> Void = {}
  ) async throws {
    let client = T3Client(endpoint: endpoint, token: token)
    while !Task.isCancelled {
      if source == .local, !T3LocalDiscovery.isTrusted(endpoint) {
        throw T3ClientError.untrustedLocalEndpoint
      }
      let shell = try await client.fetchShell()
      try Task.checkCancellation()
      // A successful response ends the outage. Without this callback, a later unrelated failure
      // resumed at the old exponential-backoff ceiling even after days of healthy polling.
      onConnected()
      let snapshot = Self.connectedSnapshot(
        descriptor: descriptor, endpoint: endpoint, source: source, shell: shell,
        fallbackLabel: fallbackLabel)
      upsert(snapshot)
      let busy = snapshot.agents.contains {
        [.working, .monitoring, .needsInput, .needsApproval].contains($0.phase)
      }
      let expanded = ScreenManager.shared.viewModel?.state.isExpanded ?? false
      let interval = Self.pollInterval(
        busy: busy, expanded: expanded, lowPowerMode: lowPowerMode,
        energyMode: Defaults[.energyMode])
      try await Task.sleep(for: .seconds(Self.jitter(interval)))
    }
  }

  nonisolated static func connectedSnapshot(
    descriptor: T3EnvironmentDescriptor,
    endpoint: T3Endpoint,
    source: T3EnvironmentSource,
    shell: T3ShellSnapshot,
    fallbackLabel: String? = nil,
    now: Date = Date()
  ) -> T3EnvironmentSnapshot {
    let snapshotID: String
    switch source {
    case .local:
      snapshotID = localSnapshotID(descriptor.environmentId)
    case .connect:
      snapshotID = connectSnapshotID(descriptor.environmentId)
    case .manual:
      snapshotID = remoteSnapshotID(
        environmentID: descriptor.environmentId,
        baseURL: endpoint.baseURL.absoluteString)
    }
    let agents = T3AgentSnapshot.activeAgents(
      in: shell, logicalEnvironmentID: descriptor.environmentId, now: now)
    let platform = [descriptor.platform?.os, descriptor.platform?.arch]
      .compactMap { $0 }.joined(separator: " · ")
    return T3EnvironmentSnapshot(
      id: snapshotID, logicalEnvironmentID: descriptor.environmentId, source: source,
      label: descriptor.label.isEmpty ? (fallbackLabel ?? "T3 Code") : descriptor.label,
      baseURL: endpoint.baseURL.absoluteString,
      platform: platform.isEmpty ? nil : platform,
      serverVersion: descriptor.serverVersion,
      state: .connected,
      agents: agents)
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
      id: Self.remoteSnapshotID(environmentID: profile.id, baseURL: profile.baseURL),
      logicalEnvironmentID: profile.id, source: .manual,
      label: descriptor?.label ?? profile.label,
      baseURL: profile.baseURL,
      platform: platform.isEmpty ? nil : platform,
      serverVersion: descriptor?.serverVersion,
      state: state,
      agents: agents)
  }

  private func upsert(_ snapshot: T3EnvironmentSnapshot) {
    let next = Self.upserting(snapshot, into: environmentCandidates)
    guard next != environmentCandidates else { return }
    environmentCandidates = next
    publishResolvedCandidates()
  }

  func removeCandidates(from source: T3EnvironmentSource) {
    let next = Self.removingCandidates(from: environmentCandidates, source: source)
    guard next != environmentCandidates else { return }
    environmentCandidates = next
    publishResolvedCandidates()
  }

  private func publishResolvedCandidates() {
    let next = T3EnvironmentResolver.resolve(environmentCandidates)
    guard next != environments else { return }
    environments = next
    activationDate = agents.isEmpty ? nil : (activationDate ?? Date())
  }

  nonisolated static func upserting(
    _ snapshot: T3EnvironmentSnapshot, into current: [T3EnvironmentSnapshot]
  ) -> [T3EnvironmentSnapshot] {
    var next = current
    // There is one local discovery task, so its newest observation replaces any older local
    // identity. This removes the provisional row after discovery and a stale identified row when
    // the process later disappears.
    if snapshot.source == .local {
      next.removeAll { $0.source == .local && $0.id != snapshot.id }
    }
    if let index = next.firstIndex(where: { $0.id == snapshot.id }) {
      next[index] = snapshot
    } else {
      next.append(snapshot)
    }
    return next
  }

  nonisolated static func removingCandidates(
    from current: [T3EnvironmentSnapshot], source: T3EnvironmentSource
  ) -> [T3EnvironmentSnapshot] {
    current.filter { $0.source != source }
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

  /// The compact agent list is intentionally empty when no work is active, but the expanded view
  /// must still show the configured machines that need attention. Build those rows from Defaults
  /// rather than relying on a monitor to publish a snapshot first.
  nonisolated static func visibleEnvironments(
    snapshots: [T3EnvironmentSnapshot], profiles: [T3EnvironmentProfile]
  ) -> [T3EnvironmentSnapshot] {
    let local = snapshots.filter(\.isLocal)
    let remotes = enabledRemoteProfiles(profiles).map { profile in
      let id = remoteSnapshotID(environmentID: profile.id, baseURL: profile.baseURL)
      return snapshots.first(where: { $0.id == id })
        ?? T3EnvironmentSnapshot(
          id: id, label: profile.label, baseURL: profile.baseURL, isLocal: false,
          platform: nil, serverVersion: nil, state: .connecting, agents: [])
    }
    return (local + remotes).sorted {
      if $0.isLocal != $1.isLocal { return $0.isLocal }
      return $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
    }
  }

  nonisolated static func environmentActions(
    for state: T3ConnectionState, isLocal: Bool
  ) -> [T3EnvironmentAction] {
    var actions: [T3EnvironmentAction]
    switch state {
    case .needsPairing:
      actions = [.pair]
    case .offline, .reconnecting:
      actions = [.retry]
    case .credentialError:
      actions = [.openSettings]
    case .connecting, .connected:
      actions = []
    }
    if !isLocal { actions.append(.disable) }
    return actions
  }

  nonisolated static func localCredentialID(environmentID: String, baseURL: String) -> String {
    "local|\(environmentID)|\(canonicalEndpointIdentity(baseURL))"
  }

  nonisolated static func remoteCredentialID(environmentID: String, baseURL: String) -> String {
    "remote|\(environmentID)|\(canonicalEndpointIdentity(baseURL))"
  }

  nonisolated static func localSnapshotID(_ environmentID: String) -> String {
    "local|\(environmentID)"
  }

  nonisolated static func connectSnapshotID(_ environmentID: String) -> String {
    "connect|\(environmentID)"
  }

  nonisolated static func remoteSnapshotID(environmentID: String, baseURL: String) -> String {
    "remote|\(environmentID)|\(canonicalEndpointIdentity(baseURL))"
  }

  nonisolated private static func remoteMonitorKey(_ environmentID: String) -> String {
    "remote:\(environmentID)"
  }

  nonisolated private static var provisionalLocalSnapshotID: String { "local" }

  private func updateCredentialError(_ error: Error?, for monitorKey: String) {
    if let error = error as? T3CredentialStoreError {
      credentialErrors[monitorKey] = error.localizedDescription
    } else if error == nil {
      credentialErrors[monitorKey] = nil
    }
    lastCredentialError = credentialErrors.keys.sorted()
      .compactMap { credentialErrors[$0] }
      .joined(separator: "\n")
    if lastCredentialError?.isEmpty == true { lastCredentialError = nil }
  }

  nonisolated private static func canonicalEndpointIdentity(_ value: String) -> String {
    guard let url = URL(string: value),
      let endpoint = try? T3Endpoint(url, allowInsecureRemoteHTTP: true)
    else { return value }
    return endpoint.baseURL.absoluteString
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
