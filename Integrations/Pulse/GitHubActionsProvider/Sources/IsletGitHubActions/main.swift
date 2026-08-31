import Foundation
import GitHubActionsProviderCore

private let usage = """
  usage:
    islet-github-actions watch --repo OWNER/REPOSITORY [--repo ...] [options]
    islet-github-actions rerun --repo OWNER/REPOSITORY --run RUN_ID [--failed]

  watch options:
    --workflow NAME|PATH|ID        Watch only selected workflows (repeatable)
    --poll-seconds SECONDS        Poll interval, 15...3600 (default: 30)
    --max-backoff-seconds SECONDS Maximum offline/rate-limit backoff (default: 900)
    --terminal-expires-seconds N  Completed item lifetime, 2...86400 (default: 30)
    --pulse-cli PATH              Path to Tools/islet-pulse.swift
    --once                        Poll once, useful for launchd and testing

  Authentication comes only from gh. Run `gh auth login` before starting the watcher.
  """

private func fail(_ message: String, status: Int32 = 64) -> Never {
  FileHandle.standardError.write(Data("\(message)\n".utf8))
  exit(status)
}

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.isEmpty || arguments == ["--help"] || arguments == ["-h"] {
  FileHandle.standardOutput.write(Data("\(usage)\n".utf8))
  exit(0)
}

do {
  switch arguments[0] {
  case "watch":
    let configuration = try WatchConfiguration.parse(Array(arguments.dropFirst()))
    try GitHubActionsWatcher(configuration: configuration, runner: ProcessRunner()).run()
  case "rerun":
    var repository: String?
    var runID: Int64?
    var failedOnly = false
    var index = 1
    while index < arguments.count {
      switch arguments[index] {
      case "--repo":
        index += 1
        guard index < arguments.count else { fail("--repo requires a value") }
        repository = arguments[index]
      case "--run":
        index += 1
        guard index < arguments.count, let parsed = Int64(arguments[index]), parsed > 0 else {
          fail("--run requires a positive run ID")
        }
        runID = parsed
      case "--failed":
        failedOnly = true
      default:
        fail("Unknown rerun option: \(arguments[index])")
      }
      index += 1
    }
    guard let repository, let runID else { fail("rerun requires --repo and --run") }
    let validated = try WatchConfiguration.parse(["--repo", repository, "--once"])
    try GitHubClient(runner: ProcessRunner()).rerun(
      repository: validated.repositories[0], runID: runID, failedOnly: failedOnly)
  default:
    fail(usage)
  }
} catch {
  fail(error.localizedDescription, status: 1)
}
