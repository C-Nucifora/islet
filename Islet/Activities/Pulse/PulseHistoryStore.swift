import Darwin
import Foundation

struct PulseHistoryConfiguration: Equatable, Sendable {
  static let allowedRetentionDays = [1, 7, 30, 90]
  static let allowedEntryCounts = [50, 100, 200, 500]
  static let defaultRetentionDays = 7
  static let defaultMaximumEntries = 200

  let isEnabled: Bool
  let retentionDays: Int
  let maximumEntries: Int

  init(isEnabled: Bool, retentionDays: Int, maximumEntries: Int) {
    self.isEnabled = isEnabled
    self.retentionDays =
      Self.allowedRetentionDays.contains(retentionDays)
      ? retentionDays : Self.defaultRetentionDays
    self.maximumEntries =
      Self.allowedEntryCounts.contains(maximumEntries)
      ? maximumEntries : Self.defaultMaximumEntries
  }

  static let sessionOnly = PulseHistoryConfiguration(
    isEnabled: false, retentionDays: defaultRetentionDays,
    maximumEntries: defaultMaximumEntries)
}

struct PulseHistoryLoadResult: Equatable {
  let entries: [PulseHistoryEntry]
  let needsRewrite: Bool
}

enum PulseHistoryStoreError: LocalizedError, Equatable {
  case documentTooLarge
  case invalidDocument
  case unsupportedVersion(Int)

  var errorDescription: String? {
    switch self {
    case .documentTooLarge: "The saved Pulse history exceeds its size limit."
    case .invalidDocument: "The saved Pulse history is not valid."
    case .unsupportedVersion(let version):
      "The saved Pulse history uses unsupported version \(version)."
    }
  }
}

/// Stores only `PulseHistoryEntry`. The wire payload, bearer token, item identifier, title,
/// subtitle, action text, URLs, progress, accent, symbol, and error text never enter this type.
struct PulseHistoryStore: @unchecked Sendable {
  static let currentVersion = 2
  static let formatIdentifier = "dev.islet.pulse-history"
  static let maximumDocumentBytes = 512 * 1024
  static let maximumDecodedEntries = 2_000

  let fileURL: URL
  private let fileManager: FileManager

  init(
    fileURL: URL = PulsePaths.supportDirectory.appendingPathComponent("pulse-history.json"),
    fileManager: FileManager = .default
  ) {
    self.fileURL = fileURL
    self.fileManager = fileManager
  }

  func load(
    now: Date, retentionDays: Int, maximumEntries: Int
  ) throws -> PulseHistoryLoadResult {
    guard fileManager.fileExists(atPath: fileURL.path) else {
      return PulseHistoryLoadResult(entries: [], needsRewrite: false)
    }
    let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
    guard attributes[.type] as? FileAttributeType == .typeRegular else {
      throw PulseHistoryStoreError.invalidDocument
    }
    if let owner = attributes[.ownerAccountID] as? NSNumber,
      owner.uint32Value != getuid()
    {
      throw PulseHistoryStoreError.invalidDocument
    }
    guard let fileSize = attributes[.size] as? NSNumber,
      fileSize.intValue <= Self.maximumDocumentBytes
    else { throw PulseHistoryStoreError.documentTooLarge }

    let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
    guard data.count <= Self.maximumDocumentBytes else {
      throw PulseHistoryStoreError.documentTooLarge
    }
    let decoded = try Self.decode(data)
    let retained = Self.retainedEntries(
      decoded.entries, now: now, retentionDays: retentionDays, maximumEntries: maximumEntries)
    return PulseHistoryLoadResult(
      entries: retained, needsRewrite: decoded.needsRewrite || retained != decoded.entries)
  }

  func save(_ entries: [PulseHistoryEntry], exportedAt: Date = Date()) throws {
    let data = try Self.exportData(entries, exportedAt: exportedAt)
    let directory = fileURL.deletingLastPathComponent()
    try fileManager.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    let temporaryURL = directory.appendingPathComponent(
      ".pulse-history-\(UUID().uuidString).tmp")
    guard
      fileManager.createFile(
        atPath: temporaryURL.path, contents: data,
        attributes: [.posixPermissions: 0o600])
    else { throw CocoaError(.fileWriteUnknown) }
    defer { try? fileManager.removeItem(at: temporaryURL) }
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporaryURL.path)
    let renameResult = temporaryURL.path.withCString { source in
      fileURL.path.withCString { destination in Darwin.rename(source, destination) }
    }
    guard renameResult == 0 else {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
  }

  func remove() throws {
    guard fileManager.fileExists(atPath: fileURL.path) else { return }
    try fileManager.removeItem(at: fileURL)
  }

  static func exportData(
    _ entries: [PulseHistoryEntry], exportedAt: Date = Date()
  ) throws -> Data {
    guard entries.count <= PulseHistoryConfiguration.allowedEntryCounts.last ?? 500 else {
      throw PulseHistoryStoreError.invalidDocument
    }
    let document = CurrentDocument(
      format: formatIdentifier, version: currentVersion, exportedAt: exportedAt, entries: entries)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(document)
    guard data.count <= maximumDocumentBytes else {
      throw PulseHistoryStoreError.documentTooLarge
    }
    return data
  }

  static func retainedEntries(
    _ entries: [PulseHistoryEntry], now: Date, retentionDays: Int, maximumEntries: Int
  ) -> [PulseHistoryEntry] {
    let configuration = PulseHistoryConfiguration(
      isEnabled: true, retentionDays: retentionDays, maximumEntries: maximumEntries)
    let cutoff = now.addingTimeInterval(-TimeInterval(configuration.retentionDays * 24 * 60 * 60))
    var seen = Set<UUID>()
    return
      entries
      .filter { $0.date >= cutoff && $0.date <= now.addingTimeInterval(24 * 60 * 60) }
      .sorted { $0.date > $1.date }
      .filter { seen.insert($0.id).inserted }
      .prefix(configuration.maximumEntries)
      .map { $0 }
  }

  private static func decode(_ data: Data) throws -> PulseHistoryLoadResult {
    let raw: Any
    do {
      raw = try JSONSerialization.jsonObject(with: data)
    } catch {
      throw PulseHistoryStoreError.invalidDocument
    }
    guard let object = raw as? [String: Any], let version = object["version"] as? Int else {
      throw PulseHistoryStoreError.invalidDocument
    }
    try validateDocumentShape(object, version: version)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    do {
      switch version {
      case 1:
        let legacy = try decoder.decode(LegacyDocument.self, from: data)
        guard legacy.history.count <= maximumDecodedEntries else {
          throw PulseHistoryStoreError.invalidDocument
        }
        try validate(legacy.history)
        return PulseHistoryLoadResult(entries: legacy.history, needsRewrite: true)
      case currentVersion:
        let current = try decoder.decode(CurrentDocument.self, from: data)
        guard current.format == formatIdentifier,
          current.entries.count <= maximumDecodedEntries
        else { throw PulseHistoryStoreError.invalidDocument }
        try validate(current.entries)
        return PulseHistoryLoadResult(entries: current.entries, needsRewrite: false)
      default:
        throw PulseHistoryStoreError.unsupportedVersion(version)
      }
    } catch let error as PulseHistoryStoreError {
      throw error
    } catch {
      throw PulseHistoryStoreError.invalidDocument
    }
  }

  private static func validateDocumentShape(
    _ object: [String: Any], version: Int
  ) throws {
    let entriesKey: String
    let expectedDocumentKeys: Set<String>
    switch version {
    case 1:
      entriesKey = "history"
      expectedDocumentKeys = ["history", "version"]
    case currentVersion:
      entriesKey = "entries"
      expectedDocumentKeys = ["entries", "exportedAt", "format", "version"]
    default:
      throw PulseHistoryStoreError.unsupportedVersion(version)
    }
    guard Set(object.keys) == expectedDocumentKeys,
      let rawEntries = object[entriesKey] as? [[String: Any]],
      rawEntries.count <= maximumDecodedEntries
    else { throw PulseHistoryStoreError.invalidDocument }

    let allowedEntryKeys: Set<String> = [
      "date", "id", "operation", "priority", "result", "source", "state",
    ]
    let requiredEntryKeys: Set<String> = ["date", "id", "operation", "result"]
    for rawEntry in rawEntries {
      let keys = Set(rawEntry.keys)
      guard keys.isSubset(of: allowedEntryKeys), requiredEntryKeys.isSubset(of: keys) else {
        throw PulseHistoryStoreError.invalidDocument
      }
    }
  }

  private static func validate(_ entries: [PulseHistoryEntry]) throws {
    for entry in entries {
      guard entry.date.timeIntervalSince1970.isFinite else {
        throw PulseHistoryStoreError.invalidDocument
      }
      if let source = entry.source {
        guard (try? PulseItem.normalizedSource(source)) == source else {
          throw PulseHistoryStoreError.invalidDocument
        }
      }
    }
  }

  private struct CurrentDocument: Codable {
    let format: String
    let version: Int
    let exportedAt: Date
    let entries: [PulseHistoryEntry]
  }

  /// Version 1 predates the format identifier and named the entry array `history`.
  private struct LegacyDocument: Codable {
    let version: Int
    let history: [PulseHistoryEntry]
  }
}

enum PulseHistoryPersistenceOperation: Sendable {
  case save(entries: [PulseHistoryEntry], exportedAt: Date)
  case remove
}

/// Coalesces full-document history writes and keeps all persistence I/O off the main actor.
/// `flush()` preserves ordering by waiting for this writer's serial queue to drain.
final class PulseHistoryPersistenceWriter: @unchecked Sendable {
  typealias OperationHandler = @Sendable (PulseHistoryPersistenceOperation) throws -> Void
  typealias ResultHandler = @Sendable (_ generation: UInt64, _ errorMessage: String?) -> Void

  private struct PendingOperation {
    let generation: UInt64
    let operation: PulseHistoryPersistenceOperation
  }

  private final class FlushResult: @unchecked Sendable {
    private let lock = NSLock()
    private var value: (generation: UInt64, errorMessage: String?)?

    func store(_ value: (generation: UInt64, errorMessage: String?)?) {
      lock.withLock { self.value = value }
    }

    func load() -> (generation: UInt64, errorMessage: String?)? {
      lock.withLock { value }
    }
  }

  private let queue = DispatchQueue(
    label: "dev.islet.pulse-history-persistence", qos: .utility)
  private let lock = NSLock()
  private let coalescingDelay: TimeInterval
  private let operationHandler: OperationHandler
  private let resultHandler: ResultHandler
  private var pendingOperation: PendingOperation?
  private var pendingWorkItem: DispatchWorkItem?

  convenience init(
    store: PulseHistoryStore, coalescingDelay: TimeInterval = 0.25,
    resultHandler: @escaping ResultHandler
  ) {
    self.init(
      coalescingDelay: coalescingDelay,
      operationHandler: { operation in
        switch operation {
        case .save(let entries, let exportedAt):
          try store.save(entries, exportedAt: exportedAt)
        case .remove:
          try store.remove()
        }
      },
      resultHandler: resultHandler)
  }

  init(
    coalescingDelay: TimeInterval = 0.25,
    operationHandler: @escaping OperationHandler,
    resultHandler: @escaping ResultHandler = { _, _ in }
  ) {
    self.coalescingDelay = coalescingDelay
    self.operationHandler = operationHandler
    self.resultHandler = resultHandler
  }

  func submit(_ operation: PulseHistoryPersistenceOperation, generation: UInt64) {
    let workItem = DispatchWorkItem { [weak self] in
      self?.drain(expectedGeneration: generation)
    }
    lock.withLock {
      pendingWorkItem?.cancel()
      pendingOperation = PendingOperation(generation: generation, operation: operation)
      pendingWorkItem = workItem
    }
    queue.asyncAfter(deadline: .now() + coalescingDelay, execute: workItem)
  }

  @discardableResult
  func flush() -> (generation: UInt64, errorMessage: String?)? {
    let semaphore = DispatchSemaphore(value: 0)
    let result = FlushResult()
    queue.async { [self] in
      result.store(drainLatest())
      semaphore.signal()
    }
    semaphore.wait()
    return result.load()
  }

  private func drain(expectedGeneration: UInt64) {
    let pending = lock.withLock { () -> PendingOperation? in
      guard pendingOperation?.generation == expectedGeneration else { return nil }
      let pending = pendingOperation
      pendingOperation = nil
      pendingWorkItem = nil
      return pending
    }
    guard let pending else { return }
    complete(pending)
  }

  private func drainLatest() -> (generation: UInt64, errorMessage: String?)? {
    let pending = lock.withLock { () -> PendingOperation? in
      pendingWorkItem?.cancel()
      pendingWorkItem = nil
      defer { pendingOperation = nil }
      return pendingOperation
    }
    guard let pending else { return nil }
    return complete(pending)
  }

  @discardableResult
  private func complete(
    _ pending: PendingOperation
  ) -> (generation: UInt64, errorMessage: String?) {
    let errorMessage: String?
    do {
      try operationHandler(pending.operation)
      errorMessage = nil
    } catch {
      switch pending.operation {
      case .save:
        errorMessage = "Pulse history could not be saved. \(error.localizedDescription)"
      case .remove:
        errorMessage = "Pulse history could not be removed. \(error.localizedDescription)"
      }
    }
    resultHandler(pending.generation, errorMessage)
    return (pending.generation, errorMessage)
  }
}
