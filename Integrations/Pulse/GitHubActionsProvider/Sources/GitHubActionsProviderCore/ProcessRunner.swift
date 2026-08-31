import Foundation

public struct ProcessRunner: CommandRunning {
  public init() {}

  public func run(executable: String, arguments: [String]) throws -> CommandResult {
    let process = Process()
    let standardOutput = Pipe()
    let standardError = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    var environment = ProcessInfo.processInfo.environment
    for key in ["GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN"] {
      environment[key] = nil
    }
    process.environment = environment
    process.standardOutput = standardOutput
    process.standardError = standardError
    try process.run()

    let outputCapture = PipeCapture()
    let errorCapture = PipeCapture()
    let readers = DispatchGroup()
    readers.enter()
    DispatchQueue.global(qos: .utility).async {
      outputCapture.read(standardOutput.fileHandleForReading)
      readers.leave()
    }
    readers.enter()
    DispatchQueue.global(qos: .utility).async {
      errorCapture.read(standardError.fileHandleForReading)
      readers.leave()
    }
    process.waitUntilExit()
    readers.wait()
    return CommandResult(
      status: process.terminationStatus, stdout: outputCapture.data, stderr: errorCapture.data)
  }
}

private final class PipeCapture: @unchecked Sendable {
  private(set) var data = Data()

  func read(_ handle: FileHandle) {
    data = handle.readDataToEndOfFile()
  }
}

public enum CommandFailureClassifier {
  public static func classify(_ result: CommandResult) -> ProviderFailure {
    let error = String(decoding: result.stderr, as: UTF8.self).lowercased()
    if error.contains("rate limit") || error.contains("http 429")
      || error.contains("secondary rate")
    {
      return .rateLimited
    }
    if error.contains("authentication") || error.contains("not logged")
      || error.contains("gh auth login") || error.contains("http 401")
    {
      return .authentication
    }
    return .offline
  }
}
