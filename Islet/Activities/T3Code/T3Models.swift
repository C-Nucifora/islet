import Defaults
import Foundation

struct T3EnvironmentProfile: Codable, Defaults.Serializable, Equatable, Identifiable, Sendable {
  let id: String
  var label: String
  var baseURL: String
  var enabled: Bool

  init(id: String, label: String, baseURL: String, enabled: Bool = true) {
    self.id = id
    self.label = label
    self.baseURL = baseURL
    self.enabled = enabled
  }
}

struct T3EnvironmentDescriptor: Decodable, Equatable, Sendable {
  struct Platform: Decodable, Equatable, Sendable {
    let os: String?
    let arch: String?
  }

  let environmentId: String
  let label: String
  let platform: Platform?
  let serverVersion: String?
}

struct T3ShellSnapshot: Decodable, Equatable, Sendable {
  let snapshotSequence: Int?
  let projects: [T3ProjectShell]
  let threads: [T3ThreadShell]
  let updatedAt: String?
}

struct T3ProjectShell: Decodable, Equatable, Sendable {
  let id: String
  let title: String
  let workspaceRoot: String?
}

struct T3ModelSelection: Decodable, Equatable, Sendable {
  let instanceId: String
  let model: String
}

struct T3LatestTurn: Decodable, Equatable, Sendable {
  let turnId: String?
  let state: String
  let requestedAt: String?
  let startedAt: String?
  let completedAt: String?
}

struct T3PlanProgress: Decodable, Equatable, Sendable {
  let step: String
  let completedSteps: Int
  let totalSteps: Int
}

struct T3Session: Decodable, Equatable, Sendable {
  let status: String
  let providerName: String?
  let providerInstanceId: String?
  let lastError: String?
}

struct T3ThreadShell: Decodable, Equatable, Sendable {
  let id: String
  let projectId: String
  let title: String
  let modelSelection: T3ModelSelection
  let runtimeMode: String?
  let interactionMode: String?
  let branch: String?
  let worktreePath: String?
  let latestTurn: T3LatestTurn?
  let createdAt: String?
  let updatedAt: String
  let archivedAt: String?
  let settledAt: String?
  let session: T3Session?
  let latestUserMessageAt: String?
  let hasPendingApprovals: Bool
  let hasPendingUserInput: Bool
  let hasActionableProposedPlan: Bool?
  let backgroundLiveness: String?
  let planProgress: T3PlanProgress?
}

enum T3AgentPhase: String, Codable, Sendable {
  case needsInput
  case needsApproval
  case working
  case monitoring
  case finished
  case failed

  var label: String {
    switch self {
    case .needsInput: "Needs input"
    case .needsApproval: "Needs approval"
    case .working: "Working"
    case .monitoring: "Monitoring"
    case .finished: "Finished"
    case .failed: "Failed"
    }
  }

  var symbol: String {
    switch self {
    case .needsInput: "questionmark.bubble.fill"
    case .needsApproval: "hand.raised.fill"
    case .working: "bolt.fill"
    case .monitoring: "eye.fill"
    case .finished: "checkmark.circle.fill"
    case .failed: "exclamationmark.triangle.fill"
    }
  }

  var rank: Int {
    switch self {
    case .needsInput, .needsApproval: 0
    case .working: 1
    case .monitoring: 2
    case .failed: 3
    case .finished: 4
    }
  }
}

struct T3AgentSnapshot: Equatable, Identifiable, Sendable {
  private static let maximumFutureClockSkew: TimeInterval = 5 * 60

  let environmentID: String
  let threadID: String
  let title: String
  let project: String
  let providerInstance: String
  let model: String
  let branch: String?
  let phase: T3AgentPhase
  let planStep: String?
  let completedPlanSteps: Int?
  let totalPlanSteps: Int?
  let updatedAt: Date

  var id: String { "\(environmentID):\(threadID)" }

  static func activeAgents(
    in shell: T3ShellSnapshot,
    environmentID: String,
    now: Date = Date()
  ) -> [Self] {
    // The shell snapshot is server-controlled. Keep the first project for a duplicated id rather
    // than using `Dictionary(uniqueKeysWithValues:)`, which traps and takes down the app.
    let projects = shell.projects.reduce(into: [String: String]()) { projects, project in
      if projects[project.id] == nil { projects[project.id] = project.title }
    }
    return shell.threads.compactMap { thread in
      guard thread.archivedAt == nil,
        let phase = phase(for: thread, now: now)
      else { return nil }
      return Self(
        environmentID: environmentID,
        threadID: thread.id,
        title: thread.title,
        project: projects[thread.projectId] ?? "Unknown project",
        providerInstance: thread.session?.providerName
          ?? thread.session?.providerInstanceId
          ?? thread.modelSelection.instanceId,
        model: thread.modelSelection.model,
        branch: thread.branch,
        phase: phase,
        planStep: thread.planProgress?.step,
        completedPlanSteps: thread.planProgress?.completedSteps,
        totalPlanSteps: thread.planProgress?.totalSteps,
        updatedAt: parseDate(thread.updatedAt) ?? .distantPast)
    }
    .sorted {
      if $0.phase.rank != $1.phase.rank { return $0.phase.rank < $1.phase.rank }
      return $0.updatedAt > $1.updatedAt
    }
  }

  private static func phase(for thread: T3ThreadShell, now: Date) -> T3AgentPhase? {
    if thread.hasPendingUserInput { return .needsInput }
    if thread.hasPendingApprovals || thread.hasActionableProposedPlan == true {
      return .needsApproval
    }
    if thread.session?.status == "error" || thread.latestTurn?.state == "error" {
      let updated = parseDate(thread.updatedAt) ?? .distantPast
      return isRecent(updated, now: now, retention: 30 * 60) ? .failed : nil
    }
    if ["starting", "running"].contains(thread.session?.status ?? "")
      || thread.latestTurn?.state == "running" || thread.backgroundLiveness == "working"
    {
      return .working
    }
    if thread.backgroundLiveness == "monitoring" { return .monitoring }

    let updated = parseDate(thread.updatedAt) ?? .distantPast
    let completedTurn =
      thread.latestTurn?.state == "completed"
      || (thread.latestTurn?.state == "interrupted" && thread.latestTurn?.completedAt != nil)
    let readySession = ["ready", "idle"].contains(thread.session?.status ?? "")
    if completedTurn || readySession,
      thread.settledAt == nil, isRecent(updated, now: now, retention: 10 * 60)
    {
      return .finished
    }
    return nil
  }

  private static func isRecent(_ date: Date, now: Date, retention: TimeInterval) -> Bool {
    let age = now.timeIntervalSince(date)
    return age >= -maximumFutureClockSkew && age < retention
  }

  private static func parseDate(_ value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
  }
}

enum T3ConnectionState: Equatable, Sendable {
  case connecting
  case connected
  case offline(String)
  case needsPairing

  var label: String {
    switch self {
    case .connecting: "Connecting"
    case .connected: "Connected"
    case .offline: "Offline"
    case .needsPairing: "Pair again"
    }
  }
}

struct T3EnvironmentSnapshot: Equatable, Identifiable, Sendable {
  let id: String
  let label: String
  let baseURL: String
  let isLocal: Bool
  let platform: String?
  let serverVersion: String?
  let state: T3ConnectionState
  let agents: [T3AgentSnapshot]
}
