import Foundation
import XCTest

@testable import Islet

@MainActor
final class T3RelayClientTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)
  private let grantID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!

  func testInventorySendsExactBearerRequestAndDecodesPinnedWrapper() async throws {
    let recorder = T3RelayHTTPRecorder(responses: [.inventory([Self.environmentJSON()])])
    let signer = T3RelayProofRecorder()
    let client = makeClient(recorder: recorder, signer: signer)

    let environments = try await client.listEnvironments(accountToken: "account-token")

    let environment = try XCTUnwrap(environments.only)
    XCTAssertEqual(environment.environmentID, "env-one")
    XCTAssertEqual(environment.id, "env-one")
    XCTAssertEqual(environment.label, "Studio")
    XCTAssertEqual(
      environment.httpBaseURL.absoluteString, "https://env-one.t3-relay-unit.test/")
    XCTAssertEqual(
      environment.webSocketBaseURL.absoluteString, "wss://env-one.t3-relay-unit.test/ws")
    XCTAssertEqual(environment.providerKind, "t3_relay")
    XCTAssertEqual(environment.linkedAt, Self.date("2026-08-30T00:00:00.000Z"))

    let request = try XCTUnwrap(recorder.requests().only)
    XCTAssertEqual(request.url?.absoluteString, "https://relay.t3-relay-unit.test/v1/environments")
    XCTAssertEqual(request.httpMethod, "GET")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer account-token")
    XCTAssertNil(request.value(forHTTPHeaderField: "DPoP"))
    XCTAssertNil(request.httpBody)
    let proofs = await signer.proofs()
    XCTAssertTrue(proofs.isEmpty)
  }

  func testInventoryAcceptsAtMost256UniqueRows() async throws {
    let rows = (0..<256).map { index in
      Self.environmentJSON(
        environmentID: "env-\(index)", label: "Environment \(index)",
        httpBaseURL: "https://env-\(index).t3-relay-unit.test",
        webSocketBaseURL: "wss://env-\(index).t3-relay-unit.test/ws")
    }
    let acceptedRecorder = T3RelayHTTPRecorder(responses: [.inventory(rows)])
    let accepted = makeClient(recorder: acceptedRecorder, signer: T3RelayProofRecorder())

    let acceptedEnvironments = try await accepted.listEnvironments(accountToken: "account")
    XCTAssertEqual(acceptedEnvironments.count, 256)

    let rejectedRows =
      rows + [
        Self.environmentJSON(
          environmentID: "env-256", label: "Environment 256",
          httpBaseURL: "https://env-256.t3-relay-unit.test",
          webSocketBaseURL: "wss://env-256.t3-relay-unit.test/ws")
      ]
    let rejectedRecorder = T3RelayHTTPRecorder(responses: [.inventory(rejectedRows)])
    let rejected = makeClient(recorder: rejectedRecorder, signer: T3RelayProofRecorder())

    await assertInvalidResponse {
      _ = try await rejected.listEnvironments(accountToken: "account")
    }
  }

  func testInventoryRejectsDuplicateIDsAndUnboundedOrMalformedFields() async throws {
    let oversized = String(repeating: "x", count: 20_000)
    let invalidInventories = [
      [Self.environmentJSON(), Self.environmentJSON(label: "Duplicate")],
      [Self.environmentJSON(environmentID: "   ")],
      [Self.environmentJSON(label: "\n\t")],
      [Self.environmentJSON(label: oversized)],
      [Self.environmentJSON(providerKind: "unknown")],
      [Self.environmentJSON(providerKind: " t3_relay ")],
      [Self.environmentJSON(linkedAt: "not-a-date")],
    ]

    for rows in invalidInventories {
      let recorder = T3RelayHTTPRecorder(responses: [.inventory(rows)])
      let client = makeClient(recorder: recorder, signer: T3RelayProofRecorder())
      await assertInvalidResponse {
        _ = try await client.listEnvironments(accountToken: "account")
      }
    }
  }

  func testWhitespaceAccountTokenAndProofThumbprintAreRejectedBeforeDispatch() async throws {
    let accountRecorder = T3RelayHTTPRecorder(responses: [.inventory([])])
    let accountClient = makeClient(
      recorder: accountRecorder, signer: T3RelayProofRecorder())
    await assertInvalidResponse {
      _ = try await accountClient.listEnvironments(accountToken: " \n\t ")
    }
    XCTAssertTrue(accountRecorder.requests().isEmpty)

    let thumbprintRecorder = T3RelayHTTPRecorder(
      responses: Self.authorizationResponses())
    let thumbprintSigner = T3RelayProofRecorder()
    await thumbprintSigner.setThumbprint(" \n\t ")
    let thumbprintClient = makeClient(
      recorder: thumbprintRecorder, signer: thumbprintSigner)
    await assertInvalidResponse {
      _ = try await thumbprintClient.authorize(
        environment: Self.environment(), accountToken: "account", grantID: self.grantID)
    }
    XCTAssertTrue(thumbprintRecorder.requests().isEmpty)
  }

  func testInventoryRejectsInsecureCredentialedFragmentedAndMalformedManagedURLs() async throws {
    let invalidRows = [
      Self.environmentJSON(httpBaseURL: "http://env-one.t3-relay-unit.test"),
      Self.environmentJSON(webSocketBaseURL: "ws://env-one.t3-relay-unit.test/ws"),
      Self.environmentJSON(httpBaseURL: "https://user:password@env-one.t3-relay-unit.test"),
      Self.environmentJSON(webSocketBaseURL: "wss://user@env-one.t3-relay-unit.test/ws"),
      Self.environmentJSON(httpBaseURL: "https://env-one.t3-relay-unit.test/#fragment"),
      Self.environmentJSON(webSocketBaseURL: "wss://env-one.t3-relay-unit.test/ws?secret=yes"),
      Self.environmentJSON(httpBaseURL: "https://env-one.t3-relay-unit.test/unexpected"),
      Self.environmentJSON(httpBaseURL: "not a URL"),
    ]

    for row in invalidRows {
      let recorder = T3RelayHTTPRecorder(responses: [.inventory([row])])
      let client = makeClient(recorder: recorder, signer: T3RelayProofRecorder())
      await assertInvalidResponse {
        _ = try await client.listEnvironments(accountToken: "account")
      }
    }
  }

  func testAuthorizeMatchesPinnedRelayAndEnvironmentRequests() async throws {
    let recorder = T3RelayHTTPRecorder(
      responses: Self.authorizationResponses(
        accountToken: "account +/?", relayToken: "relay-access",
        bootstrapCredential: "bootstrap +/?", environmentToken: "environment-access"))
    let signer = T3RelayProofRecorder()
    let client = makeClient(recorder: recorder, signer: signer)

    let authorization = try await client.authorize(
      environment: Self.environment(), accountToken: "account +/?", grantID: grantID)

    XCTAssertEqual(authorization.descriptor.environmentId, "env-one")
    XCTAssertEqual(
      authorization.endpoint.baseURL.absoluteString, "https://env-one.t3-relay-unit.test/")
    XCTAssertEqual(authorization.expiresAt, now.addingTimeInterval(3_600))
    switch authorization.authorization {
    case .dpop(let accessToken, _):
      XCTAssertEqual(accessToken, "environment-access")
    default:
      XCTFail("Expected DPoP environment authorization")
    }

    let requests = recorder.requests()
    XCTAssertEqual(requests.count, 5)
    let relayExchange = requests[0]
    XCTAssertEqual(
      relayExchange.url?.absoluteString,
      "https://relay.t3-relay-unit.test/v1/client/dpop-token")
    XCTAssertEqual(relayExchange.httpMethod, "POST")
    XCTAssertEqual(relayExchange.value(forHTTPHeaderField: "Accept"), "application/json")
    XCTAssertEqual(
      relayExchange.value(forHTTPHeaderField: "Content-Type"),
      "application/x-www-form-urlencoded")
    XCTAssertNil(relayExchange.value(forHTTPHeaderField: "Authorization"))
    XCTAssertEqual(relayExchange.value(forHTTPHeaderField: "DPoP"), "proof-1")
    XCTAssertEqual(
      Self.body(relayExchange),
      "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Atoken-exchange"
        + "&subject_token=account%20%2B%2F%3F"
        + "&subject_token_type=urn%3Aietf%3Aparams%3Aoauth%3Atoken-type%3Ajwt"
        + "&requested_token_type=urn%3Aietf%3Aparams%3Aoauth%3Atoken-type%3Aaccess_token"
        + "&resource=https%3A%2F%2Frelay.t3-relay-unit.test"
        + "&scope=environment%3Aconnect&client_id=test-relay-client")

    let connect = requests[1]
    XCTAssertEqual(
      connect.url?.absoluteString,
      "https://relay.t3-relay-unit.test/v1/environments/env-one/connect")
    XCTAssertEqual(connect.httpMethod, "POST")
    XCTAssertEqual(connect.value(forHTTPHeaderField: "Accept"), "application/json")
    XCTAssertEqual(connect.value(forHTTPHeaderField: "Content-Type"), "application/json")
    XCTAssertEqual(connect.value(forHTTPHeaderField: "Authorization"), "DPoP relay-access")
    XCTAssertEqual(connect.value(forHTTPHeaderField: "DPoP"), "proof-2")
    XCTAssertEqual(
      try Self.jsonObject(connect),
      ["clientProofKeyThumbprint": "proof-thumbprint"])
    XCTAssertNil(try Self.jsonObject(connect)["clientKeyThumbprint"])

    let descriptor = requests[2]
    XCTAssertEqual(
      descriptor.url?.absoluteString,
      "https://env-one.t3-relay-unit.test/.well-known/t3/environment")
    XCTAssertEqual(descriptor.httpMethod, "GET")
    XCTAssertEqual(descriptor.value(forHTTPHeaderField: "Accept"), "application/json")
    XCTAssertNil(descriptor.value(forHTTPHeaderField: "Authorization"))
    XCTAssertNil(descriptor.value(forHTTPHeaderField: "DPoP"))
    XCTAssertNil(descriptor.httpBody)

    let authState = requests[3]
    XCTAssertEqual(
      authState.url?.absoluteString,
      "https://env-one.t3-relay-unit.test/api/auth/session")
    XCTAssertEqual(authState.httpMethod, "GET")
    XCTAssertEqual(authState.value(forHTTPHeaderField: "Accept"), "application/json")
    XCTAssertNil(authState.value(forHTTPHeaderField: "Authorization"))
    XCTAssertNil(authState.value(forHTTPHeaderField: "DPoP"))
    XCTAssertNil(authState.httpBody)

    let environmentExchange = requests[4]
    XCTAssertEqual(
      environmentExchange.url?.absoluteString,
      "https://env-one.t3-relay-unit.test/oauth/token")
    XCTAssertEqual(environmentExchange.httpMethod, "POST")
    XCTAssertEqual(environmentExchange.value(forHTTPHeaderField: "Accept"), "application/json")
    XCTAssertEqual(
      environmentExchange.value(forHTTPHeaderField: "Content-Type"),
      "application/x-www-form-urlencoded")
    XCTAssertNil(environmentExchange.value(forHTTPHeaderField: "Authorization"))
    XCTAssertEqual(environmentExchange.value(forHTTPHeaderField: "DPoP"), "proof-3")
    XCTAssertEqual(
      Self.body(environmentExchange),
      "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Atoken-exchange"
        + "&subject_token=bootstrap%20%2B%2F%3F"
        + "&subject_token_type=urn%3At3%3Aparams%3Aoauth%3Atoken-type%3Aenvironment-bootstrap"
        + "&requested_token_type=urn%3Aietf%3Aparams%3Aoauth%3Atoken-type%3Aaccess_token"
        + "&scope=orchestration%3Aread&client_label=Islet"
        + "&client_device_type=desktop&client_os=macOS")

    XCTAssertFalse(
      requests[2...].contains {
        $0.value(forHTTPHeaderField: "Authorization")?.contains("account +/?") == true
          || Self.body($0).contains("account%20%2B%2F%3F")
      })
    let proofs = await signer.proofs()
    XCTAssertEqual(
      proofs,
      [
        .init(
          method: "POST", url: "https://relay.t3-relay-unit.test/v1/client/dpop-token",
          accessToken: nil),
        .init(
          method: "POST",
          url: "https://relay.t3-relay-unit.test/v1/environments/env-one/connect",
          accessToken: "relay-access"),
        .init(
          method: "POST", url: "https://env-one.t3-relay-unit.test/oauth/token",
          accessToken: nil),
      ])
  }

  func testDescriptorIdentityMismatchStopsBeforeAuthPreflightAndBootstrapExchange() async throws {
    let recorder = T3RelayHTTPRecorder(responses: [
      .relayToken(), .connect(), .descriptor(environmentID: "attacker"),
    ])
    let client = makeClient(recorder: recorder, signer: T3RelayProofRecorder())

    await assertInvalidResponse {
      _ = try await client.authorize(
        environment: Self.environment(), accountToken: "account", grantID: self.grantID)
    }

    XCTAssertEqual(
      recorder.requests().map(\.url?.path),
      [
        "/v1/client/dpop-token", "/v1/environments/env-one/connect",
        "/.well-known/t3/environment",
      ])
  }

  func testAuthPreflightMustBeUnauthenticatedAndAdvertiseDpopBeforeCredentialLeaves() async throws {
    let invalidStates = [
      #"{"authenticated":true,"auth":{"policy":"remote-reachable","bootstrapMethods":["one-time-token"],"sessionMethods":["dpop-access-token"],"sessionCookieName":"t3_session"}}"#,
      #"{"authenticated":false,"auth":{"policy":"remote-reachable","bootstrapMethods":["one-time-token"],"sessionMethods":["bearer-access-token"],"sessionCookieName":"t3_session"}}"#,
      #"{"authenticated":false}"#,
    ]

    for state in invalidStates {
      let recorder = T3RelayHTTPRecorder(responses: [
        .relayToken(), .connect(credential: "must-not-leave"), .descriptor(),
        .json(status: 200, state),
      ])
      let client = makeClient(recorder: recorder, signer: T3RelayProofRecorder())

      await assertInvalidResponse {
        _ = try await client.authorize(
          environment: Self.environment(), accountToken: "account", grantID: self.grantID)
      }

      let requests = recorder.requests()
      XCTAssertEqual(requests.count, 4)
      XCTAssertEqual(requests.last?.url?.path, "/api/auth/session")
      XCTAssertFalse(requests.contains { Self.body($0).contains("must-not-leave") })
    }
  }

  func testConnectResponseMustMatchIdentityAndContainSecureManagedEndpoints() async throws {
    let invalidResponses = [
      T3RelayHTTPResponse.connect(environmentID: "attacker"),
      .connect(httpBaseURL: "http://env-one.t3-relay-unit.test"),
      .connect(webSocketBaseURL: "ws://env-one.t3-relay-unit.test/ws"),
      .connect(httpBaseURL: "https://user@env-one.t3-relay-unit.test"),
      .connect(webSocketBaseURL: "wss://env-one.t3-relay-unit.test/ws#fragment"),
      .connect(expiresAt: "not-a-date"),
    ]

    for connectResponse in invalidResponses {
      let recorder = T3RelayHTTPRecorder(responses: [.relayToken(), connectResponse])
      let client = makeClient(recorder: recorder, signer: T3RelayProofRecorder())
      await assertInvalidResponse {
        _ = try await client.authorize(
          environment: Self.environment(), accountToken: "account", grantID: self.grantID)
      }
      XCTAssertEqual(recorder.requests().count, 2)
    }
  }

  func testConnectPercentEncodesEnvironmentIDAsOnePathComponent() async throws {
    let environment = Self.environment(
      environmentID: "env/with space", host: "encoded.t3-relay-unit.test")
    let recorder = T3RelayHTTPRecorder(
      responses: Self.authorizationResponses(environment: environment))
    let client = makeClient(recorder: recorder, signer: T3RelayProofRecorder())

    _ = try await client.authorize(
      environment: environment, accountToken: "account", grantID: grantID)

    XCTAssertEqual(
      recorder.requests()[1].url?.absoluteString,
      "https://relay.t3-relay-unit.test/v1/environments/env%2Fwith%20space/connect")
  }

  func testRotatedConnectEndpointIsValidatedAndUsedForEnvironmentRequests() async throws {
    let inventoryEnvironment = Self.environment(
      environmentID: "env-one", host: "old.t3-relay-unit.test")
    let connectedEnvironment = Self.environment(
      environmentID: "env-one", host: "new.t3-relay-unit.test")
    let recorder = T3RelayHTTPRecorder(responses: [
      .relayToken(),
      .connect(
        httpBaseURL: connectedEnvironment.httpBaseURL.absoluteString,
        webSocketBaseURL: connectedEnvironment.webSocketBaseURL.absoluteString),
      .descriptor(), .authState(), .environmentToken(),
    ])
    let client = makeClient(recorder: recorder, signer: T3RelayProofRecorder())

    let authorization = try await client.authorize(
      environment: inventoryEnvironment, accountToken: "account", grantID: grantID)

    XCTAssertEqual(authorization.endpoint.baseURL, connectedEnvironment.httpBaseURL)
    XCTAssertEqual(recorder.requests()[2].url?.host, "new.t3-relay-unit.test")
    XCTAssertEqual(recorder.requests()[3].url?.host, "new.t3-relay-unit.test")
    XCTAssertEqual(recorder.requests()[4].url?.host, "new.t3-relay-unit.test")
  }

  func testRelayTokenRequiresPinnedTypeIssuedURNFiniteBoundedExpiryAndExactScope() async throws {
    let accessTokenURN = "urn:ietf:params:oauth:token-type:access_token"
    let invalidBodies = [
      T3RelayHTTPResponse.token(
        accessToken: "relay", issuedTokenType: accessTokenURN, tokenType: "Bearer",
        expiresIn: 3_600, scope: "environment:connect"),
      .token(
        accessToken: "relay", issuedTokenType: "wrong", tokenType: "DPoP",
        expiresIn: 3_600, scope: "environment:connect"),
      .token(
        accessToken: "", issuedTokenType: accessTokenURN, tokenType: "DPoP",
        expiresIn: 3_600, scope: "environment:connect"),
      .token(
        accessToken: " \n\t ", issuedTokenType: accessTokenURN, tokenType: "DPoP",
        expiresIn: 3_600, scope: "environment:connect"),
      .token(
        accessToken: "relay", issuedTokenType: accessTokenURN, tokenType: "DPoP",
        expiresIn: 0, scope: "environment:connect"),
      .token(
        accessToken: "relay", issuedTokenType: accessTokenURN, tokenType: "DPoP",
        expiresIn: 2_678_401, scope: "environment:connect"),
      .token(
        accessToken: "relay", issuedTokenType: accessTokenURN, tokenType: "DPoP",
        expiresIn: 3_600, scope: "environment:connect environment:status"),
      .token(
        accessToken: "relay", issuedTokenType: accessTokenURN, tokenType: "DPoP",
        expiresIn: 3_600, scope: "environment:connect environment:connect"),
    ]

    for response in invalidBodies {
      let recorder = T3RelayHTTPRecorder(responses: [response])
      let client = makeClient(recorder: recorder, signer: T3RelayProofRecorder())
      await assertInvalidResponse {
        _ = try await client.authorize(
          environment: Self.environment(), accountToken: "account", grantID: self.grantID)
      }
      XCTAssertEqual(recorder.requests().count, 1)
    }
  }

  func testEnvironmentTokenRequiresDpopAccessTokenURNFiniteBoundedExpiryAndExactUnorderedScope()
    async throws
  {
    let accessTokenURN = "urn:ietf:params:oauth:token-type:access_token"
    let invalidBodies = [
      T3RelayHTTPResponse.token(
        accessToken: "environment", issuedTokenType: accessTokenURN, tokenType: "Bearer",
        expiresIn: 3_600, scope: "orchestration:read"),
      .token(
        accessToken: "environment", issuedTokenType: "wrong", tokenType: "DPoP",
        expiresIn: 3_600, scope: "orchestration:read"),
      .token(
        accessToken: "", issuedTokenType: accessTokenURN, tokenType: "DPoP",
        expiresIn: 3_600, scope: "orchestration:read"),
      .token(
        accessToken: " \n\t ", issuedTokenType: accessTokenURN, tokenType: "DPoP",
        expiresIn: 3_600, scope: "orchestration:read"),
      .token(
        accessToken: "environment", issuedTokenType: accessTokenURN, tokenType: "DPoP",
        expiresIn: 0, scope: "orchestration:read"),
      .token(
        accessToken: "environment", issuedTokenType: accessTokenURN, tokenType: "DPoP",
        expiresIn: 2_678_401, scope: "orchestration:read"),
      .token(
        accessToken: "environment", issuedTokenType: accessTokenURN, tokenType: "DPoP",
        expiresIn: 3_600, scope: "orchestration:read orchestration:operate"),
      .token(
        accessToken: "environment", issuedTokenType: accessTokenURN, tokenType: "DPoP",
        expiresIn: 3_600, scope: "orchestration:read orchestration:read"),
    ]

    for invalidResponse in invalidBodies {
      let responses = [
        T3RelayHTTPResponse.relayToken(), .connect(), .descriptor(), .authState(),
        invalidResponse,
      ]
      let recorder = T3RelayHTTPRecorder(responses: responses)
      let client = makeClient(recorder: recorder, signer: T3RelayProofRecorder())
      await assertInvalidResponse {
        _ = try await client.authorize(
          environment: Self.environment(), accountToken: "account", grantID: self.grantID)
      }
      XCTAssertEqual(recorder.requests().count, 5)
    }
  }

  func testEnvironmentAuthorizationCacheExpiresAtLeast60SecondsEarly() async throws {
    let clock = T3RelayTestClock(now: now)
    let responses =
      Self.authorizationResponses(
        relayExpiresIn: 3_600, environmentExpiresIn: 120)
      + Self.environmentAuthorizationResponses(environmentExpiresIn: 120)
    let recorder = T3RelayHTTPRecorder(responses: responses)
    let client = makeClient(
      recorder: recorder, signer: T3RelayProofRecorder(), now: { clock.value() })

    _ = try await client.authorize(
      environment: Self.environment(), accountToken: "account", grantID: grantID)
    clock.advance(by: 61)
    _ = try await client.authorize(
      environment: Self.environment(), accountToken: "account", grantID: grantID)

    XCTAssertEqual(recorder.requests().filter { $0.url?.path == "/v1/client/dpop-token" }.count, 1)
    XCTAssertEqual(recorder.requests().filter { $0.url?.path == "/oauth/token" }.count, 2)
  }

  func testRelayTokenCacheExpiresAtLeast60SecondsEarly() async throws {
    let clock = T3RelayTestClock(now: now)
    let first = Self.environment(environmentID: "env-one", host: "env-one.t3-relay-unit.test")
    let second = Self.environment(environmentID: "env-two", host: "env-two.t3-relay-unit.test")
    let responses =
      Self.authorizationResponses(
        environment: first, relayExpiresIn: 120, environmentExpiresIn: 3_600)
      + Self.authorizationResponses(
        environment: second, includeRelayToken: true, relayExpiresIn: 120,
        environmentExpiresIn: 3_600)
    let recorder = T3RelayHTTPRecorder(responses: responses)
    let client = makeClient(
      recorder: recorder, signer: T3RelayProofRecorder(), now: { clock.value() })

    _ = try await client.authorize(
      environment: first, accountToken: "account", grantID: grantID)
    clock.advance(by: 61)
    _ = try await client.authorize(
      environment: second, accountToken: "account", grantID: grantID)

    XCTAssertEqual(recorder.requests().filter { $0.url?.path == "/v1/client/dpop-token" }.count, 2)
  }

  func testConcurrentAuthorizationMintsAreCoalesced() async throws {
    let reused = T3RelayTestSignal()
    let recorder = T3RelayHTTPRecorder(
      responses: Self.authorizationResponses(), suspendedResponseIndices: [1])
    let client = makeClient(
      recorder: recorder, signer: T3RelayProofRecorder(),
      onEnvironmentTaskReused: { reused.signal() })
    let environment = Self.environment()
    let currentGrantID = grantID

    async let first = client.authorize(
      environment: environment, accountToken: "account", grantID: currentGrantID)
    await recorder.waitForRequestCount(1)
    async let second = client.authorize(
      environment: environment, accountToken: "account", grantID: currentGrantID)
    await reused.wait()
    recorder.resumeAll()

    let results = try await [first, second]
    XCTAssertEqual(results.map(\.descriptor.environmentId), ["env-one", "env-one"])
    XCTAssertEqual(recorder.requests().count, 5)
  }

  func testConcurrentEnvironmentMintsShareOneRelayTokenMint() async throws {
    let relayTaskReused = T3RelayTestSignal()
    let recorder = T3RelayHTTPRecorder(
      responses: [.relayToken()], suspendedResponseIndices: [1])
    let client = makeClient(
      recorder: recorder, signer: T3RelayProofRecorder(),
      onRelayTaskReused: { relayTaskReused.signal() })
    let firstEnvironment = Self.environment(
      environmentID: "env-one", host: "env-one.t3-relay-unit.test")
    let secondEnvironment = Self.environment(
      environmentID: "env-two", host: "env-two.t3-relay-unit.test")
    let currentGrantID = grantID
    let first = Task {
      try await client.authorize(
        environment: firstEnvironment, accountToken: "account", grantID: currentGrantID)
    }
    await recorder.waitForRequestCount(1)
    let second = Task {
      try await client.authorize(
        environment: secondEnvironment, accountToken: "account", grantID: currentGrantID)
    }

    await relayTaskReused.wait()
    XCTAssertEqual(recorder.requests().count, 1)
    await client.clearCaches()
    recorder.resumeAll()
    _ = try? await first.value
    _ = try? await second.value
  }

  func testGrantIDPartitionsRelayAndEnvironmentCachesAcrossRelink() async throws {
    let secondGrantID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let recorder = T3RelayHTTPRecorder(
      responses: Self.authorizationResponses(relayToken: "relay-old", environmentToken: "old")
        + Self.authorizationResponses(relayToken: "relay-new", environmentToken: "new"))
    let client = makeClient(recorder: recorder, signer: T3RelayProofRecorder())

    _ = try await client.authorize(
      environment: Self.environment(), accountToken: "account", grantID: grantID)
    let relinked = try await client.authorize(
      environment: Self.environment(), accountToken: "account", grantID: secondGrantID)

    switch relinked.authorization {
    case .dpop(let accessToken, _): XCTAssertEqual(accessToken, "new")
    default: XCTFail("Expected DPoP authorization")
    }
    XCTAssertEqual(recorder.requests().filter { $0.url?.path == "/v1/client/dpop-token" }.count, 2)
    XCTAssertEqual(recorder.requests().filter { $0.url?.path == "/oauth/token" }.count, 2)
  }

  func testProofThumbprintPartitionsRelayAndEnvironmentCaches() async throws {
    let recorder = T3RelayHTTPRecorder(
      responses: Self.authorizationResponses(relayToken: "relay-one", environmentToken: "one")
        + Self.authorizationResponses(relayToken: "relay-two", environmentToken: "two"))
    let signer = T3RelayProofRecorder()
    let client = makeClient(recorder: recorder, signer: signer)

    _ = try await client.authorize(
      environment: Self.environment(), accountToken: "account", grantID: grantID)
    await signer.setThumbprint("replacement-thumbprint")
    let replacement = try await client.authorize(
      environment: Self.environment(), accountToken: "account", grantID: grantID)

    switch replacement.authorization {
    case .dpop(let accessToken, _): XCTAssertEqual(accessToken, "two")
    default: XCTFail("Expected DPoP authorization")
    }
    let connectBodies = try recorder.requests().filter {
      $0.url?.path.hasSuffix("/connect") == true
    }
    .map(Self.jsonObject)
    XCTAssertEqual(
      connectBodies.map { $0["clientProofKeyThumbprint"] as? String },
      [
        "proof-thumbprint", "replacement-thumbprint",
      ])
  }

  func testRejectedRelayTokenIsInvalidatedAndRetriedOnceWithFreshProofs() async throws {
    let recorder = T3RelayHTTPRecorder(responses: [
      .relayToken(accessToken: "rejected-relay"), .json(status: 401, #"{"error":"invalid"}"#),
      .relayToken(accessToken: "fresh-relay"), .connect(), .descriptor(), .authState(),
      .environmentToken(),
    ])
    let signer = T3RelayProofRecorder()
    let client = makeClient(recorder: recorder, signer: signer)

    _ = try await client.authorize(
      environment: Self.environment(), accountToken: "account", grantID: grantID)

    let requests = recorder.requests()
    XCTAssertEqual(requests.filter { $0.url?.path == "/v1/client/dpop-token" }.count, 2)
    XCTAssertEqual(requests.filter { $0.url?.path.hasSuffix("/connect") == true }.count, 2)
    XCTAssertEqual(
      requests.filter { $0.url?.path.hasSuffix("/connect") == true }
        .map { $0.value(forHTTPHeaderField: "Authorization") },
      ["DPoP rejected-relay", "DPoP fresh-relay"])
    let proofs = await signer.proofs()
    XCTAssertEqual(proofs.map(\.accessToken), [nil, "rejected-relay", nil, "fresh-relay", nil])
  }

  func testSecondRejectedRelayTokenEscapesWithoutAThirdAttempt() async throws {
    let recorder = T3RelayHTTPRecorder(responses: [
      .relayToken(accessToken: "rejected-one"), .json(status: 401, "{}"),
      .relayToken(accessToken: "rejected-two"), .json(status: 403, "{}"),
    ])
    let client = makeClient(recorder: recorder, signer: T3RelayProofRecorder())

    do {
      _ = try await client.authorize(
        environment: Self.environment(), accountToken: "account", grantID: grantID)
      XCTFail("Expected the second relay rejection to escape")
    } catch T3ClientError.unauthorized {
    }

    XCTAssertEqual(recorder.requests().count, 4)
  }

  func testLateOldRelayRejectionDoesNotCancelAnotherEnvironmentsFreshRelayMint()
    async throws
  {
    let outcome = T3RelayTestValueSignal<Bool>()
    let recorder = T3RelayHTTPRecorder(
      responses: [
        .relayToken(accessToken: "rejected-relay"), .json(status: 401, "{}"),
        .json(status: 401, "{}"), .relayToken(accessToken: "fresh-relay"),
      ],
      suspendedResponseIndices: [2, 4],
      onRequest: { index in
        if index == 5 { outcome.signal(false) }
      })
    let client = makeClient(
      recorder: recorder, signer: T3RelayProofRecorder(),
      onRelayTaskReused: { outcome.signal(true) })
    let firstEnvironment = Self.environment(
      environmentID: "env-one", host: "env-one.t3-relay-unit.test")
    let secondEnvironment = Self.environment(
      environmentID: "env-two", host: "env-two.t3-relay-unit.test")
    let currentGrantID = grantID

    let first = Task {
      try await client.authorize(
        environment: firstEnvironment, accountToken: "account", grantID: currentGrantID)
    }
    await recorder.waitForRequestCount(2)
    let second = Task {
      try await client.authorize(
        environment: secondEnvironment, accountToken: "account", grantID: currentGrantID)
    }
    await recorder.waitForRequestCount(4)

    recorder.resumeNext()
    let reusedFreshMint = await outcome.wait()
    XCTAssertTrue(reusedFreshMint)

    await client.clearCaches()
    recorder.resumeAll()
    _ = try? await first.value
    _ = try? await second.value
  }

  func testTargetedInvalidationRemintsOnlyTheNamedEnvironmentForTheGrant() async throws {
    let first = Self.environment(environmentID: "env-one", host: "env-one.t3-relay-unit.test")
    let second = Self.environment(environmentID: "env-two", host: "env-two.t3-relay-unit.test")
    let recorder = T3RelayHTTPRecorder(
      responses: Self.authorizationResponses(environment: first)
        + Self.environmentAuthorizationResponses(environment: second)
        + Self.environmentAuthorizationResponses(environment: first))
    let client = makeClient(recorder: recorder, signer: T3RelayProofRecorder())

    _ = try await client.authorize(environment: first, accountToken: "account", grantID: grantID)
    _ = try await client.authorize(environment: second, accountToken: "account", grantID: grantID)
    await client.invalidateAuthorization(environmentID: first.environmentID, grantID: grantID)
    let requestsBeforeCachedSecond = recorder.requests().count
    _ = try await client.authorize(environment: second, accountToken: "account", grantID: grantID)
    XCTAssertEqual(recorder.requests().count, requestsBeforeCachedSecond)
    _ = try await client.authorize(environment: first, accountToken: "account", grantID: grantID)

    let environmentExchanges = recorder.requests().filter { $0.url?.path == "/oauth/token" }
    XCTAssertEqual(
      environmentExchanges.map(\.url?.host),
      [
        "env-one.t3-relay-unit.test", "env-two.t3-relay-unit.test",
        "env-one.t3-relay-unit.test",
      ])
    XCTAssertEqual(recorder.requests().filter { $0.url?.path == "/v1/client/dpop-token" }.count, 1)
  }

  func testTargetedInvalidationRejectsAnAuthorizationSuspendedDuringThumbprintLookup() async throws
  {
    let thumbprintRequested = T3RelayTestSignal()
    let signer = T3RelaySuspendedThumbprintSigner(requested: thumbprintRequested)
    let recorder = T3RelayHTTPRecorder(responses: Self.authorizationResponses())
    let client = makeClient(recorder: recorder, signer: signer)
    let currentGrantID = grantID
    let suspended = Task {
      try await client.authorize(
        environment: Self.environment(), accountToken: "account", grantID: currentGrantID)
    }
    await thumbprintRequested.wait()

    await client.invalidateAuthorization(environmentID: "env-one", grantID: currentGrantID)
    await signer.resume()

    do {
      _ = try await suspended.value
      XCTFail("Expected targeted invalidation to reject the suspended authorization")
    } catch T3RelayClientError.staleOperation {
    }
    XCTAssertTrue(recorder.requests().isEmpty)
  }

  func testClearCachesIsACancellationBarrierForSuspendedMintResults() async throws {
    let recorder = T3RelayHTTPRecorder(
      responses: Self.authorizationResponses(environmentToken: "stale")
        + Self.authorizationResponses(environmentToken: "fresh"),
      suspendedResponseIndices: [5])
    let client = makeClient(recorder: recorder, signer: T3RelayProofRecorder())
    let stale = Task {
      try await client.authorize(
        environment: Self.environment(), accountToken: "account", grantID: grantID)
    }
    await recorder.waitForRequestCount(5)

    await client.clearCaches()
    recorder.resumeAll()
    do {
      _ = try await stale.value
      XCTFail("Expected the pre-clear mint result to be rejected")
    } catch {
    }

    let fresh = try await client.authorize(
      environment: Self.environment(), accountToken: "account", grantID: grantID)
    switch fresh.authorization {
    case .dpop(let accessToken, _): XCTAssertEqual(accessToken, "fresh")
    default: XCTFail("Expected DPoP authorization")
    }
    XCTAssertEqual(recorder.requests().filter { $0.url?.path == "/v1/client/dpop-token" }.count, 2)
    XCTAssertEqual(recorder.requests().filter { $0.url?.path == "/oauth/token" }.count, 2)
  }

  private func makeClient(
    recorder: T3RelayHTTPRecorder,
    signer: any T3DPoPProofProviding,
    now: @escaping @Sendable () -> Date? = { nil },
    onRelayTaskReused: @escaping @Sendable () -> Void = {},
    onEnvironmentTaskReused: @escaping @Sendable () -> Void = {}
  ) -> T3RelayClient {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [T3RelayURLProtocol.self]
    T3RelayURLProtocol.recorder = recorder
    let fixedNow = self.now
    return T3RelayClient(
      transport: T3HTTPTransport(session: URLSession(configuration: configuration)),
      signer: signer,
      configuration: .relayTest,
      now: { now() ?? fixedNow },
      onRelayTaskReused: onRelayTaskReused,
      onEnvironmentTaskReused: onEnvironmentTaskReused)
  }

  private func assertInvalidResponse(
    _ operation: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async {
    do {
      try await operation()
      XCTFail("Expected invalidResponse", file: file, line: line)
    } catch T3ClientError.invalidResponse {
    } catch {
      XCTFail("Expected invalidResponse, got \(error)", file: file, line: line)
    }
  }

  private static func environment(
    environmentID: String = "env-one", host: String = "env-one.t3-relay-unit.test"
  ) -> T3ConnectEnvironment {
    T3ConnectEnvironment(
      environmentID: environmentID,
      label: environmentID == "env-one" ? "Studio" : "Second studio",
      httpBaseURL: URL(string: "https://\(host)/")!,
      webSocketBaseURL: URL(string: "wss://\(host)/ws")!,
      providerKind: "t3_relay",
      linkedAt: date("2026-08-30T00:00:00.000Z"))
  }

  private static func authorizationResponses(
    environment: T3ConnectEnvironment = environment(),
    accountToken: String = "account",
    relayToken: String = "relay-access",
    bootstrapCredential: String = "bootstrap",
    environmentToken: String = "environment-access",
    includeRelayToken: Bool = true,
    relayExpiresIn: Int = 3_600,
    environmentExpiresIn: Double = 3_600
  ) -> [T3RelayHTTPResponse] {
    let relay =
      includeRelayToken
      ? [T3RelayHTTPResponse.relayToken(accessToken: relayToken, expiresIn: relayExpiresIn)] : []
    return relay
      + environmentAuthorizationResponses(
        environment: environment, bootstrapCredential: bootstrapCredential,
        environmentToken: environmentToken, environmentExpiresIn: environmentExpiresIn)
  }

  private static func environmentAuthorizationResponses(
    environment: T3ConnectEnvironment = environment(),
    bootstrapCredential: String = "bootstrap",
    environmentToken: String = "environment-access",
    environmentExpiresIn: Double = 3_600
  ) -> [T3RelayHTTPResponse] {
    [
      .connect(
        environmentID: environment.environmentID,
        httpBaseURL: environment.httpBaseURL.absoluteString,
        webSocketBaseURL: environment.webSocketBaseURL.absoluteString,
        credential: bootstrapCredential),
      .descriptor(environmentID: environment.environmentID), .authState(),
      .environmentToken(accessToken: environmentToken, expiresIn: environmentExpiresIn),
    ]
  }

  private static func environmentJSON(
    environmentID: String = "env-one",
    label: String = "Studio",
    httpBaseURL: String = "https://env-one.t3-relay-unit.test",
    webSocketBaseURL: String = "wss://env-one.t3-relay-unit.test/ws",
    providerKind: String = "t3_relay",
    linkedAt: String = "2026-08-30T00:00:00.000Z"
  ) -> String {
    let object: [String: Any] = [
      "environmentId": environmentID,
      "label": label,
      "endpoint": [
        "httpBaseUrl": httpBaseURL,
        "wsBaseUrl": webSocketBaseURL,
        "providerKind": providerKind,
      ],
      "linkedAt": linkedAt,
    ]
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
  }

  private static func body(_ request: URLRequest) -> String {
    String(decoding: request.httpBody ?? Data(), as: UTF8.self)
  }

  private static func jsonObject(_ request: URLRequest) throws -> [String: AnyHashable] {
    try XCTUnwrap(
      JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: AnyHashable])
  }

  private static func date(_ value: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: value)!
  }
}

extension T3ConnectConfiguration {
  fileprivate static let relayTest = T3ConnectConfiguration(
    hostedAuthorizationURL: URL(string: "https://app.t3-relay-unit.test/connect")!,
    tokenEndpoint: URL(string: "https://oauth.t3-relay-unit.test/token")!,
    clientID: "test-client",
    redirectURI: URL(string: "http://127.0.0.1:34338/callback")!,
    scopes: ["openid", "profile", "email"],
    relayOrigin: URL(string: "https://relay.t3-relay-unit.test")!,
    relayClientID: "test-relay-client")
}

private struct T3RelayHTTPResponse: Sendable {
  let status: Int
  let data: Data

  static func json(status: Int, _ body: String) -> Self {
    Self(status: status, data: Data(body.utf8))
  }

  static func inventory(_ environments: [String]) -> Self {
    json(status: 200, "{\"environments\":[\(environments.joined(separator: ","))]}")
  }

  static func relayToken(accessToken: String = "relay-access", expiresIn: Int = 3_600) -> Self {
    token(
      accessToken: accessToken,
      issuedTokenType: "urn:ietf:params:oauth:token-type:access_token",
      tokenType: "DPoP", expiresIn: Double(expiresIn), scope: "environment:connect")
  }

  static func connect(
    environmentID: String = "env-one",
    httpBaseURL: String = "https://env-one.t3-relay-unit.test/",
    webSocketBaseURL: String = "wss://env-one.t3-relay-unit.test/ws",
    providerKind: String = "t3_relay",
    credential: String = "bootstrap",
    expiresAt: String = "2027-01-15T08:05:00.000Z"
  ) -> Self {
    json(
      status: 200,
      object: [
        "environmentId": environmentID,
        "endpoint": [
          "httpBaseUrl": httpBaseURL,
          "wsBaseUrl": webSocketBaseURL,
          "providerKind": providerKind,
        ],
        "credential": credential,
        "expiresAt": expiresAt,
      ])
  }

  static func descriptor(environmentID: String = "env-one") -> Self {
    json(
      status: 200,
      object: [
        "environmentId": environmentID,
        "label": "Studio",
        "platform": ["os": "macOS", "arch": "arm64"],
        "serverVersion": "1.0.0",
      ])
  }

  static func authState() -> Self {
    json(
      status: 200,
      #"{"authenticated":false,"auth":{"policy":"remote-reachable","bootstrapMethods":["one-time-token"],"sessionMethods":["bearer-access-token","dpop-access-token"],"sessionCookieName":"t3_session"}}"#
    )
  }

  static func environmentToken(
    accessToken: String = "environment-access", expiresIn: Double = 3_600
  ) -> Self {
    token(
      accessToken: accessToken,
      issuedTokenType: "urn:ietf:params:oauth:token-type:access_token",
      tokenType: "DPoP", expiresIn: expiresIn, scope: "orchestration:read")
  }

  static func token(
    accessToken: String, issuedTokenType: String, tokenType: String, expiresIn: Double,
    scope: String
  ) -> Self {
    json(
      status: 200,
      object: [
        "access_token": accessToken,
        "issued_token_type": issuedTokenType,
        "token_type": tokenType,
        "expires_in": expiresIn,
        "scope": scope,
      ])
  }

  private static func json(status: Int, object: [String: Any]) -> Self {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return Self(status: status, data: data)
  }
}

private final class T3RelayHTTPRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var responses: [T3RelayHTTPResponse]
  private var recordedRequests: [URLRequest] = []
  private var pending: [(T3RelayURLProtocol, T3RelayHTTPResponse)] = []
  private var requestWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
  private let suspendedResponseIndices: Set<Int>
  private let onRequest: @Sendable (Int) -> Void

  init(
    responses: [T3RelayHTTPResponse],
    suspendedResponseIndices: Set<Int> = [],
    onRequest: @escaping @Sendable (Int) -> Void = { _ in }
  ) {
    self.responses = responses
    self.suspendedResponseIndices = suspendedResponseIndices
    self.onRequest = onRequest
  }

  func handle(_ loader: T3RelayURLProtocol) {
    var request = loader.request
    if request.httpBody == nil, let stream = request.httpBodyStream {
      request.httpBody = Self.read(stream)
    }

    lock.lock()
    recordedRequests.append(request)
    let index = recordedRequests.count
    let response = responses.isEmpty ? nil : responses.removeFirst()
    let satisfied = requestWaiters.filter { index >= $0.0 }
    requestWaiters.removeAll { index >= $0.0 }
    if let response, suspendedResponseIndices.contains(index) {
      pending.append((loader, response))
      lock.unlock()
    } else {
      lock.unlock()
      if let response {
        loader.deliver(response)
      } else {
        loader.fail(URLError(.badServerResponse))
      }
    }
    onRequest(index)
    for waiter in satisfied { waiter.1.resume() }
  }

  func requests() -> [URLRequest] {
    lock.lock()
    defer { lock.unlock() }
    return recordedRequests
  }

  func waitForRequestCount(_ count: Int) async {
    await withCheckedContinuation { continuation in
      lock.lock()
      if recordedRequests.count >= count {
        lock.unlock()
        continuation.resume()
      } else {
        requestWaiters.append((count, continuation))
        lock.unlock()
      }
    }
  }

  func resumeAll() {
    lock.lock()
    let deliveries = pending
    pending.removeAll()
    lock.unlock()
    for (loader, response) in deliveries { loader.deliver(response) }
  }

  func resumeNext() {
    lock.lock()
    let delivery = pending.isEmpty ? nil : pending.removeFirst()
    lock.unlock()
    if let (loader, response) = delivery { loader.deliver(response) }
  }

  private static func read(_ stream: InputStream) -> Data {
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 1_024)
    while stream.hasBytesAvailable {
      let count = stream.read(&buffer, maxLength: buffer.count)
      guard count > 0 else { break }
      data.append(contentsOf: buffer.prefix(count))
    }
    return data
  }
}

private final class T3RelayURLProtocol: URLProtocol, @unchecked Sendable {
  nonisolated(unsafe) static var recorder: T3RelayHTTPRecorder?

  private let lock = NSLock()
  private var stopped = false

  override class func canInit(with request: URLRequest) -> Bool {
    request.url?.host?.hasSuffix("t3-relay-unit.test") == true
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    Self.recorder?.handle(self)
  }

  override func stopLoading() {
    lock.lock()
    stopped = true
    lock.unlock()
  }

  func deliver(_ response: T3RelayHTTPResponse) {
    guard !isStopped, let url = request.url else { return }
    let http = HTTPURLResponse(
      url: url, statusCode: response.status, httpVersion: "HTTP/1.1",
      headerFields: ["Content-Type": "application/json"])!
    client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: response.data)
    client?.urlProtocolDidFinishLoading(self)
  }

  func fail(_ error: Error) {
    guard !isStopped else { return }
    client?.urlProtocol(self, didFailWithError: error)
  }

  private var isStopped: Bool {
    lock.lock()
    defer { lock.unlock() }
    return stopped
  }
}

private actor T3RelayProofRecorder: T3DPoPProofProviding {
  struct Proof: Equatable {
    let method: String
    let url: String
    let accessToken: String?
  }

  private var thumbprint = "proof-thumbprint"
  private var recordedProofs: [Proof] = []

  func proof(method: String, url: URL, accessToken: String?) async throws -> String {
    recordedProofs.append(
      Proof(method: method, url: url.absoluteString, accessToken: accessToken))
    return "proof-\(recordedProofs.count)"
  }

  func keyThumbprint() async throws -> String { thumbprint }

  func setThumbprint(_ value: String) {
    thumbprint = value
  }

  func proofs() -> [Proof] { recordedProofs }
}

private actor T3RelaySuspendedThumbprintSigner: T3DPoPProofProviding {
  private let requested: T3RelayTestSignal
  private var continuation: CheckedContinuation<Void, Never>?

  init(requested: T3RelayTestSignal) {
    self.requested = requested
  }

  func proof(method: String, url: URL, accessToken: String?) async throws -> String {
    "proof"
  }

  func keyThumbprint() async throws -> String {
    requested.signal()
    await withCheckedContinuation { continuation = $0 }
    return "proof-thumbprint"
  }

  func resume() {
    continuation?.resume()
    continuation = nil
  }
}

private final class T3RelayTestClock: @unchecked Sendable {
  private let lock = NSLock()
  private var now: Date

  init(now: Date) {
    self.now = now
  }

  func value() -> Date {
    lock.lock()
    defer { lock.unlock() }
    return now
  }

  func advance(by interval: TimeInterval) {
    lock.lock()
    now = now.addingTimeInterval(interval)
    lock.unlock()
  }
}

private final class T3RelayTestSignal: @unchecked Sendable {
  private let lock = NSLock()
  private var signaled = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func signal() {
    lock.lock()
    signaled = true
    let pending = waiters
    waiters.removeAll()
    lock.unlock()
    for waiter in pending { waiter.resume() }
  }

  func wait() async {
    await withCheckedContinuation { continuation in
      lock.lock()
      if signaled {
        lock.unlock()
        continuation.resume()
      } else {
        waiters.append(continuation)
        lock.unlock()
      }
    }
  }
}

private final class T3RelayTestValueSignal<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Value?
  private var waiters: [CheckedContinuation<Value, Never>] = []

  func signal(_ value: Value) {
    lock.lock()
    guard self.value == nil else {
      lock.unlock()
      return
    }
    self.value = value
    let pending = waiters
    waiters.removeAll()
    lock.unlock()
    for waiter in pending { waiter.resume(returning: value) }
  }

  func wait() async -> Value {
    await withCheckedContinuation { continuation in
      lock.lock()
      if let value {
        lock.unlock()
        continuation.resume(returning: value)
      } else {
        waiters.append(continuation)
        lock.unlock()
      }
    }
  }
}

extension Array {
  fileprivate var only: Element? {
    count == 1 ? self[0] : nil
  }
}
