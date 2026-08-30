import Combine
import Defaults
import Foundation

@MainActor
protocol PulseClock: AnyObject {
  var now: Date { get }
}

@MainActor
final class PulseSystemClock: PulseClock {
  var now: Date { Date() }
}

@MainActor
final class PulseDeadlineTask {
  private var cancellation: (() -> Void)?

  init(cancellation: @escaping () -> Void) {
    self.cancellation = cancellation
  }

  func cancel() {
    cancellation?()
    cancellation = nil
  }
}

@MainActor
protocol PulseDeadlineScheduling: AnyObject {
  func schedule(
    at deadline: Date, action: @escaping @MainActor @Sendable () -> Void
  ) -> PulseDeadlineTask
}

@MainActor
final class PulseSystemDeadlineScheduler: PulseDeadlineScheduling {
  private let clock: any PulseClock

  init(clock: any PulseClock) {
    self.clock = clock
  }

  func schedule(
    at deadline: Date, action: @escaping @MainActor @Sendable () -> Void
  ) -> PulseDeadlineTask {
    let task = Task { @MainActor [clock] in
      let delay = max(0, deadline.timeIntervalSince(clock.now))
      do {
        try await Task.sleep(for: .seconds(delay))
      } catch {
        return
      }
      guard !Task.isCancelled else { return }
      action()
    }
    return PulseDeadlineTask { task.cancel() }
  }
}

@MainActor
final class PulseCenter: ObservableObject {
  static let shared = PulseCenter(
    revisionStore: .defaults,
    historyStore: PulseHistoryStore(),
    historyConfiguration: PulseHistoryConfiguration(
      isEnabled: Defaults[.pulseHistoryPersistenceEnabled],
      retentionDays: Defaults[.pulseHistoryRetentionDays],
      maximumEntries: Defaults[.pulseHistoryMaximumEntries]))
  static let maximumItems = 100
  static let maximumHistoryEntries = 200
  static let maximumRevisionRecords = 2_048

  private enum OrderingError: LocalizedError {
    case stale
    case revisionRequired
    case generationEnded
    case capacity

    var errorDescription: String? {
      switch self {
      case .stale: "revision is not newer than the last accepted command"
      case .revisionRequired: "revision is required after an ordered stream starts"
      case .generationEnded: "update cannot reopen an ended activity; use show or event"
      case .capacity: "Pulse revision tracking is at capacity"
      }
    }

    var code: PulseErrorCode {
      switch self {
      case .stale: .staleRevision
      case .revisionRequired: .revisionRequired
      case .generationEnded: .generationEnded
      case .capacity: .capacityExceeded
      }
    }
  }

  /// The presentation slice. `storedItems` also retains still-live filtered and muted work so
  /// changing a profile can reveal it again without requiring a provider retransmission.
  @Published private(set) var items: [PulseItem] = []
  @Published private(set) var history: [PulseHistoryEntry] = []
  @Published private(set) var historyPersistenceError: String?
  @Published private(set) var sourcePolicies: [String: PulseSourcePolicy] = [:]
  @Published var deliveryProfile: PulseDeliveryProfile {
    didSet {
      guard deliveryProfile != oldValue else { return }
      Defaults[deliveryProfileKey] = deliveryProfile
      refreshVisibleItems()
    }
  }
  private let deliveryProfileKey: Defaults.Key<PulseDeliveryProfile>
  private let sourcePoliciesKey: Defaults.Key<[String: String]>
  var ruleDeliveryProfile: PulseDeliveryProfile? {
    didSet {
      guard ruleDeliveryProfile != oldValue else { return }
      refreshVisibleItems()
    }
  }
  private let symbolAvailability: (String) -> Bool?
  private let historyStore: PulseHistoryStore?
  private var historyPersistenceWriter: PulseHistoryPersistenceWriter?
  private var historyConfiguration: PulseHistoryConfiguration
  private var historyPersistenceIsReadOnly = false
  private var historyPersistenceGeneration: UInt64 = 0
  private var storedItems: [PulseItem] = []
  private var revisionRecords: [PulseItem.ID: PulseRevisionRecord]
  private let revisionWriter: PulseRevisionPersistenceWriter?
  private var deadlineTask: PulseDeadlineTask?
  private let clock: any PulseClock
  private let deadlineScheduler: any PulseDeadlineScheduling
  private var stalenessPolicy: PulseStalenessPolicy

  init(
    staleTimeout: TimeInterval = Defaults[.pulseStaleTimeout],
    staleRetention: TimeInterval = PulseStalenessPolicy.defaultRetention,
    clock: (any PulseClock)? = nil,
    scheduler: (any PulseDeadlineScheduling)? = nil,
    revisionStore: PulseRevisionPersistenceStore? = nil,
    revisionPersistenceDelay: TimeInterval = PulseRevisionPersistenceWriter.defaultCoalescingDelay,
    symbolAvailability: @escaping (String) -> Bool? = PulseSymbolValidator.platformAvailability,
    deliveryProfileKey: Defaults.Key<PulseDeliveryProfile> = .pulseDeliveryProfile,
    sourcePoliciesKey: Defaults.Key<[String: String]> = .pulseSourcePolicies,
    historyStore: PulseHistoryStore? = nil,
    historyConfiguration: PulseHistoryConfiguration = .sessionOnly,
    now: Date? = nil,
    historyPersistenceDelay: TimeInterval = 0.25
  ) {
    let resolvedClock = clock ?? PulseSystemClock()
    let historyReferenceDate = now ?? resolvedClock.now
    self.clock = resolvedClock
    deadlineScheduler = scheduler ?? PulseSystemDeadlineScheduler(clock: resolvedClock)
    stalenessPolicy = PulseStalenessPolicy(
      timeout: staleTimeout, retention: staleRetention)
    self.symbolAvailability = symbolAvailability
    self.deliveryProfileKey = deliveryProfileKey
    self.sourcePoliciesKey = sourcePoliciesKey
    deliveryProfile = Defaults[deliveryProfileKey]
    if let revisionStore {
      let restoration = PulseRevisionPersistence.restore(
        from: revisionStore, now: resolvedClock.now,
        maximumRecords: Self.maximumRevisionRecords)
      let writer = PulseRevisionPersistenceWriter(
        store: revisionStore, coalescingDelay: revisionPersistenceDelay)
      revisionRecords = restoration.records
      revisionWriter = writer
      if restoration.requiresRewrite { writer.submit(restoration.records) }
    } else {
      revisionRecords = [:]
      revisionWriter = nil
    }
    let rawStoredPolicies = sourcePoliciesKey.suite.dictionary(forKey: sourcePoliciesKey.name)
    let storageIsValid =
      sourcePoliciesKey.suite.object(forKey: sourcePoliciesKey.name) == nil
      || rawStoredPolicies?.values.allSatisfy { $0 is String } == true
    let storedPolicies = Defaults[sourcePoliciesKey]
    sourcePolicies = Self.restoreSourcePolicies(from: storedPolicies)
    let canonicalPolicies = Self.persistedSourcePolicies(from: sourcePolicies)
    if !storageIsValid || storedPolicies != canonicalPolicies {
      Defaults[sourcePoliciesKey] = canonicalPolicies
    }
    self.historyStore = historyStore
    self.historyConfiguration = historyConfiguration
    guard let historyStore else { return }
    historyPersistenceWriter = PulseHistoryPersistenceWriter(
      store: historyStore, coalescingDelay: historyPersistenceDelay
    ) { [weak self] generation, errorMessage in
      Task { @MainActor [weak self] in
        self?.completeHistoryPersistence(generation: generation, errorMessage: errorMessage)
      }
    }
    guard historyConfiguration.isEnabled else {
      do {
        try historyStore.remove()
      } catch {
        historyPersistenceError =
          "Saved Pulse history could not be removed. \(error.localizedDescription)"
      }
      return
    }
    do {
      let restored = try historyStore.load(
        now: historyReferenceDate, retentionDays: historyConfiguration.retentionDays,
        maximumEntries: historyConfiguration.maximumEntries)
      history = restored.entries
      if restored.needsRewrite {
        if history.isEmpty {
          try historyStore.remove()
        } else {
          try historyStore.save(history, exportedAt: historyReferenceDate)
        }
      }
    } catch let error as PulseHistoryStoreError {
      if case .unsupportedVersion = error {
        historyPersistenceIsReadOnly = true
        historyPersistenceError =
          "Saved Pulse history comes from a newer Islet version and was not changed."
        return
      }
      let readError = error
      history = []
      do {
        try historyStore.remove()
        historyPersistenceError =
          "Saved Pulse history could not be read and was cleared. \(readError.localizedDescription)"
      } catch {
        historyPersistenceError =
          "Saved Pulse history could not be read or removed. \(readError.localizedDescription)"
      }
    } catch {
      let readError = error
      history = []
      do {
        try historyStore.remove()
        historyPersistenceError =
          "Saved Pulse history could not be read and was cleared. \(readError.localizedDescription)"
      } catch {
        historyPersistenceError =
          "Saved Pulse history could not be read or removed. \(readError.localizedDescription)"
      }
    }
  }

  var primary: PulseItem? { items.first }
  var retainedItemCount: Int { storedItems.count }
  var hiddenItemCount: Int { max(0, storedItems.count - items.count) }
  var effectiveDeliveryProfile: PulseDeliveryProfile {
    ruleDeliveryProfile ?? deliveryProfile
  }
  var staleTimeout: TimeInterval { stalenessPolicy.timeout }

  func flushRevisionPersistence() {
    revisionWriter?.flush()
  }

  @discardableResult
  func applyIfEnabled(
    _ command: PulseCommand, now: Date? = nil,
    activityEnabled: Bool = ActivityEnablement.isEnabled("pulse")
  ) -> PulseResponse {
    guard activityEnabled else {
      return .failure(
        "Pulse is disabled in Islet Settings", code: .featureDisabled,
        requestID: command.requestID)
    }
    return apply(command, now: now)
  }

  @discardableResult
  func apply(_ command: PulseCommand, now suppliedNow: Date? = nil) -> PulseResponse {
    let now = suppliedNow ?? clock.now
    do {
      processDeadlines(now: now)
      switch command.operation {
      case .show, .update, .event:
        guard var payload = command.activity else {
          record(operation: command.operation, item: nil, result: .rejected, date: now)
          return .failure(
            "activity is required for \(command.operation.rawValue)", code: .invalidCommand,
            requestID: command.requestID)
        }
        if command.operation == .event, payload.expiresAt == nil {
          payload.expiresAt = now.addingTimeInterval(8)
        }
        let incomingID = try PulseItem.ID(
          source: payload.source, providerIdentifier: payload.id)
        try validateRevision(
          command.revision, for: incomingID, operation: command.operation, now: now)
        let previous = storedItems.first { $0.id == incomingID }
        let item = try PulseItem(
          payload: payload, now: now, previous: previous,
          staleTimeout: stalenessPolicy.timeout, symbolAvailability: symbolAvailability)
        guard policy(for: item.source) != .revoked else {
          record(operation: command.operation, item: nil, result: .rejected, date: now)
          return .failure(
            "source is revoked in Islet Settings", code: .sourceRevoked,
            requestID: command.requestID)
        }
        let visible = shouldPresent(item)
        guard upsertStored(item, operation: command.operation, now: now) else {
          refreshVisibleItems()
          return .failure(
            "activity was evicted because Pulse is at capacity", code: .capacityExceeded,
            requestID: command.requestID)
        }
        acceptRevision(command.revision, for: incomingID, ended: false, now: now)
        record(
          operation: command.operation, item: item,
          result: visible ? (previous == nil ? .shown : .updated) : .suppressed, date: now)
        refreshVisibleItems()
        return .success(
          id: item.providerIdentifier, warning: item.symbolWarning?.localizedDescription,
          requestID: command.requestID)
      case .end:
        guard let rawIdentifier = command.id ?? command.activity?.id else {
          record(operation: .end, item: nil, result: .rejected, date: now)
          return .failure(
            "id is required for end", code: .invalidCommand, requestID: command.requestID)
        }
        guard command.revision == nil || command.source != nil else {
          record(operation: .end, item: nil, result: .rejected, date: now)
          return .failure(
            "source is required when end includes revision", code: .invalidCommand,
            requestID: command.requestID)
        }
        let identifier = try PulseItem.normalizedIdentifier(rawIdentifier)
        let matchingItems = storedItems.filter { $0.providerIdentifier == identifier }
        let targetID: PulseItem.ID?
        let item: PulseItem?
        if let source = command.source {
          let scopedID = try PulseItem.ID(source: source, providerIdentifier: identifier)
          targetID = scopedID
          item = storedItems.first(where: { $0.id == scopedID })
          if item == nil, !matchingItems.isEmpty {
            record(operation: .end, item: nil, result: .rejected, date: now)
            return .failure(
              "id belongs to a different source", code: .sourceMismatch,
              requestID: command.requestID)
          }
        } else if matchingItems.count > 1 {
          record(operation: .end, item: nil, result: .rejected, date: now)
          return .failure(
            "source is required because multiple providers use this id",
            code: .ambiguousIdentifier, requestID: command.requestID)
        } else {
          item = matchingItems.first
          targetID = item?.id
        }
        if let targetID {
          try validateRevision(command.revision, for: targetID, operation: .end, now: now)
          if let item {
            storedItems.removeAll { $0.id == item.id }
            record(operation: .end, item: item, result: .ended, date: now)
          }
          acceptRevision(command.revision, for: targetID, ended: true, now: now)
        }
        refreshVisibleItems()
        scheduleDeadline()
        return .success(id: identifier, requestID: command.requestID)
      }
    } catch let error as OrderingError {
      // A retry or reordered command is a protocol no-op. Do not append history, since doing so
      // would let repeated delivery change provider health and consume the bounded audit log.
      return .failure(
        error.localizedDescription, code: error.code, requestID: command.requestID)
    } catch {
      // Rejected wire data and error descriptions can contain secrets. Only the operation and
      // outcome are retained for local diagnostics.
      record(operation: command.operation, item: nil, result: .rejected, date: now)
      return .failure(
        error.localizedDescription, code: .validationFailed, requestID: command.requestID)
    }
  }

  func dismiss(_ id: PulseItem.ID, now suppliedNow: Date? = nil) {
    let now = suppliedNow ?? clock.now
    guard let item = storedItems.first(where: { $0.id == id }) else { return }
    storedItems.removeAll { $0.id == id }
    record(operation: .end, item: item, result: .dismissed, date: now)
    refreshVisibleItems()
    scheduleDeadline()
  }

  func keepStale(_ id: PulseItem.ID, now suppliedNow: Date? = nil) {
    let now = suppliedNow ?? clock.now
    guard let index = storedItems.firstIndex(where: { $0.id == id && $0.state == .stale })
    else { return }
    guard !storedItems[index].isStaleKept else { return }
    storedItems[index].isStaleKept = true
    storedItems[index].expiresAt = nil
    storedItems[index].staleRemovalAt = nil
    record(operation: .update, item: storedItems[index], result: .kept, date: now)
    refreshVisibleItems()
    scheduleDeadline()
  }

  func setStaleTimeout(_ timeout: TimeInterval, now suppliedNow: Date? = nil) {
    let now = suppliedNow ?? clock.now
    let updatedPolicy = PulseStalenessPolicy(
      timeout: timeout, retention: stalenessPolicy.retention)
    guard updatedPolicy.timeout != stalenessPolicy.timeout else { return }
    stalenessPolicy = updatedPolicy
    for index in storedItems.indices where storedItems[index].state.receivesStaleDeadline {
      storedItems[index].staleAt = storedItems[index].updatedAt.addingTimeInterval(
        stalenessPolicy.timeout)
    }
    processDeadlines(now: now)
    scheduleDeadline()
  }

  func removeAll(now suppliedNow: Date? = nil) {
    let now = suppliedNow ?? clock.now
    for item in storedItems {
      record(operation: .end, item: item, result: .dismissed, date: now, persist: false)
    }
    if !storedItems.isEmpty { finishHistoryMutation(date: now) }
    storedItems.removeAll()
    items.removeAll()
    deadlineTask?.cancel()
    deadlineTask = nil
  }

  /// Dismisses only what the user can currently see. Muted or delivery-filtered provider state is
  /// intentionally retained so a visible-stack action never silently destroys hidden work.
  func dismissVisible(now suppliedNow: Date? = nil) {
    let now = suppliedNow ?? clock.now
    let visibleIDs = Set(items.map(\.id))
    guard !visibleIDs.isEmpty else { return }
    let removed = storedItems.filter { visibleIDs.contains($0.id) }
    storedItems.removeAll { visibleIDs.contains($0.id) }
    for item in removed {
      record(operation: .end, item: item, result: .dismissed, date: now, persist: false)
    }
    finishHistoryMutation(date: now)
    refreshVisibleItems()
    scheduleDeadline()
  }

  func clearHistory() {
    history.removeAll()
    historyPersistenceIsReadOnly = false
    submitHistoryPersistence(.remove)
    flushHistoryPersistence()
  }

  func configureHistoryPersistence(
    enabled: Bool, retentionDays: Int, maximumEntries: Int, now: Date = Date()
  ) {
    historyConfiguration = PulseHistoryConfiguration(
      isEnabled: enabled, retentionDays: retentionDays, maximumEntries: maximumEntries)
    if enabled {
      history = PulseHistoryStore.retainedEntries(
        history, now: now, retentionDays: historyConfiguration.retentionDays,
        maximumEntries: historyConfiguration.maximumEntries)
      persistHistory(exportedAt: now)
    } else {
      historyPersistenceIsReadOnly = false
      submitHistoryPersistence(.remove)
      flushHistoryPersistence()
      if history.count > historyConfiguration.maximumEntries {
        history.removeLast(history.count - historyConfiguration.maximumEntries)
      }
    }
  }

  func exportHistoryData(exportedAt: Date = Date()) throws -> Data {
    try PulseHistoryStore.exportData(history, exportedAt: exportedAt)
  }

  private func validateRevision(
    _ revision: UInt64?, for id: PulseItem.ID, operation: PulseOperation, now: Date
  ) throws {
    try PulseRevision.validate(revision)
    pruneRevisionRecords(now: now)
    guard let record = revisionRecords[id] else {
      if revision != nil, revisionRecords.count >= Self.maximumRevisionRecords {
        throw OrderingError.capacity
      }
      return
    }
    guard let revision else { throw OrderingError.revisionRequired }
    guard revision > record.revision else { throw OrderingError.stale }
    if record.ended, operation == .update { throw OrderingError.generationEnded }
  }

  private func acceptRevision(
    _ revision: UInt64?, for id: PulseItem.ID, ended: Bool, now: Date
  ) {
    guard let revision else { return }
    revisionRecords[id] = PulseRevisionRecord(
      id: id, revision: revision, ended: ended, acceptedAt: now)
    persistRevisionRecords()
  }

  private func pruneRevisionRecords(now: Date) {
    let activeIDs = Set(storedItems.map(\.id))
    let originalCount = revisionRecords.count
    revisionRecords = revisionRecords.filter { id, record in
      activeIDs.contains(id) || !PulseRevisionPersistence.isExpired(record, now: now)
    }
    if revisionRecords.count != originalCount { persistRevisionRecords() }
  }

  private func persistRevisionRecords() {
    revisionWriter?.submit(revisionRecords)
  }

  /// Waits for the newest queued history operation. The disk work itself stays on the writer's
  /// utility queue so shutdown and deterministic tests retain ordered persistence.
  func flushHistoryPersistence() {
    guard let result = historyPersistenceWriter?.flush() else { return }
    completeHistoryPersistence(
      generation: result.generation, errorMessage: result.errorMessage)
  }

  func policy(for source: String) -> PulseSourcePolicy {
    sourcePolicies[sourceKey(source)] ?? .allowed
  }

  func policy(for descriptor: PulseProviderDescriptor) -> PulseSourcePolicy {
    let policies = Set(descriptor.sourceIDs.map { policy(for: $0) })
    return policies.count == 1 ? (policies.first ?? .allowed) : .muted
  }

  func setPolicy(
    _ policy: PulseSourcePolicy, for source: String, now suppliedNow: Date? = nil
  ) {
    let now = suppliedNow ?? clock.now
    let key = sourceKey(source)
    guard !key.isEmpty else { return }
    if policy == .allowed { sourcePolicies[key] = nil } else { sourcePolicies[key] = policy }
    Defaults[sourcePoliciesKey] = Self.persistedSourcePolicies(from: sourcePolicies)
    if policy == .revoked {
      let removed = storedItems.filter { sourceKey($0.source) == key }
      storedItems.removeAll { sourceKey($0.source) == key }
      for item in removed {
        record(operation: .end, item: item, result: .dismissed, date: now, persist: false)
      }
      if !removed.isEmpty { finishHistoryMutation(date: now) }
      scheduleDeadline()
    }
    refreshVisibleItems()
  }

  func setPolicy(
    _ policy: PulseSourcePolicy, for descriptor: PulseProviderDescriptor,
    now suppliedNow: Date? = nil
  ) {
    let now = suppliedNow ?? clock.now
    for source in descriptor.sourceIDs { setPolicy(policy, for: source, now: now) }
  }

  var providerStatuses: [PulseProviderStatus] {
    PulseProviderDescriptor.gallery.map { descriptor in
      let activeItems = storedItems.filter {
        $0.state != .stale && descriptor.sourceIDs.contains(sourceKey($0.source))
      }
      let attentionCount = activeItems.count { $0.state == .failed || $0.state == .needsAction }
      if attentionCount > 0 {
        return PulseProviderStatus(
          descriptor: descriptor, health: .needsAttention(attentionCount))
      }
      if !activeItems.isEmpty {
        return PulseProviderStatus(descriptor: descriptor, health: .active(activeItems.count))
      }
      let lastSeen = history.first {
        guard let source = $0.source else { return false }
        return descriptor.sourceIDs.contains(sourceKey(source))
      }?.date
      return PulseProviderStatus(
        descriptor: descriptor, health: lastSeen.map(PulseProviderHealth.seen) ?? .neverSeen)
    }
  }

  var unlistedSources: [String] {
    let listed = PulseProviderDescriptor.gallery.reduce(into: Set<String>()) {
      $0.formUnion($1.sourceIDs)
    }
    return Set(storedItems.map(\.source) + history.compactMap(\.source))
      .filter { !listed.contains(sourceKey($0)) }
      .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
  }

  @discardableResult
  private func upsertStored(
    _ item: PulseItem, operation: PulseOperation, now: Date
  ) -> Bool {
    if let index = storedItems.firstIndex(where: { $0.id == item.id }) {
      storedItems[index] = item
    } else {
      storedItems.append(item)
    }
    sortStoredItems()
    if storedItems.count > Self.maximumItems {
      let evicted = Array(storedItems.suffix(storedItems.count - Self.maximumItems))
      storedItems.removeLast(storedItems.count - Self.maximumItems)
      for item in evicted {
        record(operation: operation, item: item, result: .evicted, date: now)
      }
    }
    scheduleDeadline()
    return storedItems.contains { $0.id == item.id }
  }

  private func refreshVisibleItems() {
    items = storedItems.filter(shouldPresent)
  }

  private func shouldPresent(_ item: PulseItem) -> Bool {
    policy(for: item.source) == .allowed && effectiveDeliveryProfile.allows(item)
  }

  private func sortStoredItems() {
    storedItems.sort {
      if $0.priority != $1.priority { return $0.priority > $1.priority }
      let leftNeedsAction = [.needsAction, .failed, .stale].contains($0.state)
      let rightNeedsAction = [.needsAction, .failed, .stale].contains($1.state)
      if leftNeedsAction != rightNeedsAction { return leftNeedsAction }
      return $0.updatedAt > $1.updatedAt
    }
  }

  private func scheduleDeadline() {
    deadlineTask?.cancel()
    let deadlines = storedItems.flatMap { item in
      [item.expiresAt, item.staleAt, item.staleRemovalAt].compactMap { $0 }
    }
    guard let next = deadlines.min() else {
      deadlineTask = nil
      return
    }
    deadlineTask = deadlineScheduler.schedule(at: next) { [weak self] in
      self?.deadlineReached()
    }
  }

  private func deadlineReached() {
    processDeadlines(now: clock.now)
    scheduleDeadline()
  }

  private func processDeadlines(now: Date) {
    let providerExpired = storedItems.filter { ($0.expiresAt ?? .distantFuture) <= now }
    storedItems.removeAll { ($0.expiresAt ?? .distantFuture) <= now }
    for item in providerExpired {
      record(operation: .end, item: item, result: .expired, date: now, persist: false)
    }

    var newlyStale: [PulseItem] = []
    for index in storedItems.indices {
      guard let staleAt = storedItems[index].staleAt, staleAt <= now,
        storedItems[index].state.receivesStaleDeadline
      else { continue }
      storedItems[index].state = .stale
      storedItems[index].staleAt = nil
      storedItems[index].staleRemovalAt = staleAt.addingTimeInterval(
        stalenessPolicy.retention)
      newlyStale.append(storedItems[index])
    }
    for item in newlyStale {
      record(operation: .update, item: item, result: .stale, date: now, persist: false)
    }

    let staleExpired = storedItems.filter { ($0.staleRemovalAt ?? .distantFuture) <= now }
    storedItems.removeAll { ($0.staleRemovalAt ?? .distantFuture) <= now }
    for item in staleExpired {
      record(operation: .end, item: item, result: .expired, date: now, persist: false)
    }
    guard !providerExpired.isEmpty || !newlyStale.isEmpty || !staleExpired.isEmpty else { return }
    finishHistoryMutation(date: now)
    sortStoredItems()
    refreshVisibleItems()
  }

  private func record(
    operation: PulseOperation, item: PulseItem?, result: PulseHistoryResult, date: Date,
    persist: Bool = true
  ) {
    history.insert(
      PulseHistoryEntry(
        id: UUID(), date: date, operation: operation, source: item?.source,
        providerIdentifier: item?.providerIdentifier, state: item?.state,
        priority: item?.priority, result: result),
      at: 0)
    if persist { finishHistoryMutation(date: date) }
  }

  private func finishHistoryMutation(date: Date) {
    if historyConfiguration.isEnabled {
      history = PulseHistoryStore.retainedEntries(
        history, now: date, retentionDays: historyConfiguration.retentionDays,
        maximumEntries: historyConfiguration.maximumEntries)
      persistHistory(exportedAt: date)
    } else if history.count > historyConfiguration.maximumEntries {
      history.removeLast(history.count - historyConfiguration.maximumEntries)
    }
  }

  private func persistHistory(exportedAt: Date) {
    guard historyConfiguration.isEnabled, !historyPersistenceIsReadOnly else {
      return
    }
    let operation: PulseHistoryPersistenceOperation =
      history.isEmpty ? .remove : .save(entries: history, exportedAt: exportedAt)
    submitHistoryPersistence(operation)
  }

  private func submitHistoryPersistence(_ operation: PulseHistoryPersistenceOperation) {
    guard let historyPersistenceWriter else { return }
    historyPersistenceGeneration &+= 1
    historyPersistenceWriter.submit(operation, generation: historyPersistenceGeneration)
  }

  private func completeHistoryPersistence(generation: UInt64, errorMessage: String?) {
    guard generation == historyPersistenceGeneration else { return }
    historyPersistenceError = errorMessage
  }

  private func sourceKey(_ source: String) -> String {
    Self.sourceKey(source)
  }

  private static func restoreSourcePolicies(
    from storedPolicies: [String: String]
  ) -> [String: PulseSourcePolicy] {
    storedPolicies.reduce(into: [:]) { policies, entry in
      let key = sourceKey(entry.key)
      guard !key.isEmpty, let policy = PulseSourcePolicy(rawValue: entry.value), policy != .allowed
      else { return }
      if policy == .revoked || policies[key] == nil {
        policies[key] = policy
      }
    }
  }

  private static func persistedSourcePolicies(
    from policies: [String: PulseSourcePolicy]
  ) -> [String: String] {
    policies.reduce(into: [:]) { persisted, entry in
      let key = sourceKey(entry.key)
      guard !key.isEmpty, entry.value != .allowed else { return }
      if entry.value == .revoked || persisted[key] == nil {
        persisted[key] = entry.value.rawValue
      }
    }
  }

  private static func sourceKey(_ source: String) -> String {
    (try? PulseItem.normalizedSourceKey(source)) ?? ""
  }
}
