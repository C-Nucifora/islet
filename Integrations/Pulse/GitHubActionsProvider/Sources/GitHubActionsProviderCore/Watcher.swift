import Foundation

public final class GitHubActionsWatcher<Runner: CommandRunning> {
  private let configuration: WatchConfiguration
  private let client: GitHubClient<Runner>
  private let publisher: PulsePublisher<Runner>
  private var completedRunAttempts: [String: String] = [:]
  private var lastPresentations: [String: PulsePresentation] = [:]
  private var lastPublishedAt: [String: Date] = [:]
  private var rerunPermissions: [String: Bool] = [:]
  private var currentHealth: ProviderFailure?

  public init(configuration: WatchConfiguration, runner: Runner) {
    self.configuration = configuration
    client = GitHubClient(runner: runner)
    publisher = PulsePublisher(runner: runner, pulseCLI: configuration.pulseCLI)
  }

  public func run() throws {
    var backoff = ExponentialBackoff(
      initial: configuration.pollInterval, maximum: configuration.maximumBackoff)
    while true {
      do {
        try poll(now: Date())
        backoff.reset()
        if configuration.once { return }
        Thread.sleep(forTimeInterval: configuration.pollInterval)
      } catch ProviderError.commandFailed(let failure) {
        try reportHealth(failure)
        if configuration.once { throw ProviderError.commandFailed(failure) }
        Thread.sleep(forTimeInterval: backoff.failureDelay())
      } catch ProviderError.invalidResponse {
        try reportHealth(.offline)
        if configuration.once { throw ProviderError.invalidResponse }
        Thread.sleep(forTimeInterval: backoff.failureDelay())
      }
    }
  }

  public func poll(now: Date) throws {
    for repository in configuration.repositories {
      let runs = try client.workflowRuns(
        repository: repository, workflows: configuration.workflows)
      let latestRuns =
        configuration.workflows.isEmpty ? Array(runs.prefix(1)) : runs
      for run in latestRuns {
        let runAttempt = "\(run.id)#\(run.runAttempt)"
        let itemScope =
          configuration.workflows.isEmpty
          ? repository : "\(repository)#\(run.workflowID)"
        guard completedRunAttempts[itemScope] != runAttempt else { continue }
        let terminal = run.status == "completed"
        let failedJob =
          terminal && isFailure(run)
          ? try client.failedJob(repository: repository, runID: run.id) : nil
        let canRerun = terminal ? try rerunPermission(repository: repository) : false
        let presentation = RunPresentationBuilder.make(
          run: run, repository: repository,
          identifierScope: itemScope,
          failedJob: failedJob, canRerun: canRerun,
          activeExpiry: configuration.activeExpiry,
          terminalExpiry: configuration.terminalExpiry)
        if shouldPublish(presentation, now: now) {
          try publisher.publish(presentation)
          lastPresentations[presentation.identifier] = presentation
          lastPublishedAt[presentation.identifier] = now
        }
        if presentation.terminal { completedRunAttempts[itemScope] = runAttempt }
      }
    }
    if currentHealth != nil {
      try publisher.end(identifier: "github-actions-health")
      currentHealth = nil
    }
  }

  private func shouldPublish(_ presentation: PulsePresentation, now: Date) -> Bool {
    guard lastPresentations[presentation.identifier] == presentation else { return true }
    guard !presentation.terminal, let last = lastPublishedAt[presentation.identifier] else {
      return false
    }
    return now.timeIntervalSince(last) >= presentation.expiresAfter / 2
  }

  private func rerunPermission(repository: String) throws -> Bool {
    if let cached = rerunPermissions[repository] { return cached }
    let permission = try client.canRerun(repository: repository)
    rerunPermissions[repository] = permission
    return permission
  }

  private func isFailure(_ run: WorkflowRun) -> Bool {
    ["failure", "timed_out", "startup_failure"].contains(run.conclusion ?? "")
  }

  func reportHealth(_ failure: ProviderFailure) throws {
    guard currentHealth != failure else { return }
    try publisher.publish(RunPresentationBuilder.health(failure))
    currentHealth = failure
  }
}
