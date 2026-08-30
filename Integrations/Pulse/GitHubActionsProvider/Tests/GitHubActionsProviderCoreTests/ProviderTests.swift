import Foundation
import XCTest

@testable import GitHubActionsProviderCore

final class ProviderTests: XCTestCase {
  func testRecordedWorkflowStatesMapToPulseStates() throws {
    let cases: [(String, String, String, Bool)] = [
      ("queued", "active", "normal", false),
      ("running", "progress", "normal", false),
      ("needs-attention", "needsAction", "high", true),
      ("failed", "failed", "critical", true),
      ("cancelled", "cancelled", "low", true),
      ("succeeded", "succeeded", "normal", true),
    ]

    for (fixture, expectedState, expectedPriority, terminal) in cases {
      let run = try XCTUnwrap(try recordedRuns(fixture).first)
      let presentation = RunPresentationBuilder.make(
        run: run, repository: "C-Nucifora/islet", failedJob: nil, canRerun: false,
        activeExpiry: 90, terminalExpiry: 30)
      XCTAssertEqual(presentation.state, expectedState, fixture)
      XCTAssertEqual(presentation.priority, expectedPriority, fixture)
      XCTAssertEqual(presentation.terminal, terminal, fixture)
      XCTAssertEqual(presentation.expiresAfter, terminal ? 30 : 90, fixture)
      XCTAssertEqual(presentation.actions.map(\.title), ["Open run"], fixture)
    }
  }

  func testRecordedFailedJobAndPermissionAddOnlySafeWebActions() throws {
    let run = try XCTUnwrap(try recordedRuns("failed").first)
    let jobs = try decode(WorkflowJobsResponse.self, fixture: "failed-jobs")
    let failedJob = try XCTUnwrap(jobs.jobs.first)
    let presentation = RunPresentationBuilder.make(
      run: run, repository: "C-Nucifora/islet", failedJob: failedJob, canRerun: true,
      activeExpiry: 90, terminalExpiry: 30)

    XCTAssertEqual(
      presentation.actions.map(\.title), ["Open run", "Failed job", "Rerun in GitHub"])
    XCTAssertTrue(presentation.actions.allSatisfy { $0.url.scheme == "https" })
  }

  func testWorkflowSelectionAcceptsNamePathAndIDWithoutDuplicates() throws {
    let runs = try recordedRuns("selection")
    let selected = RunSelector.latest(
      from: runs, workflows: ["CI", ".github/workflows/release.yml", "9001", "missing"])

    XCTAssertEqual(selected.map(\.id), [101, 202])
    XCTAssertEqual(RunSelector.latest(from: runs, workflows: []).map(\.id), [101])
  }

  func testRepositoryAndWorkflowUseOneStableItemAcrossRuns() throws {
    let queued = try XCTUnwrap(try recordedRuns("queued").first)
    let running = try XCTUnwrap(try recordedRuns("running").first)
    let first = RunPresentationBuilder.make(
      run: queued, repository: "C-Nucifora/islet", failedJob: nil, canRerun: false,
      activeExpiry: 90, terminalExpiry: 30)
    let second = RunPresentationBuilder.make(
      run: running, repository: "C-Nucifora/islet", failedJob: nil, canRerun: false,
      activeExpiry: 90, terminalExpiry: 30)

    XCTAssertNotEqual(queued.id, running.id)
    XCTAssertEqual(first.identifier, second.identifier)
  }

  func testRerunAttemptKeepsStableItemAndChangesPresentation() throws {
    let firstRun = try XCTUnwrap(try recordedRuns("queued").first)
    let rerun = try XCTUnwrap(try recordedRuns("rerun-succeeded").first)
    let first = RunPresentationBuilder.make(
      run: firstRun, repository: "C-Nucifora/islet", failedJob: nil, canRerun: false,
      activeExpiry: 90, terminalExpiry: 30)
    let second = RunPresentationBuilder.make(
      run: rerun, repository: "C-Nucifora/islet", failedJob: nil, canRerun: false,
      activeExpiry: 90, terminalExpiry: 30)

    XCTAssertEqual(first.identifier, second.identifier)
    XCTAssertNotEqual(first.subtitle, second.subtitle)
    XCTAssertTrue(second.subtitle.hasSuffix("attempt 2"))
  }

  func testConfigurationSelectsRepositoriesAndRejectsTokens() throws {
    let configuration = try WatchConfiguration.parse([
      "--repo", "C-Nucifora/islet", "--repo", "C-Nucifora/islet",
      "--workflow", "CI", "--poll-seconds", "20", "--max-backoff-seconds", "80", "--once",
    ])

    XCTAssertEqual(configuration.repositories, ["C-Nucifora/islet"])
    XCTAssertEqual(configuration.workflows, ["CI"])
    XCTAssertEqual(configuration.pollInterval, 20)
    XCTAssertEqual(configuration.maximumBackoff, 80)
    XCTAssertTrue(configuration.once)
    XCTAssertThrowsError(
      try WatchConfiguration.parse([
        "--repo", "C-Nucifora/islet", "--token", "secret",
      ]))
  }

  func testBackoffCapsAndResets() {
    var backoff = ExponentialBackoff(initial: 30, maximum: 100)
    XCTAssertEqual(backoff.failureDelay(), 30)
    XCTAssertEqual(backoff.failureDelay(), 60)
    XCTAssertEqual(backoff.failureDelay(), 100)
    XCTAssertEqual(backoff.failureDelay(), 100)
    backoff.reset()
    XCTAssertEqual(backoff.failureDelay(), 30)
  }

  func testFailuresClassifyWithoutRetainingErrorText() {
    XCTAssertEqual(classification("HTTP 401: authentication required"), .authentication)
    XCTAssertEqual(classification("API rate limit exceeded"), .rateLimited)
    XCTAssertEqual(classification("connection reset by peer"), .offline)
  }

  func testGitHubClientUsesGhCredentialStoreAndNeverPassesToken() throws {
    let runner = RecordingRunner(results: [
      CommandResult(status: 0, stdout: try fixtureData("queued"), stderr: Data())
    ])
    let runs = try GitHubClient(runner: runner).workflowRuns(repository: "C-Nucifora/islet")

    XCTAssertEqual(runs.map(\.id), [101])
    let invocation = try XCTUnwrap(runner.invocations.first)
    XCTAssertEqual(invocation.executable, "/usr/bin/env")
    XCTAssertEqual(invocation.arguments.prefix(4), ["gh", "api", "--method", "GET"])
    XCTAssertFalse(invocation.arguments.contains { $0.lowercased().contains("token") })
  }

  func testPulsePublisherUsesStableSourceExpiryAndBoundedActions() throws {
    let runner = RecordingRunner(results: [
      CommandResult(status: 0, stdout: Data(), stderr: Data())
    ])
    let run = try XCTUnwrap(try recordedRuns("succeeded").first)
    let presentation = RunPresentationBuilder.make(
      run: run, repository: "C-Nucifora/islet", failedJob: nil, canRerun: true,
      activeExpiry: 90, terminalExpiry: 30)
    try PulsePublisher(runner: runner, pulseCLI: "Tools/islet-pulse.swift").publish(presentation)

    let arguments = try XCTUnwrap(runner.invocations.first?.arguments)
    XCTAssertTrue(arguments.contains("github-actions"))
    XCTAssertTrue(arguments.contains("--expires"))
    XCTAssertTrue(arguments.contains("30"))
    XCTAssertEqual(arguments.filter { $0 == "--action" }.count, 2)
  }

  func testRepeatedHealthFailurePublishesOnceAndDoesNotExpireBeforeRecovery() throws {
    let runner = RecordingRunner(results: [
      CommandResult(status: 0, stdout: Data(), stderr: Data())
    ])
    let configuration = WatchConfiguration(repositories: ["C-Nucifora/islet"])
    let watcher = GitHubActionsWatcher(configuration: configuration, runner: runner)

    try watcher.reportHealth(.rateLimited)
    try watcher.reportHealth(.rateLimited)

    XCTAssertEqual(runner.invocations.count, 1)
    let arguments = try XCTUnwrap(runner.invocations.first?.arguments)
    XCTAssertFalse(arguments.contains("--expires"))
    XCTAssertTrue(arguments.contains("needsAction"))
  }

  func testCompletedRunPublishesOnceAndStopsDetailPolling() throws {
    let failedRuns = try fixtureData("failed")
    let failedJobs = try fixtureData("failed-jobs")
    let permission = try fixtureData("repository-permission")
    let success = CommandResult(status: 0, stdout: Data(), stderr: Data())
    let runner = RecordingRunner(results: [
      CommandResult(status: 0, stdout: failedRuns, stderr: Data()),
      CommandResult(status: 0, stdout: failedJobs, stderr: Data()),
      CommandResult(status: 0, stdout: permission, stderr: Data()),
      success,
      CommandResult(status: 0, stdout: failedRuns, stderr: Data()),
    ])
    let configuration = WatchConfiguration(repositories: ["C-Nucifora/islet"], once: true)
    let watcher = GitHubActionsWatcher(configuration: configuration, runner: runner)

    try watcher.poll(now: Date(timeIntervalSince1970: 1_000))
    try watcher.poll(now: Date(timeIntervalSince1970: 1_030))

    XCTAssertEqual(
      runner.invocations.filter { invocation in
        invocation.arguments.contains { $0.hasSuffix("/jobs") }
      }.count, 1)
    XCTAssertEqual(
      runner.invocations.filter { $0.arguments.contains("github-actions") }.count, 1)
    XCTAssertEqual(runner.invocations.count, 5)
  }

  private func classification(_ error: String) -> ProviderFailure {
    CommandFailureClassifier.classify(
      CommandResult(status: 1, stdout: Data(), stderr: Data(error.utf8)))
  }

  private func recordedRuns(_ name: String) throws -> [WorkflowRun] {
    try decode(WorkflowRunsResponse.self, fixture: name).workflowRuns
  }

  private func decode<T: Decodable>(_ type: T.Type, fixture: String) throws -> T {
    try JSONDecoder().decode(type, from: fixtureData(fixture))
  }

  private func fixtureData(_ name: String) throws -> Data {
    let url = try XCTUnwrap(
      Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
  }
}

private final class RecordingRunner: CommandRunning {
  struct Invocation {
    let executable: String
    let arguments: [String]
  }

  private var results: [CommandResult]
  private(set) var invocations: [Invocation] = []

  init(results: [CommandResult]) {
    self.results = results
  }

  func run(executable: String, arguments: [String]) throws -> CommandResult {
    invocations.append(Invocation(executable: executable, arguments: arguments))
    return results.removeFirst()
  }
}
