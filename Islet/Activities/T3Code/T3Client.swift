import Darwin
import Foundation

enum T3ClientError: Error, LocalizedError, Sendable {
  case invalidURL
  case unsupportedScheme
  case credentialsInURL
  case insecureRemoteHTTP
  case environmentIdentityConflict
  case missingPairingToken
  case invalidResponse
  case unauthorized
  case http(Int)
  case tokenMintFailed(String)
  case tokenMintTimedOut

  var errorDescription: String? {
    switch self {
    case .invalidURL: "That is not a valid T3 Code URL."
    case .unsupportedScheme: "T3 Code endpoints must use HTTP or HTTPS."
    case .credentialsInURL: "Usernames and passwords are not allowed in an endpoint URL."
    case .insecureRemoteHTTP: "Remote T3 Code machines must use HTTPS."
    case .environmentIdentityConflict:
      "That T3 Code machine reports an identity already used by a different endpoint."
    case .missingPairingToken: "The pairing link has no one-time token."
    case .invalidResponse: "T3 Code returned an unreadable response."
    case .unauthorized: "This T3 Code credential is no longer authorized."
    case .http(let status): "T3 Code returned HTTP \(status)."
    case .tokenMintFailed(let message): message
    case .tokenMintTimedOut: "T3 Code did not issue a local pairing token within 15 seconds."
    }
  }
}

struct T3Endpoint: Equatable, Sendable {
  let baseURL: URL

  init(_ url: URL, allowInsecureRemoteHTTP: Bool = false) throws {
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      let scheme = components.scheme?.lowercased(),
      scheme == "http" || scheme == "https",
      let host = components.host, !host.isEmpty
    else { throw T3ClientError.invalidURL }
    guard components.user == nil, components.password == nil else {
      throw T3ClientError.credentialsInURL
    }
    let loopback = ["127.0.0.1", "::1", "localhost"].contains(host.lowercased())
    if scheme == "http", !loopback, !allowInsecureRemoteHTTP {
      throw T3ClientError.insecureRemoteHTTP
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
}

struct T3PairingTarget: Equatable, Sendable {
  let endpoint: T3Endpoint
  let credential: String

  static func parse(_ text: String, allowInsecureRemoteHTTP: Bool = false) throws -> Self {
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
      endpoint: T3Endpoint(endpointURL, allowInsecureRemoteHTTP: allowInsecureRemoteHTTP),
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
  let token: String?

  func fetchDescriptor() async throws -> T3EnvironmentDescriptor {
    try await get(".well-known/t3/environment", as: T3EnvironmentDescriptor.self, authorized: false)
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
    return try await perform(request, as: T3TokenExchange.self)
  }

  private func get<T: Decodable>(
    _ path: String, as type: T.Type, authorized: Bool
  ) async throws -> T {
    var request = URLRequest(url: endpoint.url(path))
    request.timeoutInterval = 5
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if authorized, let token {
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
    return try await perform(request, as: type)
  }

  private func perform<T: Decodable>(_ request: URLRequest, as type: T.Type) async throws -> T {
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw T3ClientError.invalidResponse }
    if http.statusCode == 401 || http.statusCode == 403 { throw T3ClientError.unauthorized }
    guard (200..<300).contains(http.statusCode) else { throw T3ClientError.http(http.statusCode) }
    do {
      return try JSONDecoder().decode(type, from: data)
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

enum T3LocalDiscovery {
  static func endpoint() async -> T3Endpoint {
    let primary = T3Endpoint()
    if await reachable(primary) { return primary }
    if let port = runtimePort() {
      let fallback = T3Endpoint(port: port)
      if await reachable(fallback) { return fallback }
    }
    return primary
  }

  private static func reachable(_ endpoint: T3Endpoint) async -> Bool {
    var request = URLRequest(url: endpoint.url(".well-known/t3/environment"))
    request.timeoutInterval = 1.5
    do {
      let (data, response) = try await URLSession.shared.data(for: request)
      guard let http = response as? HTTPURLResponse else { return false }
      return acceptsDiscoveryResponse(data: data, statusCode: http.statusCode)
    } catch { return false }
  }

  /// A listening port is T3 Code only when its public descriptor succeeds and decodes. Treating a
  /// 404 from an unrelated service as reachable would suppress the runtime-file fallback.
  nonisolated static func acceptsDiscoveryResponse(data: Data, statusCode: Int) -> Bool {
    (200..<300).contains(statusCode)
      && (try? JSONDecoder().decode(T3EnvironmentDescriptor.self, from: data)) != nil
  }

  private static func runtimePort() -> Int? {
    let url = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".t3/userdata/server-runtime.json")
    guard let data = try? Data(contentsOf: url),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    return object["port"] as? Int
  }
}

enum T3LocalPairingMinting {
  private struct Output: Decodable {
    let credential: String
  }

  static func mint() async throws -> String {
    let worker = Task.detached(priority: .utility) {
      let process = Process()
      guard let executable = executableURL() else {
        throw T3ClientError.tokenMintFailed(
          "The T3 Code command-line tool is not installed. Install it or pair this Mac from T3 Code, then reconnect.")
      }
      process.executableURL = executable
      process.arguments = [
        "auth", "pairing", "create", "--json", "--ttl", "2m", "--label", "Islet",
      ]
      process.standardInput = FileHandle.nullDevice
      let stdout = Pipe()
      let stderr = Pipe()
      process.standardOutput = stdout
      process.standardError = stderr
      do { try process.run() } catch {
        throw T3ClientError.tokenMintFailed("Could not run the T3 Code pairing command.")
      }
      defer { if process.isRunning { terminate(process) } }

      // Drain both pipes while the child runs. Waiting first can deadlock once either pipe fills.
      let stdoutHandle = SendableFileHandle(stdout.fileHandleForReading)
      let stderrHandle = SendableFileHandle(stderr.fileHandleForReading)
      let stdoutTask = Task.detached(priority: .utility) {
        stdoutHandle.value.readDataToEndOfFile()
      }
      let stderrTask = Task.detached(priority: .utility) {
        stderrHandle.value.readDataToEndOfFile()
      }
      let deadline = ProcessInfo.processInfo.systemUptime + 15
      while process.isRunning {
        if Task.isCancelled {
          terminate(process)
          _ = await stdoutTask.value
          _ = await stderrTask.value
          throw CancellationError()
        }
        if ProcessInfo.processInfo.systemUptime >= deadline {
          terminate(process)
          _ = await stdoutTask.value
          _ = await stderrTask.value
          throw T3ClientError.tokenMintTimedOut
        }
        try await Task.sleep(for: .milliseconds(50))
      }
      let outputData = await stdoutTask.value
      let errorData = await stderrTask.value
      let output = String(data: outputData, encoding: .utf8) ?? ""
      let error = String(data: errorData, encoding: .utf8) ?? ""
      guard process.terminationStatus == 0 else {
        let detail = error.trimmingCharacters(in: .whitespacesAndNewlines)
        throw T3ClientError.tokenMintFailed(
          detail.isEmpty ? "T3 Code could not issue a local pairing token." : detail)
      }
      guard let data = output.data(using: .utf8),
        let credential = try? JSONDecoder().decode(Output.self, from: data).credential,
        !credential.isEmpty
      else { throw T3ClientError.tokenMintFailed("T3 Code returned no local pairing token.") }
      return credential
    }
    return try await withTaskCancellationHandler {
      try await worker.value
    } onCancel: {
      worker.cancel()
    }
  }

  nonisolated static func candidateExecutablePaths(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> [String] {
    let fromPath = (environment["PATH"] ?? "")
      .split(separator: ":")
      .map { String($0) + "/t3" }
    var seen: Set<String> = []
    return (fromPath + ["/opt/homebrew/bin/t3", "/usr/local/bin/t3"])
      .filter { seen.insert($0).inserted }
  }

  private static func executableURL() -> URL? {
    candidateExecutablePaths().first {
      FileManager.default.isExecutableFile(atPath: $0)
    }.map(URL.init(fileURLWithPath:))
  }

  private static func terminate(_ process: Process) {
    guard process.isRunning else { return }
    process.terminate()
    let deadline = ProcessInfo.processInfo.systemUptime + 0.25
    while process.isRunning, ProcessInfo.processInfo.systemUptime < deadline {
      Thread.sleep(forTimeInterval: 0.01)
    }
    if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
  }
}

private final class SendableFileHandle: @unchecked Sendable {
  let value: FileHandle
  init(_ value: FileHandle) { self.value = value }
}
