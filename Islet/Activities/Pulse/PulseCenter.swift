import Combine
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
  @Published var deliveryProfile: PulseDeliveryProfile = .everything {
    didSet {
      guard deliveryProfile != oldValue else { return }
      refreshVisibleItems()
    }
  }
  private var storedItems: [PulseItem] = []
  private var expiryTask: Task<Void, Never>?

  var primary: PulseItem? { items.first }

  @discardableResult
  func apply(_ command: PulseCommand, now: Date = Date()) -> PulseResponse {
    do {
      removeExpired(now: now)
      switch command.operation {
      case .show, .update, .event:
        guard var payload = command.activity else {
          record(operation: command.operation, item: nil, result: .rejected, date: now)
          return .failure("activity is required for \(command.operation.rawValue)")
        }
        if command.operation == .event, payload.expiresAt == nil {
          payload.expiresAt = now.addingTimeInterval(8)
        }
        let previous = storedItems.first { $0.id == payload.id }
        let item = try PulseItem(payload: payload, now: now, previous: previous)
        guard policy(for: item.source) != .revoked else {
          record(operation: command.operation, item: nil, result: .rejected, date: now)
          return .failure("source is revoked in Islet Settings")
        }
        let visible = shouldPresent(item)
        upsertStored(item, operation: command.operation, now: now)
        record(
          operation: command.operation, item: item,
          result: visible ? (previous == nil ? .shown : .updated) : .suppressed, date: now)
        refreshVisibleItems()
        return .success(id: item.id)
      case .end:
        guard let rawIdentifier = command.id ?? command.activity?.id else {
          record(operation: .end, item: nil, result: .rejected, date: now)
          return .failure("id is required for end")
        }
        let identifier = try PulseItem.normalizedIdentifier(rawIdentifier)
        if let item = storedItems.first(where: { $0.id == identifier }) {
          storedItems.removeAll { $0.id == identifier }
          record(operation: .end, item: item, result: .ended, date: now)
        }
        refreshVisibleItems()
        scheduleExpiry()
        return .success(id: identifier)
      }
    } catch {
      // Rejected wire data and error descriptions can contain secrets. Only the operation and
      // outcome are retained for local diagnostics.
      record(operation: command.operation, item: nil, result: .rejected, date: now)
      return .failure(error.localizedDescription)
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
      let activeCount = storedItems.count {
        descriptor.sourceIDs.contains(sourceKey($0.source))
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

  private func upsertStored(_ item: PulseItem, operation: PulseOperation, now: Date) {
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
        id: UUID(), date: date, operation: operation, itemID: item?.id,
        source: item?.source, state: item?.state, priority: item?.priority, result: result),
      at: 0)
    if history.count > Self.maximumHistoryEntries {
      history.removeLast(history.count - Self.maximumHistoryEntries)
    }
  }

  private func sourceKey(_ source: String) -> String {
    source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }
}
