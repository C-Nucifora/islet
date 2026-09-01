import Foundation

enum T3RelayClientError: Error, Equatable, LocalizedError {
  case staleOperation

  var errorDescription: String? {
    switch self {
    case .staleOperation:
      "The T3 Connect authorization was invalidated."
    }
  }
}

actor T3RelayClient {
  private nonisolated static let requestDeadline: TimeInterval = 30
  private nonisolated static let cacheExpiryLeadTime: TimeInterval = 60
  private nonisolated static let maximumTokenLifetime = T3OAuthRecord.maximumResponseLifetime
  private nonisolated static let maximumInventoryCount = 256
  private nonisolated static let maximumStringBytes = 16 * 1_024
  private nonisolated static let maximumURLBytes = 4 * 1_024
  private nonisolated static let maximumScopeBytes = 16 * 1_024
  private nonisolated static let maximumAuthMethods = 32
  private nonisolated static let maximumBootstrapLifetime: TimeInterval = 10 * 60
  private nonisolated static let relayScope = "environment:connect"
  private nonisolated static let environmentScope = "orchestration:read"
  private nonisolated static let tokenExchangeGrant =
    "urn:ietf:params:oauth:grant-type:token-exchange"
  private nonisolated static let jwtTokenURN = "urn:ietf:params:oauth:token-type:jwt"
  private nonisolated static let accessTokenURN =
    "urn:ietf:params:oauth:token-type:access_token"

  private let transport: T3HTTPTransport
  private let signer: any T3DPoPProofProviding
  private let configuration: T3ConnectConfiguration
  private let relayOrigin: T3HTTPOrigin?
  private let relayResource: String?
  private let now: @Sendable () -> Date
  private let onRelayTaskReused: @Sendable () -> Void
  private let onEnvironmentTaskReused: @Sendable () -> Void
  private var generation: UInt64 = 0
  private var relayCache: [RelayCacheKey: RelayToken] = [:]
  private var relayTasks: [RelayCacheKey: PendingRelayTask] = [:]
  private var environmentCache: [EnvironmentCacheKey: T3ConnectEnvironmentAuthorization] = [:]
  private var environmentTasks: [EnvironmentCacheKey: PendingEnvironmentTask] = [:]
  private var environmentInvalidations: [EnvironmentSelector: UInt64] = [:]

  // MARK: Lifecycle

  init(
    transport: T3HTTPTransport = .shared,
    signer: any T3DPoPProofProviding = T3DPoPSigner(store: T3ConnectCredentialStore()),
    configuration: T3ConnectConfiguration = .production,
    now: @escaping @Sendable () -> Date = Date.init,
    onRelayTaskReused: @escaping @Sendable () -> Void = {},
    onEnvironmentTaskReused: @escaping @Sendable () -> Void = {}
  ) {
    self.transport = transport
    self.signer = signer
    self.configuration = configuration
    relayOrigin = try? T3HTTPOrigin(configuration.relayOrigin)
    relayResource = Self.normalizedRelayOrigin(configuration.relayOrigin)
    self.now = now
    self.onRelayTaskReused = onRelayTaskReused
    self.onEnvironmentTaskReused = onEnvironmentTaskReused
  }

  // MARK: Public operations

  func listEnvironments(accountToken: String) async throws -> [T3ConnectEnvironment] {
    guard Self.isUsableToken(accountToken), let relayOrigin,
      let url = Self.relayURL(configuration.relayOrigin, path: "/v1/environments")
    else {
      throw T3ClientError.invalidResponse
    }
    let capturedGeneration = generation
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    let response = try await transport.send(
      request, authorization: .bearer(accountToken), expectedOrigin: relayOrigin,
      deadline: Self.requestDeadline)
    try Task.checkCancellation()
    guard capturedGeneration == generation else { throw T3RelayClientError.staleOperation }
    try Self.requireSuccess(response)
    let wire = try Self.decode(InventoryResponse.self, from: response.data)
    guard wire.environments.count <= Self.maximumInventoryCount else {
      throw T3ClientError.invalidResponse
    }

    var seenIDs = Set<String>()
    return try wire.environments.map { item in
      guard let environmentID = Self.environmentID(item.environmentId),
        let label = Self.boundedString(item.label),
        let providerKind = Self.providerKind(item.endpoint.providerKind),
        let httpBaseURL = Self.managedHTTPURL(item.endpoint.httpBaseUrl),
        let webSocketBaseURL = Self.managedWebSocketURL(item.endpoint.wsBaseUrl),
        let linkedAtString = Self.boundedString(item.linkedAt),
        let linkedAt = Self.date(linkedAtString),
        seenIDs.insert(environmentID).inserted
      else {
        throw T3ClientError.invalidResponse
      }
      return T3ConnectEnvironment(
        environmentID: environmentID, label: label, httpBaseURL: httpBaseURL,
        webSocketBaseURL: webSocketBaseURL, providerKind: providerKind, linkedAt: linkedAt)
    }
  }

  func authorize(
    environment: T3ConnectEnvironment,
    accountToken: String,
    grantID: UUID
  ) async throws -> T3ConnectEnvironmentAuthorization {
    guard Self.isUsableToken(accountToken) else { throw T3ClientError.invalidResponse }
    let validatedEnvironment = try Self.validate(environment)
    let capturedGeneration = generation
    let selector = EnvironmentSelector(
      grantID: grantID, environmentID: validatedEnvironment.environmentID)
    let invalidation = environmentInvalidations[selector, default: 0]
    let proofSigner = try await signer.proofLease()
    try requireCurrent(capturedGeneration, selector: selector, invalidation: invalidation)
    let thumbprint = try await proofSigner.keyThumbprint()
    try requireCurrent(capturedGeneration, selector: selector, invalidation: invalidation)
    guard Self.boundedString(thumbprint) != nil else {
      throw T3ClientError.invalidResponse
    }

    let key = EnvironmentCacheKey(
      grantID: grantID,
      environmentID: validatedEnvironment.environmentID,
      endpoint: validatedEnvironment.httpBaseURL.absoluteString,
      thumbprint: thumbprint)
    if let cached = environmentCache[key], Self.isCacheable(cached.expiresAt, now: now()) {
      return cached
    }
    environmentCache.removeValue(forKey: key)

    if let pending = environmentTasks[key] {
      onEnvironmentTaskReused()
      let authorization = try await waitForEnvironmentTask(pending, key: key)
      try Task.checkCancellation()
      try requireCurrent(
        capturedGeneration, selector: selector, invalidation: invalidation)
      return authorization
    }

    let taskID = UUID()
    let task = Task { [self] in
      try await mintAuthorization(
        environment: validatedEnvironment,
        accountToken: accountToken,
        grantID: grantID,
        signer: proofSigner,
        thumbprint: thumbprint,
        capturedGeneration: capturedGeneration,
        selector: selector,
        invalidation: invalidation)
    }
    environmentTasks[key] = PendingEnvironmentTask(id: taskID, task: task, waiterIDs: [])
    let authorization = try await waitForEnvironmentTask(
      PendingEnvironmentTask(id: taskID, task: task, waiterIDs: []), key: key)
    try Task.checkCancellation()
    try requireCurrent(
      capturedGeneration, selector: selector, invalidation: invalidation)
    return authorization
  }

  func invalidateAuthorization(environmentID: String, grantID: UUID) async {
    let selector = EnvironmentSelector(grantID: grantID, environmentID: environmentID)
    environmentInvalidations[selector, default: 0] &+= 1
    let cacheKeys = environmentCache.keys.filter {
      $0.grantID == grantID && $0.environmentID == environmentID
    }
    for key in cacheKeys { environmentCache.removeValue(forKey: key) }
    let taskKeys = environmentTasks.keys.filter {
      $0.grantID == grantID && $0.environmentID == environmentID
    }
    for key in taskKeys {
      environmentTasks.removeValue(forKey: key)?.task.cancel()
    }
  }

  func clearCaches() async {
    generation &+= 1
    for pending in relayTasks.values { pending.task.cancel() }
    for pending in environmentTasks.values { pending.task.cancel() }
    relayCache.removeAll()
    relayTasks.removeAll()
    environmentCache.removeAll()
    environmentTasks.removeAll()
    environmentInvalidations.removeAll()
  }

  // MARK: Authorization flow

  private func mintAuthorization(
    environment: T3ConnectEnvironment,
    accountToken: String,
    grantID: UUID,
    signer: any T3DPoPProofProviding,
    thumbprint: String,
    capturedGeneration: UInt64,
    selector: EnvironmentSelector,
    invalidation: UInt64
  ) async throws -> T3ConnectEnvironmentAuthorization {
    var relayAuthorization = try await relayToken(
      accountToken: accountToken, grantID: grantID, signer: signer, thumbprint: thumbprint,
      capturedGeneration: capturedGeneration)
    try requireCurrent(capturedGeneration, selector: selector, invalidation: invalidation)

    let connected: ConnectedEnvironment
    do {
      connected = try await connect(
        environmentID: environment.environmentID, relayToken: relayAuthorization.accessToken,
        signer: signer, thumbprint: thumbprint)
    } catch T3ClientError.unauthorized {
      let relayKey = relayCacheKey(grantID: grantID, thumbprint: thumbprint)
      invalidateRelayToken(relayKey, matching: relayAuthorization.id)
      relayAuthorization = try await relayToken(
        accountToken: accountToken, grantID: grantID, signer: signer, thumbprint: thumbprint,
        capturedGeneration: capturedGeneration)
      try requireCurrent(capturedGeneration, selector: selector, invalidation: invalidation)
      connected = try await connect(
        environmentID: environment.environmentID, relayToken: relayAuthorization.accessToken,
        signer: signer, thumbprint: thumbprint)
    }
    try requireCurrent(capturedGeneration, selector: selector, invalidation: invalidation)
    guard connected.environmentID == environment.environmentID else {
      throw T3ClientError.invalidResponse
    }

    let endpoint = try T3Endpoint(connected.httpBaseURL)
    let environmentClient = T3Client(
      endpoint: endpoint, authorization: .none, transport: transport)
    let descriptor = try await environmentClient.fetchDescriptor()
    try requireCurrent(capturedGeneration, selector: selector, invalidation: invalidation)
    guard descriptor.environmentId == environment.environmentID else {
      throw T3ClientError.invalidResponse
    }

    let authState = try await environmentClient.fetchAuthState()
    try requireCurrent(capturedGeneration, selector: selector, invalidation: invalidation)
    guard Self.accepts(authState) else { throw T3ClientError.invalidResponse }

    let exchange = try await environmentClient.exchange(
      pairingCredential: connected.credential, signer: signer)
    try requireCurrent(capturedGeneration, selector: selector, invalidation: invalidation)
    let receivedAt = now()
    guard Self.isUsableToken(exchange.accessToken),
      exchange.issuedTokenType == Self.accessTokenURN,
      exchange.tokenType == "DPoP",
      Self.hasExactScope(exchange.scope, expected: [Self.environmentScope]),
      exchange.expiresIn.isFinite, exchange.expiresIn > 0,
      exchange.expiresIn <= Self.maximumTokenLifetime,
      receivedAt.timeIntervalSince1970.isFinite
    else {
      throw T3ClientError.invalidResponse
    }
    let expiresAt = receivedAt.addingTimeInterval(exchange.expiresIn)
    guard expiresAt.timeIntervalSince1970.isFinite else {
      throw T3ClientError.invalidResponse
    }
    return T3ConnectEnvironmentAuthorization(
      descriptor: descriptor,
      endpoint: endpoint,
      authorization: .dpop(accessToken: exchange.accessToken, signer: signer),
      expiresAt: expiresAt)
  }

  private func relayToken(
    accountToken: String,
    grantID: UUID,
    signer: any T3DPoPProofProviding,
    thumbprint: String,
    capturedGeneration: UInt64
  ) async throws -> RelayToken {
    let key = relayCacheKey(grantID: grantID, thumbprint: thumbprint)
    if let cached = relayCache[key], Self.isCacheable(cached.expiresAt, now: now()) {
      return cached
    }
    relayCache.removeValue(forKey: key)
    if let pending = relayTasks[key] {
      onRelayTaskReused()
      let token = try await waitForRelayTask(pending, key: key)
      try Task.checkCancellation()
      guard capturedGeneration == generation else {
        throw T3RelayClientError.staleOperation
      }
      return token
    }

    let taskID = UUID()
    let task = Task { [self] in
      try await mintRelayToken(
        accountToken: accountToken, signer: signer, capturedGeneration: capturedGeneration)
    }
    relayTasks[key] = PendingRelayTask(id: taskID, task: task, waiterIDs: [])
    let token = try await waitForRelayTask(
      PendingRelayTask(id: taskID, task: task, waiterIDs: []), key: key)
    try Task.checkCancellation()
    guard capturedGeneration == generation else {
      throw T3RelayClientError.staleOperation
    }
    return token
  }

  private func mintRelayToken(
    accountToken: String,
    signer: any T3DPoPProofProviding,
    capturedGeneration: UInt64
  ) async throws -> RelayToken {
    guard let relayOrigin, let relayResource,
      let url = Self.relayURL(configuration.relayOrigin, path: "/v1/client/dpop-token")
    else {
      throw T3ClientError.invalidURL
    }
    let fields = [
      ("grant_type", Self.tokenExchangeGrant),
      ("subject_token", accountToken),
      ("subject_token_type", Self.jwtTokenURN),
      ("requested_token_type", Self.accessTokenURN),
      ("resource", relayResource),
      ("scope", Self.relayScope),
      ("client_id", configuration.relayClientID),
    ]
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue(
      "application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.httpBody = Data(Self.formBody(fields).utf8)
    let proof = try await signer.proof(method: "POST", url: url, accessToken: nil)
    request.setValue(proof, forHTTPHeaderField: "DPoP")
    let response = try await transport.send(
      request, expectedOrigin: relayOrigin, deadline: Self.requestDeadline)
    try Task.checkCancellation()
    guard capturedGeneration == generation else { throw T3RelayClientError.staleOperation }
    try Self.requireSuccess(response)
    let wire = try Self.decode(TokenResponse.self, from: response.data)
    let receivedAt = now()
    guard Self.isUsableToken(wire.accessToken),
      wire.issuedTokenType == Self.accessTokenURN,
      wire.tokenType == "DPoP",
      Self.hasExactScope(wire.scope, expected: [Self.relayScope]),
      wire.expiresIn > 0,
      Double(wire.expiresIn) <= Self.maximumTokenLifetime,
      receivedAt.timeIntervalSince1970.isFinite
    else {
      throw T3ClientError.invalidResponse
    }
    let expiresAt = receivedAt.addingTimeInterval(Double(wire.expiresIn))
    guard expiresAt.timeIntervalSince1970.isFinite else {
      throw T3ClientError.invalidResponse
    }
    return RelayToken(id: UUID(), accessToken: wire.accessToken, expiresAt: expiresAt)
  }

  private func connect(
    environmentID: String,
    relayToken: String,
    signer: any T3DPoPProofProviding,
    thumbprint: String
  ) async throws -> ConnectedEnvironment {
    guard let relayOrigin,
      let encodedID = Self.percentEncodedPathComponent(environmentID),
      let url = Self.relayURL(
        configuration.relayOrigin,
        path: "/v1/environments/\(encodedID)/connect")
    else {
      throw T3ClientError.invalidURL
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(
      ConnectRequest(clientProofKeyThumbprint: thumbprint))
    let response = try await transport.send(
      request,
      authorization: .dpop(accessToken: relayToken, signer: signer),
      expectedOrigin: relayOrigin,
      deadline: Self.requestDeadline)
    try Self.requireSuccess(response)
    let wire = try Self.decode(ConnectResponse.self, from: response.data)
    guard let responseEnvironmentID = Self.environmentID(wire.environmentId),
      let providerKind = Self.providerKind(wire.endpoint.providerKind),
      let httpBaseURL = Self.managedHTTPURL(wire.endpoint.httpBaseUrl),
      let webSocketBaseURL = Self.managedWebSocketURL(wire.endpoint.wsBaseUrl),
      let credential = Self.boundedString(wire.credential),
      let expiresAtString = Self.boundedString(wire.expiresAt),
      let expiresAt = Self.date(expiresAtString)
    else {
      throw T3ClientError.invalidResponse
    }
    let lifetime = expiresAt.timeIntervalSince(now())
    guard lifetime.isFinite, lifetime > 0, lifetime <= Self.maximumBootstrapLifetime else {
      throw T3ClientError.invalidResponse
    }
    return ConnectedEnvironment(
      environmentID: responseEnvironmentID, httpBaseURL: httpBaseURL,
      webSocketBaseURL: webSocketBaseURL, providerKind: providerKind,
      credential: credential)
  }

  // MARK: Cache state

  private func relayCacheKey(grantID: UUID, thumbprint: String) -> RelayCacheKey {
    RelayCacheKey(
      grantID: grantID,
      relayOrigin: relayResource ?? configuration.relayOrigin.absoluteString,
      clientID: configuration.relayClientID,
      scope: Self.relayScope,
      thumbprint: thumbprint)
  }

  private func invalidateRelayToken(_ key: RelayCacheKey, matching tokenID: UUID) {
    if relayCache[key]?.id == tokenID { relayCache.removeValue(forKey: key) }
  }

  private func requireCurrent(
    _ capturedGeneration: UInt64,
    selector: EnvironmentSelector,
    invalidation: UInt64
  ) throws {
    try Task.checkCancellation()
    guard capturedGeneration == generation,
      environmentInvalidations[selector, default: 0] == invalidation
    else {
      throw T3RelayClientError.staleOperation
    }
  }

  private func waitForRelayTask(
    _ pending: PendingRelayTask, key: RelayCacheKey
  ) async throws -> RelayToken {
    let waiterID = UUID()
    guard relayTasks[key]?.id == pending.id else { throw T3RelayClientError.staleOperation }
    relayTasks[key]?.waiterIDs.insert(waiterID)
    let waiter = T3RelayTaskWaiter<RelayToken>()
    Task { [self] in
      let result = await pending.task.result
      finishRelayTask(result, key: key, taskID: pending.id)
      waiter.resolve(with: result)
      releaseRelayWaiter(key: key, taskID: pending.id, waiterID: waiterID, cancelIfUnused: false)
    }
    return try await withTaskCancellationHandler {
      try await waiter.value()
    } onCancel: {
      waiter.resolve(with: .failure(CancellationError()))
      Task {
        await self.releaseRelayWaiter(
          key: key, taskID: pending.id, waiterID: waiterID, cancelIfUnused: true)
      }
    }
  }

  private func waitForEnvironmentTask(
    _ pending: PendingEnvironmentTask, key: EnvironmentCacheKey
  ) async throws -> T3ConnectEnvironmentAuthorization {
    let waiterID = UUID()
    guard environmentTasks[key]?.id == pending.id else {
      throw T3RelayClientError.staleOperation
    }
    environmentTasks[key]?.waiterIDs.insert(waiterID)
    let waiter = T3RelayTaskWaiter<T3ConnectEnvironmentAuthorization>()
    Task { [self] in
      let result = await pending.task.result
      finishEnvironmentTask(result, key: key, taskID: pending.id)
      waiter.resolve(with: result)
      releaseEnvironmentWaiter(
        key: key, taskID: pending.id, waiterID: waiterID, cancelIfUnused: false)
    }
    return try await withTaskCancellationHandler {
      try await waiter.value()
    } onCancel: {
      waiter.resolve(with: .failure(CancellationError()))
      Task {
        await self.releaseEnvironmentWaiter(
          key: key, taskID: pending.id, waiterID: waiterID, cancelIfUnused: true)
      }
    }
  }

  private func finishRelayTask(
    _ result: Result<RelayToken, any Error>, key: RelayCacheKey, taskID: UUID
  ) {
    guard relayTasks[key]?.id == taskID else { return }
    relayTasks.removeValue(forKey: key)
    if case .success(let token) = result, Self.isCacheable(token.expiresAt, now: now()) {
      relayCache[key] = token
    }
  }

  private func finishEnvironmentTask(
    _ result: Result<T3ConnectEnvironmentAuthorization, any Error>, key: EnvironmentCacheKey,
    taskID: UUID
  ) {
    guard environmentTasks[key]?.id == taskID else { return }
    environmentTasks.removeValue(forKey: key)
    if case .success(let authorization) = result,
      Self.isCacheable(authorization.expiresAt, now: now())
    {
      environmentCache[key] = authorization
    }
  }

  private func releaseRelayWaiter(
    key: RelayCacheKey, taskID: UUID, waiterID: UUID, cancelIfUnused: Bool
  ) {
    guard var pending = relayTasks[key], pending.id == taskID,
      pending.waiterIDs.remove(waiterID) != nil
    else { return }
    if cancelIfUnused, pending.waiterIDs.isEmpty {
      relayTasks.removeValue(forKey: key)
      pending.task.cancel()
    } else {
      relayTasks[key] = pending
    }
  }

  private func releaseEnvironmentWaiter(
    key: EnvironmentCacheKey, taskID: UUID, waiterID: UUID, cancelIfUnused: Bool
  ) {
    guard var pending = environmentTasks[key], pending.id == taskID,
      pending.waiterIDs.remove(waiterID) != nil
    else { return }
    if cancelIfUnused, pending.waiterIDs.isEmpty {
      environmentTasks.removeValue(forKey: key)
      pending.task.cancel()
    } else {
      environmentTasks[key] = pending
    }
  }

  // MARK: Validation and encoding

  private nonisolated static func validate(
    _ environment: T3ConnectEnvironment
  ) throws -> T3ConnectEnvironment {
    guard let environmentID = Self.environmentID(environment.environmentID),
      let label = boundedString(environment.label),
      let providerKind = providerKind(environment.providerKind),
      let httpBaseURL = managedHTTPURL(environment.httpBaseURL.absoluteString),
      let webSocketBaseURL = managedWebSocketURL(
        environment.webSocketBaseURL.absoluteString),
      environment.linkedAt.timeIntervalSince1970.isFinite
    else {
      throw T3ClientError.invalidResponse
    }
    return T3ConnectEnvironment(
      environmentID: environmentID, label: label, httpBaseURL: httpBaseURL,
      webSocketBaseURL: webSocketBaseURL, providerKind: providerKind,
      linkedAt: environment.linkedAt)
  }

  private nonisolated static func accepts(_ state: T3EnvironmentAuthState) -> Bool {
    !state.authenticated
      && boundedWireString(state.auth.policy)
      && boundedWireString(state.auth.sessionCookieName)
      && boundedWireStrings(state.auth.bootstrapMethods, maximumCount: maximumAuthMethods)
      && boundedWireStrings(state.auth.sessionMethods, maximumCount: maximumAuthMethods)
      && state.auth.sessionMethods.contains("dpop-access-token")
  }

  private nonisolated static func boundedWireStrings(
    _ strings: [String], maximumCount: Int
  ) -> Bool {
    strings.count <= maximumCount && strings.allSatisfy(boundedWireString)
  }

  private nonisolated static func boundedWireString(_ value: String) -> Bool {
    value.utf8.count <= maximumStringBytes
  }

  private nonisolated static func boundedString(
    _ value: String, maximumBytes: Int = maximumStringBytes
  ) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed == value, value.utf8.count <= maximumBytes else {
      return nil
    }
    return value
  }

  private nonisolated static func isUsableToken(_ token: String) -> Bool {
    boundedString(token, maximumBytes: T3OAuthRecord.maximumTokenBytes) != nil
  }

  private nonisolated static func environmentID(_ value: String) -> String? {
    guard let value = boundedString(value), value != ".", value != ".." else {
      return nil
    }
    return value
  }

  private nonisolated static func providerKind(_ value: String) -> String? {
    guard let kind = boundedString(value),
      ["manual", "cloudflare_tunnel", "t3_relay"].contains(kind)
    else {
      return nil
    }
    return kind
  }

  private nonisolated static func managedHTTPURL(_ value: String) -> URL? {
    guard value.utf8.count <= maximumURLBytes,
      var components = URLComponents(string: value),
      components.scheme?.lowercased() == "https",
      let host = components.host, !host.isEmpty,
      components.user == nil, components.password == nil,
      components.query == nil, components.fragment == nil,
      validPort(components.port),
      components.path.isEmpty || components.path == "/"
    else {
      return nil
    }
    components.scheme = "https"
    components.path = "/"
    guard T3URLAuthorityCanonicalizer.canonicalize(&components) else { return nil }
    return components.url
  }

  private nonisolated static func managedWebSocketURL(_ value: String) -> URL? {
    guard value.utf8.count <= maximumURLBytes,
      var components = URLComponents(string: value),
      components.scheme?.lowercased() == "wss",
      let host = components.host, !host.isEmpty,
      components.user == nil, components.password == nil,
      components.query == nil, components.fragment == nil,
      validPort(components.port)
    else {
      return nil
    }
    components.scheme = "wss"
    guard T3URLAuthorityCanonicalizer.canonicalize(&components) else { return nil }
    return components.url
  }

  private nonisolated static func normalizedRelayOrigin(_ url: URL) -> String? {
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      components.scheme?.lowercased() == "https",
      let host = components.host, !host.isEmpty,
      components.user == nil, components.password == nil,
      components.query == nil, components.fragment == nil,
      components.path.isEmpty || components.path == "/"
    else {
      return nil
    }
    components.scheme = "https"
    components.path = ""
    guard T3URLAuthorityCanonicalizer.canonicalize(&components) else { return nil }
    return components.url?.absoluteString
  }

  private nonisolated static func relayURL(_ origin: URL, path: String) -> URL? {
    guard let resource = normalizedRelayOrigin(origin) else { return nil }
    return URL(string: resource + path)
  }

  private nonisolated static func validPort(_ port: Int?) -> Bool {
    guard let port else { return true }
    return (1...65_535).contains(port)
  }

  private nonisolated static func percentEncodedPathComponent(_ value: String) -> String? {
    guard let normalized = environmentID(value) else { return nil }
    let hexadecimal = Array("0123456789ABCDEF".utf8)
    var encoded = [UInt8]()
    for byte in normalized.utf8 {
      if (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
        || (byte >= 0x30 && byte <= 0x39) || byte == 0x2D || byte == 0x2E || byte == 0x5F
        || byte == 0x7E
      {
        encoded.append(byte)
      } else {
        encoded.append(0x25)
        encoded.append(hexadecimal[Int(byte >> 4)])
        encoded.append(hexadecimal[Int(byte & 0x0F)])
      }
    }
    return String(decoding: encoded, as: UTF8.self)
  }

  private nonisolated static func hasExactScope(
    _ value: String, expected: Set<String>
  ) -> Bool {
    let bytes = Array(value.utf8)
    guard !bytes.isEmpty, bytes.count <= maximumScopeBytes else { return false }
    var scopes: [String] = []
    var tokenBytes: [UInt8] = []
    for byte in bytes {
      if byte == 0x20 {
        guard !tokenBytes.isEmpty else { return false }
        scopes.append(String(decoding: tokenBytes, as: UTF8.self))
        tokenBytes.removeAll(keepingCapacity: true)
      } else {
        guard byte == 0x21 || (0x23...0x5B).contains(byte) || (0x5D...0x7E).contains(byte)
        else {
          return false
        }
        tokenBytes.append(byte)
      }
    }
    guard !tokenBytes.isEmpty else { return false }
    scopes.append(String(decoding: tokenBytes, as: UTF8.self))
    return scopes.count == expected.count && Set(scopes) == expected
  }

  private nonisolated static func isCacheable(_ expiresAt: Date, now: Date) -> Bool {
    expiresAt.timeIntervalSince(now) > cacheExpiryLeadTime
  }

  private nonisolated static func date(_ value: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
  }

  private nonisolated static func requireSuccess(_ response: T3HTTPResponse) throws {
    if response.statusCode == 401 || response.statusCode == 403 {
      throw T3ClientError.unauthorized
    }
    guard (200..<300).contains(response.statusCode) else {
      throw T3ClientError.http(response.statusCode)
    }
  }

  private nonisolated static func decode<Value: Decodable>(
    _ type: Value.Type, from data: Data
  ) throws -> Value {
    do {
      return try JSONDecoder().decode(type, from: data)
    } catch {
      throw T3ClientError.invalidResponse
    }
  }

  private nonisolated static func formBody(_ fields: [(String, String)]) -> String {
    fields.map { "\(formEncode($0.0))=\(formEncode($0.1))" }.joined(separator: "&")
  }

  private nonisolated static func formEncode(_ value: String) -> String {
    let hexadecimal = Array("0123456789ABCDEF".utf8)
    var encoded = [UInt8]()
    encoded.reserveCapacity(value.utf8.count)
    for byte in value.utf8 {
      if (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
        || (byte >= 0x30 && byte <= 0x39) || byte == 0x2D || byte == 0x2E || byte == 0x5F
        || byte == 0x7E
      {
        encoded.append(byte)
      } else {
        encoded.append(0x25)
        encoded.append(hexadecimal[Int(byte >> 4)])
        encoded.append(hexadecimal[Int(byte & 0x0F)])
      }
    }
    return String(decoding: encoded, as: UTF8.self)
  }

  // MARK: Wire models

  private struct InventoryResponse: Decodable {
    let environments: [WireEnvironment]
  }

  private struct WireEnvironment: Decodable {
    let environmentId: String
    let label: String
    let endpoint: WireEndpoint
    let linkedAt: String
  }

  private struct WireEndpoint: Decodable {
    let httpBaseUrl: String
    let wsBaseUrl: String
    let providerKind: String
  }

  private struct TokenResponse: Decodable {
    let accessToken: String
    let issuedTokenType: String
    let tokenType: String
    let expiresIn: Int
    let scope: String

    enum CodingKeys: String, CodingKey {
      case accessToken = "access_token"
      case issuedTokenType = "issued_token_type"
      case tokenType = "token_type"
      case expiresIn = "expires_in"
      case scope
    }
  }

  private struct ConnectRequest: Encodable {
    let clientProofKeyThumbprint: String
  }

  private struct ConnectResponse: Decodable {
    let environmentId: String
    let endpoint: WireEndpoint
    let credential: String
    let expiresAt: String
  }

  private struct ConnectedEnvironment: Sendable {
    let environmentID: String
    let httpBaseURL: URL
    let webSocketBaseURL: URL
    let providerKind: String
    let credential: String
  }

  private struct RelayToken: Sendable {
    let id: UUID
    let accessToken: String
    let expiresAt: Date
  }

  private struct RelayCacheKey: Hashable, Sendable {
    let grantID: UUID
    let relayOrigin: String
    let clientID: String
    let scope: String
    let thumbprint: String
  }

  private struct EnvironmentCacheKey: Hashable, Sendable {
    let grantID: UUID
    let environmentID: String
    let endpoint: String
    let thumbprint: String
  }

  private struct EnvironmentSelector: Hashable, Sendable {
    let grantID: UUID
    let environmentID: String
  }

  private struct PendingRelayTask: Sendable {
    let id: UUID
    let task: Task<RelayToken, any Error>
    var waiterIDs: Set<UUID>
  }

  private struct PendingEnvironmentTask: Sendable {
    let id: UUID
    let task: Task<T3ConnectEnvironmentAuthorization, any Error>
    var waiterIDs: Set<UUID>
  }
}

private final class T3RelayTaskWaiter<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Value, any Error>?
  private var result: Result<Value, any Error>?

  func value() async throws -> Value {
    try await withCheckedThrowingContinuation { continuation in
      lock.lock()
      if let result {
        lock.unlock()
        continuation.resume(with: result)
      } else {
        self.continuation = continuation
        lock.unlock()
      }
    }
  }

  func resolve(with result: Result<Value, any Error>) {
    lock.lock()
    guard self.result == nil else {
      lock.unlock()
      return
    }
    self.result = result
    let continuation = continuation
    self.continuation = nil
    lock.unlock()
    continuation?.resume(with: result)
  }
}
