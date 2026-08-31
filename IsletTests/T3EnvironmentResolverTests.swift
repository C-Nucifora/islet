import XCTest

@testable import Islet

final class T3EnvironmentResolverTests: XCTestCase {
  func testConnectedLocalWinsOverConnectedConnectAndManualCandidates() {
    let resolved = T3EnvironmentResolver.resolve([
      snapshot(
        id: "remote|studio|https://manual.example/", logicalEnvironmentID: "studio",
        source: .manual, label: "Manual", state: .connected),
      snapshot(
        id: "connect|studio", logicalEnvironmentID: "studio", source: .connect,
        label: "Connect", state: .connected),
      snapshot(
        id: "local|studio", logicalEnvironmentID: "studio", source: .local,
        label: "Local", state: .connected),
    ])

    XCTAssertEqual(resolved.map(\.id), ["local|studio"])
  }

  func testConnectedConnectWinsWhenLocalCandidateIsOffline() {
    let resolved = T3EnvironmentResolver.resolve([
      snapshot(
        id: "local|studio", logicalEnvironmentID: "studio", source: .local,
        label: "Local", state: .offline("Local unavailable")),
      snapshot(
        id: "remote|studio|https://manual.example/", logicalEnvironmentID: "studio",
        source: .manual, label: "Manual", state: .connected),
      snapshot(
        id: "connect|studio", logicalEnvironmentID: "studio", source: .connect,
        label: "Connect", state: .connected),
    ])

    XCTAssertEqual(resolved.map(\.id), ["connect|studio"])
  }

  func testConnectedManualWinsWhenLocalAndConnectCandidatesAreOffline() {
    let resolved = T3EnvironmentResolver.resolve([
      snapshot(
        id: "local|studio", logicalEnvironmentID: "studio", source: .local,
        label: "Local", state: .offline("Local unavailable")),
      snapshot(
        id: "connect|studio", logicalEnvironmentID: "studio", source: .connect,
        label: "Connect", state: .offline("Relay unavailable")),
      snapshot(
        id: "remote|studio|https://manual.example/", logicalEnvironmentID: "studio",
        source: .manual, label: "Manual", state: .connected),
    ])

    XCTAssertEqual(resolved.map(\.id), ["remote|studio|https://manual.example/"])
  }

  func testNonConnectedCandidatesKeepLocalConnectManualSourceOrder() {
    let candidates = [
      snapshot(
        id: "remote|studio|https://manual.example/", logicalEnvironmentID: "studio",
        source: .manual, label: "Manual", state: .offline("Manual unavailable")),
      snapshot(
        id: "connect|studio", logicalEnvironmentID: "studio", source: .connect,
        label: "Connect", state: .needsPairing),
      snapshot(
        id: "local|studio", logicalEnvironmentID: "studio", source: .local,
        label: "Local", state: .connecting),
    ]

    XCTAssertEqual(T3EnvironmentResolver.resolve(candidates).map(\.id), ["local|studio"])
    XCTAssertEqual(
      T3EnvironmentResolver.resolve(candidates.filter { $0.source != .local }).map(\.id),
      ["connect|studio"])
  }

  func testResolverReturnsOneWinnerForEachLogicalEnvironment() {
    let resolved = T3EnvironmentResolver.resolve([
      snapshot(
        id: "local|shared", logicalEnvironmentID: "shared", source: .local,
        label: "Shared local", state: .connected),
      snapshot(
        id: "connect|shared", logicalEnvironmentID: "shared", source: .connect,
        label: "Shared cloud", state: .connected),
      snapshot(
        id: "connect|cloud", logicalEnvironmentID: "cloud", source: .connect,
        label: "Cloud", state: .connected),
    ])

    XCTAssertEqual(resolved.map(\.id), ["local|shared", "connect|cloud"])
    XCTAssertEqual(Set(resolved.map(\.logicalEnvironmentID)), ["shared", "cloud"])
  }

  func testRemovingConnectCandidateRevealsUnchangedManualCandidate() {
    let manual = snapshot(
      id: "remote|studio|https://manual.example/", logicalEnvironmentID: "studio",
      source: .manual, label: "Manual", state: .connected)
    let candidates = [
      manual,
      snapshot(
        id: "connect|studio", logicalEnvironmentID: "studio", source: .connect,
        label: "Connect", state: .connected),
    ]

    XCTAssertEqual(T3EnvironmentResolver.resolve(candidates).map(\.id), ["connect|studio"])
    XCTAssertEqual(
      T3EnvironmentResolver.resolve(candidates.filter { $0.source != .connect }), [manual])
  }

  func testAgentIDsRemainStableWhenTheWinningSourceChanges() {
    let localAgent = agent(logicalEnvironmentID: "studio", threadID: "thread-one")
    let connectAgent = agent(logicalEnvironmentID: "studio", threadID: "thread-one")
    let local = snapshot(
      id: "local|studio", logicalEnvironmentID: "studio", source: .local, label: "Local",
      state: .connected, agents: [localAgent])
    let connect = snapshot(
      id: "connect|studio", logicalEnvironmentID: "studio", source: .connect, label: "Connect",
      state: .connected, agents: [connectAgent])

    let localWinner = T3EnvironmentResolver.resolve([local, connect]).first
    let connectWinner = T3EnvironmentResolver.resolve([
      snapshot(
        id: "local|studio", logicalEnvironmentID: "studio", source: .local,
        label: "Local", state: .offline("Local unavailable")),
      connect,
    ]).first

    XCTAssertNotEqual(localWinner?.id, connectWinner?.id)
    XCTAssertEqual(localWinner?.agents.map(\.id), connectWinner?.agents.map(\.id))
    XCTAssertEqual(connectWinner?.agents.map(\.id), ["studio:thread-one"])
  }

  func testResolverOrdersUnrelatedLocalCandidateBeforeAlphabetizedRemoteCandidates() {
    let resolved = T3EnvironmentResolver.resolve([
      snapshot(
        id: "connect|bravo", logicalEnvironmentID: "bravo", source: .connect,
        label: "Bravo", state: .connected),
      snapshot(
        id: "local|zulu", logicalEnvironmentID: "zulu", source: .local,
        label: "Zulu", state: .connected),
      snapshot(
        id: "remote|alpha|https://alpha.example/", logicalEnvironmentID: "alpha",
        source: .manual, label: "Alpha", state: .connected),
    ])

    XCTAssertEqual(
      resolved.map(\.id),
      ["local|zulu", "remote|alpha|https://alpha.example/", "connect|bravo"])
  }

  func testProvisionalLocalCandidateDoesNotHideRealEnvironmentNamedLocal() {
    let resolved = T3EnvironmentResolver.resolve([
      snapshot(
        id: "local", logicalEnvironmentID: "local", source: .local, label: "This Mac",
        state: .offline("Not discovered")),
      snapshot(
        id: "remote|local|https://manual.example/", logicalEnvironmentID: "local",
        source: .manual, label: "Remote local", state: .connected),
    ])

    XCTAssertEqual(resolved.map(\.id), ["local", "remote|local|https://manual.example/"])
  }

  func testEqualRankCandidatesUseSourceSpecificIDAsDeterministicTieBreak() {
    let first = snapshot(
      id: "remote|studio|https://a.example/", logicalEnvironmentID: "studio",
      source: .manual, label: "Studio A", state: .connected)
    let second = snapshot(
      id: "remote|studio|https://b.example/", logicalEnvironmentID: "studio",
      source: .manual, label: "Studio B", state: .connected)

    XCTAssertEqual(T3EnvironmentResolver.resolve([second, first]).map(\.id), [first.id])
    XCTAssertEqual(T3EnvironmentResolver.resolve([first, second]).map(\.id), [first.id])
  }

  private func snapshot(
    id: String,
    logicalEnvironmentID: String,
    source: T3EnvironmentSource,
    label: String,
    state: T3ConnectionState,
    agents: [T3AgentSnapshot] = []
  ) -> T3EnvironmentSnapshot {
    T3EnvironmentSnapshot(
      id: id, logicalEnvironmentID: logicalEnvironmentID, source: source, label: label,
      baseURL: "https://example.test/", platform: nil, serverVersion: nil, state: state,
      agents: agents)
  }

  private func agent(
    logicalEnvironmentID: String,
    threadID: String
  ) -> T3AgentSnapshot {
    T3AgentSnapshot(
      logicalEnvironmentID: logicalEnvironmentID, threadID: threadID, title: "Agent",
      project: "Project", providerInstance: "provider", model: "model", branch: nil,
      phase: .working, planStep: nil, completedPlanSteps: nil, totalPlanSteps: nil,
      updatedAt: Date(timeIntervalSince1970: 1_788_000_000))
  }
}
