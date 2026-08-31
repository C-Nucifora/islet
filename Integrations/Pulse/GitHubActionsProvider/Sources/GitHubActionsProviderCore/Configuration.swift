import Foundation

public struct WatchConfiguration: Equatable, Sendable {
  public static let defaultPollInterval: TimeInterval = 30
  public static let defaultMaximumBackoff: TimeInterval = 15 * 60
  public static let defaultTerminalExpiry: TimeInterval = 30

  public var repositories: [String]
  public var workflows: [String]
  public var pollInterval: TimeInterval
  public var maximumBackoff: TimeInterval
  public var terminalExpiry: TimeInterval
  public var once: Bool
  public var pulseCLI: String

  public init(
    repositories: [String],
    workflows: [String] = [],
    pollInterval: TimeInterval = Self.defaultPollInterval,
    maximumBackoff: TimeInterval = Self.defaultMaximumBackoff,
    terminalExpiry: TimeInterval = Self.defaultTerminalExpiry,
    once: Bool = false,
    pulseCLI: String = "Tools/islet-pulse.swift"
  ) {
    self.repositories = repositories
    self.workflows = workflows
    self.pollInterval = pollInterval
    self.maximumBackoff = maximumBackoff
    self.terminalExpiry = terminalExpiry
    self.once = once
    self.pulseCLI = pulseCLI
  }

  public var activeExpiry: TimeInterval { max(60, pollInterval * 3) }

  public static func parse(_ arguments: [String]) throws -> Self {
    var configuration = Self(repositories: [])
    var index = 0
    while index < arguments.count {
      let argument = arguments[index]
      switch argument {
      case "--repo":
        configuration.repositories.append(try value(after: argument, at: &index, in: arguments))
      case "--workflow":
        configuration.workflows.append(try value(after: argument, at: &index, in: arguments))
      case "--poll-seconds":
        configuration.pollInterval = try seconds(
          value(after: argument, at: &index, in: arguments), option: argument, range: 15...3_600)
      case "--max-backoff-seconds":
        configuration.maximumBackoff = try seconds(
          value(after: argument, at: &index, in: arguments), option: argument,
          range: 15...86_400)
      case "--terminal-expires-seconds":
        configuration.terminalExpiry = try seconds(
          value(after: argument, at: &index, in: arguments), option: argument,
          range: 2...86_400)
      case "--pulse-cli":
        configuration.pulseCLI = try value(after: argument, at: &index, in: arguments)
      case "--once":
        configuration.once = true
      case "--token", "--github-token":
        throw ProviderError.invalidArguments(
          "Do not pass a token. This provider uses the credentials already stored by gh.")
      default:
        throw ProviderError.invalidArguments("Unknown option: \(argument)")
      }
      index += 1
    }

    configuration.repositories = try orderedUnique(
      configuration.repositories.map(validatedRepository))
    configuration.workflows = orderedUnique(
      configuration.workflows.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty })
    guard !configuration.repositories.isEmpty else {
      throw ProviderError.invalidArguments("At least one --repo OWNER/REPOSITORY is required.")
    }
    guard configuration.maximumBackoff >= configuration.pollInterval else {
      throw ProviderError.invalidArguments(
        "--max-backoff-seconds must be at least --poll-seconds.")
    }
    return configuration
  }

  private static func value(
    after option: String, at index: inout Int, in arguments: [String]
  ) throws -> String {
    index += 1
    guard index < arguments.count else {
      throw ProviderError.invalidArguments("\(option) requires a value.")
    }
    return arguments[index]
  }

  private static func seconds(
    _ rawValue: String, option: String, range: ClosedRange<TimeInterval>
  ) throws -> TimeInterval {
    guard let value = TimeInterval(rawValue), value.isFinite, range.contains(value) else {
      throw ProviderError.invalidArguments(
        "\(option) must be from \(Int(range.lowerBound)) through \(Int(range.upperBound)).")
    }
    return value
  }

  private static func validatedRepository(_ rawValue: String) throws -> String {
    let repository = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    let parts = repository.split(separator: "/", omittingEmptySubsequences: false)
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
    guard
      parts.count == 2,
      parts.allSatisfy({
        !$0.isEmpty && $0.unicodeScalars.allSatisfy { allowed.contains($0) }
      })
    else {
      throw ProviderError.invalidArguments(
        "Invalid repository '\(rawValue)'. Use OWNER/REPOSITORY.")
    }
    return repository
  }

  private static func orderedUnique<T: Hashable>(_ values: [T]) -> [T] {
    var seen = Set<T>()
    return values.filter { seen.insert($0).inserted }
  }
}

public struct ExponentialBackoff: Equatable, Sendable {
  private let initial: TimeInterval
  private let maximum: TimeInterval
  private(set) public var current: TimeInterval

  public init(initial: TimeInterval, maximum: TimeInterval) {
    self.initial = initial
    self.maximum = maximum
    current = initial
  }

  public mutating func failureDelay() -> TimeInterval {
    let delay = current
    current = min(maximum, current * 2)
    return delay
  }

  public mutating func reset() {
    current = initial
  }
}
