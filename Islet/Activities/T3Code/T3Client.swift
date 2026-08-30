import Darwin
import Foundation
import Security

enum T3ClientError: Error, LocalizedError, Sendable {
  case invalidURL
  case unsupportedScheme
  case credentialsInURL
  case insecureRemoteHTTP
  case unapprovedInsecureRemoteHTTP
  case environmentIdentityConflict
  case missingPairingToken
  case invalidResponse
  case responseTooLarge
  case requestTimedOut
  case untrustedLocalEndpoint
  case unauthorized
  case http(Int)

  var errorDescription: String? {
    switch self {
    case .invalidURL: "That is not a valid T3 Code URL."
    case .unsupportedScheme: "T3 Code endpoints must use HTTP or HTTPS."
    case .credentialsInURL: "Usernames and passwords are not allowed in an endpoint URL."
    case .insecureRemoteHTTP: "Remote T3 Code machines must use HTTPS."
    case .unapprovedInsecureRemoteHTTP:
      "This build does not approve plain HTTP for that T3 Code address. Pair it over HTTPS."
    case .environmentIdentityConflict:
      "That T3 Code machine reports an identity already used by a different endpoint."
    case .missingPairingToken: "The pairing link has no one-time token."
    case .invalidResponse: "T3 Code returned an unreadable response."
    case .responseTooLarge: "T3 Code returned more data than Islet accepts."
    case .requestTimedOut: "T3 Code did not finish the request before the deadline."
    case .untrustedLocalEndpoint:
      "The local endpoint is not owned by a trusted T3 Code app or CLI process. Pairing was not attempted."
    case .unauthorized: "This T3 Code credential is no longer authorized."
    case .http(let status): "T3 Code returned HTTP \(status)."
    }
  }
}

struct T3TransportPolicy: Sendable {
  nonisolated static let approvedOriginsInfoKey = "T3ApprovedInsecureHTTPOrigins"
  nonisolated static let app = T3TransportPolicy(
    infoDictionary: Bundle.main.infoDictionary ?? [:])

  private let approvedInsecureRemoteOrigins: Set<String>

  nonisolated init(infoDictionary: [String: Any]) {
    let configuredOrigins = infoDictionary[Self.approvedOriginsInfoKey] as? [String] ?? []
    let exceptionDomains =
      (infoDictionary["NSAppTransportSecurity"] as? [String: Any])?["NSExceptionDomains"]
      as? [String: Any] ?? [:]
    let approvedHosts = Set(
      exceptionDomains.compactMap { host, value -> String? in
        guard let settings = value as? [String: Any],
          settings["NSExceptionAllowsInsecureHTTPLoads"] as? Bool == true,
          settings["NSIncludesSubdomains"] as? Bool != true
        else { return nil }
        return host.lowercased()
      })
    approvedInsecureRemoteOrigins = Set(
      configuredOrigins.compactMap { value in
        guard let url = URL(string: value), let origin = Self.remoteHTTPOrigin(url),
          let host = url.host?.lowercased(), approvedHosts.contains(host)
        else { return nil }
        return origin
      })
  }

  nonisolated func permitsInsecureRemoteHTTP(_ url: URL) -> Bool {
    guard let origin = Self.remoteHTTPOrigin(url) else { return false }
    return approvedInsecureRemoteOrigins.contains(origin)
  }

  nonisolated func requiresHTTPSMigration(_ url: URL) -> Bool {
    guard url.scheme?.lowercased() == "http", !T3Endpoint.isLoopbackHost(url.host) else {
      return false
    }
    return !permitsInsecureRemoteHTTP(url)
  }

  nonisolated private static func remoteHTTPOrigin(_ url: URL) -> String? {
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      components.scheme?.lowercased() == "http",
      let host = components.host, !host.isEmpty,
      !T3Endpoint.isLoopbackHost(host),
      components.user == nil, components.password == nil
    else { return nil }
    components.scheme = "http"
    components.host = host.lowercased()
    components.path = "/"
    components.query = nil
    components.fragment = nil
    return components.url?.absoluteString
  }
}

struct T3Endpoint: Equatable, Sendable {
  let baseURL: URL

  var isLoopback: Bool {
    Self.isLoopbackHost(baseURL.host)
  }

  init(
    _ url: URL,
    allowInsecureRemoteHTTP: Bool = false,
    transportPolicy: T3TransportPolicy = .app
  ) throws {
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      let scheme = components.scheme?.lowercased(),
      scheme == "http" || scheme == "https",
      let host = components.host, !host.isEmpty
    else { throw T3ClientError.invalidURL }
    guard components.user == nil, components.password == nil else {
      throw T3ClientError.credentialsInURL
    }
    let loopback = Self.isLoopbackHost(host)
    if scheme == "http", !loopback, !allowInsecureRemoteHTTP {
      throw T3ClientError.insecureRemoteHTTP
    }
    if scheme == "http", !loopback, !transportPolicy.permitsInsecureRemoteHTTP(url) {
      throw T3ClientError.unapprovedInsecureRemoteHTTP
    }
    components.scheme = scheme
    components.path = "/"
    components.query = nil
    components.fragment = nil
    guard let canonical = components.url else { throw T3ClientError.invalidURL }
    baseURL = canonical
  }

  init(host: String = "127.0.0.1", port: Int = 3773) {
    var components = URLComponents()
    components.scheme = "http"
    components.host = host
    components.port = port
    components.path = "/"
    baseURL = components.url!
  }

  func url(_ path: String) -> URL {
    baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
  }

  nonisolated static func isLoopbackHost(_ host: String?) -> Bool {
    guard let host else { return false }
    let normalized = host.lowercased().trimmingCharacters(
      in: CharacterSet(charactersIn: "[]"))
    return ["127.0.0.1", "::1", "localhost"].contains(normalized)
  }
}

struct T3PairingTarget: Equatable, Sendable {
  let endpoint: T3Endpoint
  let credential: String

  static func parse(
    _ text: String,
    allowInsecureRemoteHTTP: Bool = false,
    transportPolicy: T3TransportPolicy = .app
  ) throws -> Self {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let link = URL(string: trimmed),
      let linkComponents = URLComponents(url: link, resolvingAgainstBaseURL: false)
    else { throw T3ClientError.invalidURL }

    let fragmentValues = formValues(linkComponents.fragment)
    let queryValues = (linkComponents.queryItems ?? []).reduce(into: [String: String]()) {
      values, item in
      if let value = item.value { values[item.name] = value }
    }
    guard let credential = fragmentValues["token"] ?? queryValues["token"], !credential.isEmpty
    else { throw T3ClientError.missingPairingToken }

    let endpointURL: URL
    if link.host?.lowercased() == "app.t3.codes", link.path == "/pair" {
      guard let host = queryValues["host"], let parsed = URL(string: host) else {
        throw T3ClientError.invalidURL
      }
      endpointURL = parsed
    } else {
      endpointURL = link
    }
    return try Self(
      endpoint: T3Endpoint(
        endpointURL,
        allowInsecureRemoteHTTP: allowInsecureRemoteHTTP,
        transportPolicy: transportPolicy),
      credential: credential)
  }

  private static func formValues(_ encoded: String?) -> [String: String] {
    guard let encoded else { return [:] }
    return encoded.split(separator: "&").reduce(into: [String: String]()) { values, pair in
      let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      guard parts.count == 2 else { return }
      let key = String(parts[0]).removingPercentEncoding ?? String(parts[0])
      let value = String(parts[1]).removingPercentEncoding ?? String(parts[1])
      values[key] = value
    }
  }
}

enum T3RedirectPolicy {
  /// T3 requests may carry a one-time pairing credential or a bearer token. Do not replay either
  /// after a redirect, even when the proposed destination appears to share the endpoint origin.
  nonisolated static func requestToFollow(
    _ request: URLRequest,
    from response: HTTPURLResponse
  ) -> URLRequest? {
    nil
  }
}

struct T3TokenExchange: Decodable, Sendable {
  let accessToken: String
  let tokenType: String
  let expiresIn: Double
  let scope: String

  private enum CodingKeys: String, CodingKey {
    case accessToken = "access_token"
    case tokenType = "token_type"
    case expiresIn = "expires_in"
    case scope
  }
}

struct T3Client: Sendable {
  let endpoint: T3Endpoint
  let authorization: T3Authorization
  let session: URLSession?

  init(endpoint: T3Endpoint, token: String?, session: URLSession? = nil) {
    self.endpoint = endpoint
    authorization = token.map(T3Authorization.bearer) ?? .none
    self.session = session
  }

  init(
    endpoint: T3Endpoint,
    authorization: T3Authorization,
    session: URLSession? = nil
  ) {
    self.endpoint = endpoint
    self.authorization = authorization
    self.session = session
  }

  func fetchDescriptor(timeoutInterval: TimeInterval = 5) async throws -> T3EnvironmentDescriptor {
    try await get(
      ".well-known/t3/environment", as: T3EnvironmentDescriptor.self, authorized: false,
      timeoutInterval: timeoutInterval)
  }

  func fetchShell() async throws -> T3ShellSnapshot {
    try await get("api/orchestration/shell", as: T3ShellSnapshot.self, authorized: true)
  }

  func exchange(pairingCredential: String) async throws -> T3TokenExchange {
    let fields = [
      ("grant_type", "urn:ietf:params:oauth:grant-type:token-exchange"),
      ("subject_token", pairingCredential),
      ("subject_token_type", "urn:t3:params:oauth:token-type:environment-bootstrap"),
      ("requested_token_type", "urn:ietf:params:oauth:token-type:access_token"),
      ("scope", "orchestration:read"),
      ("client_label", "Islet"),
      ("client_device_type", "desktop"),
      ("client_os", "macOS"),
    ]
    var request = URLRequest(url: endpoint.url("oauth/token"))
    request.httpMethod = "POST"
    request.timeoutInterval = 10
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.httpBody = Self.formEncode(fields)
    return try await perform(request, as: T3TokenExchange.self, authorization: .none)
  }

  private func get<T: Decodable>(
    _ path: String, as type: T.Type, authorized: Bool, timeoutInterval: TimeInterval = 5
  ) async throws -> T {
    var request = URLRequest(url: endpoint.url(path))
    request.timeoutInterval = timeoutInterval
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    return try await perform(request, as: type, authorization: authorized ? authorization : .none)
  }

  private func perform<T: Decodable>(
    _ request: URLRequest, as type: T.Type, authorization: T3Authorization
  ) async throws -> T {
    let origin = try T3HTTPOrigin(
      endpoint.baseURL, allowInsecureHTTP: endpoint.baseURL.scheme == "http")
    let response = try await T3HTTPTransport(session: session).send(
      request,
      authorization: authorization,
      expectedOrigin: origin,
      deadline: request.timeoutInterval)
    if response.statusCode == 401 || response.statusCode == 403 {
      throw T3ClientError.unauthorized
    }
    guard (200..<300).contains(response.statusCode) else {
      throw T3ClientError.http(response.statusCode)
    }
    do {
      return try JSONDecoder().decode(type, from: response.data)
    } catch {
      throw T3ClientError.invalidResponse
    }
  }

  private static func formEncode(_ fields: [(String, String)]) -> Data {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    let body = fields.map { key, value in
      let escapedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
      let escapedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
      return "\(escapedKey)=\(escapedValue)"
    }.joined(separator: "&")
    return Data(body.utf8)
  }
}

struct T3LocalRuntime: Equatable, Sendable {
  let endpoint: T3Endpoint
  let processID: Int32
}

enum T3LocalDiscovery {
  private static let runtimeURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".t3/userdata/server-runtime.json")

  static func endpoint() async -> T3Endpoint? {
    guard let runtime = trustedRuntime(), await reachable(runtime.endpoint) else { return nil }
    return runtime.endpoint
  }

  static func isTrusted(_ endpoint: T3Endpoint) -> Bool {
    guard endpoint.isLoopback, let port = endpoint.baseURL.port,
      let trusted = trustedRuntime()
    else { return false }
    return trusted.endpoint.baseURL.port == port
  }

  private static func reachable(_ endpoint: T3Endpoint) async -> Bool {
    (try? await T3Client(endpoint: endpoint, token: nil).fetchDescriptor(timeoutInterval: 1.5))
      != nil
  }

  /// A listening port is T3 Code only when its public descriptor succeeds and decodes. Treating a
  /// 404 from an unrelated service as reachable would suppress the runtime-file fallback.
  nonisolated static func acceptsDiscoveryResponse(data: Data, statusCode: Int) -> Bool {
    (200..<300).contains(statusCode)
      && (try? JSONDecoder().decode(T3EnvironmentDescriptor.self, from: data)) != nil
  }

  nonisolated static func runtime(from data: Data) -> T3LocalRuntime? {
    struct WireRuntime: Decodable {
      let origin: String
      let pid: Int
      let port: Int
    }
    guard let wire = try? JSONDecoder().decode(WireRuntime.self, from: data),
      (1...65_535).contains(wire.port),
      (1...Int(Int32.max)).contains(wire.pid),
      let origin = URL(string: wire.origin),
      let endpoint = try? T3Endpoint(origin),
      endpoint.isLoopback,
      endpoint.baseURL.port == wire.port
    else { return nil }
    return T3LocalRuntime(endpoint: endpoint, processID: Int32(wire.pid))
  }

  private static func trustedRuntime() -> T3LocalRuntime? {
    var fileInfo = stat()
    guard lstat(runtimeURL.path, &fileInfo) == 0,
      (fileInfo.st_mode & S_IFMT) == S_IFREG,
      fileInfo.st_uid == getuid(),
      (fileInfo.st_mode & (S_IWGRP | S_IWOTH)) == 0,
      let data = try? Data(contentsOf: runtimeURL),
      let runtime = runtime(from: data), let port = runtime.endpoint.baseURL.port,
      processIsOwnedByCurrentUser(runtime.processID),
      isSignedT3Code(processID: runtime.processID)
        || isT3CLI(processID: runtime.processID),
      process(runtime.processID, ownsListeningTCPPort: port)
    else { return nil }
    return runtime
  }

  nonisolated private static func isSignedT3Code(processID: Int32) -> Bool {
    let attributes =
      [
        kSecGuestAttributePid as String: NSNumber(value: processID)
      ] as CFDictionary
    let flags = SecCSFlags(rawValue: 0)
    var code: SecCode?
    guard SecCodeCopyGuestWithAttributes(nil, attributes, flags, &code) == errSecSuccess,
      let code
    else { return false }

    var requirement: SecRequirement?
    let requirementText =
      "anchor apple generic and identifier \"com.t3tools.t3code\" and certificate leaf[subject.OU] = \"ARK85ZXQ4Z\""
      as CFString
    guard SecRequirementCreateWithString(requirementText, flags, &requirement) == errSecSuccess,
      let requirement
    else { return false }
    return SecCodeCheckValidity(code, flags, requirement) == errSecSuccess
  }

  nonisolated static func acceptsT3CLILaunch(
    executablePath: String,
    arguments: [String],
    entryPointPath: String,
    packageName: String,
    declaredBin: String
  ) -> Bool {
    let executable = URL(fileURLWithPath: executablePath).standardizedFileURL
    let entryPoint = URL(fileURLWithPath: entryPointPath).standardizedFileURL
    let packageRoot = entryPoint.deletingLastPathComponent().deletingLastPathComponent()
    guard executable.lastPathComponent == "node",
      packageName == "t3",
      packageRoot.lastPathComponent == "t3",
      packageRoot.deletingLastPathComponent().lastPathComponent == "node_modules"
    else { return false }

    let declaredEntryPoint = packageRoot.appendingPathComponent(declaredBin).standardizedFileURL
    guard declaredEntryPoint.path == entryPoint.path,
      arguments.indices.contains(2),
      URL(fileURLWithPath: arguments[1]).standardizedFileURL.path == entryPoint.path,
      arguments[2] == "serve"
    else { return false }
    return true
  }

  nonisolated private static func isT3CLI(processID: Int32) -> Bool {
    guard let executablePath = processPath(processID),
      let arguments = processArguments(processID),
      arguments.indices.contains(1),
      arguments[1].hasSuffix("/t3/dist/bin.mjs")
    else { return false }

    let executable = URL(fileURLWithPath: executablePath).resolvingSymlinksInPath()
    let entryPoint = URL(fileURLWithPath: arguments[1]).resolvingSymlinksInPath()
    let packageRoot = entryPoint.deletingLastPathComponent().deletingLastPathComponent()
    let manifestURL = packageRoot.appendingPathComponent("package.json")
    guard secureRegularFile(executable.path),
      secureRegularFile(entryPoint.path),
      secureRegularFile(manifestURL.path),
      let data = try? Data(contentsOf: manifestURL),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let packageName = object["name"] as? String,
      let declaredBin = (object["bin"] as? String)
        ?? (object["bin"] as? [String: String])?["t3"]
    else { return false }

    return acceptsT3CLILaunch(
      executablePath: executable.path,
      arguments: arguments,
      entryPointPath: entryPoint.path,
      packageName: packageName,
      declaredBin: declaredBin)
  }

  nonisolated private static func processIsOwnedByCurrentUser(_ processID: Int32) -> Bool {
    var info = proc_bsdinfo()
    let size = MemoryLayout<proc_bsdinfo>.stride
    let result = withUnsafeMutablePointer(to: &info) {
      proc_pidinfo(processID, PROC_PIDTBSDINFO, 0, $0, Int32(size))
    }
    return result == size && info.pbi_uid == getuid()
  }

  nonisolated private static func processPath(_ processID: Int32) -> String? {
    var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    let count = proc_pidpath(processID, &buffer, UInt32(buffer.count))
    guard count > 0 else { return nil }
    let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return String(decoding: bytes, as: UTF8.self)
  }

  nonisolated private static func processArguments(_ processID: Int32) -> [String]? {
    var mib = [CTL_KERN, KERN_PROCARGS2, processID]
    var size = 0
    guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0,
      size > MemoryLayout<Int32>.size
    else { return nil }

    var buffer = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, u_int(mib.count), &buffer, &size, nil, 0) == 0 else { return nil }
    let argumentCount = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
    guard argumentCount > 0 else { return nil }

    var index = MemoryLayout<Int32>.size
    func consumeString() -> String? {
      guard index < size else { return nil }
      let start = index
      while index < size, buffer[index] != 0 { index += 1 }
      guard index < size else { return nil }
      let value = String(decoding: buffer[start..<index], as: UTF8.self)
      index += 1
      return value
    }

    guard consumeString() != nil else { return nil }
    while index < size, buffer[index] == 0 { index += 1 }
    var arguments: [String] = []
    for _ in 0..<argumentCount {
      guard let argument = consumeString() else { return nil }
      arguments.append(argument)
    }
    return arguments
  }

  nonisolated private static func secureRegularFile(_ path: String) -> Bool {
    var fileInfo = stat()
    guard lstat(path, &fileInfo) == 0,
      (fileInfo.st_mode & S_IFMT) == S_IFREG,
      fileInfo.st_uid == 0 || fileInfo.st_uid == getuid(),
      (fileInfo.st_mode & (S_IWGRP | S_IWOTH)) == 0
    else { return false }
    return true
  }

  nonisolated private static func process(
    _ processID: Int32, ownsListeningTCPPort port: Int
  ) -> Bool {
    let estimatedBytes = proc_pidinfo(processID, PROC_PIDLISTFDS, 0, nil, 0)
    guard estimatedBytes > 0 else { return false }
    let stride = MemoryLayout<proc_fdinfo>.stride
    var descriptors = [proc_fdinfo](
      repeating: proc_fdinfo(), count: max(1, Int(estimatedBytes) / stride))
    let returnedBytes = descriptors.withUnsafeMutableBytes {
      proc_pidinfo(processID, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
    }
    guard returnedBytes > 0 else { return false }

    let expectedPort = UInt16(port)
    for descriptor in descriptors.prefix(Int(returnedBytes) / stride)
    where descriptor.proc_fdtype == PROX_FDTYPE_SOCKET {
      var socket = socket_fdinfo()
      let result = withUnsafeMutablePointer(to: &socket) {
        proc_pidfdinfo(
          processID, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, $0,
          Int32(MemoryLayout<socket_fdinfo>.stride))
      }
      guard result == MemoryLayout<socket_fdinfo>.stride,
        socket.psi.soi_kind == SOCKINFO_TCP
      else { continue }
      let tcp = socket.psi.soi_proto.pri_tcp
      let localPort = UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport))
      if tcp.tcpsi_state == TSI_S_LISTEN, localPort == expectedPort { return true }
    }
    return false
  }
}
