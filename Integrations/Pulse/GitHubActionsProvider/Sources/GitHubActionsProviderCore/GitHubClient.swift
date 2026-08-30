import Foundation

public struct GitHubClient<Runner: CommandRunning> {
  private let runner: Runner
  private let decoder = JSONDecoder()

  public init(runner: Runner) {
    self.runner = runner
  }

  public func workflowRuns(repository: String) throws -> [WorkflowRun] {
    let result = try ghAPI("repos/\(repository)/actions/runs", fields: ["per_page=100"])
    do {
      return try decoder.decode(WorkflowRunsResponse.self, from: result).workflowRuns
    } catch {
      throw ProviderError.invalidResponse
    }
  }

  public func failedJob(repository: String, runID: Int64) throws -> WorkflowJob? {
    let result = try ghAPI(
      "repos/\(repository)/actions/runs/\(runID)/jobs", fields: ["per_page=100"])
    do {
      return try decoder.decode(WorkflowJobsResponse.self, from: result).jobs.first {
        ["failure", "timed_out", "startup_failure"].contains($0.conclusion ?? "")
      }
    } catch {
      throw ProviderError.invalidResponse
    }
  }

  public func canRerun(repository: String) throws -> Bool {
    let result = try ghAPI("repos/\(repository)")
    do {
      return try decoder.decode(RepositoryResponse.self, from: result).permissions?.push == true
    } catch {
      throw ProviderError.invalidResponse
    }
  }

  public func rerun(repository: String, runID: Int64, failedOnly: Bool) throws {
    var arguments = ["gh", "run", "rerun", String(runID), "--repo", repository]
    if failedOnly { arguments.append("--failed") }
    let result = try runner.run(executable: "/usr/bin/env", arguments: arguments)
    guard result.status == 0 else {
      throw ProviderError.commandFailed(CommandFailureClassifier.classify(result))
    }
  }

  private func ghAPI(_ endpoint: String, fields: [String] = []) throws -> Data {
    var arguments = ["gh", "api", "--method", "GET", endpoint]
    for field in fields {
      arguments.append(contentsOf: ["-f", field])
    }
    let result = try runner.run(executable: "/usr/bin/env", arguments: arguments)
    guard result.status == 0 else {
      throw ProviderError.commandFailed(CommandFailureClassifier.classify(result))
    }
    return result.stdout
  }
}

public enum RunSelector {
  public static func latest(from runs: [WorkflowRun], workflows: [String]) -> [WorkflowRun] {
    guard !workflows.isEmpty else { return Array(runs.prefix(1)) }
    var selected: [WorkflowRun] = []
    var selectedIDs = Set<Int64>()
    for workflow in workflows {
      let normalized = workflow.lowercased()
      guard
        let run = runs.first(where: {
          $0.name.lowercased() == normalized || $0.path.lowercased() == normalized
            || String($0.workflowID) == workflow
        }), selectedIDs.insert(run.id).inserted
      else { continue }
      selected.append(run)
    }
    return selected
  }
}
