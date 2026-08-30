import Foundation
import XCTest

@testable import Islet

final class PulseHistoryStoreTests: XCTestCase {
  @MainActor
  func testOptInHistoryRestoresBeforeProviderHealthIsRead() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let configuration = PulseHistoryConfiguration(
      isEnabled: true, retentionDays: 7, maximumEntries: 50)
    let first = PulseCenter(
      historyStore: fixture.store, historyConfiguration: configuration, now: now)
    let payload = PulsePayload(
      id: "private-item-id", source: "CLI", title: "Private build name", subtitle: nil,
      symbol: nil, accentHex: nil, progress: 0.4, state: .progress, priority: .normal,
      expiresAt: nil, actions: nil)

    XCTAssertTrue(first.apply(command(.show, payload), now: now).ok)
    first.dismiss("private-item-id", now: now.addingTimeInterval(1))

    let restored = PulseCenter(
      historyStore: fixture.store, historyConfiguration: configuration,
      now: now.addingTimeInterval(2))
    let status = try XCTUnwrap(restored.providerStatuses.first { $0.id == "cli" })
    XCTAssertEqual(status.health, .seen(now.addingTimeInterval(1)))
    XCTAssertEqual(restored.history.count, 2)
  }

  func testRetentionExpiryAndEntryLimitAreAppliedDuringLoad() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let recent = (0..<65).map { index in
      entry(id: UUID(), date: now.addingTimeInterval(-TimeInterval(index)), source: "cli")
    }
    let expired = entry(
      id: UUID(), date: now.addingTimeInterval(-(2 * 24 * 60 * 60)), source: "old")
    try fixture.store.save(recent + [expired], exportedAt: now)

    let loaded = try fixture.store.load(now: now, retentionDays: 1, maximumEntries: 50)

    XCTAssertEqual(loaded.entries.count, 50)
    XCTAssertFalse(loaded.entries.contains { $0.source == "old" })
    XCTAssertEqual(loaded.entries.map(\.date), loaded.entries.map(\.date).sorted(by: >))
    XCTAssertTrue(loaded.needsRewrite)
  }

  @MainActor
  func testCorruptHistoryIsClearedWithoutBlockingPulseStartup() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try FileManager.default.createDirectory(
      at: fixture.store.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(#"{"version":2,"entries":"not-an-array"}"#.utf8).write(
      to: fixture.store.fileURL)

    let center = PulseCenter(
      historyStore: fixture.store,
      historyConfiguration: PulseHistoryConfiguration(
        isEnabled: true, retentionDays: 7, maximumEntries: 50))

    XCTAssertTrue(center.history.isEmpty)
    XCTAssertNotNil(center.historyPersistenceError)
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.store.fileURL.path))
  }

  @MainActor
  func testUnexpectedPayloadFieldsMakeTheSavedDocumentInvalid() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let validData = try PulseHistoryStore.exportData([
      entry(id: UUID(), date: now, source: "cli")
    ])
    var document = try XCTUnwrap(
      JSONSerialization.jsonObject(with: validData) as? [String: Any])
    var entries = try XCTUnwrap(document["entries"] as? [[String: Any]])
    entries[0]["token"] = "must-not-survive"
    document["entries"] = entries
    try FileManager.default.createDirectory(
      at: fixture.store.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: document).write(to: fixture.store.fileURL)

    let center = PulseCenter(
      historyStore: fixture.store,
      historyConfiguration: PulseHistoryConfiguration(
        isEnabled: true, retentionDays: 7, maximumEntries: 50),
      now: now)

    XCTAssertTrue(center.history.isEmpty)
    XCTAssertNotNil(center.historyPersistenceError)
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.store.fileURL.path))
  }

  @MainActor
  func testOversizedHistoryIsRejectedBeforeDecode() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try FileManager.default.createDirectory(
      at: fixture.store.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(repeating: 0x20, count: PulseHistoryStore.maximumDocumentBytes + 1).write(
      to: fixture.store.fileURL)

    let center = PulseCenter(
      historyStore: fixture.store,
      historyConfiguration: PulseHistoryConfiguration(
        isEnabled: true, retentionDays: 7, maximumEntries: 50))

    XCTAssertTrue(center.history.isEmpty)
    XCTAssertNotNil(center.historyPersistenceError)
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.store.fileURL.path))
  }

  @MainActor
  func testExportContainsOnlyTheHistoryMetadataAllowlist() throws {
    let center = PulseCenter()
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let payload = PulsePayload(
      id: "private-item-id", source: "cli", title: "private-title",
      subtitle: "private-subtitle", symbol: "lock", accentHex: "#123456", progress: 0.75,
      state: .progress, priority: .high, expiresAt: nil,
      actions: [
        PulseAction(
          id: "private-action", title: "private-action-title",
          url: URL(string: "https://example.com/private-link")!)
      ])
    var pulseCommand = command(.show, payload)
    pulseCommand.token = "private-bearer-token"
    XCTAssertTrue(center.apply(pulseCommand, now: now).ok)

    let data = try center.exportHistoryData(exportedAt: now)
    let text = try XCTUnwrap(String(data: data, encoding: .utf8))
    for forbidden in [
      "private-item-id", "private-title", "private-subtitle", "private-action",
      "private-link", "private-bearer-token", "#123456", "0.75",
    ] {
      XCTAssertFalse(text.contains(forbidden), "Export retained \(forbidden)")
    }
    let document = try XCTUnwrap(
      JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(
      Set(document.keys), ["entries", "exportedAt", "format", "version"])
    let entries = try XCTUnwrap(document["entries"] as? [[String: Any]])
    XCTAssertEqual(entries.count, 1)
    XCTAssertEqual(
      Set(entries[0].keys), ["date", "id", "operation", "priority", "result", "source", "state"])
  }

  @MainActor
  func testVersionOneHistoryMigratesAndRewritesCurrentSchema() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let legacyEntry: [String: Any] = [
      "id": UUID().uuidString,
      "date": ISO8601DateFormatter().string(from: now.addingTimeInterval(-10)),
      "operation": "show",
      "source": "cli",
      "state": "active",
      "priority": "normal",
      "result": "shown",
    ]
    let data = try JSONSerialization.data(
      withJSONObject: ["version": 1, "history": [legacyEntry]])
    try FileManager.default.createDirectory(
      at: fixture.store.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: fixture.store.fileURL)

    let center = PulseCenter(
      historyStore: fixture.store,
      historyConfiguration: PulseHistoryConfiguration(
        isEnabled: true, retentionDays: 7, maximumEntries: 50),
      now: now)

    XCTAssertEqual(center.history.map(\.source), ["cli"])
    let rewritten =
      try JSONSerialization.jsonObject(
        with: Data(contentsOf: fixture.store.fileURL)) as? [String: Any]
    XCTAssertEqual(rewritten?["version"] as? Int, PulseHistoryStore.currentVersion)
    XCTAssertEqual(rewritten?["format"] as? String, PulseHistoryStore.formatIdentifier)
    XCTAssertNotNil(rewritten?["entries"])
    XCTAssertNil(rewritten?["history"])
  }

  @MainActor
  func testNewerSchemaIsPreservedAndCannotBeOverwritten() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let futureData = try JSONSerialization.data(
      withJSONObject: [
        "format": PulseHistoryStore.formatIdentifier,
        "version": PulseHistoryStore.currentVersion + 1,
        "exportedAt": "2027-01-15T08:00:00Z",
        "entries": [],
      ], options: [.sortedKeys])
    try FileManager.default.createDirectory(
      at: fixture.store.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try futureData.write(to: fixture.store.fileURL)

    let center = PulseCenter(
      historyStore: fixture.store,
      historyConfiguration: PulseHistoryConfiguration(
        isEnabled: true, retentionDays: 7, maximumEntries: 50))
    let payload = PulsePayload(
      id: "item", source: "cli", title: "Title", subtitle: nil, symbol: nil,
      accentHex: nil, progress: nil, state: .active, priority: .normal, expiresAt: nil,
      actions: nil)
    XCTAssertTrue(center.apply(command(.show, payload)).ok)

    XCTAssertTrue(center.historyPersistenceError?.contains("newer Islet version") == true)
    XCTAssertEqual(try Data(contentsOf: fixture.store.fileURL), futureData)
  }

  @MainActor
  func testOptOutRemovesSavedHistoryWithoutLoadingIt() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    try fixture.store.save([entry(id: UUID(), date: now, source: "cli")])

    let center = PulseCenter(
      historyStore: fixture.store, historyConfiguration: .sessionOnly, now: now)

    XCTAssertTrue(center.history.isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.store.fileURL.path))
  }

  @MainActor
  func testClearHistoryDeletesTheSavedDocument() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let center = PulseCenter(
      historyStore: fixture.store,
      historyConfiguration: PulseHistoryConfiguration(
        isEnabled: true, retentionDays: 7, maximumEntries: 50),
      now: now)
    let payload = PulsePayload(
      id: "item", source: "cli", title: "Title", subtitle: nil, symbol: nil,
      accentHex: nil, progress: nil, state: .active, priority: .normal, expiresAt: nil,
      actions: nil)
    XCTAssertTrue(center.apply(command(.show, payload), now: now).ok)
    XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.store.fileURL.path))

    center.clearHistory()

    XCTAssertTrue(center.history.isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.store.fileURL.path))
  }

  func testSavedHistoryUsesPrivateFilePermissions() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    try fixture.store.save([entry(id: UUID(), date: now, source: "cli")])

    let attributes = try FileManager.default.attributesOfItem(
      atPath: fixture.store.fileURL.path)
    let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
    XCTAssertEqual(permissions.intValue & 0o777, 0o600)
  }

  private func makeFixture() throws -> (root: URL, store: PulseHistoryStore) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "PulseHistoryTests-\(UUID().uuidString)", isDirectory: true)
    let fileURL = root.appendingPathComponent("Support", isDirectory: true)
      .appendingPathComponent("pulse-history.json")
    return (root, PulseHistoryStore(fileURL: fileURL))
  }

  private func entry(
    id: UUID, date: Date, source: String?
  ) -> PulseHistoryEntry {
    PulseHistoryEntry(
      id: id, date: date, operation: .show, source: source, state: .active,
      priority: .normal, result: .shown)
  }

  private func command(_ operation: PulseOperation, _ payload: PulsePayload) -> PulseCommand {
    PulseCommand(token: "test", operation: operation, activity: payload, id: nil)
  }
}
