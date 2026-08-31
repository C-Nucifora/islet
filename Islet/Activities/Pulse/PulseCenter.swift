import Combine
import Defaults
import Foundation

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
  @Published var deliveryProfile: PulseDeliveryProfile {
    didSet {
      guard deliveryProfile != oldValue else { return }
      Defaults[deliveryProfileKey] = deliveryProfile
      refreshVisibleItems()
    }
  }
  private let deliveryProfileKey: Defaults.Key<PulseDeliveryProfile>
  private let symbolAvailability: (String) -> Bool?
  private var storedItems: [PulseItem] = []
  private var expiryTask: Task<Void, Never>?

  init(
    symbolAvailability: @escaping (String) -> Bool? = PulseSymbolValidator.platformAvailability,
    deliveryProfileKey: Defaults.Key<PulseDeliveryProfile> = .pulseDeliveryProfile
  ) {
    self.symbolAvailability = symbolAvailability
    self.deliveryProfileKey = deliveryProfileKey
    deliveryProfile = Defaults[deliveryProfileKey]
  }

  var primary: PulseItem? { items.first }
  var retainedItemCount: Int { storedItems.count }
  var hiddenItemCount: Int { max(0, storedItems.count - items.count) }

  @discardableResult
  func applyIfEnabled(
    _ command: PulseCommand, now: Date = Date(),
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
  func apply(_ command: PulseCommand, now: Date = Date()) -> PulseResponse {
    do {
      removeExpired(now: now)
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
        let normalizedIncomingID = try PulseItem.normalizedIdentifier(payload.id)
        let previous = storedItems.first { $0.id == normalizedIncomingID }
        let item = try PulseItem(
          payload: payload, now: now, previous: previous, symbolAvailability: symbolAvailability)
        if let previous, sourceKey(previous.source) != sourceKey(item.source) {
          record(operation: command.operation, item: nil, result: .rejected, date: now)
          return .failure(
            "id is already active under a different source", code: .identifierConflict,
            requestID: command.requestID)
        }
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
        return .success(
          id: item.id, warning: item.symbolWarning?.localizedDescription,
          requestID: command.requestID)
      case .end:
        guard let rawIdentifier = command.id ?? command.activity?.id else {
          record(operation: .end, item: nil, result: .rejected, date: now)
          return .failure(
            "id is required for end", code: .invalidCommand, requestID: command.requestID)
        }
        let identifier = try PulseItem.normalizedIdentifier(rawIdentifier)
        let normalizedEndSource = try command.source.map(PulseItem.normalizedSource)
        if let item = storedItems.first(where: { $0.id == identifier }) {
          if let normalizedEndSource {
            guard sourceKey(normalizedEndSource) == sourceKey(item.source) else {
              record(operation: .end, item: nil, result: .rejected, date: now)
              return .failure(
                "id belongs to a different source", code: .sourceMismatch,
                requestID: command.requestID)
            }
          }
          storedItems.removeAll { $0.id == identifier }
          record(operation: .end, item: item, result: .ended, date: now)
        }
        refreshVisibleItems()
        scheduleExpiry()
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

  func dismiss(_ id: String, now: Date = Date()) {
    guard let item = storedItems.first(where: { $0.id == id }) else { return }
    storedItems.removeAll { $0.id == id }
    record(operation: .end, item: item, result: .dismissed, date: now)
    refreshVisibleItems()
    scheduleExpiry()
  }

  func removeAll(now: Date = Date()) {
    for item in storedItems {
      record(operation: .end, item: item, result: .dismissed, date: now)
    }
    storedItems.removeAll()
    items.removeAll()
    expiryTask?.cancel()
    expiryTask = nil
  }

  /// Dismisses only what the user can currently see. Muted or delivery-filtered provider state is
  /// intentionally retained so a visible-stack action never silently destroys hidden work.
  func dismissVisible(now: Date = Date()) {
    let visibleIDs = Set(items.map(\.id))
    guard !visibleIDs.isEmpty else { return }
    let removed = storedItems.filter { visibleIDs.contains($0.id) }
    storedItems.removeAll { visibleIDs.contains($0.id) }
    for item in removed {
      record(operation: .end, item: item, result: .dismissed, date: now)
    }
    refreshVisibleItems()
    scheduleExpiry()
  }

  func clearHistory() { history.removeAll() }

  func policy(for source: String) -> PulseSourcePolicy {
    sourcePolicies[sourceKey(source)] ?? .allowed
  }

  func policy(for descriptor: PulseProviderDescriptor) -> PulseSourcePolicy {
    let policies = Set(descriptor.sourceIDs.map { policy(for: $0) })
    return policies.count == 1 ? (policies.first ?? .allowed) : .muted
  }

  func setPolicy(_ policy: PulseSourcePolicy, for source: String, now: Date = Date()) {
    let key = sourceKey(source)
    guard !key.isEmpty else { return }
    if policy == .allowed { sourcePolicies[key] = nil } else { sourcePolicies[key] = policy }
    if policy == .revoked {
      let removed = storedItems.filter { sourceKey($0.source) == key }
      storedItems.removeAll { sourceKey($0.source) == key }
      for item in removed {
        record(operation: .end, item: item, result: .dismissed, date: now)
      }
      scheduleExpiry()
    }
    refreshVisibleItems()
  }

  func setPolicy(
    _ policy: PulseSourcePolicy, for descriptor: PulseProviderDescriptor, now: Date = Date()
  ) {
    for source in descriptor.sourceIDs { setPolicy(policy, for: source, now: now) }
  }

  var providerStatuses: [PulseProviderStatus] {
    PulseProviderDescriptor.gallery.map { descriptor in
      let activeItems = storedItems.filter {
        descriptor.sourceIDs.contains(sourceKey($0.source))
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
    scheduleExpiry()
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
      let leftNeedsAction = $0.state == .needsAction || $0.state == .failed
      let rightNeedsAction = $1.state == .needsAction || $1.state == .failed
      if leftNeedsAction != rightNeedsAction { return leftNeedsAction }
      return $0.updatedAt > $1.updatedAt
    }
  }

  private func scheduleExpiry() {
    expiryTask?.cancel()
    guard let next = storedItems.compactMap(\.expiresAt).min() else {
      expiryTask = nil
      return
    }
    expiryTask = Task { [weak self] in
      let delay = max(0, next.timeIntervalSinceNow)
      try? await Task.sleep(for: .seconds(delay))
      guard !Task.isCancelled else { return }
      self?.expire(now: Date())
    }
  }

  private func expire(now: Date) {
    removeExpired(now: now)
    scheduleExpiry()
  }

  private func removeExpired(now: Date) {
    let expired = storedItems.filter { ($0.expiresAt ?? .distantFuture) <= now }
    guard !expired.isEmpty else { return }
    storedItems.removeAll { ($0.expiresAt ?? .distantFuture) <= now }
    for item in expired {
      record(operation: .end, item: item, result: .expired, date: now)
    }
    refreshVisibleItems()
  }

  private func record(
    operation: PulseOperation, item: PulseItem?, result: PulseHistoryResult, date: Date
  ) {
    history.insert(
      PulseHistoryEntry(
        id: UUID(), date: date, operation: operation, source: item?.source,
        state: item?.state, priority: item?.priority, result: result),
      at: 0)
    if history.count > Self.maximumHistoryEntries {
      history.removeLast(history.count - Self.maximumHistoryEntries)
    }
  }

  private func sourceKey(_ source: String) -> String {
    source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }
}
