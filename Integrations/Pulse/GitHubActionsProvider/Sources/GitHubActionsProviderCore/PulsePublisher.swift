import Foundation

public struct PulsePublisher<Runner: CommandRunning> {
  private let runner: Runner
  private let pulseCLI: String

  public init(runner: Runner, pulseCLI: String) {
    self.runner = runner
    self.pulseCLI = pulseCLI
  }

  public func publish(_ presentation: PulsePresentation) throws {
    var arguments = [
      "swift", pulseCLI, presentation.operation.rawValue, presentation.identifier,
      presentation.title, presentation.subtitle,
      "--source", "github-actions",
      "--state", presentation.state,
      "--priority", presentation.priority,
    ]
    if presentation.expiresAfter > 0 {
      arguments.append(contentsOf: ["--expires", seconds(presentation.expiresAfter)])
    }
    for action in presentation.actions.prefix(3) {
      arguments.append(contentsOf: ["--action", action.title, action.url.absoluteString])
    }
    let result = try runner.run(executable: "/usr/bin/env", arguments: arguments)
    guard result.status == 0 else { throw ProviderError.pulseRejected }
  }

  public func end(identifier: String) throws {
    let result = try runner.run(
      executable: "/usr/bin/env",
      arguments: [
        "swift", pulseCLI, "end", identifier, "--source", "github-actions",
      ])
    guard result.status == 0 else { throw ProviderError.pulseRejected }
  }

  private func seconds(_ value: TimeInterval) -> String {
    String(Int(value.rounded()))
  }
}
