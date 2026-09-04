import Combine
import Defaults
import XCTest

@testable import Islet

@MainActor
final class T3CodeTests: XCTestCase {
  func testCredentialVaultUsesTheCanonicalService() {
    XCTAssertEqual(T3CredentialStore.service, "dev.islet")
  }

  func testAppTransportConfigurationScopesHTTPToLocalNetworking() throws {
    let appTransportSecurity = try XCTUnwrap(
      Bundle.main.infoDictionary?["NSAppTransportSecurity"] as? [String: Any])

    XCTAssertNotEqual(appTransportSecurity["NSAllowsArbitraryLoads"] as? Bool, true)
    XCTAssertEqual(appTransportSecurity["NSAllowsLocalNetworking"] as? Bool, true)
    XCTAssertTrue(
      (appTransportSecurity["NSExceptionDomains"] as? [String: Any] ?? [:]).isEmpty)
    XCTAssertTrue(
      (Bundle.main.infoDictionary?[T3TransportPolicy.approvedOriginsInfoKey] as? [String] ?? [])
        .isEmpty)
  }

  func testEnvironmentAuthStateDecodesNestedSessionMethods() throws {
    let data = Data(
      #"{"authenticated":false,"auth":{"policy":"remote-reachable","bootstrapMethods":["one-time-token"],"sessionMethods":["bearer-access-token","dpop-access-token"],"sessionCookieName":"t3_session"}}"#
        .utf8)

    let state = try JSONDecoder().decode(T3EnvironmentAuthState.self, from: data)

    XCTAssertFalse(state.authenticated)
    XCTAssertEqual(state.auth.policy, "remote-reachable")
    XCTAssertEqual(state.auth.bootstrapMethods, ["one-time-token"])
    XCTAssertEqual(state.auth.sessionMethods, ["bearer-access-token", "dpop-access-token"])
    XCTAssertEqual(state.auth.sessionCookieName, "t3_session")
  }

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

  func testUserApprovalCannotBypassTheBuildTransportPolicy() throws {
    let policy = T3TransportPolicy(infoDictionary: [:])

    XCTAssertThrowsError(
      try T3PairingTarget.parse(
        "http://mini.example.com:3773/pair#token=once",
        allowInsecureRemoteHTTP: true,
        transportPolicy: policy)
    ) { error in
      guard case T3ClientError.unapprovedInsecureRemoteHTTP = error else {
        return XCTFail("Expected unapprovedInsecureRemoteHTTP, got \(error)")
      }
    }
  }

  func testReviewedBuildPolicyCannotBypassUserApproval() {
    let policy = Self.transportPolicy(
      origins: ["http://mini.example.com:3773/"],
      exceptionDomains: [
        "mini.example.com": ["NSExceptionAllowsInsecureHTTPLoads": true]
      ])

    XCTAssertThrowsError(
      try T3Endpoint(
        URL(string: "http://mini.example.com:3773/")!,
        allowInsecureRemoteHTTP: false,
        transportPolicy: policy)
    ) { error in
      guard case T3ClientError.insecureRemoteHTTP = error else {
        return XCTFail("Expected insecureRemoteHTTP, got \(error)")
      }
    }
  }

  func testRemoteHTTPRequiresMatchingReviewedOriginAndATSException() throws {
    let policy = Self.transportPolicy(
      origins: ["http://mini.example.com:3773/"],
      exceptionDomains: [
        "mini.example.com": ["NSExceptionAllowsInsecureHTTPLoads": true]
      ])

    let endpoint = try T3Endpoint(
      URL(string: "http://mini.example.com:3773/pair?ignored=yes")!,
      allowInsecureRemoteHTTP: true,
      transportPolicy: policy)
    XCTAssertEqual(endpoint.baseURL.absoluteString, "http://mini.example.com:3773/")
    XCTAssertFalse(
      policy.permitsInsecureRemoteHTTP(URL(string: "http://mini.example.com:4888/")!))
    XCTAssertFalse(
      policy.permitsInsecureRemoteHTTP(URL(string: "http://child.mini.example.com:3773/")!))
  }

  func testRemoteHTTPApprovalWithoutAnATSExceptionIsIgnored() {
    let policy = Self.transportPolicy(
      origins: ["http://mini.example.com:3773/"], exceptionDomains: [:])

    XCTAssertFalse(
      policy.permitsInsecureRemoteHTTP(URL(string: "http://mini.example.com:3773/")!))
  }

  func testBroadATSSubdomainExceptionCannotApproveRemoteHTTP() {
    let policy = Self.transportPolicy(
      origins: ["http://mini.example.com:3773/"],
      exceptionDomains: [
        "mini.example.com": [
          "NSExceptionAllowsInsecureHTTPLoads": true,
          "NSIncludesSubdomains": true,
        ]
      ])

    XCTAssertFalse(
      policy.permitsInsecureRemoteHTTP(URL(string: "http://mini.example.com:3773/")!))
  }

  func testLoopbackHTTPNeedsNoRemoteException() throws {
    let policy = T3TransportPolicy(infoDictionary: [:])

    XCTAssertNoThrow(
      try T3Endpoint(
        URL(string: "http://127.0.0.1:3773/")!, transportPolicy: policy))
    XCTAssertNoThrow(
      try T3Endpoint(URL(string: "http://[::1]:3773/")!, transportPolicy: policy))
    XCTAssertFalse(
      policy.requiresHTTPSMigration(URL(string: "http://localhost:3773/")!))
  }

  func testSavedUnapprovedRemoteHTTPRequiresHTTPSMigration() {
    let policy = T3TransportPolicy(infoDictionary: [:])

    XCTAssertTrue(
      policy.requiresHTTPSMigration(URL(string: "http://mini.example.com:3773/")!))
    XCTAssertFalse(
      policy.requiresHTTPSMigration(URL(string: "https://mini.example.com:3773/")!))
  }

  func testPairingFormClearsTheSubmittedLinkOnlyAfterSuccess() throws {
    var form = T3PairingFormState()
    form.pairingLink = "http://mini.example.com/pair#token=one-time-secret"
    form.allowInsecureHTTP = true

    let submission = try XCTUnwrap(form.begin())

    XCTAssertTrue(form.isPairing)
    XCTAssertEqual(form.pairingLink, submission.pairingLink)
    XCTAssertEqual(form.finish(submission, result: .success), .succeeded)
    XCTAssertFalse(form.isPairing)
    XCTAssertEqual(form.pairingLink, "")
    XCTAssertFalse(form.allowInsecureHTTP)
    XCTAssertEqual(form.statusMessage, "Added T3 Code machine.")
  }

  func testPairingFormSuccessKeepsAReplacementLinkTypedWhilePairing() throws {
    var form = T3PairingFormState()
    form.pairingLink = "https://first.example.com/pair#token=first"
    let submission = try XCTUnwrap(form.begin())
    form.pairingLink = "https://second.example.com/pair#token=second"

    XCTAssertEqual(form.finish(submission, result: .success), .succeeded)
    XCTAssertEqual(form.pairingLink, "https://second.example.com/pair#token=second")
  }

  func testPairingFormPreservesFailedPlainHTTPLinkAndFocusesIt() throws {
    var form = T3PairingFormState()
    form.pairingLink = "http://mini.example.com/pair#token=one-time-secret"
    form.allowInsecureHTTP = true
    let submission = try XCTUnwrap(form.begin())

    XCTAssertEqual(
      form.finish(submission, result: .failure("T3 Code returned HTTP 503.")), .failed)
    XCTAssertFalse(form.isPairing)
    XCTAssertEqual(form.pairingLink, submission.pairingLink)
    XCTAssertTrue(form.allowInsecureHTTP)
    XCTAssertEqual(form.focusedField, .pairingLink)
    XCTAssertEqual(form.statusMessage, "T3 Code returned HTTP 503.")
  }

  func testPairingFormFailureDoesNotFocusAReplacementLinkTypedWhilePairing() throws {
    var form = T3PairingFormState()
    form.pairingLink = "https://first.example.com/pair#token=first"
    let submission = try XCTUnwrap(form.begin())
    form.pairingLink = "  https://second.example.com/pair#token=second  "

    XCTAssertEqual(form.finish(submission, result: .failure("Try again.")), .failed)
    XCTAssertEqual(form.pairingLink, "  https://second.example.com/pair#token=second  ")
    XCTAssertNil(form.focusedField)
    XCTAssertEqual(form.statusMessage, "Try again.")
  }

  func testPairingFormIgnoresAStaleCompletion() throws {
    var form = T3PairingFormState()
    form.pairingLink = "https://first.example.com/pair#token=first"
    let first = try XCTUnwrap(form.begin())
    XCTAssertEqual(form.finish(first, result: .failure("Try again.")), .failed)

    form.pairingLink = "https://second.example.com/pair#token=second"
    let second = try XCTUnwrap(form.begin())
    XCTAssertEqual(form.finish(first, result: .success), .ignored)

    XCTAssertTrue(form.isPairing)
    XCTAssertEqual(form.pairingLink, second.pairingLink)
    XCTAssertNil(form.statusMessage)
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
      in: shell, logicalEnvironmentID: "machine", isLocal: true,
      now: Date(timeIntervalSince1970: 1_788_000_000))
    XCTAssertEqual(agents.count, 1)
    XCTAssertEqual(agents[0].providerInstance, "Future Provider")
    XCTAssertEqual(agents[0].model, "future-1")
    XCTAssertEqual(agents[0].phase, .needsInput)
    XCTAssertEqual(agents[0].planStep, "Wire the API")
    XCTAssertTrue(agents[0].isLocal)
    XCTAssertEqual(agents[0].workspacePath, "/tmp/islet")
  }

  func testSessionActionsRejectUnsafePathsAndReconnectStaleAgents() {
    XCTAssertNil(T3SessionActionPolicy.safeWorkspacePath("relative/private"))
    XCTAssertNil(T3SessionActionPolicy.safeWorkspacePath(" /Users/test/private"))
    XCTAssertNil(T3SessionActionPolicy.safeWorkspacePath("/Users/test/private\nnext"))
    XCTAssertEqual(
      T3SessionActionPolicy.safeWorkspacePath("/Users/test/Project Name"),
      "/Users/test/Project Name")

    let agent = Self.agent(
      id: "approval", phase: .needsApproval,
      updatedAt: Date(timeIntervalSince1970: 1_788_000_000))
    let stale = T3EnvironmentSnapshot(
      id: "remote|machine", logicalEnvironmentID: "machine", source: .manual,
      label: "Office Mac", baseURL: "https://office.example", platform: nil,
      serverVersion: nil, state: .reconnecting("No route"), agents: [agent], isStale: true)

    XCTAssertEqual(
      T3CodeActivity.sessionAvailability(for: agent, in: [stale]),
      .reconnect(reason: "Office Mac is reconnecting. Reconnect to refresh it."))
  }

  func testAgentAttentionOrderCoversEveryPhase() {
    let now = Date(timeIntervalSince1970: 1_788_000_000)
    let agents = [
      Self.agent(id: "finished", phase: .finished, updatedAt: now),
      Self.agent(id: "monitoring", phase: .monitoring, updatedAt: now),
      Self.agent(id: "working", phase: .working, updatedAt: now),
      Self.agent(id: "failed", phase: .failed, updatedAt: now),
      Self.agent(id: "approval", phase: .needsApproval, updatedAt: now),
      Self.agent(id: "input", phase: .needsInput, updatedAt: now),
    ]

    XCTAssertEqual(
      T3AgentSnapshot.sortedForAttention(agents).map(\.phase),
      [.needsInput, .needsApproval, .failed, .working, .monitoring, .finished])
  }

  func testAgentAttentionOrderUsesRecencyWithinEachPhase() {
    let now = Date(timeIntervalSince1970: 1_788_000_000)
    let agents = [
      Self.agent(id: "older", phase: .monitoring, updatedAt: now.addingTimeInterval(-20)),
      Self.agent(id: "newer", phase: .monitoring, updatedAt: now.addingTimeInterval(-5)),
      Self.agent(id: "failed", phase: .failed, updatedAt: now.addingTimeInterval(-30)),
    ]

    XCTAssertEqual(
      T3AgentSnapshot.sortedForAttention(agents).map(\.id),
      ["machine:failed", "machine:newer", "machine:older"])
  }

  func testExpandedRowsKeepEveryMachineAlongsideGloballyOrderedAgents() {
    let now = Date(timeIntervalSince1970: 1_788_000_000)
    let remoteURL = "https://office.example"
    let snapshots = [
      T3EnvironmentSnapshot(
        id: "machine", logicalEnvironmentID: "machine", source: .local,
        label: "This Mac", baseURL: "http://127.0.0.1",
        platform: nil, serverVersion: nil, state: .connected,
        agents: [
          Self.agent(id: "working", phase: .working, updatedAt: now),
          Self.agent(id: "failed", phase: .failed, updatedAt: now.addingTimeInterval(-10)),
        ]),
      T3EnvironmentSnapshot(
        id: T3CodeActivity.remoteSnapshotID(environmentID: "office", baseURL: remoteURL),
        logicalEnvironmentID: "office", source: .manual,
        label: "Office Mac", baseURL: remoteURL,
        platform: nil, serverVersion: nil, state: .offline("No route"), agents: []),
    ]
    let rows = T3CodeActivity.expandedRows(
      snapshots: snapshots,
      profiles: [T3EnvironmentProfile(id: "office", label: "Office Mac", baseURL: remoteURL)])

    let agentRows = rows.compactMap { row -> (T3AgentPhase, String)? in
      guard case .agent(let agent, let environmentLabel) = row else { return nil }
      return (agent.phase, environmentLabel)
    }
    XCTAssertEqual(agentRows.map(\.0), [.failed, .working])
    XCTAssertEqual(agentRows.map(\.1), ["This Mac", "This Mac"])
    let environments = rows.compactMap { row -> T3EnvironmentSnapshot? in
      guard case .environment(let environment) = row else { return nil }
      return environment
    }
    XCTAssertEqual(environments.map(\.label), ["This Mac", "Office Mac"])
    XCTAssertEqual(environments.map(\.state), [.connected, .offline("No route")])
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
      in: shell, logicalEnvironmentID: "machine",
      now: Date(timeIntervalSince1970: 1_788_000_000))

    XCTAssertEqual(agents.first?.project, "First")
  }

  func testLocalDiscoveryRequiresASuccessfulT3Descriptor() {
    let descriptor = Data(
      #"{"environmentId":"machine","label":"This Mac","platform":null,"serverVersion":"1"}"#
        .utf8)
    XCTAssertTrue(T3LocalDiscovery.acceptsDiscoveryResponse(data: descriptor, statusCode: 200))
    XCTAssertFalse(T3LocalDiscovery.acceptsDiscoveryResponse(data: descriptor, statusCode: 404))
    XCTAssertFalse(
      T3LocalDiscovery.acceptsDiscoveryResponse(
        data: Data(#"{"error":"not found"}"#.utf8), statusCode: 200))
  }

  func testRuntimePortRejectsMalformedAndOutOfRangeValues() {
    let valid = T3LocalDiscovery.runtime(
      from: Data(#"{"origin":"http://127.0.0.1:4773","pid":123,"port":4773}"#.utf8))
    XCTAssertEqual(valid?.endpoint.baseURL.absoluteString, "http://127.0.0.1:4773/")
    XCTAssertEqual(valid?.processID, 123)
    XCTAssertNil(
      T3LocalDiscovery.runtime(
        from: Data(#"{"origin":"http://127.0.0.1:3773","pid":123,"port":-1}"#.utf8)))
    XCTAssertNil(
      T3LocalDiscovery.runtime(
        from: Data(#"{"origin":"http://127.0.0.1:3773","pid":123,"port":0}"#.utf8)))
    XCTAssertNil(
      T3LocalDiscovery.runtime(
        from: Data(#"{"origin":"http://127.0.0.1:65536","pid":123,"port":65536}"#.utf8)))
    XCTAssertNil(
      T3LocalDiscovery.runtime(
        from: Data(#"{"origin":"http://127.0.0.1:3773","pid":123,"port":"3773"}"#.utf8)))
    XCTAssertNil(
      T3LocalDiscovery.runtime(
        from: Data(#"{"origin":"http://127.0.0.1:4888","pid":123,"port":3773}"#.utf8)))
    XCTAssertNil(
      T3LocalDiscovery.runtime(
        from: Data(#"{"origin":"http://example.com:3773","pid":123,"port":3773}"#.utf8)))
  }

  func testStandardHomebrewT3ServeProcessShapeIsAccepted() {
    XCTAssertTrue(
      T3LocalDiscovery.acceptsT3CLILaunch(
        executablePath: "/opt/homebrew/Cellar/node/24.6.0/bin/node",
        arguments: [
          "/opt/homebrew/bin/node",
          "/opt/homebrew/lib/node_modules/t3/dist/bin.mjs",
          "serve",
        ],
        entryPointPath: "/opt/homebrew/lib/node_modules/t3/dist/bin.mjs",
        packageName: "t3",
        declaredBin: "dist/bin.mjs"))
    XCTAssertFalse(
      T3LocalDiscovery.acceptsT3CLILaunch(
        executablePath: "/opt/homebrew/Cellar/node/24.6.0/bin/node",
        arguments: ["node", "/tmp/t3/dist/bin.mjs", "serve"],
        entryPointPath: "/tmp/t3/dist/bin.mjs",
        packageName: "t3",
        declaredBin: "dist/bin.mjs"))
    XCTAssertFalse(
      T3LocalDiscovery.acceptsT3CLILaunch(
        executablePath: "/opt/homebrew/Cellar/node/24.6.0/bin/node",
        arguments: [
          "/opt/homebrew/bin/node",
          "/tmp/attacker.js",
          "/opt/homebrew/lib/node_modules/t3/dist/bin.mjs",
          "serve",
        ],
        entryPointPath: "/opt/homebrew/lib/node_modules/t3/dist/bin.mjs",
        packageName: "t3",
        declaredBin: "dist/bin.mjs"))
  }

  func testT3ResponseGrowthIsBounded() {
    XCTAssertTrue(
      T3HTTPTransport.acceptsResponseGrowth(
        currentBytes: T3HTTPTransport.maximumResponseBytes - 1, additionalBytes: 1))
    XCTAssertFalse(
      T3HTTPTransport.acceptsResponseGrowth(
        currentBytes: T3HTTPTransport.maximumResponseBytes, additionalBytes: 1))
    XCTAssertFalse(T3HTTPTransport.acceptsResponseGrowth(currentBytes: -1, additionalBytes: 1))
  }

  func testT3RequestHasATotalDeadlineEvenWhileBytesKeepArriving() async throws {
    let session = Self.testSession()
    defer { session.invalidateAndCancel() }
    let endpoint = try T3Endpoint(URL(string: "https://slow.t3-unit.test")!)

    do {
      _ = try await T3Client(endpoint: endpoint, token: nil, session: session)
        .fetchDescriptor(timeoutInterval: 0.15)
      XCTFail("Expected the total request deadline to expire")
    } catch T3ClientError.requestTimedOut {
    } catch {
      XCTFail("Expected requestTimedOut, got \(error)")
    }
  }

  func testT3RequestRejectsOversizedDeclaredResponseBeforeBufferingIt() async throws {
    let session = Self.testSession()
    defer { session.invalidateAndCancel() }
    let endpoint = try T3Endpoint(URL(string: "https://oversized.t3-unit.test")!)

    do {
      _ = try await T3Client(endpoint: endpoint, token: nil, session: session)
        .fetchDescriptor()
      XCTFail("Expected the response size limit to reject the request")
    } catch T3ClientError.responseTooLarge {
    } catch {
      XCTFail("Expected responseTooLarge, got \(error)")
    }
  }

  func testT3ClientRejectsRedirectsBeforeReplayingPairingCredential() async throws {
    let session = Self.testSession()
    defer { session.invalidateAndCancel() }
    let endpoint = try T3Endpoint(URL(string: "https://redirect.t3-unit.test")!)

    do {
      _ = try await T3Client(endpoint: endpoint, token: nil, session: session)
        .exchange(pairingCredential: "one-time-secret")
      XCTFail("Expected the redirect to be rejected")
    } catch T3ClientError.http(307) {
    } catch {
      XCTFail("Expected the original redirect response, got \(error)")
    }
  }

  func testT3RedirectPolicyRejectsCrossOriginAndTransportDowngrade() throws {
    let response = try XCTUnwrap(
      HTTPURLResponse(
        url: URL(string: "https://mini.example.com/oauth/token")!, statusCode: 307,
        httpVersion: "HTTP/1.1", headerFields: nil))
    var crossOrigin = URLRequest(url: URL(string: "https://attacker.example/capture")!)
    crossOrigin.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
    var downgrade = URLRequest(url: URL(string: "http://mini.example.com/capture")!)
    downgrade.setValue("Bearer secret", forHTTPHeaderField: "Authorization")

    XCTAssertNil(T3RedirectPolicy.requestToFollow(crossOrigin, from: response))
    XCTAssertNil(T3RedirectPolicy.requestToFollow(downgrade, from: response))
  }

  func testFutureDatedFailedAgentIsRejected() {
    let now = Date(timeIntervalSince1970: 1_788_000_000)
    let shell = Self.shell(
      updatedAt: now.addingTimeInterval(24 * 60 * 60), sessionStatus: "error",
      turnState: "error")
    XCTAssertTrue(
      T3AgentSnapshot.activeAgents(in: shell, logicalEnvironmentID: "machine", now: now)
        .isEmpty)
  }

  func testFutureDatedFinishedAgentIsRejected() {
    let now = Date(timeIntervalSince1970: 1_788_000_000)
    let shell = Self.shell(
      updatedAt: now.addingTimeInterval(24 * 60 * 60), sessionStatus: "ready",
      turnState: "completed")
    XCTAssertTrue(
      T3AgentSnapshot.activeAgents(in: shell, logicalEnvironmentID: "machine", now: now)
        .isEmpty)
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

  func testUpsertOfUnchangedSnapshotDoesNotChangeCandidateArray() {
    let snapshot = T3EnvironmentSnapshot(
      id: "local|machine", logicalEnvironmentID: "machine", source: .local,
      label: "This Mac", baseURL: "http://127.0.0.1:3773/", platform: "macOS · arm64",
      serverVersion: "1", state: .connected, agents: [])
    let current = [snapshot]
    XCTAssertEqual(T3CodeActivity.upserting(snapshot, into: current), current)
  }

  func testEveryConnectionStateHasAnIconSemanticColourAndAccessibleLabel() {
    let states: [T3ConnectionState] = [
      .connecting,
      .connected,
      .offline("No route"),
      .reconnecting("Trying again"),
      .needsPairing,
      .credentialError("Keychain unavailable"),
    ]
    let expected: [(String, T3ConnectionState.SemanticColor, String)] = [
      ("arrow.triangle.2.circlepath", .neutral, "Connecting"),
      ("checkmark.circle.fill", .positive, "Connected"),
      ("wifi.slash", .negative, "Offline: No route"),
      ("arrow.clockwise.circle.fill", .warning, "Reconnecting: Trying again"),
      ("link.badge.plus", .warning, "Pair again"),
      ("key.slash.fill", .negative, "Credential error: Keychain unavailable"),
    ]

    for (state, expected) in zip(states, expected) {
      XCTAssertEqual(state.icon, expected.0)
      XCTAssertEqual(state.semanticColor, expected.1)
      XCTAssertEqual(state.accessibilityLabel, expected.2)
      XCTAssertFalse(state.label.isEmpty)
    }
  }

  func testConnectionIndicatorUsesDistinctHighContrastTones() {
    XCTAssertEqual(
      T3ConnectionIndicatorView.tone(for: .connecting, increasedContrast: false), .secondary)
    XCTAssertEqual(
      T3ConnectionIndicatorView.tone(
        for: .connecting, increasedContrast: true, colorScheme: .light), .primary)
    XCTAssertEqual(
      T3ConnectionIndicatorView.tone(
        for: .connecting, increasedContrast: true, colorScheme: .dark), .primary)
    XCTAssertEqual(
      T3ConnectionIndicatorView.tone(for: .reconnecting("Retrying"), increasedContrast: false),
      .orange)
    XCTAssertEqual(
      T3ConnectionIndicatorView.tone(for: .reconnecting("Retrying"), increasedContrast: true),
      .yellow)
    XCTAssertEqual(
      T3ConnectionIndicatorView.tone(for: .connected, increasedContrast: true), .green)
    XCTAssertEqual(
      T3ConnectionIndicatorView.tone(for: .offline("No route"), increasedContrast: true), .red)
  }

  func testStaleEnvironmentRetainsTheLastPayloadAndOnlyChangesConnectionIndicator() {
    let agent = T3AgentSnapshot(
      logicalEnvironmentID: "machine", threadID: "thread",
      title: "Build", project: "Islet", providerInstance: "Provider", model: "model",
      branch: "main", phase: .working, planStep: nil, completedPlanSteps: nil,
      totalPlanSteps: nil, updatedAt: Date(timeIntervalSince1970: 1_788_000_000))
    let previous = T3EnvironmentSnapshot(
      id: "remote|machine|https://machine.example/", logicalEnvironmentID: "machine",
      source: .manual, label: "Machine", baseURL: "https://machine.example/",
      platform: "macOS · arm64",
      serverVersion: "1", state: .connected, agents: [agent])
    let candidate = T3EnvironmentSnapshot(
      id: previous.id, logicalEnvironmentID: "machine", source: .manual,
      label: "Fallback", baseURL: previous.baseURL,
      platform: nil, serverVersion: nil, state: .reconnecting("No route"), agents: [])

    let stale = T3CodeActivity.retainingStalePayload(candidate, from: [previous])

    XCTAssertEqual(stale.state, .reconnecting("No route"))
    XCTAssertTrue(stale.isStale)
    XCTAssertEqual(stale.label, previous.label)
    XCTAssertEqual(stale.platform, previous.platform)
    XCTAssertEqual(stale.serverVersion, previous.serverVersion)
    XCTAssertEqual(stale.agents, previous.agents)
    XCTAssertEqual(
      T3ConnectionIndicatorView.accessibilityLabel(for: stale.state, isStale: stale.isStale),
      "Reconnecting: No route, showing the last update")
  }

  func testColdStartFailureDoesNotClaimToRetainAnUpdate() {
    let candidate = T3EnvironmentSnapshot(
      id: "remote|machine|https://machine.example/", logicalEnvironmentID: "machine",
      source: .manual, label: "Machine", baseURL: "https://machine.example/", platform: nil,
      serverVersion: nil, state: .offline("No route"), agents: [])

    let failure = T3CodeActivity.retainingStalePayload(candidate, from: [])

    XCTAssertFalse(failure.isStale)
    XCTAssertEqual(failure.agents, [])
    XCTAssertEqual(
      T3ConnectionIndicatorView.accessibilityLabel(
        for: failure.state, isStale: failure.isStale),
      "Offline: No route")
  }

  func testCompactPresentationSeparatesLiveAndStaleAgents() {
    let live = T3AgentSnapshot(
      logicalEnvironmentID: "live", threadID: "live-thread", title: "Live", project: "Islet",
      providerInstance: "Provider", model: "model", branch: nil, phase: .needsApproval,
      planStep: nil, completedPlanSteps: nil, totalPlanSteps: nil,
      updatedAt: Date(timeIntervalSince1970: 2))
    let stale = T3AgentSnapshot(
      logicalEnvironmentID: "stale", threadID: "stale-thread", title: "Stale", project: "Islet",
      providerInstance: "Provider", model: "model", branch: nil, phase: .working,
      planStep: nil, completedPlanSteps: nil, totalPlanSteps: nil,
      updatedAt: Date(timeIntervalSince1970: 1))
    let environments = [
      T3EnvironmentSnapshot(
        id: "live", logicalEnvironmentID: "live", source: .manual,
        label: "Live", baseURL: "https://live.example",
        platform: nil, serverVersion: nil, state: .connected, agents: [live]),
      T3EnvironmentSnapshot(
        id: "stale", logicalEnvironmentID: "stale", source: .manual,
        label: "Stale", baseURL: "https://stale.example",
        platform: nil, serverVersion: nil, state: .reconnecting("No route"), agents: [stale],
        isStale: true),
    ]

    let mixed = T3CodeActivity.compactPresentation(for: environments)
    XCTAssertEqual(mixed.liveAgentCount, 1)
    XCTAssertEqual(mixed.staleAgentCount, 1)
    XCTAssertEqual(mixed.leadingPhase, .needsApproval)
    XCTAssertEqual(mixed.displayedAgentCount, 1)
    XCTAssertEqual(mixed.accessibilityLabel, "1 active T3 Code agent; 1 stale")

    let entirelyStale = T3CodeActivity.compactPresentation(for: [environments[1]])
    XCTAssertTrue(entirelyStale.isEntirelyStale)
    XCTAssertNil(entirelyStale.leadingPhase)
    XCTAssertEqual(entirelyStale.displayedAgentCount, 1)
    XCTAssertEqual(
      entirelyStale.accessibilityLabel,
      "1 T3 Code agent from the last update; connection stale")
  }

  func testVisibleEnvironmentsIncludeHealthyEmptyAndUnhealthyConfiguredRemotes() {
    let profiles = [
      T3EnvironmentProfile(id: "healthy", label: "Healthy", baseURL: "https://healthy.example"),
      T3EnvironmentProfile(id: "offline", label: "Offline", baseURL: "https://offline.example"),
      T3EnvironmentProfile(
        id: "reconnecting", label: "Reconnecting", baseURL: "https://reconnecting.example"),
      T3EnvironmentProfile(id: "unpaired", label: "Unpaired", baseURL: "https://unpaired.example"),
      T3EnvironmentProfile(
        id: "credentials", label: "Credential", baseURL: "https://credentials.example"),
      T3EnvironmentProfile(id: "pending", label: "Pending", baseURL: "https://pending.example"),
      T3EnvironmentProfile(
        id: "disabled", label: "Disabled", baseURL: "https://disabled.example", enabled: false),
    ]
    let snapshots = [
      T3EnvironmentSnapshot(
        id: T3CodeActivity.remoteSnapshotID(
          environmentID: "healthy", baseURL: "https://healthy.example"),
        logicalEnvironmentID: "healthy", source: .manual,
        label: "Healthy", baseURL: "https://healthy.example",
        platform: nil, serverVersion: nil, state: .connected, agents: []),
      T3EnvironmentSnapshot(
        id: T3CodeActivity.remoteSnapshotID(
          environmentID: "offline", baseURL: "https://offline.example"),
        logicalEnvironmentID: "offline", source: .manual,
        label: "Offline", baseURL: "https://offline.example",
        platform: nil, serverVersion: nil, state: .offline("No route"), agents: []),
      T3EnvironmentSnapshot(
        id: T3CodeActivity.remoteSnapshotID(
          environmentID: "reconnecting", baseURL: "https://reconnecting.example"),
        logicalEnvironmentID: "reconnecting", source: .manual,
        label: "Reconnecting", baseURL: "https://reconnecting.example",
        platform: nil, serverVersion: nil, state: .reconnecting("No route"), agents: []),
      T3EnvironmentSnapshot(
        id: T3CodeActivity.remoteSnapshotID(
          environmentID: "unpaired", baseURL: "https://unpaired.example"),
        logicalEnvironmentID: "unpaired", source: .manual,
        label: "Unpaired", baseURL: "https://unpaired.example",
        platform: nil, serverVersion: nil, state: .needsPairing, agents: []),
      T3EnvironmentSnapshot(
        id: T3CodeActivity.remoteSnapshotID(
          environmentID: "credentials", baseURL: "https://credentials.example"),
        logicalEnvironmentID: "credentials", source: .manual,
        label: "Credential", baseURL: "https://credentials.example",
        platform: nil, serverVersion: nil,
        state: .credentialError("Keychain unavailable"), agents: []),
    ]

    let visible = T3CodeActivity.visibleEnvironments(snapshots: snapshots, profiles: profiles)

    XCTAssertEqual(
      visible.map(\.label),
      ["Credential", "Healthy", "Offline", "Pending", "Reconnecting", "Unpaired"])
    let states = Dictionary(uniqueKeysWithValues: visible.map { ($0.label, $0.state) })
    XCTAssertEqual(states["Healthy"], .connected)
    XCTAssertTrue(visible.first(where: { $0.label == "Healthy" })?.agents.isEmpty == true)
    XCTAssertEqual(states["Offline"], .offline("No route"))
    XCTAssertEqual(states["Pending"], .connecting)
    XCTAssertEqual(states["Reconnecting"], .reconnecting("No route"))
    XCTAssertEqual(states["Unpaired"], .needsPairing)
    XCTAssertEqual(states["Credential"], .credentialError("Keychain unavailable"))
  }

  func testPausedRemotePollingExcludesRetainedRemoteActivityFromLiveCounts() {
    let localAgent = Self.agentSnapshot(environmentID: "local", threadID: "local-thread")
    let connectAgent = Self.agentSnapshot(environmentID: "connect", threadID: "connect-thread")
    let snapshots = [
      T3EnvironmentSnapshot(
        id: "local|local", logicalEnvironmentID: "local", source: .local,
        label: "This Mac", baseURL: "http://127.0.0.1:3773/", platform: nil,
        serverVersion: "1", state: .connected, agents: [localAgent]),
      T3EnvironmentSnapshot(
        id: "connect|connect", logicalEnvironmentID: "connect", source: .connect,
        label: "Cloud", baseURL: "https://cloud.example/", platform: nil,
        serverVersion: "1", state: .connected, agents: [connectAgent]),
    ]

    XCTAssertEqual(
      T3CodeActivity.currentAgents(in: snapshots, remotePollingActive: false), [localAgent])
    XCTAssertEqual(
      T3CodeActivity.connectedEnvironmentCount(in: snapshots, remotePollingActive: false), 1)
    XCTAssertEqual(
      T3CodeActivity.currentAgents(in: snapshots, remotePollingActive: true).map(\.id).sorted(),
      [localAgent.id, connectAgent.id].sorted())
    XCTAssertEqual(
      T3CodeActivity.connectedEnvironmentCount(in: snapshots, remotePollingActive: true), 2)
  }

  func testPausedRemoteCandidateCannotHideADegradedLocalOrReenterLiveCountsOnResume() {
    let connectAgent = Self.agentSnapshot(environmentID: "shared", threadID: "connect-thread")
    let local = Self.environmentSnapshot(
      id: "local|shared", logicalEnvironmentID: "shared", source: .local,
      state: .offline("Local unavailable"))
    let connect = T3EnvironmentSnapshot(
      id: "connect|shared", logicalEnvironmentID: "shared", source: .connect,
      label: "Cloud", baseURL: "https://cloud.example/", platform: nil,
      serverVersion: "1", state: .connected, agents: [connectAgent])

    let awaitingRefresh = T3CodeActivity.markingRemoteCandidatesAwaitingRefresh([local, connect])

    XCTAssertEqual(T3EnvironmentResolver.resolve(awaitingRefresh), [local])
    let retainedConnect = awaitingRefresh.first { $0.source == .connect }
    XCTAssertEqual(retainedConnect?.state, .connecting)
    XCTAssertTrue(retainedConnect?.agents.isEmpty == true)
    XCTAssertTrue(
      T3CodeActivity.currentAgents(in: awaitingRefresh, remotePollingActive: true).isEmpty)
    XCTAssertEqual(
      T3CodeActivity.connectedEnvironmentCount(
        in: awaitingRefresh, remotePollingActive: true),
      0)
  }

  func testVisibleEnvironmentsIncludesConnectSourcesWithoutDuplicatingManualFailover() {
    let connect = Self.environmentSnapshot(
      id: "connect|shared", logicalEnvironmentID: "shared", source: .connect)
    let connectOnly = Self.environmentSnapshot(
      id: "connect|cloud-only", logicalEnvironmentID: "cloud-only", source: .connect)
    let profiles = [
      T3EnvironmentProfile(
        id: "shared", label: "Manual fallback", baseURL: "https://manual.example")
    ]

    let visible = T3CodeActivity.visibleEnvironments(
      snapshots: [connect, connectOnly], profiles: profiles)

    XCTAssertEqual(Set(visible.map(\.id)), [connect.id, connectOnly.id])
    XCTAssertEqual(visible.count, 2)
  }

  func testVisibleEnvironmentsKeepsManualLocalIDBesideProvisionalLocalDiscovery() {
    let provisionalLocal = Self.environmentSnapshot(
      id: "local", logicalEnvironmentID: "local", source: .local,
      state: .offline("Not discovered"))
    let profile = T3EnvironmentProfile(
      id: "local", label: "Remote named local", baseURL: "https://manual.example")

    let visible = T3CodeActivity.visibleEnvironments(
      snapshots: [provisionalLocal], profiles: [profile])

    XCTAssertEqual(
      Set(visible.map(\.id)),
      [
        provisionalLocal.id,
        T3CodeActivity.remoteSnapshotID(
          environmentID: profile.id, baseURL: profile.baseURL),
      ])
  }

  func testEnvironmentActionsMatchConnectionStateAndMachineType() {
    XCTAssertEqual(
      T3CodeActivity.environmentActions(for: .needsPairing, isLocal: true), [.pair])
    XCTAssertEqual(
      T3CodeActivity.environmentActions(for: .needsPairing, isLocal: false), [.pair, .disable])
    XCTAssertEqual(
      T3CodeActivity.environmentActions(for: .offline("No route"), isLocal: false),
      [.retry, .disable])
    XCTAssertEqual(
      T3CodeActivity.environmentActions(for: .reconnecting("No route"), isLocal: true),
      [.retry])
    XCTAssertEqual(
      T3CodeActivity.environmentActions(
        for: .credentialError("Keychain unavailable"), isLocal: false),
      [.openSettings, .disable])
    XCTAssertEqual(
      T3CodeActivity.environmentActions(for: .connected, isLocal: true), [])
    XCTAssertEqual(
      T3CodeActivity.environmentActions(for: .connected, isLocal: false), [.disable])
    XCTAssertEqual(
      T3CodeActivity.environmentActions(for: .connecting, isLocal: false), [.disable])
  }

  func testUpsertingDifferentSourcesRetainsEveryFailoverCandidate() {
    let local = Self.environmentSnapshot(
      id: "local|same", logicalEnvironmentID: "same", source: .local)
    let connect = Self.environmentSnapshot(
      id: "connect|same", logicalEnvironmentID: "same", source: .connect)
    let manual = Self.environmentSnapshot(
      id: "remote|same|https://mini.example.com/", logicalEnvironmentID: "same",
      source: .manual)

    let withLocal = T3CodeActivity.upserting(local, into: [])
    let withConnect = T3CodeActivity.upserting(connect, into: withLocal)
    let candidates = T3CodeActivity.upserting(manual, into: withConnect)

    XCTAssertEqual(Set(candidates.map(\.id)), [local.id, connect.id, manual.id])
    XCTAssertEqual(T3EnvironmentResolver.resolve(candidates).map(\.id), [local.id])
  }

  func testIdentifiedLocalObservationRemovesProvisionalLocalCandidate() {
    let provisional = Self.environmentSnapshot(
      id: "local", logicalEnvironmentID: "local", source: .local,
      state: .offline("Not discovered"))
    let identified = Self.environmentSnapshot(
      id: "local|machine", logicalEnvironmentID: "machine", source: .local)
    let manualNamedLocal = Self.environmentSnapshot(
      id: "remote|local|https://mini.example.com/", logicalEnvironmentID: "local",
      source: .manual)

    let candidates = T3CodeActivity.upserting(
      identified, into: [provisional, manualNamedLocal])

    XCTAssertEqual(candidates.filter(\.isLocal).map(\.id), ["local|machine"])
    XCTAssertTrue(candidates.contains(manualNamedLocal))
  }

  func testProvisionalLocalObservationReplacesDisappearedIdentifiedLocalCandidate() {
    let identified = Self.environmentSnapshot(
      id: "local|machine", logicalEnvironmentID: "machine", source: .local)
    let provisional = Self.environmentSnapshot(
      id: "local", logicalEnvironmentID: "local", source: .local,
      state: .offline("Not discovered"))

    let candidates = T3CodeActivity.upserting(provisional, into: [identified])

    XCTAssertEqual(candidates.filter(\.isLocal).map(\.id), ["local"])
  }

  func testStopDropsLocalDiscoveryThatCompletesAfterCancellation() async {
    let previousDisabledActivities = Defaults[.disabledActivities]
    let previousProfiles = Defaults[.t3RemoteEnvironments]
    Defaults[.disabledActivities] = previousDisabledActivities.filter { $0 != "t3Code" }
    Defaults[.t3RemoteEnvironments] = []
    defer {
      Defaults[.disabledActivities] = previousDisabledActivities
      Defaults[.t3RemoteEnvironments] = previousProfiles
    }
    let discovery = T3LocalDiscoveryGate()
    let completed = T3LocalDiscoverySignal()
    let activity = T3CodeActivity(
      localEndpointProvider: { await discovery.endpoint() },
      onLocalDiscoveryCompleted: { completed.signal() })
    activity.start()
    await discovery.waitUntilRequested()

    activity.stop()
    await discovery.resume(returning: nil)
    await completed.wait(for: 1)

    XCTAssertTrue(activity.environments.isEmpty)
  }

  func testPreservedRestartDropsOlderSuspendedLocalDiscoveryResult() async {
    let previousDisabledActivities = Defaults[.disabledActivities]
    let previousProfiles = Defaults[.t3RemoteEnvironments]
    Defaults[.disabledActivities] = previousDisabledActivities.filter { $0 != "t3Code" }
    Defaults[.t3RemoteEnvironments] = []
    defer {
      Defaults[.disabledActivities] = previousDisabledActivities
      Defaults[.t3RemoteEnvironments] = previousProfiles
    }
    let staleDiscovery = T3LocalDiscoveryGate()
    let currentDiscovery = T3LocalDiscoveryGate()
    let discoveries = T3LocalDiscoverySequence([staleDiscovery, currentDiscovery])
    let completed = T3LocalDiscoverySignal()
    let activity = T3CodeActivity(
      localEndpointProvider: { await discoveries.endpoint() },
      onLocalDiscoveryCompleted: { completed.signal() })
    activity.start()
    await staleDiscovery.waitUntilRequested()
    let identified = Self.environmentSnapshot(
      id: "local|machine", logicalEnvironmentID: "machine", source: .local)
    activity.upsert(identified)

    activity.restartMonitors(clearSnapshots: false)
    await currentDiscovery.waitUntilRequested()
    await staleDiscovery.resume(returning: nil)
    await completed.wait(for: 1)

    XCTAssertEqual(activity.environments, [identified])

    activity.stop()
    await currentDiscovery.resume(returning: nil)
    await completed.wait(for: 2)
  }

  func testRemovingConnectCandidatesPreservesLocalAndManualCandidates() {
    let local = Self.environmentSnapshot(
      id: "local|same", logicalEnvironmentID: "same", source: .local)
    let connect = Self.environmentSnapshot(
      id: "connect|same", logicalEnvironmentID: "same", source: .connect)
    let manual = Self.environmentSnapshot(
      id: "remote|same|https://mini.example.com/", logicalEnvironmentID: "same",
      source: .manual)

    let remaining = T3CodeActivity.removingCandidates(
      from: [local, connect, manual], source: .connect)

    XCTAssertEqual(remaining, [local, manual])
  }

  func testReplacingConnectCandidatesIsAtomicAndPreservesLocalAndManualCandidates() {
    let local = Self.environmentSnapshot(
      id: "local|local", logicalEnvironmentID: "local", source: .local)
    let oldConnect = Self.environmentSnapshot(
      id: "connect|old", logicalEnvironmentID: "old", source: .connect)
    let manual = Self.environmentSnapshot(
      id: "remote|manual|https://mini.example.com/", logicalEnvironmentID: "manual",
      source: .manual)
    let replacement = Self.environmentSnapshot(
      id: "connect|new", logicalEnvironmentID: "new", source: .connect)

    let updated = T3CodeActivity.replacingCandidates(
      from: [local, oldConnect, manual], source: .connect, with: [replacement])

    XCTAssertEqual(updated, [local, manual, replacement])
  }

  func testHiddenManualCandidateSnapshotRemainsAvailableToSettings() throws {
    let activity = T3CodeActivity()
    let local = Self.environmentSnapshot(
      id: "local|same", logicalEnvironmentID: "same", source: .local)
    let retainedAgent = Self.agentSnapshot(environmentID: "same", threadID: "retained")
    let manual = Self.environmentSnapshot(
      id: "remote|same|https://mini.example.com/", logicalEnvironmentID: "same",
      source: .manual, state: .offline("Timed out"), agents: [retainedAgent], isStale: true)

    activity.upsert(local)
    activity.upsert(manual)

    XCTAssertEqual(activity.environments, [local])
    let hidden = try XCTUnwrap(
      activity.manualConnectionSnapshot(
        environmentID: "same", baseURL: "https://mini.example.com/"))
    XCTAssertEqual(hidden, manual)
    XCTAssertTrue(hidden.isStale)
    XCTAssertEqual(hidden.agents, [retainedAgent])
  }

  func testHiddenManualCandidateStateChangePublishesForSettings() {
    let activity = T3CodeActivity()
    let local = Self.environmentSnapshot(
      id: "local|same", logicalEnvironmentID: "same", source: .local)
    let connecting = Self.environmentSnapshot(
      id: "remote|same|https://mini.example.com/", logicalEnvironmentID: "same",
      source: .manual, state: .connecting)
    let offline = Self.environmentSnapshot(
      id: connecting.id, logicalEnvironmentID: "same", source: .manual,
      state: .offline("Timed out"))
    activity.upsert(local)
    activity.upsert(connecting)
    XCTAssertEqual(activity.environments, [local])

    let changed = expectation(description: "activity published hidden manual state")
    let cancellable = activity.objectWillChange.sink { changed.fulfill() }
    activity.upsert(offline)

    wait(for: [changed], timeout: 1)
    XCTAssertEqual(activity.environments, [local])
    XCTAssertEqual(
      activity.manualConnectionState(
        environmentID: "same", baseURL: "https://mini.example.com/"),
      .offline("Timed out"))
    withExtendedLifetime(cancellable) {}
  }

  func testConnectedSnapshotDerivesAgentIDsFromLogicalEnvironmentID() throws {
    let now = Date(timeIntervalSince1970: 1_788_000_000)
    let descriptor = T3EnvironmentDescriptor(
      environmentId: "studio", label: "Studio",
      platform: T3EnvironmentDescriptor.Platform(os: "macOS", arch: "arm64"),
      serverVersion: "1")
    let endpoint = try T3Endpoint(URL(string: "https://mini.example.com")!)
    let shell = Self.shell(updatedAt: now, sessionStatus: "running", turnState: "running")

    let snapshot = T3CodeActivity.connectedSnapshot(
      descriptor: descriptor, endpoint: endpoint, source: .manual, shell: shell, now: now)

    XCTAssertEqual(snapshot.id, "remote|studio|https://mini.example.com/")
    XCTAssertEqual(snapshot.logicalEnvironmentID, "studio")
    XCTAssertEqual(snapshot.agents.map(\.id), ["studio:thread"])
  }

  func testIdentifiedLocalFailureFallsBackToConnectWithoutCreatingASecondRow() throws {
    let descriptor = T3EnvironmentDescriptor(
      environmentId: "shared", label: "Studio",
      platform: T3EnvironmentDescriptor.Platform(os: "macOS", arch: "arm64"),
      serverVersion: "1")
    let endpoint = try T3Endpoint(URL(string: "http://127.0.0.1:3773")!)
    let local = T3CodeActivity.localFailureSnapshot(
      descriptor: descriptor, endpoint: endpoint, state: .offline("Timed out"))
    let connect = Self.environmentSnapshot(
      id: "connect|shared", logicalEnvironmentID: "shared", source: .connect)

    let candidates = T3CodeActivity.upserting(
      connect, into: T3CodeActivity.upserting(local, into: []))
    let visible = T3EnvironmentResolver.resolve(candidates)
    let activity = T3CodeActivity()
    activity.upsert(local)
    activity.replaceCandidates(from: .connect, with: [connect])

    XCTAssertEqual(local.id, "local|shared")
    XCTAssertEqual(local.logicalEnvironmentID, "shared")
    XCTAssertEqual(visible, [connect])
    XCTAssertEqual(activity.environments, [connect])
    XCTAssertTrue(activity.hasLocalObservation)
  }

  func testLocalAndRemoteEnvironmentIdentityCannotCollide() {
    XCTAssertEqual(T3CodeActivity.localSnapshotID("same"), "local|same")
    XCTAssertEqual(T3CodeActivity.connectSnapshotID("same"), "connect|same")
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

  func testPairingTargetsIdentifyLoopbackWithoutTrustingArbitraryHosts() throws {
    XCTAssertTrue(
      try T3PairingTarget.parse("http://127.0.0.1:3773/pair#token=once")
        .endpoint.isLoopback)
    XCTAssertFalse(
      try T3PairingTarget.parse("https://mini.example.com/pair#token=once")
        .endpoint.isLoopback)
  }

  private static func testSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [T3TestURLProtocol.self]
    return URLSession(configuration: configuration)
  }

  private static func transportPolicy(
    origins: [String],
    exceptionDomains: [String: [String: Any]]
  ) -> T3TransportPolicy {
    T3TransportPolicy(infoDictionary: [
      T3TransportPolicy.approvedOriginsInfoKey: origins,
      "NSAppTransportSecurity": ["NSExceptionDomains": exceptionDomains],
    ])
  }

  private static func shell(
    updatedAt: Date, sessionStatus: String, turnState: String
  ) -> T3ShellSnapshot {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let timestamp = formatter.string(from: updatedAt)
    return T3ShellSnapshot(
      snapshotSequence: 1,
      projects: [T3ProjectShell(id: "project", title: "Project", workspaceRoot: nil)],
      threads: [
        T3ThreadShell(
          id: "thread", projectId: "project", title: "Thread",
          modelSelection: T3ModelSelection(instanceId: "provider", model: "model"),
          runtimeMode: nil, interactionMode: nil, branch: nil, worktreePath: nil,
          latestTurn: T3LatestTurn(
            turnId: "turn", state: turnState, requestedAt: nil, startedAt: nil,
            completedAt: turnState == "completed" ? timestamp : nil),
          createdAt: nil, updatedAt: timestamp, archivedAt: nil, settledAt: nil,
          session: T3Session(
            status: sessionStatus, providerName: nil, providerInstanceId: "provider",
            lastError: nil),
          latestUserMessageAt: nil, hasPendingApprovals: false, hasPendingUserInput: false,
          hasActionableProposedPlan: false, backgroundLiveness: nil, planProgress: nil)
      ],
      updatedAt: timestamp)
  }

  private static func agent(
    id: String, phase: T3AgentPhase, updatedAt: Date
  ) -> T3AgentSnapshot {
    T3AgentSnapshot(
      logicalEnvironmentID: "machine", threadID: id, title: id, project: "Project",
      providerInstance: "provider", model: "model", branch: nil, phase: phase,
      planStep: nil, completedPlanSteps: nil, totalPlanSteps: nil, updatedAt: updatedAt)
  }

  private static func environmentSnapshot(
    id: String,
    logicalEnvironmentID: String,
    source: T3EnvironmentSource,
    state: T3ConnectionState = .connected,
    agents: [T3AgentSnapshot] = [],
    isStale: Bool = false
  ) -> T3EnvironmentSnapshot {
    T3EnvironmentSnapshot(
      id: id, logicalEnvironmentID: logicalEnvironmentID, source: source, label: id,
      baseURL: "https://mini.example.com/", platform: nil, serverVersion: "1", state: state,
      agents: agents, isStale: isStale)
  }

  private static func agentSnapshot(
    environmentID: String,
    threadID: String
  ) -> T3AgentSnapshot {
    T3AgentSnapshot(
      logicalEnvironmentID: environmentID, threadID: threadID, title: threadID,
      project: "Project", providerInstance: "provider", model: "model", branch: nil,
      phase: .working, planStep: nil, completedPlanSteps: nil, totalPlanSteps: nil,
      updatedAt: Date(timeIntervalSince1970: 1_788_000_000))
  }
}

private actor T3LocalDiscoveryGate {
  private var requested = false
  private var requestWaiter: CheckedContinuation<Void, Never>?
  private var resultContinuation: CheckedContinuation<T3Endpoint?, Never>?

  func endpoint() async -> T3Endpoint? {
    requested = true
    requestWaiter?.resume()
    requestWaiter = nil
    return await withCheckedContinuation { continuation in
      resultContinuation = continuation
    }
  }

  func waitUntilRequested() async {
    if requested { return }
    await withCheckedContinuation { continuation in
      requestWaiter = continuation
    }
  }

  func resume(returning endpoint: T3Endpoint?) {
    resultContinuation?.resume(returning: endpoint)
    resultContinuation = nil
  }
}

private actor T3LocalDiscoverySequence {
  private var discoveries: [T3LocalDiscoveryGate]

  init(_ discoveries: [T3LocalDiscoveryGate]) {
    self.discoveries = discoveries
  }

  func endpoint() async -> T3Endpoint? {
    guard !discoveries.isEmpty else { return nil }
    let discovery = discoveries.removeFirst()
    return await discovery.endpoint()
  }
}

private final class T3LocalDiscoverySignal: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

  func signal() {
    lock.lock()
    count += 1
    let ready = waiters.filter { $0.count <= count }
    waiters.removeAll { $0.count <= count }
    lock.unlock()
    for waiter in ready { waiter.continuation.resume() }
  }

  func wait(for targetCount: Int) async {
    await withCheckedContinuation { continuation in
      lock.lock()
      if count >= targetCount {
        lock.unlock()
        continuation.resume()
      } else {
        waiters.append((targetCount, continuation))
        lock.unlock()
      }
    }
  }
}

private final class T3TestURLProtocol: URLProtocol, @unchecked Sendable {
  private let lock = NSLock()
  private var stopped = false
  private let queue = DispatchQueue(label: "T3TestURLProtocol")

  override class func canInit(with request: URLRequest) -> Bool {
    request.url?.host?.hasSuffix("t3-unit.test") == true
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let url = request.url else { return }
    if url.host == "oversized.t3-unit.test" {
      let response = HTTPURLResponse(
        url: url, statusCode: 200, httpVersion: "HTTP/1.1",
        headerFields: ["Content-Length": String(T3HTTPTransport.maximumResponseBytes + 1)])!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocolDidFinishLoading(self)
      return
    }
    if url.host == "redirect.t3-unit.test" {
      let response = HTTPURLResponse(
        url: url, statusCode: 307, httpVersion: "HTTP/1.1",
        headerFields: ["Location": "http://plaintext.t3-unit.test/capture"])!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocolDidFinishLoading(self)
      return
    }
    if url.host == "plaintext.t3-unit.test" {
      let body = Data(
        #"{"access_token":"stolen","token_type":"Bearer","expires_in":3600,"scope":"orchestration:read"}"#
          .utf8)
      let response = HTTPURLResponse(
        url: url, statusCode: 200, httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "application/json"]
      )!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: body)
      client?.urlProtocolDidFinishLoading(self)
      return
    }

    let body = Data(
      #"{"environmentId":"machine","label":"This Mac","platform":null,"serverVersion":"1"}"#
        .utf8)
    let response = HTTPURLResponse(
      url: url, statusCode: 200, httpVersion: "HTTP/1.1",
      headerFields: ["Content-Type": "application/json"])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    let chunks = stride(from: 0, to: body.count, by: 8).map {
      body[$0..<min($0 + 8, body.count)]
    }
    for (index, chunk) in chunks.enumerated() {
      queue.asyncAfter(deadline: .now() + 0.05 * Double(index + 1)) { [weak self] in
        guard let self, !self.isStopped else { return }
        self.client?.urlProtocol(self, didLoad: Data(chunk))
        if index == chunks.count - 1 { self.client?.urlProtocolDidFinishLoading(self) }
      }
    }
  }

  override func stopLoading() {
    lock.lock()
    stopped = true
    lock.unlock()
  }

  private var isStopped: Bool {
    lock.lock()
    defer { lock.unlock() }
    return stopped
  }
}
