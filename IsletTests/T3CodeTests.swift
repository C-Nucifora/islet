import XCTest

@testable import Islet

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
}
