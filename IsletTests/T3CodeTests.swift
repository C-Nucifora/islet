import XCTest

@testable import Islet

@MainActor
final class T3CodeTests: XCTestCase {
  func testParsesHostedPairingLink() throws {
    let target = try T3PairingTarget.parse(
      "https://app.t3.codes/pair?host=https%3A%2F%2Fmini.example.com%3A44342%2F#token=once")
    XCTAssertEqual(target.endpoint.baseURL.absoluteString, "https://mini.example.com:44342/")
    XCTAssertEqual(target.credential, "once")
  }

  func testParsesDirectPairingLink() throws {
    let target = try T3PairingTarget.parse("https://mini.example.com/pair#token=once")
    XCTAssertEqual(target.endpoint.baseURL.absoluteString, "https://mini.example.com/")
    XCTAssertEqual(target.credential, "once")
  }

  func testRejectsInsecureRemotePairingByDefault() {
    XCTAssertThrowsError(
      try T3PairingTarget.parse("http://mini.example.com:3773/pair#token=once"))
  }

  func testAgentDerivationIsProviderNeutralAndPrioritizesQuestions() throws {
    let json = """
      {
        "snapshotSequence": 1,
        "projects": [{"id":"p1","title":"Islet","workspaceRoot":"/tmp/islet"}],
        "threads": [{
          "id":"t1","projectId":"p1","title":"Build the monitor",
          "modelSelection":{"instanceId":"future-provider","model":"future-1"},
          "runtimeMode":"auto","interactionMode":"default","branch":"feature/t3",
          "worktreePath":"/tmp/islet","latestTurn":{"turnId":"turn1","state":"running",
          "requestedAt":"2026-08-27T00:00:00.000Z","startedAt":"2026-08-27T00:00:00.000Z",
          "completedAt":null},"createdAt":"2026-08-27T00:00:00.000Z",
          "updatedAt":"2026-08-27T00:00:01.000Z","archivedAt":null,"settledAt":null,
          "session":{"status":"running","providerName":"Future Provider",
          "providerInstanceId":"future-provider","lastError":null},
          "latestUserMessageAt":"2026-08-27T00:00:00.000Z","hasPendingApprovals":false,
          "hasPendingUserInput":true,"hasActionableProposedPlan":false,
          "backgroundLiveness":null,"planProgress":{"step":"Wire the API","completedSteps":1,"totalSteps":3}
        }],
        "updatedAt":"2026-08-27T00:00:01.000Z"
      }
      """
    let shell = try JSONDecoder().decode(T3ShellSnapshot.self, from: Data(json.utf8))
    let agents = T3AgentSnapshot.activeAgents(
      in: shell, environmentID: "machine", now: Date(timeIntervalSince1970: 1_788_000_000))
    XCTAssertEqual(agents.count, 1)
    XCTAssertEqual(agents[0].providerInstance, "Future Provider")
    XCTAssertEqual(agents[0].model, "future-1")
    XCTAssertEqual(agents[0].phase, .needsInput)
    XCTAssertEqual(agents[0].planStep, "Wire the API")
  }

  func testDuplicateProjectIDsDoNotCrashAgentDerivation() throws {
    let json = """
      {
        "snapshotSequence": 1,
        "projects": [
          {"id":"duplicate","title":"First","workspaceRoot":"/tmp/first"},
          {"id":"duplicate","title":"Second","workspaceRoot":"/tmp/second"}
        ],
        "threads": [{
          "id":"t1","projectId":"duplicate","title":"Work",
          "modelSelection":{"instanceId":"provider","model":"model"},
          "runtimeMode":"auto","interactionMode":"default","branch":null,
          "worktreePath":"/tmp/first","latestTurn":{"turnId":"turn1","state":"running",
          "requestedAt":null,"startedAt":null,"completedAt":null},
          "createdAt":null,"updatedAt":"2026-08-28T00:00:00.000Z","archivedAt":null,
          "settledAt":null,"session":{"status":"running","providerName":null,
          "providerInstanceId":"provider","lastError":null},"latestUserMessageAt":null,
          "hasPendingApprovals":false,"hasPendingUserInput":false,
          "hasActionableProposedPlan":false,"backgroundLiveness":null,"planProgress":null
        }],
        "updatedAt":"2026-08-28T00:00:00.000Z"
      }
      """
    let shell = try JSONDecoder().decode(T3ShellSnapshot.self, from: Data(json.utf8))

    let agents = T3AgentSnapshot.activeAgents(
      in: shell, environmentID: "machine", now: Date(timeIntervalSince1970: 1_788_000_000))

    XCTAssertEqual(agents.first?.project, "First")
  }

  func testLocalDiscoveryRequiresASuccessfulT3Descriptor() {
    let descriptor = Data(
      #"{"environmentId":"machine","label":"This Mac","platform":null,"serverVersion":"1"}"#
        .utf8)
    XCTAssertTrue(T3LocalDiscovery.acceptsDiscoveryResponse(data: descriptor, statusCode: 200))
    XCTAssertFalse(T3LocalDiscovery.acceptsDiscoveryResponse(data: descriptor, statusCode: 404))
    XCTAssertFalse(
      T3LocalDiscovery.acceptsDiscoveryResponse(data: Data(#"{"error":"not found"}"#.utf8), statusCode: 200))
  }

  func testPollingPolicySlowsInBackgroundAndLowPowerMode() {
    XCTAssertEqual(
      T3CodeActivity.pollInterval(busy: true, expanded: true, lowPowerMode: false), 3)
    XCTAssertEqual(
      T3CodeActivity.pollInterval(busy: false, expanded: true, lowPowerMode: false), 5)
    XCTAssertEqual(
      T3CodeActivity.pollInterval(busy: true, expanded: false, lowPowerMode: false), 5)
    XCTAssertEqual(
      T3CodeActivity.pollInterval(busy: false, expanded: false, lowPowerMode: false), 12)
    XCTAssertEqual(
      T3CodeActivity.pollInterval(busy: true, expanded: true, lowPowerMode: true), 30)
    XCTAssertEqual(
      T3CodeActivity.pollInterval(
        busy: true, expanded: true, lowPowerMode: true, energyMode: .live), 2)
    XCTAssertEqual(
      T3CodeActivity.pollInterval(
        busy: true, expanded: true, lowPowerMode: false, energyMode: .lowEnergy), 30)
  }

  func testReconnectBackoffIsExponentialAndCapped() {
    XCTAssertEqual(T3CodeActivity.reconnectDelay(failureCount: 1, remote: false), 3)
    XCTAssertEqual(T3CodeActivity.reconnectDelay(failureCount: 4, remote: false), 24)
    XCTAssertEqual(T3CodeActivity.reconnectDelay(failureCount: 20, remote: false), 60)
    XCTAssertEqual(T3CodeActivity.reconnectDelay(failureCount: 1, remote: true), 5)
    XCTAssertEqual(T3CodeActivity.reconnectDelay(failureCount: 20, remote: true), 300)
  }

  func testRemoteMonitorProfilesAreEnabledUniqueAndOrdered() {
    let profiles = [
      T3EnvironmentProfile(id: "one", label: "First", baseURL: "https://one.example"),
      T3EnvironmentProfile(
        id: "off", label: "Off", baseURL: "https://off.example", enabled: false),
      T3EnvironmentProfile(id: "one", label: "Duplicate", baseURL: "https://dup.example"),
      T3EnvironmentProfile(id: "local", label: "Reserved-looking", baseURL: "https://two.example"),
    ]
    let selected = T3CodeActivity.enabledRemoteProfiles(profiles)
    XCTAssertEqual(selected.map(\.id), ["one", "local"])
    XCTAssertEqual(selected.first?.label, "First")
  }

  func testUpsertOfUnchangedSnapshotDoesNotChangePublishedValue() {
    let snapshot = T3EnvironmentSnapshot(
      id: "local", label: "This Mac", baseURL: "http://127.0.0.1:3773/",
      isLocal: true, platform: "macOS · arm64", serverVersion: "1",
      state: .connected, agents: [])
    let current = [snapshot]
    XCTAssertEqual(T3CodeActivity.upserting(snapshot, into: current), current)
  }

  func testLocalAndRemoteEnvironmentIdentityCannotCollide() {
    XCTAssertEqual(T3CodeActivity.localSnapshotID("same"), "local|same")
    XCTAssertEqual(
      T3CodeActivity.remoteSnapshotID(
        environmentID: "same", baseURL: "https://mini.example.com/api?ignored=yes"),
      "remote|same|https://mini.example.com/")
    XCTAssertNotEqual(
      T3CodeActivity.localCredentialID(
        environmentID: "same", baseURL: "http://127.0.0.1:3773"),
      T3CodeActivity.remoteCredentialID(
        environmentID: "same", baseURL: "http://127.0.0.1:3773"))
  }

  func testLocalCredentialMigrationPrefersScopedTokenAndRemovesObsoleteEntries() {
    let current = "local|machine|http://127.0.0.1:4888/"
    let old = "local|machine|http://127.0.0.1:3773/"
    let migration = T3CredentialStore.migratingLocalCredential(
      in: [old: "scoped", "machine": "legacy", "remote|other|https://example.com/": "keep"],
      credentialID: current, environmentID: "machine")

    XCTAssertEqual(migration.token, "scoped")
    XCTAssertEqual(migration.tokens[current], "scoped")
    XCTAssertNil(migration.tokens[old])
    XCTAssertNil(migration.tokens["machine"])
    XCTAssertEqual(migration.tokens["remote|other|https://example.com/"], "keep")
  }

  func testLocalPairingCommandUsesAnInstalledT3ExecutableWithoutNpx() {
    let paths = T3LocalPairingMinting.candidateExecutablePaths(
      environment: ["PATH": "/custom/bin:/second/bin"])
    XCTAssertEqual(Array(paths.prefix(2)), ["/custom/bin/t3", "/second/bin/t3"])
    XCTAssertTrue(paths.contains("/custom/bin/t3"))
    XCTAssertTrue(paths.contains("/second/bin/t3"))
    XCTAssertFalse(paths.contains { $0.contains("npx") || $0.contains("latest") })
  }
}
