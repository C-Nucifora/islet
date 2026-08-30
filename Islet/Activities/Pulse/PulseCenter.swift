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
  static let shared = PulseCenter()
  static let maximumItems = 100
  static let maximumHistoryEntries = 200

  /// The presentation slice. `storedItems` also retains still-live filtered and muted work so
  /// changing a profile can reveal it again without requiring a provider retransmission.
  @Published private(set) var items: [PulseItem] = []
  @Published private(set) var history: [PulseHistoryEntry] = []
  @Published private(set) var sourcePolicies: [String: PulseSourcePolicy] = [:]
  @Published var deliveryProfile: PulseDeliveryProfile = .everything {
    didSet {
      guard deliveryProfile != oldValue else { return }
      refreshVisibleItems()
    }
  }
  private var storedItems: [PulseItem] = []
  private var deadlineTask: PulseDeadlineTask?
  private let clock: any PulseClock
  private let deadlineScheduler: any PulseDeadlineScheduling
  private var stalenessPolicy: PulseStalenessPolicy

  init(
    staleTimeout: TimeInterval = Defaults[.pulseStaleTimeout],
    staleRetention: TimeInterval = PulseStalenessPolicy.defaultRetention,
    clock: (any PulseClock)? = nil,
    scheduler: (any PulseDeadlineScheduling)? = nil
  ) {
    let resolvedClock = clock ?? PulseSystemClock()
    self.clock = resolvedClock
    deadlineScheduler = scheduler ?? PulseSystemDeadlineScheduler(clock: resolvedClock)
    stalenessPolicy = PulseStalenessPolicy(
      timeout: staleTimeout, retention: staleRetention)
  }

  var primary: PulseItem? { items.first }
  var retainedItemCount: Int { storedItems.count }
  var hiddenItemCount: Int { max(0, storedItems.count - items.count) }
  var staleTimeout: TimeInterval { stalenessPolicy.timeout }

  @discardableResult
  func applyIfEnabled(
    _ command: PulseCommand, now: Date? = nil, featureEnabled: Bool = Defaults[.pulseEnabled]
  ) -> PulseResponse {
    guard featureEnabled else {
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
        let previous = storedItems.first { $0.id == incomingID }
        let item = try PulseItem(
          payload: payload, now: now, previous: previous,
          staleTimeout: stalenessPolicy.timeout)
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
        record(
          operation: command.operation, item: item,
          result: visible ? (previous == nil ? .shown : .updated) : .suppressed, date: now)
        refreshVisibleItems()
        return .success(id: item.providerIdentifier, requestID: command.requestID)
      case .end:
        guard let rawIdentifier = command.id ?? command.activity?.id else {
          record(operation: .end, item: nil, result: .rejected, date: now)
          return .failure(
            "id is required for end", code: .invalidCommand, requestID: command.requestID)
        }
        let identifier = try PulseItem.normalizedIdentifier(rawIdentifier)
        let matchingItems = storedItems.filter { $0.providerIdentifier == identifier }
        if let source = command.source {
          let scopedID = try PulseItem.ID(source: source, providerIdentifier: identifier)
          if let item = storedItems.first(where: { $0.id == scopedID }) {
            storedItems.removeAll { $0.id == scopedID }
            record(operation: .end, item: item, result: .ended, date: now)
          } else if !matchingItems.isEmpty {
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
        } else if let item = matchingItems.first {
          storedItems.removeAll { $0.id == item.id }
          record(operation: .end, item: item, result: .ended, date: now)
        }
        refreshVisibleItems()
        scheduleDeadline()
        return .success(id: identifier, requestID: command.requestID)
      }
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
      record(operation: .end, item: item, result: .dismissed, date: now)
    }
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
      record(operation: .end, item: item, result: .dismissed, date: now)
    }
    refreshVisibleItems()
    scheduleDeadline()
  }

  func clearHistory() { history.removeAll() }

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
    if policy == .revoked {
      let removed = storedItems.filter { sourceKey($0.source) == key }
      storedItems.removeAll { sourceKey($0.source) == key }
      for item in removed {
        record(operation: .end, item: item, result: .dismissed, date: now)
      }
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
      let activeCount = storedItems.count {
        $0.state != .stale && descriptor.sourceIDs.contains(sourceKey($0.source))
      }
      if activeCount > 0 {
        return PulseProviderStatus(descriptor: descriptor, health: .active(activeCount))
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
    policy(for: item.source) == .allowed && deliveryProfile.allows(item)
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
      record(operation: .end, item: item, result: .expired, date: now)
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
      record(operation: .update, item: item, result: .stale, date: now)
    }

    let staleExpired = storedItems.filter { ($0.staleRemovalAt ?? .distantFuture) <= now }
    storedItems.removeAll { ($0.staleRemovalAt ?? .distantFuture) <= now }
    for item in staleExpired {
      record(operation: .end, item: item, result: .expired, date: now)
    }
    guard !providerExpired.isEmpty || !newlyStale.isEmpty || !staleExpired.isEmpty else { return }
    sortStoredItems()
    refreshVisibleItems()
  }

  private func record(
    operation: PulseOperation, item: PulseItem?, result: PulseHistoryResult, date: Date
  ) {
    history.insert(
      PulseHistoryEntry(
        id: UUID(), date: date, operation: operation, source: item?.source,
        providerIdentifier: item?.providerIdentifier, state: item?.state,
        priority: item?.priority, result: result),
      at: 0)
    if history.count > Self.maximumHistoryEntries {
      history.removeLast(history.count - Self.maximumHistoryEntries)
    }
  }

  private func sourceKey(_ source: String) -> String {
    (try? PulseItem.normalizedSourceKey(source)) ?? ""
  }
}
