import Combine
import Defaults
import XCTest

@testable import Islet

@MainActor
final class T3ConnectCoordinatorTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_788_000_000)

  func testLoadPublishesSavedIdentityWhileRemotePollingIsDisabled() async throws {
    let old = try record(grantID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
    let session = T3CoordinatorSessionFake(storedRecord: old)
    let relay = T3CoordinatorRelayFake()
    let fixture = makeFixture(session: session, relay: relay)

    await fixture.coordinator.loadAccount()

    XCTAssertEqual(
      fixture.coordinator.state,
      .linked(T3ConnectAccount(record: old), lastSync: nil))
    XCTAssertTrue(fixture.coordinator.environments.isEmpty)
    let listCalls = await relay.listCallCount()
    XCTAssertEqual(listCalls, 0)
  }

  func testSignOutSuppressesAStoredAccountLoadThatReturnsLate() async throws {
    let old = try record(grantID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
    let loadGate = T3CoordinatorGate()
    let session = T3CoordinatorSessionFake(storedRecord: old, loadGate: loadGate)
    let relay = T3CoordinatorRelayFake()
    let fixture = makeFixture(session: session, relay: relay)

    let loadTask = Task { await fixture.coordinator.loadAccount() }
    await loadGate.waitUntilEntered()
    try await fixture.coordinator.signOut()
    await loadGate.resume()
    await loadTask.value

    XCTAssertEqual(fixture.coordinator.state, .signedOut)
  }

  func testFailedLinkRestoresStoredAccountLoadedWhileAttemptIsActive() async throws {
    let old = try record(grantID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
    let loadGate = T3CoordinatorGate()
    let callbackGate = T3CoordinatorGate()
    let events = T3CoordinatorEventRecorder()
    let session = T3CoordinatorSessionFake(storedRecord: old, loadGate: loadGate)
    let relay = T3CoordinatorRelayFake()
    let listener = T3CoordinatorListenerFake(
      result: .denied("access_denied"), events: events, waitGate: callbackGate)
    let fixture = makeFixture(
      session: session, relay: relay, listener: listener, events: events)

    let loadTask = Task { await fixture.coordinator.loadAccount() }
    await loadGate.waitUntilEntered()
    let linkTask = Task { await fixture.coordinator.link() }
    await callbackGate.waitUntilEntered()
    await loadGate.resume()
    await loadTask.value

    XCTAssertEqual(
      fixture.coordinator.state,
      .linking(previous: T3ConnectAccount(record: old)))

    await callbackGate.resume()
    await linkTask.value

    XCTAssertEqual(
      fixture.coordinator.state,
      .linked(T3ConnectAccount(record: old), lastSync: nil))
  }

  func testFailedLinkRestoresAccountLoadErrorReceivedWhileAttemptIsActive() async {
    let loadGate = T3CoordinatorGate()
    let callbackGate = T3CoordinatorGate()
    let events = T3CoordinatorEventRecorder()
    let session = T3CoordinatorSessionFake(loadGate: loadGate, loadOutcome: .failure)
    let relay = T3CoordinatorRelayFake()
    let listener = T3CoordinatorListenerFake(
      result: .denied("access_denied"), events: events, waitGate: callbackGate)
    let fixture = makeFixture(
      session: session, relay: relay, listener: listener, events: events)

    let loadTask = Task { await fixture.coordinator.loadAccount() }
    await loadGate.waitUntilEntered()
    let linkTask = Task { await fixture.coordinator.link() }
    await callbackGate.waitUntilEntered()
    await loadGate.resume()
    await loadTask.value
    await callbackGate.resume()
    await linkTask.value

    guard case .needsSignIn(nil, let message) = fixture.coordinator.state else {
      return XCTFail("Expected the account-load error to remain the link rollback state")
    }
    XCTAssertFalse(message.isEmpty)
  }

  func testLinkStartsListenerBeforeOpeningBrowser() async throws {
    let events = T3CoordinatorEventRecorder()
    let candidate = try record(
      grantID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
      accessToken: "candidate-access")
    let session = T3CoordinatorSessionFake(exchangeRecord: candidate, events: events)
    let relay = T3CoordinatorRelayFake(listOutcomes: [.success([])])
    let listener = T3CoordinatorListenerFake(
      result: .authorizationCode("browser-code"), events: events)
    let fixture = makeFixture(
      session: session, relay: relay, listener: listener, events: events)

    await fixture.coordinator.link()

    XCTAssertEqual(
      Array(events.values().prefix(3)),
      ["listener.start", "browser.open", "listener.wait"])
    XCTAssertEqual(
      fixture.coordinator.state,
      .linked(T3ConnectAccount(record: candidate), lastSync: now))
  }

  func testCancelDuringSuspendedListenerStartAlwaysClosesListener() async {
    let events = T3CoordinatorEventRecorder()
    let startGate = T3CoordinatorGate()
    let listener = T3CoordinatorListenerFake(
      result: .authorizationCode("unused"), events: events, startGate: startGate)
    let session = T3CoordinatorSessionFake()
    let relay = T3CoordinatorRelayFake()
    let fixture = makeFixture(
      session: session, relay: relay, listener: listener, events: events)

    let linkTask = Task { await fixture.coordinator.link() }
    await startGate.waitUntilEntered()
    fixture.coordinator.cancelLink()
    await startGate.resume()
    await linkTask.value

    XCTAssertEqual(fixture.coordinator.state, .signedOut)
    XCTAssertTrue(events.values().contains("listener.cancel"))
  }

  func testInitialLinkDenialRestoresSignedOutStateAndPublishesReason() async {
    let events = T3CoordinatorEventRecorder()
    let listener = T3CoordinatorListenerFake(
      result: .denied("access_denied"), events: events)
    let session = T3CoordinatorSessionFake()
    let relay = T3CoordinatorRelayFake()
    let fixture = makeFixture(
      session: session, relay: relay, listener: listener, events: events)

    await fixture.coordinator.link()

    XCTAssertEqual(fixture.coordinator.state, .signedOut)
    XCTAssertEqual(
      fixture.coordinator.lastLinkError,
      "T3 Connect declined authorization (access_denied).")
  }

  func testLinkKeepsCandidateUncommittedAndUnpublishedUntilFirstInventoryReturns() async throws {
    let old = try record(grantID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
    let candidate = try record(
      grantID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
      accessToken: "candidate-access")
    let candidateEnvironment = environment(id: "candidate")
    let listGate = T3CoordinatorGate()
    let session = T3CoordinatorSessionFake(storedRecord: old, exchangeRecord: candidate)
    let relay = T3CoordinatorRelayFake(
      listOutcomes: [.success([candidateEnvironment])], listGates: [1: listGate])
    let fixture = makeFixture(session: session, relay: relay)
    await fixture.coordinator.loadAccount()

    let linkTask = Task { await fixture.coordinator.link() }
    await listGate.waitUntilEntered()

    let suspendedCommitCalls = await session.commitCallCount()
    XCTAssertEqual(suspendedCommitCalls, 0)
    XCTAssertTrue(fixture.coordinator.environments.isEmpty)
    XCTAssertTrue(fixture.coordinator.cloudCandidates.isEmpty)
    XCTAssertEqual(fixture.coordinator.state, .linking(previous: T3ConnectAccount(record: old)))

    await listGate.resume()
    await linkTask.value

    let completedCommitCalls = await session.commitCallCount()
    XCTAssertEqual(completedCommitCalls, 1)
    XCTAssertEqual(fixture.coordinator.environments, [candidateEnvironment])
    XCTAssertEqual(fixture.coordinator.cloudCandidates.map(\.logicalEnvironmentID), ["candidate"])
  }

  func testFailedRelinkRestoresOldAccountInventoryAndCloudWork() async throws {
    let old = try record(grantID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
    let candidate = try record(
      grantID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!)
    let oldEnvironment = environment(id: "old")
    let session = T3CoordinatorSessionFake(storedRecord: old, exchangeRecord: candidate)
    let relay = T3CoordinatorRelayFake(
      listOutcomes: [.success([oldEnvironment]), .failure, .success([oldEnvironment])])
    let fixture = makeFixture(session: session, relay: relay)
    await fixture.coordinator.loadAccount()
    fixture.coordinator.startInventory()
    await fixture.sleeper.waitForSleep(interval: 60, count: 1)
    await fixture.sleeper.waitForSleep(interval: 10, count: 1)
    let oldCandidates = fixture.coordinator.cloudCandidates

    await fixture.coordinator.link()

    let commitCalls = await session.commitCallCount()
    XCTAssertEqual(commitCalls, 0)
    XCTAssertEqual(fixture.coordinator.state, .linked(T3ConnectAccount(record: old), lastSync: now))
    XCTAssertEqual(fixture.coordinator.environments, [oldEnvironment])
    XCTAssertEqual(fixture.coordinator.cloudCandidates, oldCandidates)
    let shellCalls = await fixture.shells.callCount(environmentID: "old")
    XCTAssertGreaterThanOrEqual(shellCalls, 1)
  }

  func testCommitFailureRestoresOldAccountWithoutClearingOldRelayWork() async throws {
    let old = try record(grantID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
    let candidate = try record(
      grantID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!)
    let oldEnvironment = environment(id: "old")
    let session = T3CoordinatorSessionFake(
      storedRecord: old, exchangeRecord: candidate, commitOutcome: .failure)
    let relay = T3CoordinatorRelayFake(
      listOutcomes: [
        .success([oldEnvironment]), .success([environment(id: "new")]),
        .success([oldEnvironment]),
      ])
    let fixture = makeFixture(session: session, relay: relay)
    await fixture.coordinator.loadAccount()
    fixture.coordinator.startInventory()
    await fixture.sleeper.waitForSleep(interval: 60, count: 1)
    let clearsBeforeRelink = await relay.clearCallCount()

    await fixture.coordinator.link()

    XCTAssertEqual(fixture.coordinator.state, .linked(T3ConnectAccount(record: old), lastSync: now))
    XCTAssertEqual(fixture.coordinator.environments, [oldEnvironment])
    let clearsAfterRelink = await relay.clearCallCount()
    XCTAssertEqual(clearsAfterRelink, clearsBeforeRelink)
  }

  func testCommitWindowKeepsLastGoodCloudSnapshotStableOnFailedRelink() async throws {
    let old = try record(grantID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
    let candidate = try record(
      grantID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!)
    let oldEnvironment = environment(id: "old")
    let commitGate = T3CoordinatorGate()
    let cloudCycles = T3CoordinatorSignal()
    let session = T3CoordinatorSessionFake(
      storedRecord: old, exchangeRecord: candidate, commitOutcome: .failure,
      commitGate: commitGate)
    let relay = T3CoordinatorRelayFake(
      listOutcomes: [
        .success([oldEnvironment]), .success([environment(id: "new")]),
        .success([oldEnvironment]),
      ])
    let fixture = makeFixture(
      session: session, relay: relay,
      onCloudCycleCompleted: { _ in cloudCycles.signal() })
    await fixture.coordinator.loadAccount()
    fixture.coordinator.startInventory()
    await cloudCycles.wait(for: 1)
    let lastGood = fixture.coordinator.cloudCandidates

    let linkTask = Task { await fixture.coordinator.link() }
    await commitGate.waitUntilEntered()
    await fixture.sleeper.resumeFirst(interval: 10)
    await cloudCycles.wait(for: 2)

    XCTAssertEqual(fixture.coordinator.cloudCandidates, lastGood)

    await commitGate.resume()
    await linkTask.value
    await fixture.sleeper.waitForSleep(interval: 60, count: 2)
    let listCalls = await relay.listCallCount()
    XCTAssertEqual(
      fixture.coordinator.state,
      .linked(T3ConnectAccount(record: old), lastSync: now))
    XCTAssertEqual(fixture.coordinator.cloudCandidates, lastGood)
    XCTAssertEqual(listCalls, 3)
  }

  func testCancelDuringCommitCannotLeaveStoredAndDisplayedAccountsDifferent() async throws {
    let candidate = try record(
      grantID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!)
    let commitGate = T3CoordinatorGate()
    let session = T3CoordinatorSessionFake(
      exchangeRecord: candidate, commitOutcome: .success, commitGate: commitGate)
    let relay = T3CoordinatorRelayFake(listOutcomes: [.success([])])
    let fixture = makeFixture(session: session, relay: relay)

    let linkTask = Task { await fixture.coordinator.link() }
    await commitGate.waitUntilEntered()
    fixture.coordinator.cancelLink()
    await commitGate.resume()
    await linkTask.value

    let storedAccount = await session.storedAccount()
    XCTAssertEqual(storedAccount, T3ConnectAccount(record: candidate))
    XCTAssertEqual(
      fixture.coordinator.state,
      .linked(T3ConnectAccount(record: candidate), lastSync: now))
  }

  func testSignOutWaitsForStartedCommitBeforeDeletingStoredAccount() async throws {
    let candidate = try record(
      grantID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!)
    let commitGate = T3CoordinatorGate()
    let session = T3CoordinatorSessionFake(
      exchangeRecord: candidate, commitOutcome: .success, commitGate: commitGate)
    let relay = T3CoordinatorRelayFake(listOutcomes: [.success([])])
    let fixture = makeFixture(session: session, relay: relay)
    let linkTask = Task { await fixture.coordinator.link() }
    await commitGate.waitUntilEntered()

    let signOutTask = Task { try await fixture.coordinator.signOut() }
    while fixture.coordinator.state != .signedOut { await Task.yield() }
    let resetsWhileCommitSuspended = await fixture.signer.resetCallCount()
    XCTAssertEqual(resetsWhileCommitSuspended, 0)

    await commitGate.resume()
    try await signOutTask.value
    await linkTask.value

    let storedAccount = await session.storedAccount()
    XCTAssertNil(storedAccount)
    XCTAssertEqual(fixture.coordinator.state, .signedOut)
  }

  func testInventoryFailureKeepsLastGoodInventoryAndMonitorTasks() async throws {
    let old = try record(grantID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
    let environment = environment(id: "old")
    let session = T3CoordinatorSessionFake(storedRecord: old)
    let relay = T3CoordinatorRelayFake(listOutcomes: [.success([environment]), .failure])
    let fixture = makeFixture(session: session, relay: relay)
    await fixture.coordinator.loadAccount()
    fixture.coordinator.startInventory()
    await fixture.sleeper.waitForSleep(interval: 60, count: 1)
    await fixture.sleeper.waitForSleep(interval: 10, count: 1)
    let candidates = fixture.coordinator.cloudCandidates

    fixture.coordinator.refreshNow()
    await fixture.sleeper.waitForSleep(interval: 5, count: 1)

    XCTAssertEqual(fixture.coordinator.environments, [environment])
    XCTAssertEqual(fixture.coordinator.cloudCandidates, candidates)
    guard case .unavailable(let account, _) = fixture.coordinator.state else {
      return XCTFail("Expected unavailable state")
    }
    XCTAssertEqual(account, T3ConnectAccount(record: old))
  }

  func testDependencyCancellationRetriesInventoryWithoutStrandingItsHandle() async throws {
    let account = try record(
      grantID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
    let environment = environment(id: "recovered")
    let cycles = T3CoordinatorSignal()
    let session = T3CoordinatorSessionFake(storedRecord: account)
    await session.setValidOutcomes([.cancellation, .success([])])
    let relay = T3CoordinatorRelayFake(listOutcomes: [.success([environment])])
    let fixture = makeFixture(
      session: session, relay: relay,
      onInventoryCycleCompleted: { cycles.signal() })
    await fixture.coordinator.loadAccount()

    fixture.coordinator.startInventory()
    await cycles.wait(for: 1)
    guard case .unavailable = fixture.coordinator.state else {
      return XCTFail("Expected dependency cancellation to enter retry backoff")
    }

    await fixture.sleeper.resumeFirst(interval: 5)
    await cycles.wait(for: 2)

    XCTAssertEqual(
      fixture.coordinator.state,
      .linked(T3ConnectAccount(record: account), lastSync: now))
    XCTAssertEqual(fixture.coordinator.environments, [environment])
  }

  func testDependencyCancellationRetriesCloudMonitorWithoutStrandingItsHandle() async throws {
    let account = try record(
      grantID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
    let environment = environment(id: "recovered")
    let cycles = T3CoordinatorSignal()
    let session = T3CoordinatorSessionFake(storedRecord: account)
    await session.setValidOutcomes([.success([]), .cancellation, .success([])])
    let relay = T3CoordinatorRelayFake(listOutcomes: [.success([environment])])
    let fixture = makeFixture(
      session: session, relay: relay,
      onCloudCycleCompleted: { _ in cycles.signal() })
    await fixture.coordinator.loadAccount()

    fixture.coordinator.startInventory()
    await cycles.wait(for: 1)
    guard case .offline = fixture.coordinator.cloudCandidates.first?.state else {
      return XCTFail("Expected dependency cancellation to enter cloud retry backoff")
    }

    await fixture.sleeper.resumeFirst(interval: 5)
    await cycles.wait(for: 2)

    XCTAssertEqual(fixture.coordinator.cloudCandidates.map(\.state), [.connected])
    let authorizationCalls = await relay.authorizationCallCount("recovered")
    XCTAssertEqual(authorizationCalls, 1)
  }

  func testSuccessfulEmptyInventoryRemovesAllConnectCandidates() async throws {
    let old = try record(grantID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
    let session = T3CoordinatorSessionFake(storedRecord: old)
    let relay = T3CoordinatorRelayFake(
      listOutcomes: [.success([environment(id: "old")]), .success([])])
    let fixture = makeFixture(session: session, relay: relay)
    await fixture.coordinator.loadAccount()
    fixture.coordinator.startInventory()
    await fixture.sleeper.waitForSleep(interval: 60, count: 1)
    XCTAssertFalse(fixture.coordinator.cloudCandidates.isEmpty)

    fixture.coordinator.refreshNow()
    await fixture.sleeper.waitForSleep(interval: 60, count: 2)

    XCTAssertTrue(fixture.coordinator.environments.isEmpty)
    XCTAssertTrue(fixture.coordinator.cloudCandidates.isEmpty)
  }

  func testRejectedRefreshStopsOnlyCloudWorkAndClearsRelayCaches() async throws {
    let old = try record(grantID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
    let session = T3CoordinatorSessionFake(storedRecord: old)
    await session.setValidOutcomes([.reauthenticationRequired])
    let relay = T3CoordinatorRelayFake()
    let fixture = makeFixture(session: session, relay: relay)
    await fixture.coordinator.loadAccount()

    fixture.coordinator.startInventory()
    await relay.waitForClearCalls(1)

    guard case .needsSignIn(let account, _) = fixture.coordinator.state else {
      return XCTFail("Expected needs-sign-in state")
    }
    XCTAssertEqual(account, T3ConnectAccount(record: old))
    XCTAssertTrue(fixture.coordinator.environments.isEmpty)
    let clearCalls = await relay.clearCallCount()
    XCTAssertEqual(clearCalls, 1)
  }

  func testCloudRefreshRejectionMovesAccountToNeedsSignInImmediately() async throws {
    let account = try record(
      grantID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
    let environment = environment(id: "rejected")
    let cycles = T3CoordinatorSignal()
    let session = T3CoordinatorSessionFake(storedRecord: account)
    await session.setValidOutcomes([.success([]), .reauthenticationRequired])
    let relay = T3CoordinatorRelayFake(listOutcomes: [.success([environment])])
    let fixture = makeFixture(
      session: session, relay: relay,
      onCloudCycleCompleted: { _ in cycles.signal() })
    await fixture.coordinator.loadAccount()

    fixture.coordinator.startInventory()
    await cycles.wait(for: 1)

    guard case .needsSignIn(let displayedAccount, _) = fixture.coordinator.state else {
      return XCTFail("Expected cloud refresh rejection to require sign-in")
    }
    XCTAssertEqual(displayedAccount, T3ConnectAccount(record: account))
    let clearCalls = await relay.clearCallCount()
    XCTAssertEqual(clearCalls, 1)
  }

  func testRemotePolicyStopCancelsWorkButRetainsInventoryAndSnapshots() async throws {
    let old = try record(grantID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
    let environment = environment(id: "old")
    let session = T3CoordinatorSessionFake(storedRecord: old)
    let relay = T3CoordinatorRelayFake(listOutcomes: [.success([environment])])
    let fixture = makeFixture(session: session, relay: relay)
    await fixture.coordinator.loadAccount()
    fixture.coordinator.startInventory()
    await fixture.sleeper.waitForSleep(interval: 60, count: 1)
    await fixture.sleeper.waitForSleep(interval: 10, count: 1)
    let state = fixture.coordinator.state
    let candidates = fixture.coordinator.cloudCandidates

    fixture.coordinator.stopInventory(preserveInventory: true)

    XCTAssertEqual(fixture.coordinator.state, state)
    XCTAssertEqual(fixture.coordinator.environments, [environment])
    XCTAssertEqual(fixture.coordinator.cloudCandidates, candidates)
  }

  func testRemotePolicyResumeListsAndPollsImmediately() async throws {
    let old = try record(grantID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
    let environment = environment(id: "old")
    let session = T3CoordinatorSessionFake(storedRecord: old)
    let relay = T3CoordinatorRelayFake(
      listOutcomes: [.success([environment]), .success([environment])])
    let fixture = makeFixture(session: session, relay: relay)
    await fixture.coordinator.loadAccount()
    fixture.coordinator.startInventory()
    await fixture.sleeper.waitForSleep(interval: 60, count: 1)
    await fixture.sleeper.waitForSleep(interval: 10, count: 1)
    fixture.coordinator.stopInventory(preserveInventory: true)

    fixture.coordinator.startInventory()
    await fixture.sleeper.waitForSleep(interval: 60, count: 2)
    await fixture.sleeper.waitForSleep(interval: 10, count: 2)

    let listCalls = await relay.listCallCount()
    let authorizationCalls = await relay.authorizationCallCount("old")
    XCTAssertEqual(listCalls, 2)
    XCTAssertGreaterThanOrEqual(authorizationCalls, 2)
  }

  func testSignOutDuringSuspendedInventorySuppressesLateList() async throws {
    let old = try record(grantID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
    let gate = T3CoordinatorGate()
    let session = T3CoordinatorSessionFake(storedRecord: old)
    let relay = T3CoordinatorRelayFake(
      listOutcomes: [.success([environment(id: "late")])], listGates: [1: gate])
    let fixture = makeFixture(session: session, relay: relay)
    await fixture.coordinator.loadAccount()
    fixture.coordinator.startInventory()
    await gate.waitUntilEntered()

    try await fixture.coordinator.signOut()
    await gate.resume()
    await relay.waitForListReturns(1)

    XCTAssertEqual(fixture.coordinator.state, .signedOut)
    XCTAssertTrue(fixture.coordinator.environments.isEmpty)
    XCTAssertTrue(fixture.coordinator.cloudCandidates.isEmpty)
  }

  func testLateRejectedInventoryCannotOverwriteANewerRefresh() async throws {
    let account = try record(
      grantID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
    let environment = environment(id: "current")
    let oldGate = T3CoordinatorGate()
    let cycles = T3CoordinatorSignal()
    let session = T3CoordinatorSessionFake(storedRecord: account)
    let relay = T3CoordinatorRelayFake(
      listOutcomes: [.reauthenticationRequired, .success([environment])],
      listGates: [1: oldGate])
    let fixture = makeFixture(
      session: session, relay: relay,
      onInventoryCycleCompleted: { cycles.signal() })
    await fixture.coordinator.loadAccount()
    fixture.coordinator.startInventory()
    await oldGate.waitUntilEntered()

    fixture.coordinator.refreshNow()
    await cycles.wait(for: 1)
    await fixture.sleeper.waitForSleep(interval: 10, count: 1)
    await oldGate.resume()
    await cycles.wait(for: 2)

    XCTAssertEqual(
      fixture.coordinator.state,
      .linked(T3ConnectAccount(record: account), lastSync: now))
    XCTAssertEqual(fixture.coordinator.environments, [environment])
    let clearCalls = await relay.clearCallCount()
    XCTAssertEqual(clearCalls, 0)
  }

  func testSignOutDuringSuspendedAuthorizationSuppressesLateSnapshot() async throws {
    let old = try record(grantID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
    let gate = T3CoordinatorGate()
    let session = T3CoordinatorSessionFake(storedRecord: old)
    let relay = T3CoordinatorRelayFake(
      listOutcomes: [.success([environment(id: "late")])],
      authorizationGates: ["late": [gate]])
    let fixture = makeFixture(session: session, relay: relay)
    await fixture.coordinator.loadAccount()
    fixture.coordinator.startInventory()
    await gate.waitUntilEntered()

    try await fixture.coordinator.signOut()
    await gate.resume()
    await relay.waitForAuthorizationReturns(environmentID: "late", count: 1)

    XCTAssertEqual(fixture.coordinator.state, .signedOut)
    XCTAssertTrue(fixture.coordinator.cloudCandidates.isEmpty)
    let shellCalls = await fixture.shells.callCount(environmentID: "late")
    XCTAssertEqual(shellCalls, 0)
  }

  func testSignOutCleanupOrderIsSignerRelayOAuthThenProofKey() async throws {
    let events = T3CoordinatorEventRecorder()
    let old = try record(grantID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
    let session = T3CoordinatorSessionFake(storedRecord: old, events: events)
    let relay = T3CoordinatorRelayFake(events: events)
    let signer = T3CoordinatorSignerFake(events: events)
    let fixture = makeFixture(
      session: session, relay: relay, events: events, signer: signer)
    await fixture.coordinator.loadAccount()

    try await fixture.coordinator.signOut()

    XCTAssertEqual(
      events.values(),
      ["signer.reset", "relay.clear", "session.signOut", "oauth.delete", "proof.delete"])
    XCTAssertEqual(fixture.coordinator.state, .signedOut)
  }

  func testUnauthorizedCloudRequestRemintsOnlyTheRejectedEnvironmentOnce() async throws {
    let account = try record(
      grantID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
    let first = environment(id: "first")
    let second = environment(id: "second")
    let session = T3CoordinatorSessionFake(storedRecord: account)
    let relay = T3CoordinatorRelayFake(listOutcomes: [.success([first, second])])
    let shells = T3CoordinatorShellFake()
    await shells.setOutcomes([.unauthorized, .success(.empty)], environmentID: "first")
    let sleeper = T3CoordinatorSleeper(returnImmediately: [5])
    let fixture = makeFixture(
      session: session, relay: relay, shells: shells, sleeper: sleeper)
    await fixture.coordinator.loadAccount()

    fixture.coordinator.startInventory()
    await sleeper.waitForSleep(interval: 10, count: 2)

    let firstAuthorizations = await relay.authorizationCallCount("first")
    let secondAuthorizations = await relay.authorizationCallCount("second")
    let invalidations = await relay.invalidatedEnvironmentIDs()
    XCTAssertEqual(firstAuthorizations, 2)
    XCTAssertEqual(secondAuthorizations, 1)
    XCTAssertEqual(invalidations, ["first"])
  }

  func testUnauthorizedRetryIsNotRemintedASecondTimeBeforeBackoff() async throws {
    let account = try record(
      grantID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
    let environment = environment(id: "rejected")
    let session = T3CoordinatorSessionFake(storedRecord: account)
    let relay = T3CoordinatorRelayFake(listOutcomes: [.success([environment])])
    let shells = T3CoordinatorShellFake()
    await shells.setOutcomes([.unauthorized, .unauthorized], environmentID: "rejected")
    let fixture = makeFixture(session: session, relay: relay, shells: shells)
    await fixture.coordinator.loadAccount()

    fixture.coordinator.startInventory()
    await fixture.sleeper.waitForSleep(interval: 5, count: 1)

    let authorizationCalls = await relay.authorizationCallCount("rejected")
    let shellCalls = await shells.callCount(environmentID: "rejected")
    let invalidations = await relay.invalidatedEnvironmentIDs()
    XCTAssertEqual(authorizationCalls, 2)
    XCTAssertEqual(shellCalls, 2)
    XCTAssertEqual(invalidations, ["rejected", "rejected"])
  }

  func testEndpointRotationRejectsTheOldMonitorsLateSnapshot() async throws {
    let account = try record(
      grantID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
    let old = environment(id: "same", origin: "https://old.example.test")
    let replacement = environment(id: "same", origin: "https://new.example.test")
    let oldGate = T3CoordinatorGate()
    let replacementGate = T3CoordinatorGate()
    let session = T3CoordinatorSessionFake(storedRecord: account)
    let relay = T3CoordinatorRelayFake(
      listOutcomes: [.success([old]), .success([replacement])])
    let shells = T3CoordinatorShellFake()
    await shells.setGates([oldGate, replacementGate], environmentID: "same")
    let fixture = makeFixture(session: session, relay: relay, shells: shells)
    await fixture.coordinator.loadAccount()
    fixture.coordinator.startInventory()
    await oldGate.waitUntilEntered()

    fixture.coordinator.refreshNow()
    await replacementGate.waitUntilEntered()
    XCTAssertEqual(
      fixture.coordinator.cloudCandidates.map(\.baseURL),
      ["https://new.example.test"])
    XCTAssertEqual(fixture.coordinator.cloudCandidates.map(\.state), [.connecting])
    await replacementGate.resume()
    await fixture.sleeper.waitForSleep(interval: 10, count: 1)
    await oldGate.resume()
    await shells.waitForReturns(environmentID: "same", count: 2)

    XCTAssertEqual(fixture.coordinator.environments, [replacement])
    XCTAssertEqual(
      fixture.coordinator.cloudCandidates.map(\.baseURL),
      ["https://new.example.test/"])
  }

  func testRemovedEnvironmentRejectsItsOldMonitorsLateSnapshot() async throws {
    let account = try record(
      grantID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
    let removed = environment(id: "removed")
    let oldGate = T3CoordinatorGate()
    let session = T3CoordinatorSessionFake(storedRecord: account)
    let relay = T3CoordinatorRelayFake(
      listOutcomes: [.success([removed]), .success([])])
    let shells = T3CoordinatorShellFake()
    await shells.setGates([oldGate], environmentID: "removed")
    let fixture = makeFixture(session: session, relay: relay, shells: shells)
    await fixture.coordinator.loadAccount()
    fixture.coordinator.startInventory()
    await oldGate.waitUntilEntered()

    fixture.coordinator.refreshNow()
    await fixture.sleeper.waitForSleep(interval: 60, count: 2)
    await oldGate.resume()
    await shells.waitForReturns(environmentID: "removed", count: 1)

    XCTAssertTrue(fixture.coordinator.environments.isEmpty)
    XCTAssertTrue(fixture.coordinator.cloudCandidates.isEmpty)
  }

  func testPublicAuthorizationRejectsEnvironmentRemovedWhileMintIsSuspended() async throws {
    let candidate = try record(
      grantID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!)
    let removed = environment(id: "removed")
    let authorizationGate = T3CoordinatorGate()
    let session = T3CoordinatorSessionFake(exchangeRecord: candidate)
    let relay = T3CoordinatorRelayFake(
      listOutcomes: [.success([removed])],
      authorizationGates: ["removed": [authorizationGate]])
    let fixture = makeFixture(session: session, relay: relay)
    await fixture.coordinator.link()

    let authorizationTask = Task { () -> (any Error)? in
      do {
        _ = try await fixture.coordinator.authorization(for: removed)
        return nil
      } catch {
        return error
      }
    }
    await authorizationGate.waitUntilEntered()
    fixture.coordinator.stopInventory(preserveInventory: false)
    await authorizationGate.resume()
    let error = await authorizationTask.value

    guard let coordinatorError = error as? T3ConnectCoordinatorError,
      case .staleOperation = coordinatorError
    else {
      return XCTFail("Expected stale authorization for a removed environment")
    }
  }

  func testReconnectRestartsInventoryAndEveryEnabledCloudMonitor() async throws {
    let account = try record(
      grantID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
    let first = environment(id: "first")
    let second = environment(id: "second")
    let session = T3CoordinatorSessionFake(storedRecord: account)
    let relay = T3CoordinatorRelayFake(
      listOutcomes: [.success([first, second]), .success([first, second])])
    let fixture = makeFixture(session: session, relay: relay)
    await fixture.coordinator.loadAccount()
    fixture.coordinator.startInventory()
    await fixture.sleeper.waitForSleep(interval: 60, count: 1)
    await fixture.sleeper.waitForSleep(interval: 10, count: 2)

    fixture.coordinator.refreshNow()
    await fixture.sleeper.waitForSleep(interval: 60, count: 2)
    await fixture.sleeper.waitForSleep(interval: 10, count: 4)

    let listCalls = await relay.listCallCount()
    let firstCalls = await relay.authorizationCallCount("first")
    let secondCalls = await relay.authorizationCallCount("second")
    XCTAssertEqual(listCalls, 2)
    XCTAssertEqual(firstCalls, 2)
    XCTAssertEqual(secondCalls, 2)
  }

  func testRepeatedInventoryStartsAreIdempotent() async throws {
    let account = try record(
      grantID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
    let listGate = T3CoordinatorGate()
    let session = T3CoordinatorSessionFake(storedRecord: account)
    let relay = T3CoordinatorRelayFake(
      listOutcomes: [.success([])], listGates: [1: listGate])
    let fixture = makeFixture(session: session, relay: relay)
    await fixture.coordinator.loadAccount()

    fixture.coordinator.startInventory()
    fixture.coordinator.startInventory()
    fixture.coordinator.startInventory()
    await listGate.waitUntilEntered()

    let listCalls = await relay.listCallCount()
    XCTAssertEqual(listCalls, 1)
    fixture.coordinator.stopInventory(preserveInventory: true)
    await listGate.resume()
    await relay.waitForListReturns(1)
  }

  func testPolicyResumeDuringRelinkDefersOldInventoryAndNextListForSixtySeconds() async throws {
    let old = try record(grantID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
    let candidate = try record(
      grantID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!)
    let oldEnvironment = environment(id: "old")
    let newEnvironment = environment(id: "new")
    let callbackGate = T3CoordinatorGate()
    let events = T3CoordinatorEventRecorder()
    let listener = T3CoordinatorListenerFake(
      result: .authorizationCode("browser-code"), events: events, waitGate: callbackGate)
    let session = T3CoordinatorSessionFake(storedRecord: old, exchangeRecord: candidate)
    let relay = T3CoordinatorRelayFake(
      listOutcomes: [
        .success([oldEnvironment]), .success([newEnvironment]), .success([newEnvironment]),
      ])
    let fixture = makeFixture(
      session: session, relay: relay, listener: listener, events: events)
    await fixture.coordinator.loadAccount()
    fixture.coordinator.startInventory()
    await fixture.sleeper.waitForSleep(interval: 60, count: 1)
    await fixture.sleeper.waitForSleep(interval: 10, count: 1)

    let linkTask = Task { await fixture.coordinator.link() }
    await callbackGate.waitUntilEntered()
    fixture.coordinator.stopInventory(preserveInventory: true)
    fixture.coordinator.startInventory()
    fixture.coordinator.refreshNow()

    XCTAssertEqual(
      fixture.coordinator.state,
      .linking(previous: T3ConnectAccount(record: old)))
    let callsDuringLink = await relay.listCallCount()
    XCTAssertEqual(callsDuringLink, 1)

    await callbackGate.resume()
    await linkTask.value
    await fixture.sleeper.waitForSleep(interval: 60, count: 2)
    let callsBeforeInterval = await relay.listCallCount()
    XCTAssertEqual(callsBeforeInterval, 2)
    XCTAssertEqual(fixture.coordinator.activeCloudMonitorEnvironmentIDs, ["new"])

    await fixture.sleeper.resumeFirst(interval: 60)
    await relay.waitForListReturns(3)
    let callsAfterInterval = await relay.listCallCount()
    XCTAssertEqual(callsAfterInterval, 3)
  }

  func testSignOutThenLinkPreservesEnabledRemotePollingPolicy() async throws {
    let old = try record(grantID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
    let candidate = try record(
      grantID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!)
    let oldEnvironment = environment(id: "old")
    let newEnvironment = environment(id: "new")
    let session = T3CoordinatorSessionFake(storedRecord: old, exchangeRecord: candidate)
    let relay = T3CoordinatorRelayFake(
      listOutcomes: [.success([oldEnvironment]), .success([newEnvironment])])
    let fixture = makeFixture(session: session, relay: relay)
    await fixture.coordinator.loadAccount()
    fixture.coordinator.startInventory()
    await fixture.sleeper.waitForSleep(interval: 60, count: 1)
    await fixture.sleeper.waitForSleep(interval: 10, count: 1)

    try await fixture.coordinator.signOut()
    await fixture.coordinator.link()

    guard fixture.coordinator.activeCloudMonitorEnvironmentIDs == ["new"],
      fixture.coordinator.hasScheduledInventory
    else {
      return XCTFail("Expected relink to resume the already-enabled remote polling policy")
    }
    await fixture.sleeper.waitForSleep(interval: 10, count: 2)
    XCTAssertEqual(fixture.coordinator.cloudCandidates.map(\.state), [.connected])
  }

  func testUnchangedPeriodicInventoryDoesNotRestartCloudMonitor() async throws {
    let account = try record(
      grantID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
    let environment = environment(id: "stable")
    let session = T3CoordinatorSessionFake(storedRecord: account)
    let relay = T3CoordinatorRelayFake(
      listOutcomes: [.success([environment]), .success([environment])])
    let fixture = makeFixture(session: session, relay: relay)
    await fixture.coordinator.loadAccount()
    fixture.coordinator.startInventory()
    await fixture.sleeper.waitForSleep(interval: 60, count: 1)
    await fixture.sleeper.waitForSleep(interval: 10, count: 1)

    await fixture.sleeper.resumeFirst(interval: 60)
    await fixture.sleeper.waitForSleep(interval: 60, count: 2)

    let authorizationCalls = await relay.authorizationCallCount("stable")
    XCTAssertEqual(authorizationCalls, 1)
  }

  func testActivitySuspensionEnergyResumeReconnectAndSignOutStaySourceSelective() async throws {
    let previousEnabled = Defaults[.t3CodeEnabled]
    let previousEnergy = Defaults[.energyMode]
    let previousProfiles = Defaults[.t3RemoteEnvironments]
    Defaults[.t3CodeEnabled] = true
    Defaults[.energyMode] = .live
    Defaults[.t3RemoteEnvironments] = []
    defer {
      Defaults[.t3CodeEnabled] = previousEnabled
      Defaults[.energyMode] = previousEnergy
      Defaults[.t3RemoteEnvironments] = previousProfiles
    }
    let account = try record(
      grantID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
    let environment = environment(id: "cloud")
    let session = T3CoordinatorSessionFake(storedRecord: account)
    let relay = T3CoordinatorRelayFake(
      listOutcomes: Array(repeating: .success([environment]), count: 4))
    let fixture = makeFixture(session: session, relay: relay)
    let activity = T3CodeActivity(
      localEndpointProvider: { nil }, connectCoordinator: fixture.coordinator)
    await activity.loadConnectAccount()
    activity.start()
    await fixture.sleeper.waitForSleep(interval: 60, count: 1)
    await fixture.sleeper.waitForSleep(interval: 10, count: 1)
    XCTAssertEqual(activity.environments.filter { $0.source == .connect }.count, 1)

    activity.setSystemSuspended(true)
    XCTAssertFalse(fixture.coordinator.hasScheduledInventory)
    XCTAssertTrue(fixture.coordinator.activeCloudMonitorEnvironmentIDs.isEmpty)
    XCTAssertEqual(activity.environments.filter { $0.source == .connect }.count, 1)

    activity.setSystemSuspended(false)
    await fixture.sleeper.waitForSleep(interval: 60, count: 2)
    await fixture.sleeper.waitForSleep(interval: 10, count: 2)

    Defaults[.energyMode] = .lowEnergy
    activity.restartMonitors(clearSnapshots: false)
    XCTAssertFalse(fixture.coordinator.hasScheduledInventory)
    XCTAssertEqual(activity.environments.filter { $0.source == .connect }.count, 1)

    Defaults[.energyMode] = .live
    activity.restartMonitors(clearSnapshots: false)
    await fixture.sleeper.waitForSleep(interval: 60, count: 3)
    await fixture.sleeper.waitForSleep(interval: 10, count: 3)

    activity.reconnect()
    await fixture.sleeper.waitForSleep(interval: 60, count: 4)
    await fixture.sleeper.waitForSleep(interval: 10, count: 4)

    let manual = T3EnvironmentSnapshot(
      id: "remote|manual|https://manual.example.test/", logicalEnvironmentID: "manual",
      source: .manual, label: "Manual", baseURL: "https://manual.example.test/",
      platform: nil, serverVersion: "1", state: .connected, agents: [])
    activity.upsert(manual)
    try await fixture.coordinator.signOut()

    XCTAssertTrue(activity.environments.filter { $0.source == .connect }.isEmpty)
    XCTAssertTrue(activity.environments.contains(manual))
    activity.stop()
  }

  private func makeFixture(
    session: T3CoordinatorSessionFake,
    relay: T3CoordinatorRelayFake,
    listener: T3CoordinatorListenerFake? = nil,
    events: T3CoordinatorEventRecorder = T3CoordinatorEventRecorder(),
    signer: T3CoordinatorSignerFake? = nil,
    shells: T3CoordinatorShellFake? = nil,
    sleeper: T3CoordinatorSleeper? = nil,
    onInventoryCycleCompleted: @escaping @MainActor @Sendable () -> Void = {},
    onCloudCycleCompleted: @escaping @MainActor @Sendable (String) -> Void = { _ in }
  ) -> T3CoordinatorFixture {
    let listener =
      listener
      ?? T3CoordinatorListenerFake(
        result: .authorizationCode("browser-code"), events: events)
    let signer = signer ?? T3CoordinatorSignerFake(events: events)
    let shells = shells ?? T3CoordinatorShellFake()
    let sleeper = sleeper ?? T3CoordinatorSleeper()
    let fixedNow = now
    let coordinator = T3ConnectCoordinator(
      session: session,
      relay: relay,
      signerResetter: signer,
      configuration: .coordinatorTest,
      listenerFactory: { listener },
      openURL: { url in
        events.append("browser.open")
        return url.host == "app.t3-unit.test"
      },
      transactionFactory: {
        try T3PKCETransaction { count in
          Data(repeating: count == 32 ? 0x11 : 0x22, count: count)
        }
      },
      now: { fixedNow },
      sleeper: sleeper,
      shellLoader: { authorization in try await shells.load(authorization) },
      cloudPollInterval: { _ in 10 },
      onInventoryCycleCompleted: onInventoryCycleCompleted,
      onCloudCycleCompleted: onCloudCycleCompleted)
    return T3CoordinatorFixture(
      coordinator: coordinator, listener: listener, signer: signer, shells: shells,
      sleeper: sleeper)
  }

  private func record(
    grantID: UUID,
    accessToken: String = "old-access",
    displayIdentity: String? = "person@example.com"
  ) throws -> T3OAuthRecord {
    try T3OAuthRecord(
      grantID: grantID, accessToken: accessToken, refreshToken: "refresh-token",
      expiresAt: now.addingTimeInterval(3_600), displayIdentity: displayIdentity)
  }

  private func environment(
    id: String,
    origin: String? = nil
  ) -> T3ConnectEnvironment {
    let origin = origin ?? "https://\(id).example.test"
    return T3ConnectEnvironment(
      environmentID: id, label: id.capitalized,
      httpBaseURL: URL(string: origin)!,
      webSocketBaseURL: URL(string: origin.replacingOccurrences(of: "https://", with: "wss://"))!,
      providerKind: "cloudflare_tunnel", linkedAt: now)
  }
}

private struct T3CoordinatorFixture {
  let coordinator: T3ConnectCoordinator
  let listener: T3CoordinatorListenerFake
  let signer: T3CoordinatorSignerFake
  let shells: T3CoordinatorShellFake
  let sleeper: T3CoordinatorSleeper
}

private enum T3CoordinatorOutcome: Sendable {
  case success
  case failure
}

private enum T3CoordinatorListOutcome: Sendable {
  case success([T3ConnectEnvironment])
  case failure
  case cancellation
  case reauthenticationRequired
}

private enum T3CoordinatorShellOutcome: Sendable {
  case success(T3ShellSnapshot)
  case unauthorized
  case failure
}

private enum T3CoordinatorTestError: Error, Sendable {
  case failed
}

private final class T3CoordinatorEventRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [String] = []

  func append(_ value: String) {
    lock.lock()
    storage.append(value)
    lock.unlock()
  }

  func values() -> [String] {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }
}

private final class T3CoordinatorSignal: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

  func signal() {
    lock.lock()
    count += 1
    let ready = waiters.filter { $0.0 <= count }
    waiters.removeAll { $0.0 <= count }
    lock.unlock()
    for waiter in ready { waiter.1.resume() }
  }

  func wait(for target: Int) async {
    await withCheckedContinuation { continuation in
      lock.lock()
      if count >= target {
        lock.unlock()
        continuation.resume()
      } else {
        waiters.append((target, continuation))
        lock.unlock()
      }
    }
  }
}

private actor T3CoordinatorGate {
  private var continuation: CheckedContinuation<Void, Never>?
  private var entered = false
  private var enteredWaiters: [CheckedContinuation<Void, Never>] = []

  func suspend() async {
    entered = true
    let waiters = enteredWaiters
    enteredWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
    await withCheckedContinuation { continuation = $0 }
  }

  func waitUntilEntered() async {
    if entered { return }
    await withCheckedContinuation { enteredWaiters.append($0) }
  }

  func resume() {
    continuation?.resume()
    continuation = nil
  }
}

private actor T3CoordinatorSessionFake: T3ConnectSessionServing {
  private var record: T3OAuthRecord?
  private let loadGate: T3CoordinatorGate?
  private let loadOutcome: T3CoordinatorOutcome
  private let exchangeRecord: T3OAuthRecord?
  private let commitOutcome: T3CoordinatorOutcome
  private let commitGate: T3CoordinatorGate?
  private let events: T3CoordinatorEventRecorder?
  private var commitCalls = 0
  private var commitInProgress = false
  private var validOutcomes: [T3CoordinatorListOutcome] = []

  init(
    storedRecord: T3OAuthRecord? = nil,
    loadGate: T3CoordinatorGate? = nil,
    loadOutcome: T3CoordinatorOutcome = .success,
    exchangeRecord: T3OAuthRecord? = nil,
    commitOutcome: T3CoordinatorOutcome = .success,
    commitGate: T3CoordinatorGate? = nil,
    events: T3CoordinatorEventRecorder? = nil
  ) {
    record = storedRecord
    self.loadGate = loadGate
    self.loadOutcome = loadOutcome
    self.exchangeRecord = exchangeRecord
    self.commitOutcome = commitOutcome
    self.commitGate = commitGate
    self.events = events
  }

  func loadStoredAccount() async throws -> T3ConnectAccount? {
    let loaded = record.map(T3ConnectAccount.init(record:))
    if let loadGate { await loadGate.suspend() }
    if loadOutcome == .failure { throw T3CoordinatorTestError.failed }
    return loaded
  }

  func exchangeAuthorizationCode(_ code: String, verifier: String) async throws -> T3OAuthRecord {
    guard !code.isEmpty, !verifier.isEmpty, let exchangeRecord else {
      throw T3CoordinatorTestError.failed
    }
    return exchangeRecord
  }

  func validOAuthRecord() async throws -> T3OAuthRecord {
    if commitInProgress { throw T3ConnectSessionError.staleOperation }
    if !validOutcomes.isEmpty {
      switch validOutcomes.removeFirst() {
      case .success:
        break
      case .failure:
        throw T3CoordinatorTestError.failed
      case .cancellation:
        throw CancellationError()
      case .reauthenticationRequired:
        throw T3ConnectSessionError.reauthenticationRequired
      }
    }
    guard let record else { throw T3ConnectSessionError.notLinked }
    return record
  }

  func commit(_ candidate: T3OAuthRecord) async throws {
    commitCalls += 1
    commitInProgress = true
    defer { commitInProgress = false }
    events?.append("session.commit")
    if let commitGate { await commitGate.suspend() }
    if commitOutcome == .failure { throw T3CoordinatorTestError.failed }
    record = candidate
  }

  func signOut() async throws {
    events?.append("session.signOut")
    events?.append("oauth.delete")
    events?.append("proof.delete")
    record = nil
  }

  func setValidOutcomes(_ outcomes: [T3CoordinatorListOutcome]) { validOutcomes = outcomes }
  func commitCallCount() -> Int { commitCalls }
  func storedAccount() -> T3ConnectAccount? { record.map(T3ConnectAccount.init(record:)) }
}

private actor T3CoordinatorRelayFake: T3RelayServing {
  private var listOutcomes: [T3CoordinatorListOutcome]
  private let listGates: [Int: T3CoordinatorGate]
  private var authorizationGates: [String: [T3CoordinatorGate]]
  private let events: T3CoordinatorEventRecorder?
  private var listCalls = 0
  private var listReturns = 0
  private var clearCalls = 0
  private var authorizationCalls: [String: Int] = [:]
  private var authorizationReturns: [String: Int] = [:]
  private var invalidations: [String] = []
  private var listReturnWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
  private var clearWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
  private var authorizationReturnWaiters: [(String, Int, CheckedContinuation<Void, Never>)] = []

  init(
    listOutcomes: [T3CoordinatorListOutcome] = [],
    listGates: [Int: T3CoordinatorGate] = [:],
    authorizationGates: [String: [T3CoordinatorGate]] = [:],
    events: T3CoordinatorEventRecorder? = nil
  ) {
    self.listOutcomes = listOutcomes
    self.listGates = listGates
    self.authorizationGates = authorizationGates
    self.events = events
  }

  func listEnvironments(accountToken: String) async throws -> [T3ConnectEnvironment] {
    listCalls += 1
    let call = listCalls
    let outcome = listOutcomes.isEmpty ? .success([]) : listOutcomes.removeFirst()
    if let gate = listGates[call] { await gate.suspend() }
    listReturns += 1
    resumeListReturnWaiters()
    switch outcome {
    case .success(let environments): return environments
    case .failure: throw T3CoordinatorTestError.failed
    case .cancellation: throw CancellationError()
    case .reauthenticationRequired: throw T3ConnectSessionError.reauthenticationRequired
    }
  }

  func authorize(
    environment: T3ConnectEnvironment,
    accountToken: String,
    grantID: UUID
  ) async throws -> T3ConnectEnvironmentAuthorization {
    let environmentID = environment.environmentID
    authorizationCalls[environmentID, default: 0] += 1
    if var gates = authorizationGates[environmentID], !gates.isEmpty {
      let gate = gates.removeFirst()
      authorizationGates[environmentID] = gates
      await gate.suspend()
    }
    let endpoint = try T3Endpoint(environment.httpBaseURL)
    let authorization = T3ConnectEnvironmentAuthorization(
      descriptor: T3EnvironmentDescriptor(
        environmentId: environmentID, label: environment.label,
        platform: T3EnvironmentDescriptor.Platform(os: "macOS", arch: "arm64"),
        serverVersion: "1"),
      endpoint: endpoint, authorization: .none,
      expiresAt: Date(timeIntervalSince1970: 1_788_003_600))
    authorizationReturns[environmentID, default: 0] += 1
    resumeAuthorizationReturnWaiters()
    return authorization
  }

  func invalidateAuthorization(environmentID: String, grantID: UUID) async {
    invalidations.append(environmentID)
  }

  func clearCaches() async {
    clearCalls += 1
    events?.append("relay.clear")
    resumeClearWaiters()
  }

  func listCallCount() -> Int { listCalls }
  func clearCallCount() -> Int { clearCalls }
  func authorizationCallCount(_ environmentID: String) -> Int {
    authorizationCalls[environmentID, default: 0]
  }
  func invalidatedEnvironmentIDs() -> [String] { invalidations }

  func waitForListReturns(_ count: Int) async {
    if listReturns >= count { return }
    await withCheckedContinuation { listReturnWaiters.append((count, $0)) }
  }

  func waitForClearCalls(_ count: Int) async {
    if clearCalls >= count { return }
    await withCheckedContinuation { clearWaiters.append((count, $0)) }
  }

  func waitForAuthorizationReturns(environmentID: String, count: Int) async {
    if authorizationReturns[environmentID, default: 0] >= count { return }
    await withCheckedContinuation {
      authorizationReturnWaiters.append((environmentID, count, $0))
    }
  }

  private func resumeListReturnWaiters() {
    var remaining: [(Int, CheckedContinuation<Void, Never>)] = []
    for waiter in listReturnWaiters {
      if listReturns >= waiter.0 {
        waiter.1.resume()
      } else {
        remaining.append(waiter)
      }
    }
    listReturnWaiters = remaining
  }

  private func resumeClearWaiters() {
    var remaining: [(Int, CheckedContinuation<Void, Never>)] = []
    for waiter in clearWaiters {
      if clearCalls >= waiter.0 {
        waiter.1.resume()
      } else {
        remaining.append(waiter)
      }
    }
    clearWaiters = remaining
  }

  private func resumeAuthorizationReturnWaiters() {
    var remaining: [(String, Int, CheckedContinuation<Void, Never>)] = []
    for waiter in authorizationReturnWaiters {
      if authorizationReturns[waiter.0, default: 0] >= waiter.1 {
        waiter.2.resume()
      } else {
        remaining.append(waiter)
      }
    }
    authorizationReturnWaiters = remaining
  }
}

private actor T3CoordinatorListenerFake: T3OAuthLoopbackListening {
  private let result: T3OAuthCallbackResult
  private let events: T3CoordinatorEventRecorder
  private let startGate: T3CoordinatorGate?
  private let waitGate: T3CoordinatorGate?

  init(
    result: T3OAuthCallbackResult,
    events: T3CoordinatorEventRecorder,
    startGate: T3CoordinatorGate? = nil,
    waitGate: T3CoordinatorGate? = nil
  ) {
    self.result = result
    self.events = events
    self.startGate = startGate
    self.waitGate = waitGate
  }

  func start(state: String) async throws {
    events.append("listener.start")
    if let startGate { await startGate.suspend() }
  }
  func waitForCallback() async throws -> T3OAuthCallbackResult {
    events.append("listener.wait")
    if let waitGate { await waitGate.suspend() }
    return result
  }
  func cancel() async { events.append("listener.cancel") }
}

private actor T3CoordinatorSignerFake: T3DPoPResetting {
  private let events: T3CoordinatorEventRecorder
  private var resetCalls = 0

  init(events: T3CoordinatorEventRecorder) { self.events = events }

  func reset() async {
    resetCalls += 1
    events.append("signer.reset")
  }

  func resetCallCount() -> Int { resetCalls }
}

private actor T3CoordinatorShellFake {
  private var outcomes: [String: [T3CoordinatorShellOutcome]] = [:]
  private var gates: [String: [T3CoordinatorGate]] = [:]
  private var calls: [String: Int] = [:]
  private var returns: [String: Int] = [:]
  private var returnWaiters: [(String, Int, CheckedContinuation<Void, Never>)] = []

  func load(_ authorization: T3ConnectEnvironmentAuthorization) async throws -> T3ShellSnapshot {
    let id = authorization.descriptor.environmentId
    calls[id, default: 0] += 1
    if var environmentGates = gates[id], !environmentGates.isEmpty {
      let gate = environmentGates.removeFirst()
      gates[id] = environmentGates
      await gate.suspend()
    }
    let outcome: T3CoordinatorShellOutcome
    if var environmentOutcomes = outcomes[id], !environmentOutcomes.isEmpty {
      outcome = environmentOutcomes.removeFirst()
      outcomes[id] = environmentOutcomes
    } else {
      outcome = .success(Self.shell())
    }
    returns[id, default: 0] += 1
    resumeReturnWaiters()
    switch outcome {
    case .success(let shell):
      return shell
    case .unauthorized:
      throw T3ClientError.unauthorized
    case .failure:
      throw T3CoordinatorTestError.failed
    }
  }

  func setOutcomes(_ outcomes: [T3CoordinatorShellOutcome], environmentID: String) {
    self.outcomes[environmentID] = outcomes
  }

  func setGates(_ gates: [T3CoordinatorGate], environmentID: String) {
    self.gates[environmentID] = gates
  }

  func callCount(environmentID: String) -> Int { calls[environmentID, default: 0] }

  func waitForReturns(environmentID: String, count: Int) async {
    if returns[environmentID, default: 0] >= count { return }
    await withCheckedContinuation { returnWaiters.append((environmentID, count, $0)) }
  }

  private func resumeReturnWaiters() {
    var remaining: [(String, Int, CheckedContinuation<Void, Never>)] = []
    for waiter in returnWaiters {
      if returns[waiter.0, default: 0] >= waiter.1 {
        waiter.2.resume()
      } else {
        remaining.append(waiter)
      }
    }
    returnWaiters = remaining
  }

  private static func shell() -> T3ShellSnapshot {
    T3ShellSnapshot(snapshotSequence: 1, projects: [], threads: [], updatedAt: nil)
  }
}

private actor T3CoordinatorSleeper: T3ConnectSleeping {
  private let returnImmediately: Set<TimeInterval>
  private var calls: [TimeInterval] = []
  private var continuations: [UUID: (TimeInterval, CheckedContinuation<Void, any Error>)] = [:]
  private var waiters: [(TimeInterval, Int, CheckedContinuation<Void, Never>)] = []

  init(returnImmediately: Set<TimeInterval> = []) {
    self.returnImmediately = returnImmediately
  }

  func sleep(for interval: TimeInterval) async throws {
    calls.append(interval)
    resumeSatisfiedWaiters()
    if returnImmediately.contains(interval) { return }
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuations[id] = (interval, $0) }
    } onCancel: {
      Task { await self.cancel(id) }
    }
  }

  func waitForSleep(interval: TimeInterval, count: Int) async {
    if calls.filter({ $0 == interval }).count >= count { return }
    await withCheckedContinuation { waiters.append((interval, count, $0)) }
  }

  func resumeAll() {
    let current = continuations.values.map(\.1)
    continuations.removeAll()
    for continuation in current { continuation.resume() }
  }

  func resumeFirst(interval: TimeInterval) {
    guard let entry = continuations.first(where: { $0.value.0 == interval }) else { return }
    continuations[entry.key] = nil
    entry.value.1.resume()
  }

  private func cancel(_ id: UUID) {
    continuations.removeValue(forKey: id)?.1.resume(throwing: CancellationError())
  }

  private func resumeSatisfiedWaiters() {
    var remaining: [(TimeInterval, Int, CheckedContinuation<Void, Never>)] = []
    for waiter in waiters {
      if calls.filter({ $0 == waiter.0 }).count >= waiter.1 {
        waiter.2.resume()
      } else {
        remaining.append(waiter)
      }
    }
    waiters = remaining
  }
}

extension T3ConnectConfiguration {
  fileprivate static let coordinatorTest = T3ConnectConfiguration(
    hostedAuthorizationURL: URL(string: "https://app.t3-unit.test/connect")!,
    tokenEndpoint: URL(string: "https://oauth.t3-unit.test/token")!,
    clientID: "coordinator-test-client",
    redirectURI: URL(string: "http://127.0.0.1:34338/callback")!,
    scopes: ["openid", "profile", "email"],
    relayOrigin: URL(string: "https://relay.t3-unit.test")!,
    relayClientID: "coordinator-test-relay-client")
}

extension T3ShellSnapshot {
  fileprivate static let empty = T3ShellSnapshot(
    snapshotSequence: 1, projects: [], threads: [], updatedAt: nil)
}
