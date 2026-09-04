import Foundation

struct PulseRevisionPersistenceStore: Sendable {
  let readData: @Sendable () -> Data?
  let writeData: @Sendable (Data?) -> Void

  static var defaults: Self {
    let key = "pulseRevisionStateData"
    return Self(
      readData: { UserDefaults.standard.data(forKey: key) },
      writeData: { data in
        if let data {
          UserDefaults.standard.set(data, forKey: key)
        } else {
          UserDefaults.standard.removeObject(forKey: key)
        }
      })
  }
}

struct PulseRevisionRecord: Codable, Equatable, Sendable {
  let normalizedSource: String
  let providerIdentifier: String
  let revision: UInt64
  let ended: Bool
  let acceptedAt: Date

  init(id: PulseItem.ID, revision: UInt64, ended: Bool, acceptedAt: Date) {
    normalizedSource = id.normalizedSource
    providerIdentifier = id.providerIdentifier
    self.revision = revision
    self.ended = ended
    self.acceptedAt = acceptedAt
  }
}

private struct PulseRevisionSnapshot: Codable {
  static let currentVersion = 1

  let version: Int
  let records: [PulseRevisionRecord]

  init(records: [PulseRevisionRecord]) {
    version = Self.currentVersion
    self.records = records
  }
}

struct PulseRevisionRestoration {
  let records: [PulseItem.ID: PulseRevisionRecord]
  let requiresRewrite: Bool
}

enum PulseRevisionPersistence {
  static let maximumRecordAge: TimeInterval = 30 * 24 * 60 * 60
  static let maximumDocumentBytes = 4 * 1_024 * 1_024

  static func restore(
    from store: PulseRevisionPersistenceStore, now: Date, maximumRecords: Int
  ) -> PulseRevisionRestoration {
    guard let data = store.readData() else {
      return PulseRevisionRestoration(records: [:], requiresRewrite: false)
    }
    guard data.count <= maximumDocumentBytes,
      let snapshot = try? JSONDecoder().decode(PulseRevisionSnapshot.self, from: data),
      snapshot.version == PulseRevisionSnapshot.currentVersion,
      snapshot.records.count <= maximumRecords
    else {
      return PulseRevisionRestoration(records: [:], requiresRewrite: true)
    }

    var restored: [PulseItem.ID: PulseRevisionRecord] = [:]
    var removedExpiredRecord = false
    for record in snapshot.records {
      guard record.acceptedAt.timeIntervalSinceReferenceDate.isFinite,
        record.revision <= PulseRevision.maximum,
        let id = try? PulseItem.ID(
          source: record.normalizedSource, providerIdentifier: record.providerIdentifier),
        id.normalizedSource == record.normalizedSource,
        id.providerIdentifier == record.providerIdentifier,
        restored[id] == nil
      else {
        return PulseRevisionRestoration(records: [:], requiresRewrite: true)
      }
      if isExpired(record, now: now) {
        removedExpiredRecord = true
        continue
      }
      restored[id] = record
    }

    return PulseRevisionRestoration(
      records: restored, requiresRewrite: removedExpiredRecord)
  }

  @discardableResult
  static func save(
    _ records: [PulseItem.ID: PulseRevisionRecord], to store: PulseRevisionPersistenceStore,
    maximumBytes: Int = maximumDocumentBytes
  ) -> Bool {
    guard !records.isEmpty else {
      store.writeData(nil)
      return true
    }
    let orderedRecords = records.values.sorted {
      if $0.normalizedSource != $1.normalizedSource {
        return $0.normalizedSource < $1.normalizedSource
      }
      return $0.providerIdentifier < $1.providerIdentifier
    }
    guard let data = try? JSONEncoder().encode(PulseRevisionSnapshot(records: orderedRecords)),
      data.count <= maximumBytes
    else { return false }
    store.writeData(data)
    return true
  }

  static func isExpired(_ record: PulseRevisionRecord, now: Date) -> Bool {
    guard now.timeIntervalSinceReferenceDate.isFinite else { return false }
    return now.timeIntervalSince(record.acceptedAt) > maximumRecordAge
  }
}

/// Serializes and writes only the newest pending revision snapshot. Encoding and UserDefaults I/O
/// stay off the main actor; the serial queue preserves write order when a write is already running.
final class PulseRevisionPersistenceWriter: @unchecked Sendable {
  static let defaultCoalescingDelay: TimeInterval = 0.25

  private let queue = DispatchQueue(label: "dev.islet.pulse-revision-persistence")
  private let lock = NSLock()
  private let store: PulseRevisionPersistenceStore
  private let coalescingDelay: TimeInterval
  private var pendingRecords: [PulseItem.ID: PulseRevisionRecord]?
  private var scheduledGeneration: UInt64 = 0
  private var scheduledWorkItem: DispatchWorkItem?

  init(
    store: PulseRevisionPersistenceStore,
    coalescingDelay: TimeInterval = defaultCoalescingDelay
  ) {
    self.store = store
    self.coalescingDelay = max(0, coalescingDelay)
  }

  func submit(_ records: [PulseItem.ID: PulseRevisionRecord]) {
    lock.lock()
    pendingRecords = records
    scheduledGeneration &+= 1
    let generation = scheduledGeneration
    scheduledWorkItem?.cancel()
    let workItem = DispatchWorkItem { [weak self] in
      self?.persistIfCurrent(generation: generation)
    }
    scheduledWorkItem = workItem
    lock.unlock()
    queue.asyncAfter(deadline: .now() + coalescingDelay, execute: workItem)
  }

  @discardableResult
  func flush() -> Bool {
    lock.lock()
    scheduledWorkItem?.cancel()
    scheduledWorkItem = nil
    scheduledGeneration &+= 1
    let records = pendingRecords
    pendingRecords = nil
    lock.unlock()

    return queue.sync {
      guard let records else { return true }
      return PulseRevisionPersistence.save(records, to: store)
    }
  }

  private func persistIfCurrent(generation: UInt64) {
    lock.lock()
    guard generation == scheduledGeneration, let records = pendingRecords else {
      lock.unlock()
      return
    }
    pendingRecords = nil
    scheduledWorkItem = nil
    lock.unlock()
    PulseRevisionPersistence.save(records, to: store)
  }
}
