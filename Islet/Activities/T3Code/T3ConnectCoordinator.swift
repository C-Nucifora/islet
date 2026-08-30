import AppKit
import Combine
import Defaults
import Foundation

protocol T3ConnectSessionServing: Sendable {
  func loadStoredAccount() async throws -> T3ConnectAccount?
  func exchangeAuthorizationCode(_ code: String, verifier: String) async throws -> T3OAuthRecord
  func validOAuthRecord() async throws -> T3OAuthRecord
  func commit(_ candidate: T3OAuthRecord) async throws
  func signOut() async throws
}

extension T3ConnectSession: T3ConnectSessionServing {}

protocol T3RelayServing: Sendable {
  func listEnvironments(accountToken: String) async throws -> [T3ConnectEnvironment]
  func authorize(
    environment: T3ConnectEnvironment,
    accountToken: String,
    grantID: UUID
  ) async throws -> T3ConnectEnvironmentAuthorization
  func invalidateAuthorization(environmentID: String, grantID: UUID) async
  func clearCaches() async
}

extension T3RelayClient: T3RelayServing {}

protocol T3DPoPResetting: Sendable {
  func activate() async
  func deactivate() async
  func reset() async
}

extension T3DPoPSigner: T3DPoPResetting {}

protocol T3ConnectSleeping: Sendable {
  func sleep(for interval: TimeInterval) async throws
}

private struct T3ConnectSystemSleeper: T3ConnectSleeping {
  func sleep(for interval: TimeInterval) async throws {
    try await Task.sleep(for: .seconds(interval))
  }
}

enum T3ConnectAccountState: Equatable, Sendable {
  case signedOut
  case linking(previous: T3ConnectAccount?)
  case linked(T3ConnectAccount, lastSync: Date?)
  case needsSignIn(T3ConnectAccount?, String)
  case unavailable(T3ConnectAccount, String)
}

enum T3ConnectCoordinatorError: Error, LocalizedError, Sendable {
  case browserUnavailable
  case authorizationDenied(String)
  case staleOperation
  case notLinked

  var errorDescription: String? {
    switch self {
    case .browserUnavailable:
      "Islet could not open the T3 Connect authorization page."
    case .authorizationDenied(let code):
      "T3 Connect declined authorization (\(code))."
    case .staleOperation:
      "The T3 Connect operation is no longer current."
    case .notLinked:
      "No T3 Connect account is linked."
    }
  }
}

@MainActor
final class T3ConnectCoordinator: ObservableObject {
  @Published private(set) var state: T3ConnectAccountState = .signedOut
  @Published private(set) var environments: [T3ConnectEnvironment] = []
  @Published private(set) var cloudCandidates: [T3EnvironmentSnapshot] = []
  @Published private(set) var lastCleanupError: String?
  @Published private(set) var lastLinkError: String?

  var hasScheduledInventory: Bool { inventoryTask != nil }
  var activeCloudMonitorEnvironmentIDs: Set<String> { Set(cloudTasks.keys) }

  private let session: any T3ConnectSessionServing
  private let relay: any T3RelayServing
  private let signerResetter: any T3DPoPResetting
  private let configuration: T3ConnectConfiguration
  private let listenerFactory: @Sendable () -> any T3OAuthLoopbackListening
  private let openURL: @MainActor @Sendable (URL) -> Bool
  private let transactionFactory: @Sendable () throws -> T3PKCETransaction
  private let now: @Sendable () -> Date
  private let sleeper: any T3ConnectSleeping
  private let shellLoader:
    @Sendable (T3ConnectEnvironmentAuthorization) async throws -> T3ShellSnapshot
  private let cloudPollInterval: @MainActor @Sendable ([T3AgentSnapshot]) -> TimeInterval
  private let onInventoryCycleCompleted: @MainActor @Sendable () -> Void
  private let onCloudCycleCompleted: @MainActor @Sendable (String) -> Void

  private var activeAccount: T3ConnectAccount?
  private var generation: UInt64 = 0
  private var loadingAccount = false
  private var remotePollingAllowed = false
  private var linkTask: Task<Void, Never>?
  private var linkCommitTask: Task<Void, any Error>?
  private var linkAttemptID: UUID?
  private var linkPhase: LinkPhase?
  private var linkPreviousState: T3ConnectAccountState?
  private var activeListener: (any T3OAuthLoopbackListening)?
  private var inventoryTask: InventoryTask?
  private var cloudTasks: [String: CloudTask] = [:]
  private var signingOut = false

  static func production() -> T3ConnectCoordinator {
    let store = T3ConnectCredentialStore()
    let signer = T3DPoPSigner(store: store)
    let session = T3ConnectSession(credentialStore: store)
    let relay = T3RelayClient(signer: signer)
    return T3ConnectCoordinator(
      session: session,
      relay: relay,
      signerResetter: signer,
      configuration: .production,
      listenerFactory: { T3OAuthLoopbackListener.production() },
      openURL: { NSWorkspace.shared.open($0) },
      transactionFactory: { try T3PKCETransaction() },
      now: Date.init,
      sleeper: T3ConnectSystemSleeper(),
      shellLoader: { authorization in
        try await T3Client(
          endpoint: authorization.endpoint, authorization: authorization.authorization
        ).fetchShell()
      },
      cloudPollInterval: { agents in
        let busy = agents.contains {
          [.working, .monitoring, .needsInput, .needsApproval].contains($0.phase)
        }
        let expanded = ScreenManager.shared.viewModel?.state.isExpanded ?? false
        return T3CodeActivity.pollInterval(
          busy: busy, expanded: expanded,
          lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
          energyMode: Defaults[.energyMode])
      })
  }

  init(
    session: any T3ConnectSessionServing,
    relay: any T3RelayServing,
    signerResetter: any T3DPoPResetting,
    configuration: T3ConnectConfiguration,
    listenerFactory: @escaping @Sendable () -> any T3OAuthLoopbackListening,
    openURL: @escaping @MainActor @Sendable (URL) -> Bool,
    transactionFactory: @escaping @Sendable () throws -> T3PKCETransaction,
    now: @escaping @Sendable () -> Date,
    sleeper: any T3ConnectSleeping,
    shellLoader:
      @escaping @Sendable (T3ConnectEnvironmentAuthorization) async throws -> T3ShellSnapshot,
    cloudPollInterval: @escaping @MainActor @Sendable ([T3AgentSnapshot]) -> TimeInterval,
    onInventoryCycleCompleted: @escaping @MainActor @Sendable () -> Void = {},
    onCloudCycleCompleted: @escaping @MainActor @Sendable (String) -> Void = { _ in }
  ) {
    self.session = session
    self.relay = relay
    self.signerResetter = signerResetter
    self.configuration = configuration
    self.listenerFactory = listenerFactory
    self.openURL = openURL
    self.transactionFactory = transactionFactory
    self.now = now
    self.sleeper = sleeper
    self.shellLoader = shellLoader
    self.cloudPollInterval = cloudPollInterval
    self.onInventoryCycleCompleted = onInventoryCycleCompleted
    self.onCloudCycleCompleted = onCloudCycleCompleted
  }

  func loadAccount() async {
    guard activeAccount == nil, linkTask == nil, !loadingAccount, !signingOut else { return }
    loadingAccount = true
    defer { loadingAccount = false }
    let capturedGeneration = generation
    do {
      guard let account = try await session.loadStoredAccount() else {
        if capturedGeneration == generation, linkTask == nil, !signingOut {
          state = .signedOut
        }
        return
      }
      guard capturedGeneration == generation, !signingOut else { return }
      activeAccount = account
      let loadedState = T3ConnectAccountState.linked(account, lastSync: nil)
      if linkTask != nil {
        linkPreviousState = loadedState
        state = .linking(previous: account)
      } else {
        state = loadedState
      }
    } catch {
      guard capturedGeneration == generation, !signingOut else { return }
      let failedState = T3ConnectAccountState.needsSignIn(nil, error.localizedDescription)
      if linkTask != nil {
        linkPreviousState = failedState
      } else {
        state = failedState
      }
    }
  }

  func link() async {
    guard linkTask == nil, !signingOut else { return }
    lastLinkError = nil
    let attemptID = UUID()
    linkAttemptID = attemptID
    linkPhase = .waiting
    linkPreviousState = state
    state = .linking(previous: activeAccount)
    cancelInventoryTask()
    let listener = listenerFactory()
    activeListener = listener

    let task = Task { [weak self] in
      guard let self else { return }
      await self.performLink(attemptID: attemptID, listener: listener)
    }
    linkTask = task
    await task.value
  }

  func cancelLink() {
    guard linkPhase == .waiting else { return }
    let listener = activeListener
    linkTask?.cancel()
    linkTask = nil
    linkAttemptID = nil
    linkPhase = nil
    activeListener = nil
    restoreLinkPresentation()
    Task { await listener?.cancel() }
  }

  func startInventory() {
    remotePollingAllowed = true
    scheduleInventory(initialDelay: nil)
  }

  private func scheduleInventory(initialDelay: TimeInterval?) {
    guard inventoryTask == nil, let account = activeAccount, canRunAccountWork, !signingOut else {
      return
    }
    startRetainedCloudTasks(account: account)
    let taskID = UUID()
    let capturedGeneration = generation
    let task = Task { [weak self] in
      guard let self else { return }
      await self.runInventory(
        account: account, taskID: taskID, capturedGeneration: capturedGeneration,
        initialDelay: initialDelay)
    }
    inventoryTask = InventoryTask(id: taskID, task: task)
  }

  func stopInventory(preserveInventory: Bool) {
    if remotePollingAllowed { generation &+= 1 }
    remotePollingAllowed = false
    cancelInventoryTask()
    cancelCloudTasks()
    if !preserveInventory {
      environments = []
      cloudCandidates = []
    }
  }

  func refreshNow() {
    guard remotePollingAllowed, linkAttemptID == nil else { return }
    cancelInventoryTask()
    cancelCloudTasks()
    scheduleInventory(initialDelay: nil)
  }

  func authorization(
    for environment: T3ConnectEnvironment
  ) async throws -> T3ConnectEnvironmentAuthorization {
    let capturedGeneration = generation
    guard canRunAccountWork else { throw T3ConnectCoordinatorError.staleOperation }
    guard let account = activeAccount else { throw T3ConnectCoordinatorError.notLinked }
    guard environments.contains(environment) else {
      throw T3ConnectCoordinatorError.staleOperation
    }
    let record = try await session.validOAuthRecord()
    try requireCurrent(
      capturedGeneration: capturedGeneration, grantID: account.grantID, record: record)
    guard environments.contains(environment) else {
      throw T3ConnectCoordinatorError.staleOperation
    }
    let authorization = try await relay.authorize(
      environment: environment, accountToken: record.accessToken, grantID: record.grantID)
    try requireCurrent(
      capturedGeneration: capturedGeneration, grantID: account.grantID, record: record)
    guard environments.contains(environment) else {
      throw T3ConnectCoordinatorError.staleOperation
    }
    return authorization
  }

  func signOut() async throws {
    guard !signingOut else { return }
    signingOut = true
    defer { signingOut = false }

    generation &+= 1
    let listener = activeListener
    let commitTask = linkCommitTask
    linkTask?.cancel()
    linkTask = nil
    linkAttemptID = nil
    linkPhase = nil
    linkPreviousState = nil
    linkCommitTask = nil
    activeListener = nil
    cancelInventoryTask()
    cancelCloudTasks()
    activeAccount = nil
    environments = []
    cloudCandidates = []
    state = .signedOut
    lastCleanupError = nil
    lastLinkError = nil

    await signerResetter.deactivate()
    await relay.clearCaches()
    await listener?.cancel()
    _ = try? await commitTask?.value
    do {
      try await session.signOut()
    } catch {
      await signerResetter.reset()
      lastCleanupError = error.localizedDescription
      throw error
    }
    await signerResetter.reset()
  }

  private func performLink(
    attemptID: UUID,
    listener: any T3OAuthLoopbackListening
  ) async {
    do {
      let transaction = try transactionFactory()
      try await listener.start(state: transaction.state)
      try requireLink(attemptID, phase: .waiting)
      let authorizationURL = try transaction.hostedAuthorizationURL(configuration: configuration)
      guard openURL(authorizationURL) else {
        throw T3ConnectCoordinatorError.browserUnavailable
      }
      let result = try await listener.waitForCallback()
      try requireLink(attemptID, phase: .waiting)
      let code: String
      switch result {
      case .authorizationCode(let value):
        code = value
      case .denied(let value):
        throw T3ConnectCoordinatorError.authorizationDenied(value)
      }
      let candidate = try await session.exchangeAuthorizationCode(
        code, verifier: transaction.verifier)
      try requireLink(attemptID, phase: .waiting)
      let candidateInventory = try await relay.listEnvironments(
        accountToken: candidate.accessToken)
      try requireLink(attemptID, phase: .waiting)

      // The session temporarily rejects reads while replacing the credential. Pause old cloud
      // work without discarding its last-good rows, then resume it if the commit rolls back.
      cancelCloudTasks()
      linkPhase = .committing
      let commitTask = Task { [session] in try await session.commit(candidate) }
      linkCommitTask = commitTask
      try await commitTask.value
      linkCommitTask = nil
      try requireLink(attemptID, phase: .committing)

      generation &+= 1
      cancelInventoryTask()
      cancelCloudTasks()
      await relay.clearCaches()
      try requireLink(attemptID, phase: .committing)
      await signerResetter.activate()
      try requireLink(attemptID, phase: .committing)

      let account = T3ConnectAccount(record: candidate)
      activeAccount = account
      cloudCandidates = []
      environments = candidateInventory
      state = .linked(account, lastSync: now())
      lastCleanupError = nil
      reconcileCloudTasks(candidateInventory, account: account)
      finishLink(attemptID: attemptID)
      if remotePollingAllowed { scheduleInventory(initialDelay: 60) }
    } catch {
      if linkAttemptID == attemptID {
        lastLinkError = error.localizedDescription
        state = linkPreviousState ?? .signedOut
        finishLink(attemptID: attemptID)
        if remotePollingAllowed { startInventory() }
      }
    }
    await listener.cancel()
  }

  private func finishLink(attemptID: UUID) {
    guard linkAttemptID == attemptID else { return }
    linkTask = nil
    linkAttemptID = nil
    linkPhase = nil
    linkPreviousState = nil
    linkCommitTask = nil
    activeListener = nil
  }

  private func restoreLinkPresentation() {
    if let linkPreviousState { state = linkPreviousState }
    linkPreviousState = nil
    if remotePollingAllowed { startInventory() }
  }

  private func requireLink(_ attemptID: UUID, phase: LinkPhase) throws {
    try Task.checkCancellation()
    guard linkAttemptID == attemptID, linkPhase == phase, !signingOut else {
      throw T3ConnectCoordinatorError.staleOperation
    }
  }

  private func runInventory(
    account: T3ConnectAccount,
    taskID: UUID,
    capturedGeneration: UInt64,
    initialDelay: TimeInterval?
  ) async {
    if let initialDelay {
      do {
        try await sleeper.sleep(for: initialDelay)
      } catch {
        return
      }
      guard
        isCurrentInventory(
          taskID: taskID, capturedGeneration: capturedGeneration, grantID: account.grantID)
      else { return }
    }
    var failures = 0
    while !Task.isCancelled {
      do {
        let record = try await session.validOAuthRecord()
        try requireCurrentInventory(
          taskID: taskID, capturedGeneration: capturedGeneration,
          grantID: account.grantID, record: record)
        let listed = try await relay.listEnvironments(accountToken: record.accessToken)
        try requireCurrentInventory(
          taskID: taskID, capturedGeneration: capturedGeneration,
          grantID: account.grantID, record: record)
        for environmentID in authorizationInvalidationIDs(for: listed) {
          await relay.invalidateAuthorization(
            environmentID: environmentID, grantID: account.grantID)
        }
        try requireCurrentInventory(
          taskID: taskID, capturedGeneration: capturedGeneration,
          grantID: account.grantID, record: record)
        reconcileCloudTasks(listed, account: account)
        environments = listed
        state = .linked(account, lastSync: now())
        failures = 0
        onInventoryCycleCompleted()
        try await sleeper.sleep(for: 60)
      } catch is CancellationError where Task.isCancelled {
        onInventoryCycleCompleted()
        return
      } catch T3ConnectSessionError.reauthenticationRequired {
        guard
          isCurrentInventory(
            taskID: taskID, capturedGeneration: capturedGeneration, grantID: account.grantID)
        else {
          onInventoryCycleCompleted()
          return
        }
        await handleReauthenticationRequired(
          account: account, capturedGeneration: capturedGeneration)
        onInventoryCycleCompleted()
        return
      } catch {
        guard
          isCurrentInventory(
            taskID: taskID, capturedGeneration: capturedGeneration, grantID: account.grantID)
        else {
          onInventoryCycleCompleted()
          return
        }
        failures += 1
        state = .unavailable(account, error.localizedDescription)
        onInventoryCycleCompleted()
        do {
          try await sleeper.sleep(
            for: T3CodeActivity.reconnectDelay(failureCount: failures, remote: true))
        } catch {
          return
        }
      }
    }
  }

  private func startRetainedCloudTasks(account: T3ConnectAccount) {
    reconcileCloudTasks(environments, account: account)
  }

  private func reconcileCloudTasks(
    _ listed: [T3ConnectEnvironment],
    account: T3ConnectAccount
  ) {
    let currentByID = Dictionary(uniqueKeysWithValues: environments.map { ($0.environmentID, $0) })
    let listedByID = Dictionary(uniqueKeysWithValues: listed.map { ($0.environmentID, $0) })
    let changedIDs = Set(
      listed.compactMap { environment in
        currentByID[environment.environmentID] == environment ? nil : environment.environmentID
      })
    for (id, existing) in cloudTasks where listedByID[id] != existing.environment {
      existing.task.cancel()
      cloudTasks[id] = nil
    }

    let listedIDs = Set(listed.map(\.environmentID))
    cloudCandidates.removeAll {
      !listedIDs.contains($0.logicalEnvironmentID)
        || changedIDs.contains($0.logicalEnvironmentID)
    }
    for environment in listed {
      if !cloudCandidates.contains(where: { $0.logicalEnvironmentID == environment.environmentID })
      {
        upsertCloudCandidate(Self.connectingSnapshot(environment))
      }
      guard remotePollingAllowed, cloudTasks[environment.environmentID] == nil else { continue }
      let taskID = UUID()
      let capturedGeneration = generation
      let task = Task { [weak self] in
        guard let self else { return }
        await self.runCloudMonitor(
          environment: environment, account: account, taskID: taskID,
          capturedGeneration: capturedGeneration)
      }
      cloudTasks[environment.environmentID] = CloudTask(
        id: taskID, environment: environment, task: task)
    }
  }

  private func authorizationInvalidationIDs(
    for listed: [T3ConnectEnvironment]
  ) -> [String] {
    let listedByID = Dictionary(uniqueKeysWithValues: listed.map { ($0.environmentID, $0) })
    return environments.compactMap { current in
      listedByID[current.environmentID] == current ? nil : current.environmentID
    }
  }

  private func runCloudMonitor(
    environment: T3ConnectEnvironment,
    account: T3ConnectAccount,
    taskID: UUID,
    capturedGeneration: UInt64
  ) async {
    var failures = 0
    while !Task.isCancelled {
      do {
        let record = try await session.validOAuthRecord()
        try requireCurrent(
          environmentID: environment.environmentID, taskID: taskID,
          capturedGeneration: capturedGeneration, grantID: account.grantID, record: record)
        var authorization = try await relay.authorize(
          environment: environment, accountToken: record.accessToken, grantID: record.grantID)
        try requireCurrent(
          environmentID: environment.environmentID, taskID: taskID,
          capturedGeneration: capturedGeneration, grantID: account.grantID, record: record)
        let shell: T3ShellSnapshot
        do {
          shell = try await shellLoader(authorization)
        } catch T3ClientError.unauthorized {
          // T3Client currently folds both HTTP 401 and 403 credential rejection into
          // `.unauthorized`. Invalidate only this environment, then remint and retry once.
          try requireCurrent(
            environmentID: environment.environmentID, taskID: taskID,
            capturedGeneration: capturedGeneration, grantID: account.grantID, record: record)
          await relay.invalidateAuthorization(
            environmentID: environment.environmentID, grantID: record.grantID)
          try requireCurrent(
            environmentID: environment.environmentID, taskID: taskID,
            capturedGeneration: capturedGeneration, grantID: account.grantID, record: record)
          let retryRecord = try await session.validOAuthRecord()
          try requireCurrent(
            environmentID: environment.environmentID, taskID: taskID,
            capturedGeneration: capturedGeneration, grantID: account.grantID,
            record: retryRecord)
          authorization = try await relay.authorize(
            environment: environment, accountToken: retryRecord.accessToken,
            grantID: retryRecord.grantID)
          try requireCurrent(
            environmentID: environment.environmentID, taskID: taskID,
            capturedGeneration: capturedGeneration, grantID: account.grantID,
            record: retryRecord)
          do {
            shell = try await shellLoader(authorization)
          } catch T3ClientError.unauthorized {
            try requireCurrent(
              environmentID: environment.environmentID, taskID: taskID,
              capturedGeneration: capturedGeneration, grantID: account.grantID,
              record: retryRecord)
            await relay.invalidateAuthorization(
              environmentID: environment.environmentID, grantID: retryRecord.grantID)
            try requireCurrent(
              environmentID: environment.environmentID, taskID: taskID,
              capturedGeneration: capturedGeneration, grantID: account.grantID,
              record: retryRecord)
            throw T3ClientError.unauthorized
          }
        }
        try requireCurrent(
          environmentID: environment.environmentID, taskID: taskID,
          capturedGeneration: capturedGeneration, grantID: account.grantID, record: record)
        let snapshot = T3CodeActivity.connectedSnapshot(
          descriptor: authorization.descriptor, endpoint: authorization.endpoint,
          source: .connect, shell: shell, fallbackLabel: environment.label, now: now())
        upsertCloudCandidate(snapshot)
        failures = 0
        onCloudCycleCompleted(environment.environmentID)
        try await sleeper.sleep(for: cloudPollInterval(snapshot.agents))
      } catch is CancellationError where Task.isCancelled {
        onCloudCycleCompleted(environment.environmentID)
        return
      } catch T3ConnectSessionError.reauthenticationRequired {
        guard
          isCurrent(
            environmentID: environment.environmentID, taskID: taskID,
            capturedGeneration: capturedGeneration, grantID: account.grantID)
        else {
          onCloudCycleCompleted(environment.environmentID)
          return
        }
        await handleReauthenticationRequired(
          account: account, capturedGeneration: capturedGeneration)
        onCloudCycleCompleted(environment.environmentID)
        return
      } catch {
        guard
          isCurrent(
            environmentID: environment.environmentID, taskID: taskID,
            capturedGeneration: capturedGeneration, grantID: account.grantID)
        else {
          onCloudCycleCompleted(environment.environmentID)
          return
        }
        failures += 1
        upsertCloudCandidate(Self.offlineSnapshot(environment, error: error))
        onCloudCycleCompleted(environment.environmentID)
        do {
          try await sleeper.sleep(
            for: T3CodeActivity.reconnectDelay(failureCount: failures, remote: true))
        } catch {
          return
        }
      }
    }
  }

  private func handleReauthenticationRequired(
    account: T3ConnectAccount,
    capturedGeneration: UInt64
  ) async {
    guard isCurrent(capturedGeneration, grantID: account.grantID) else { return }
    generation &+= 1
    cancelInventoryTask()
    cancelCloudTasks()
    let reason = T3ConnectSessionError.reauthenticationRequired.localizedDescription
    cloudCandidates = cloudCandidates.map { snapshot in
      T3EnvironmentSnapshot(
        id: snapshot.id, logicalEnvironmentID: snapshot.logicalEnvironmentID,
        source: .connect, label: snapshot.label, baseURL: snapshot.baseURL,
        platform: snapshot.platform, serverVersion: snapshot.serverVersion,
        state: .offline(reason), agents: [])
    }
    state = .needsSignIn(account, reason)
    await signerResetter.deactivate()
    await relay.clearCaches()
  }

  private func requireCurrent(
    capturedGeneration: UInt64,
    grantID: UUID,
    record: T3OAuthRecord
  ) throws {
    try Task.checkCancellation()
    guard record.grantID == grantID, isCurrent(capturedGeneration, grantID: grantID) else {
      throw T3ConnectCoordinatorError.staleOperation
    }
  }

  private func requireCurrentInventory(
    taskID: UUID,
    capturedGeneration: UInt64,
    grantID: UUID,
    record: T3OAuthRecord
  ) throws {
    try Task.checkCancellation()
    guard record.grantID == grantID,
      isCurrentInventory(
        taskID: taskID, capturedGeneration: capturedGeneration, grantID: grantID)
    else {
      throw T3ConnectCoordinatorError.staleOperation
    }
  }

  private func requireCurrent(
    environmentID: String,
    taskID: UUID,
    capturedGeneration: UInt64,
    grantID: UUID,
    record: T3OAuthRecord
  ) throws {
    try Task.checkCancellation()
    guard record.grantID == grantID,
      isCurrent(
        environmentID: environmentID, taskID: taskID,
        capturedGeneration: capturedGeneration, grantID: grantID)
    else {
      throw T3ConnectCoordinatorError.staleOperation
    }
  }

  private func isCurrent(_ capturedGeneration: UInt64, grantID: UUID) -> Bool {
    canRunAccountWork && capturedGeneration == generation && activeAccount?.grantID == grantID
      && !signingOut
  }

  private var canRunAccountWork: Bool {
    guard remotePollingAllowed else { return false }
    return switch state {
    case .linked, .unavailable:
      true
    case .signedOut, .linking, .needsSignIn:
      false
    }
  }

  private func isCurrentInventory(
    taskID: UUID,
    capturedGeneration: UInt64,
    grantID: UUID
  ) -> Bool {
    isCurrent(capturedGeneration, grantID: grantID) && inventoryTask?.id == taskID
  }

  private func isCurrent(
    environmentID: String,
    taskID: UUID,
    capturedGeneration: UInt64,
    grantID: UUID
  ) -> Bool {
    isCurrent(capturedGeneration, grantID: grantID)
      && cloudTasks[environmentID]?.id == taskID
  }

  private func cancelInventoryTask() {
    inventoryTask?.task.cancel()
    inventoryTask = nil
  }

  private func cancelCloudTasks() {
    for cloudTask in cloudTasks.values { cloudTask.task.cancel() }
    cloudTasks.removeAll()
  }

  private func upsertCloudCandidate(_ snapshot: T3EnvironmentSnapshot) {
    if let index = cloudCandidates.firstIndex(where: { $0.id == snapshot.id }) {
      cloudCandidates[index] = snapshot
    } else {
      cloudCandidates.append(snapshot)
    }
    cloudCandidates.sort { $0.logicalEnvironmentID < $1.logicalEnvironmentID }
  }

  private static func connectingSnapshot(
    _ environment: T3ConnectEnvironment
  ) -> T3EnvironmentSnapshot {
    T3EnvironmentSnapshot(
      id: T3CodeActivity.connectSnapshotID(environment.environmentID),
      logicalEnvironmentID: environment.environmentID, source: .connect,
      label: environment.label, baseURL: environment.httpBaseURL.absoluteString,
      platform: nil, serverVersion: nil, state: .connecting, agents: [])
  }

  private static func offlineSnapshot(
    _ environment: T3ConnectEnvironment,
    error: any Error
  ) -> T3EnvironmentSnapshot {
    T3EnvironmentSnapshot(
      id: T3CodeActivity.connectSnapshotID(environment.environmentID),
      logicalEnvironmentID: environment.environmentID, source: .connect,
      label: environment.label, baseURL: environment.httpBaseURL.absoluteString,
      platform: nil, serverVersion: nil, state: .offline(error.localizedDescription), agents: [])
  }

  private enum LinkPhase {
    case waiting
    case committing
  }

  private struct CloudTask {
    let id: UUID
    let environment: T3ConnectEnvironment
    let task: Task<Void, Never>
  }

  private struct InventoryTask {
    let id: UUID
    let task: Task<Void, Never>
  }
}
