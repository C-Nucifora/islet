import Foundation

struct T3HTTPOrigin: Equatable, Sendable {
  private let scheme: String
  private let host: String
  private let port: Int

  init(_ url: URL, allowInsecureHTTP: Bool = false) throws {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      let scheme = components.scheme?.lowercased(),
      let host = components.host?.lowercased(), !host.isEmpty,
      components.user == nil, components.password == nil,
      components.query == nil, components.fragment == nil,
      scheme == "https" || scheme == "http"
    else { throw T3ClientError.invalidURL }
    guard scheme == "https" || allowInsecureHTTP else {
      throw T3ClientError.insecureRemoteHTTP
    }

    self.scheme = scheme
    self.host = host
    port = Self.effectivePort(for: scheme, port: components.port)
  }

  func contains(_ url: URL) -> Bool {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      let candidateScheme = components.scheme?.lowercased(),
      let candidateHost = components.host?.lowercased(), !candidateHost.isEmpty,
      components.user == nil, components.password == nil
    else { return false }
    return candidateScheme == scheme
      && candidateHost == host
      && Self.effectivePort(for: candidateScheme, port: components.port) == port
  }

  private static func effectivePort(for scheme: String, port: Int?) -> Int {
    if let port { return port }
    return scheme == "https" ? 443 : 80
  }
}

struct T3HTTPResponse: Sendable {
  let data: Data
  let statusCode: Int
  let headers: [String: String]
}

struct T3HTTPTransport: Sendable {
  static let maximumResponseBytes = 2 * 1024 * 1024
  static let shared = T3HTTPTransport()

  let session: URLSession

  init(session: URLSession? = nil) {
    if let session {
      self.session = session
    } else {
      let configuration = URLSessionConfiguration.ephemeral
      configuration.httpCookieStorage = nil
      configuration.httpShouldSetCookies = false
      configuration.urlCache = nil
      configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
      self.session = URLSession(configuration: configuration)
    }
  }

  func send(
    _ request: URLRequest,
    authorization: T3Authorization = .none,
    expectedOrigin: T3HTTPOrigin,
    deadline: TimeInterval
  ) async throws -> T3HTTPResponse {
    guard let url = request.url, expectedOrigin.contains(url) else {
      throw T3ClientError.invalidURL
    }

    let totalDeadline = max(0, deadline)
    return try await withThrowingTaskGroup(of: T3HTTPResponse.self) { group in
      group.addTask {
        var authorizedRequest = request
        Self.isolate(&authorizedRequest)
        try await Self.apply(authorization, to: &authorizedRequest)
        return try await response(for: authorizedRequest, session: session)
      }
      group.addTask {
        try await Task.sleep(for: .seconds(totalDeadline))
        throw T3ClientError.requestTimedOut
      }
      defer { group.cancelAll() }
      guard let response = try await group.next() else {
        throw T3ClientError.invalidResponse
      }
      return response
    }
  }

  static func acceptsResponseGrowth(currentBytes: Int, additionalBytes: Int) -> Bool {
    currentBytes >= 0 && additionalBytes >= 0
      && currentBytes <= maximumResponseBytes - additionalBytes
  }

  private static func isolate(_ request: inout URLRequest) {
    request.httpShouldHandleCookies = false
    request.setValue(nil, forHTTPHeaderField: "Cookie")
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.setValue("no-store, no-cache", forHTTPHeaderField: "Cache-Control")
    request.setValue("no-cache", forHTTPHeaderField: "Pragma")
  }

  private static func apply(_ authorization: T3Authorization, to request: inout URLRequest)
    async throws
  {
    switch authorization {
    case .none:
      return
    case .bearer(let token):
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    case .dpop(let accessToken, let signer):
      guard let url = request.url else { throw T3ClientError.invalidURL }
      let proof = try await signer.proof(
        method: request.httpMethod ?? "GET", url: url, accessToken: accessToken)
      request.setValue("DPoP \(accessToken)", forHTTPHeaderField: "Authorization")
      request.setValue(proof, forHTTPHeaderField: "DPoP")
    }
  }

  private func response(for request: URLRequest, session: URLSession) async throws -> T3HTTPResponse
  {
    let (bytes, response) = try await session.bytes(
      for: request, delegate: T3NoRedirectDelegate.shared)
    guard let http = response as? HTTPURLResponse else {
      throw T3ClientError.invalidResponse
    }
    if response.expectedContentLength > Int64(Self.maximumResponseBytes) {
      throw T3ClientError.responseTooLarge
    }

    var data = Data()
    data.reserveCapacity(
      min(max(0, Int(response.expectedContentLength)), Self.maximumResponseBytes))
    for try await byte in bytes {
      try Task.checkCancellation()
      guard Self.acceptsResponseGrowth(currentBytes: data.count, additionalBytes: 1) else {
        throw T3ClientError.responseTooLarge
      }
      data.append(byte)
    }
    return T3HTTPResponse(
      data: data,
      statusCode: http.statusCode,
      headers: Self.headers(from: http))
  }

  private static func headers(from response: HTTPURLResponse) -> [String: String] {
    response.allHeaderFields.reduce(into: [:]) { headers, field in
      headers[String(describing: field.key).lowercased()] = String(describing: field.value)
    }
  }
}

private final class T3NoRedirectDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  static let shared = T3NoRedirectDelegate()

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }

  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    willCacheResponse proposedResponse: CachedURLResponse,
    completionHandler: @escaping @Sendable (CachedURLResponse?) -> Void
  ) {
    completionHandler(nil)
  }
}
