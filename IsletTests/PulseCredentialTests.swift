import XCTest

@testable import Islet

final class PulseCredentialTests: XCTestCase {
  @MainActor
  func testLegacyTokenMigrationBindsSourceAndKeepsOnlyEventPermission() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let legacyToken = Data(repeating: 0x2A, count: 32).base64EncodedString()
    try writeSecure("\(legacyToken)\n", to: directory.appendingPathComponent("pulse-token"))
    let store = PulseCredentialStore(supportDirectory: directory)

    try store.prepare()

    let legacy = try XCTUnwrap(store.credentials.first)
    XCTAssertEqual(legacy.id, PulseCredentialStore.legacyCredentialID)
    XCTAssertEqual(legacy.source, "legacy")
    XCTAssertEqual(legacy.permissions, [.events])
    let event = try store.authorize(
      command(token: legacyToken, operation: .event, source: "forged", requestID: nil))
    XCTAssertEqual(event.0.activity?.source, "legacy")
    XCTAssertEqual(event.0.source, "legacy")

    XCTAssertThrowsError(
      try store.authorize(
        command(token: legacyToken, operation: .show, source: "forged", requestID: nil))
    ) { error in
      XCTAssertEqual(
        error as? PulseCredentialError, .permissionDenied(.persistentActivities))
    }
  }

  @MainActor
  func testCredentialRejectsSourceSpoofingBeforeActivityState() throws {
    let fixture = try fixture(permissions: [.events, .persistentActivities])
    defer { fixture.remove() }

    XCTAssertThrowsError(
      try fixture.store.authorize(
        command(
          token: fixture.token, operation: .show, source: "another-provider",
          requestID: "spoof-1"))
    ) { error in
      XCTAssertEqual(error as? PulseCredentialError, .sourceSpoofing)
    }
  }

  @MainActor
  func testPermissionsIndependentlyGatePersistentProgressAndWebActions() throws {
    let fixture = try fixture(permissions: [.persistentActivities])
    defer { fixture.remove() }

    XCTAssertNoThrow(
      try fixture.store.authorize(
        command(
          token: fixture.token, operation: .show, source: "build",
          requestID: "persistent-1")))
    XCTAssertThrowsError(
      try fixture.store.authorize(
        command(
          token: fixture.token, operation: .event, source: "build", requestID: "event-1"))
    ) { error in
      XCTAssertEqual(error as? PulseCredentialError, .permissionDenied(.events))
    }

    var progress = command(
      token: fixture.token, operation: .update, source: "build", requestID: "progress-1")
    progress.activity?.progress = 0.5
    progress.activity?.state = .progress
    XCTAssertThrowsError(try fixture.store.authorize(progress)) { error in
      XCTAssertEqual(error as? PulseCredentialError, .permissionDenied(.progress))
    }

    var action = command(
      token: fixture.token, operation: .show, source: "build", requestID: "action-1")
    action.activity?.actions = [
      PulseAction(title: "Open", url: URL(string: "https://example.com/run")!)
    ]
    XCTAssertThrowsError(try fixture.store.authorize(action)) { error in
      XCTAssertEqual(error as? PulseCredentialError, .permissionDenied(.webActions))
    }
  }

  @MainActor
  func testReplayIsRejectedPerCredentialWithoutCollidingAcrossProviders() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = PulseCredentialStore(supportDirectory: directory)
    let first = try store.createProvider(
      name: "Build", source: "build", permissions: [.events])
    let second = try store.createProvider(
      name: "Tests", source: "tests", permissions: [.events])
    let firstToken = try token(for: first, in: store)
    let secondToken = try token(for: second, in: store)

    XCTAssertNoThrow(
      try store.authorize(
        command(token: firstToken, operation: .event, source: "build", requestID: "same")))
    XCTAssertThrowsError(
      try store.authorize(
        command(token: firstToken, operation: .event, source: "build", requestID: "same"))
    ) { error in
      XCTAssertEqual(error as? PulseCredentialError, .replayedRequest)
    }
    XCTAssertNoThrow(
      try store.authorize(
        command(token: secondToken, operation: .event, source: "tests", requestID: "same")))
  }

  @MainActor
  func testRotationAndRevocationDoNotInvalidateOtherProviders() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = PulseCredentialStore(supportDirectory: directory)
    let first = try store.createProvider(
      name: "Build", source: "build", permissions: [.events])
    let second = try store.createProvider(
      name: "Tests", source: "tests", permissions: [.events])
    let staleFirstToken = try token(for: first, in: store)
    let secondToken = try token(for: second, in: store)

    try store.rotate(first.id)
    let rotatedFirstToken = try token(for: first, in: store)
    XCTAssertNotEqual(staleFirstToken, rotatedFirstToken)
    XCTAssertThrowsError(
      try store.authorize(
        command(
          token: staleFirstToken, operation: .event, source: "build", requestID: "stale")))
    XCTAssertNoThrow(
      try store.authorize(
        command(
          token: secondToken, operation: .event, source: "tests", requestID: "other-1")))
    XCTAssertNoThrow(
      try store.authorize(
        command(
          token: rotatedFirstToken, operation: .event, source: "build",
          requestID: "rotated")))

    try store.revoke(first.id)
    XCTAssertThrowsError(
      try store.authorize(
        command(
          token: rotatedFirstToken, operation: .event, source: "build",
          requestID: "revoked"))
    ) { error in
      XCTAssertEqual(error as? PulseCredentialError, .revoked)
    }
    XCTAssertNoThrow(
      try store.authorize(
        command(
          token: secondToken, operation: .event, source: "tests", requestID: "other-2")))
  }

  @MainActor
  func testMetadataPersistsAgeLastUsePermissionsAndRevocationWithoutTokenMaterial() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    var date = Date(timeIntervalSince1970: 1_000)
    let store = PulseCredentialStore(supportDirectory: directory, now: { date })
    let created = try store.createProvider(
      name: "Build", source: "build", permissions: [.events, .progress])
    let credential = try token(for: created, in: store)
    date = Date(timeIntervalSince1970: 2_000)
    _ = try store.authorize(
      command(token: credential, operation: .event, source: "build", requestID: "used"))
    date = Date(timeIntervalSince1970: 3_000)
    try store.revoke(created.id)

    let registry = try String(contentsOf: store.registryURL, encoding: .utf8)
    XCTAssertFalse(registry.contains(credential))
    let reloaded = PulseCredentialStore(supportDirectory: directory)
    try reloaded.prepare()
    let summary = try XCTUnwrap(reloaded.credentials.first)
    XCTAssertEqual(summary.createdAt, Date(timeIntervalSince1970: 1_000))
    XCTAssertEqual(summary.lastUsedAt, Date(timeIntervalSince1970: 2_000))
    XCTAssertEqual(summary.revokedAt, Date(timeIntervalSince1970: 3_000))
    XCTAssertEqual(summary.permissions, [.events, .progress])
  }

  func testConcurrentClientsSerializeCredentialUseWithoutCrossProviderState() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let setup = try await MainActor.run { () throws -> (PulseCredentialStore, String, String) in
      let store = PulseCredentialStore(supportDirectory: directory)
      let first = try store.createProvider(
        name: "Build", source: "build", permissions: [.events])
      let second = try store.createProvider(
        name: "Tests", source: "tests", permissions: [.events])
      let firstToken = try String(
        contentsOf: store.credentialDirectory.appendingPathComponent(
          "\(first.id).credential"),
        encoding: .utf8
      ).trimmingCharacters(in: .whitespacesAndNewlines)
      let secondToken = try String(
        contentsOf: store.credentialDirectory.appendingPathComponent(
          "\(second.id).credential"),
        encoding: .utf8
      ).trimmingCharacters(in: .whitespacesAndNewlines)
      return (store, firstToken, secondToken)
    }

    let accepted = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
      for index in 0..<32 {
        group.addTask {
          await MainActor.run {
            let isBuild = index.isMultiple(of: 2)
            let source = isBuild ? "build" : "tests"
            let command = PulseCommand(
              token: isBuild ? setup.1 : setup.2, operation: .event,
              activity: PulsePayload(
                id: "job", source: source, title: "Build", subtitle: nil, symbol: nil,
                accentHex: nil, progress: nil, state: .active, priority: .normal,
                expiresAt: nil, actions: nil),
              id: nil, requestID: "concurrent-\(index)", source: source)
            return (try? setup.0.authorize(command)) != nil
          }
        }
      }
      var count = 0
      for await success in group where success { count += 1 }
      return count
    }

    XCTAssertEqual(accepted, 32)
    let summaries = await MainActor.run { setup.0.credentials }
    XCTAssertEqual(summaries.count, 2)
    XCTAssertTrue(summaries.allSatisfy { $0.lastUsedAt != nil })
  }

  @MainActor
  func testUnsafeLegacyCredentialFileIsNotMigratedOrDisclosed() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let token = Data(repeating: 0x55, count: 32).base64EncodedString()
    let url = directory.appendingPathComponent("pulse-token")
    try "\(token)\n".write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
    let store = PulseCredentialStore(supportDirectory: directory)

    XCTAssertThrowsError(try store.prepare()) { error in
      XCTAssertEqual(error as? PulseCredentialError, .unsafeCredentialFile)
      XCTAssertFalse(error.localizedDescription.contains(token))
    }
    XCTAssertTrue(store.credentials.isEmpty)
  }

  @MainActor
  func testCredentialReadRejectsSymlinkAndOversizedMaterial() throws {
    let fixture = try fixture(permissions: [.events])
    defer { fixture.remove() }
    let credentialURL = try XCTUnwrap(
      fixture.store.credentialFileURL(for: fixture.summary.id))
    let targetURL = fixture.directory.appendingPathComponent("other-secret")
    try writeSecure(fixture.token, to: targetURL)
    try FileManager.default.removeItem(at: credentialURL)
    try FileManager.default.createSymbolicLink(at: credentialURL, withDestinationURL: targetURL)

    XCTAssertThrowsError(
      try fixture.store.authorize(
        command(
          token: fixture.token, operation: .event, source: "build",
          requestID: "symlink"))
    ) { error in
      XCTAssertEqual(error as? PulseCredentialError, .unsafeCredentialFile)
    }

    try FileManager.default.removeItem(at: credentialURL)
    try writeSecure(String(repeating: "x", count: 4_097), to: credentialURL)
    XCTAssertThrowsError(
      try fixture.store.authorize(
        command(
          token: fixture.token, operation: .event, source: "build",
          requestID: "oversized"))
    ) { error in
      XCTAssertEqual(error as? PulseCredentialError, .unsafeCredentialFile)
    }
  }

  @MainActor
  func testTamperedRegistryCannotTurnCredentialIDIntoAPath() throws {
    let fixture = try fixture(permissions: [.events])
    defer { fixture.remove() }
    let data = try Data(contentsOf: fixture.store.registryURL)
    var registry = try XCTUnwrap(
      JSONSerialization.jsonObject(with: data) as? [String: Any])
    var credentials = try XCTUnwrap(registry["credentials"] as? [[String: Any]])
    credentials[0]["id"] = "../pulse-token"
    registry["credentials"] = credentials
    let tampered = try JSONSerialization.data(withJSONObject: registry)
    try FileManager.default.removeItem(at: fixture.store.registryURL)
    XCTAssertTrue(
      FileManager.default.createFile(
        atPath: fixture.store.registryURL.path, contents: tampered,
        attributes: [.posixPermissions: 0o600]))

    let reloaded = PulseCredentialStore(supportDirectory: fixture.directory)
    XCTAssertThrowsError(try reloaded.prepare()) { error in
      XCTAssertEqual(error as? PulseCredentialError, .corruptRegistry)
    }
  }

  @MainActor
  func testFailedRotationRestoresThePreviousCredential() throws {
    let fixture = try fixture(permissions: [.events])
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: fixture.directory.path)
      fixture.remove()
    }
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o500], ofItemAtPath: fixture.directory.path)

    XCTAssertThrowsError(try fixture.store.rotate(fixture.summary.id))
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700], ofItemAtPath: fixture.directory.path)
    XCTAssertNoThrow(
      try fixture.store.authorize(
        command(
          token: fixture.token, operation: .event, source: "build",
          requestID: "old-still-valid")))
  }

  @MainActor
  func testLastUseMetadataWriteFailureDoesNotRejectAnAuthorizedCommand() throws {
    let fixture = try fixture(permissions: [.events])
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: fixture.directory.path)
      fixture.remove()
    }
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o500], ofItemAtPath: fixture.directory.path)

    XCTAssertNoThrow(
      try fixture.store.authorize(
        command(
          token: fixture.token, operation: .event, source: "build",
          requestID: "accepted-while-metadata-read-only")))
    XCTAssertNotNil(fixture.store.lastError)
    XCTAssertThrowsError(
      try fixture.store.authorize(
        command(
          token: fixture.token, operation: .event, source: "build",
          requestID: "accepted-while-metadata-read-only"))
    ) { error in
      XCTAssertEqual(error as? PulseCredentialError, .replayedRequest)
    }
  }

  private struct Fixture {
    let directory: URL
    let store: PulseCredentialStore
    let summary: PulseCredentialSummary
    let token: String

    func remove() { try? FileManager.default.removeItem(at: directory) }
  }

  @MainActor
  private func fixture(permissions: Set<PulseCredentialPermission>) throws -> Fixture {
    let directory = try temporaryDirectory()
    let store = PulseCredentialStore(supportDirectory: directory)
    let summary = try store.createProvider(
      name: "Build", source: "build", permissions: permissions)
    return Fixture(
      directory: directory, store: store, summary: summary,
      token: try token(for: summary, in: store))
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "islet-pulse-credential-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: url, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    return url
  }

  private func writeSecure(_ value: String, to url: URL) throws {
    guard
      FileManager.default.createFile(
        atPath: url.path, contents: Data(value.utf8), attributes: [.posixPermissions: 0o600])
    else { throw CocoaError(.fileWriteUnknown) }
  }

  @MainActor
  private func token(
    for summary: PulseCredentialSummary, in store: PulseCredentialStore
  ) throws -> String {
    try String(
      contentsOf: store.credentialDirectory.appendingPathComponent(
        "\(summary.id).credential"),
      encoding: .utf8
    ).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func command(
    token: String, operation: PulseOperation, source: String, requestID: String?
  ) -> PulseCommand {
    PulseCommand(
      token: token, operation: operation,
      activity: PulsePayload(
        id: "job", source: source, title: "Build", subtitle: nil, symbol: nil,
        accentHex: nil, progress: nil, state: .active, priority: .normal,
        expiresAt: nil, actions: nil),
      id: operation == .end ? "job" : nil, requestID: requestID, source: source)
  }
}
