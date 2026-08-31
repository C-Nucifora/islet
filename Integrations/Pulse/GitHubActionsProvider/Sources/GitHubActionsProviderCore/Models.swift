import Foundation

public struct WorkflowRunsResponse: Decodable, Sendable {
  public let workflowRuns: [WorkflowRun]

  enum CodingKeys: String, CodingKey {
    case workflowRuns = "workflow_runs"
  }
}

struct WorkflowsResponse: Decodable, Sendable {
  let totalCount: Int
  let workflows: [WorkflowSummary]

  enum CodingKeys: String, CodingKey {
    case totalCount = "total_count"
    case workflows
  }
}

struct WorkflowSummary: Decodable, Equatable, Sendable {
  let id: Int64
  let name: String
  let path: String
}

public struct WorkflowRun: Decodable, Equatable, Sendable {
  public let id: Int64
  public let name: String
  public let workflowID: Int64
  public let path: String
  public let status: String
  public let conclusion: String?
  public let htmlURL: URL
  public let headBranch: String?
  public let event: String
  public let runAttempt: Int

  enum CodingKeys: String, CodingKey {
    case id, name, path, status, conclusion, event
    case workflowID = "workflow_id"
    case htmlURL = "html_url"
    case headBranch = "head_branch"
    case runAttempt = "run_attempt"
  }
}

public struct WorkflowJobsResponse: Decodable, Sendable {
  public let jobs: [WorkflowJob]
}

public struct WorkflowJob: Decodable, Equatable, Sendable {
  public let name: String
  public let conclusion: String?
  public let htmlURL: URL

  enum CodingKeys: String, CodingKey {
    case name, conclusion
    case htmlURL = "html_url"
  }
}

struct RepositoryResponse: Decodable {
  let permissions: RepositoryPermissions?
}

struct RepositoryPermissions: Decodable {
  let push: Bool
}

public struct PulseLink: Equatable, Sendable {
  public let title: String
  public let url: URL

  public init(title: String, url: URL) {
    self.title = title
    self.url = url
  }
}

public struct PulsePresentation: Equatable, Sendable {
  public enum Operation: String, Sendable {
    case show
    case update
    case event
  }

  public let operation: Operation
  public let identifier: String
  public let title: String
  public let subtitle: String
  public let state: String
  public let priority: String
  public let symbol: String
  public let expiresAfter: TimeInterval
  public let actions: [PulseLink]
  public let terminal: Bool

  public init(
    operation: Operation,
    identifier: String,
    title: String,
    subtitle: String,
    state: String,
    priority: String,
    symbol: String,
    expiresAfter: TimeInterval,
    actions: [PulseLink],
    terminal: Bool
  ) {
    self.operation = operation
    self.identifier = identifier
    self.title = title
    self.subtitle = subtitle
    self.state = state
    self.priority = priority
    self.symbol = symbol
    self.expiresAfter = expiresAfter
    self.actions = actions
    self.terminal = terminal
  }
}

public enum ProviderFailure: Equatable, Sendable {
  case authentication
  case rateLimited
  case offline

  public var healthTitle: String {
    switch self {
    case .authentication: "GitHub authentication required"
    case .rateLimited: "GitHub API rate limit reached"
    case .offline: "GitHub Actions watcher is offline"
    }
  }

  public var healthSubtitle: String {
    switch self {
    case .authentication: "Run gh auth login, then leave the watcher running."
    case .rateLimited: "The watcher will retry with backoff."
    case .offline: "Check the network connection. The watcher will retry with backoff."
    }
  }
}

public struct CommandResult: Equatable, Sendable {
  public let status: Int32
  public let stdout: Data
  public let stderr: Data

  public init(status: Int32, stdout: Data, stderr: Data) {
    self.status = status
    self.stdout = stdout
    self.stderr = stderr
  }
}

public protocol CommandRunning {
  func run(executable: String, arguments: [String]) throws -> CommandResult
}

public enum ProviderError: LocalizedError, Equatable {
  case invalidArguments(String)
  case commandFailed(ProviderFailure)
  case invalidResponse
  case pulseRejected

  public var errorDescription: String? {
    switch self {
    case .invalidArguments(let message): message
    case .commandFailed(let failure): failure.healthTitle
    case .invalidResponse: "GitHub returned an invalid workflow response"
    case .pulseRejected: "Islet rejected the Pulse update"
    }
  }
}
