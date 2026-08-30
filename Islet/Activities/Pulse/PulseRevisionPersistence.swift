import Defaults
import Foundation

@MainActor
struct PulseRevisionPersistenceStore {
  let readData: () -> Data?
  let writeData: (Data?) -> Void

  static var defaults: Self {
    Self(
      readData: { Defaults[.pulseRevisionStateData] },
      writeData: { Defaults[.pulseRevisionStateData] = $0 })
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

enum PulseRevisionPersistence {
  static let maximumRecordAge: TimeInterval = 30 * 24 * 60 * 60
  static let maximumDocumentBytes = 4 * 1_024 * 1_024

  @MainActor
  static func restore(
    from store: PulseRevisionPersistenceStore, now: Date, maximumRecords: Int
  ) -> [PulseItem.ID: PulseRevisionRecord] {
    guard let data = store.readData() else { return [:] }
    guard data.count <= maximumDocumentBytes,
      let snapshot = try? JSONDecoder().decode(PulseRevisionSnapshot.self, from: data),
      snapshot.version == PulseRevisionSnapshot.currentVersion,
      snapshot.records.count <= maximumRecords
    else {
      store.writeData(nil)
      return [:]
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
        store.writeData(nil)
        return [:]
      }
      if isExpired(record, now: now) {
        removedExpiredRecord = true
        continue
      }
      restored[id] = record
    }

    if removedExpiredRecord { save(restored, to: store) }
    return restored
  }

  @MainActor
  static func save(
    _ records: [PulseItem.ID: PulseRevisionRecord], to store: PulseRevisionPersistenceStore
  ) {
    guard !records.isEmpty else {
      store.writeData(nil)
      return
    }
    let orderedRecords = records.values.sorted {
      if $0.normalizedSource != $1.normalizedSource {
        return $0.normalizedSource < $1.normalizedSource
      }
      return $0.providerIdentifier < $1.providerIdentifier
    }
    guard let data = try? JSONEncoder().encode(PulseRevisionSnapshot(records: orderedRecords)),
      data.count <= maximumDocumentBytes
    else { return }
    store.writeData(data)
  }

  static func isExpired(_ record: PulseRevisionRecord, now: Date) -> Bool {
    guard now.timeIntervalSinceReferenceDate.isFinite else { return false }
    return now.timeIntervalSince(record.acceptedAt) > maximumRecordAge
  }
}
