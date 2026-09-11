#!/usr/bin/env swift
import Darwin
import Foundation

private let usage = """
  usage: islet-xcode-pulse.swift [options] -- <xcodebuild arguments>

  options:
    --id ID                 Stable suffix for this build's Pulse item
    --label TEXT            Display name (defaults to the scheme or project name)
    --project-url URL       Safe HTTP(S) action labelled Open project
    --report-url URL        Safe HTTP(S) action labelled Open report
    --failure-url URL       Safe HTTP(S) action labelled Open failure on failure

  Example:
    swift Tools/islet-xcode-pulse.swift --label Islet -- \
      -project Islet.xcodeproj -scheme Islet build

  The wrapper runs xcodebuild unchanged, mirrors its output, and returns its exit status.
  """ + "\n"

private enum ProviderError: LocalizedError {
  case usage(String)

  var errorDescription: String? {
    switch self {
    case .usage(let message): message
    }
  }
}

private struct Options {
  let identifier: String
  let label: String
  let projectURL: String?
  let reportURL: String?
  let failureURL: String?
  let xcodebuildArguments: [String]
  let isTest: Bool

  static func parse(_ arguments: [String]) throws -> Self {
    if arguments == ["--help"] || arguments == ["-h"] {
      FileHandle.standardOutput.write(Data(usage.utf8))
      exit(0)
    }
    guard let separator = arguments.firstIndex(of: "--"), separator < arguments.count - 1 else {
      throw ProviderError.usage("xcodebuild arguments must follow --\n\(usage)")
    }

    var identifier: String?
    var label: String?
    var projectURL: String?
    var reportURL: String?
    var failureURL: String?
    var index = 0
    while index < separator {
      let option = arguments[index]
      guard index + 1 < separator else {
        throw ProviderError.usage("\(option) requires a value")
      }
      let value = arguments[index + 1]
      switch option {
      case "--id":
        let clean = Sanitizer.text(value, limit: 96)
        guard !clean.isEmpty else { throw ProviderError.usage("--id must not be empty") }
        identifier = clean.replacingOccurrences(
          of: "[^A-Za-z0-9._-]", with: "-", options: .regularExpression)
      case "--label":
        let clean = Sanitizer.text(value, limit: 120)
        guard !clean.isEmpty else { throw ProviderError.usage("--label must not be empty") }
        label = clean
      case "--project-url": projectURL = try safeWebURL(value, option: option)
      case "--report-url": reportURL = try safeWebURL(value, option: option)
      case "--failure-url": failureURL = try safeWebURL(value, option: option)
      default: throw ProviderError.usage("unknown provider option: \(option)")
      }
      index += 2
    }

    let buildArguments = Array(arguments[(separator + 1)...])
    let inferredLabel = label ?? inferLabel(from: buildArguments)
    let suffix = identifier ?? UUID().uuidString.lowercased()
    let commands = Set(["test", "test-without-building"])
    return Self(
      identifier: "xcode-\(suffix)", label: inferredLabel,
      projectURL: projectURL, reportURL: reportURL, failureURL: failureURL,
      xcodebuildArguments: buildArguments,
      isTest: buildArguments.contains { commands.contains($0.lowercased()) })
  }

  private static func inferLabel(from arguments: [String]) -> String {
    for flag in ["-scheme", "-project", "-workspace"] {
      guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
        continue
      }
      let name = URL(fileURLWithPath: arguments[index + 1]).deletingPathExtension()
        .lastPathComponent
      let clean = Sanitizer.text(name, limit: 120)
      if !clean.isEmpty { return clean }
    }
    return "Xcode"
  }

  private static func safeWebURL(_ raw: String, option: String) throws -> String {
    guard raw.count <= 2_048, let url = URL(string: raw),
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
      components.host?.isEmpty == false, components.user == nil, components.password == nil
    else {
      throw ProviderError.usage("\(option) requires a safe HTTP(S) URL without credentials")
    }
    return url.absoluteString
  }
}

private enum Sanitizer {
  private static let whitespaceExpression = try! NSRegularExpression(pattern: "\\s+")

  static func text(_ raw: String, limit: Int) -> String {
    enum EscapeState {
      case normal
      case escape
      case controlSequence
      case controlString
      case controlStringEscape
    }

    var printable = ""
    var escapeState = EscapeState.normal
    for scalar in raw.unicodeScalars {
      switch escapeState {
      case .normal:
        if scalar.value == 0x1B {
          escapeState = .escape
        } else if CharacterSet.controlCharacters.contains(scalar) || scalar == "\u{2028}"
          || scalar == "\u{2029}"
        {
          printable.append(" ")
        } else {
          printable.unicodeScalars.append(scalar)
        }
      case .escape:
        if scalar == "[" {
          escapeState = .controlSequence
        } else if ["]", "P", "X", "^", "_"].contains(scalar) {
          escapeState = .controlString
        } else if (0x30...0x7E).contains(scalar.value) {
          escapeState = .normal
        }
      case .controlSequence:
        if (0x40...0x7E).contains(scalar.value) { escapeState = .normal }
      case .controlString:
        if scalar.value == 0x07 {
          escapeState = .normal
        } else if scalar.value == 0x1B {
          escapeState = .controlStringEscape
        }
      case .controlStringEscape:
        escapeState = scalar == "\\" ? .normal : .controlString
      }
    }
    let printableRange = NSRange(printable.startIndex..<printable.endIndex, in: printable)
    let collapsed = whitespaceExpression.stringByReplacingMatches(
      in: printable, range: printableRange, withTemplate: " "
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    guard collapsed.count > limit else { return collapsed }
    guard limit > 1 else { return String(collapsed.prefix(limit)) }
    return String(collapsed.prefix(limit - 1)) + "…"
  }
}

private struct ParserSnapshot {
  let progress: Double?
  let failure: String?
  let sawFailed: Bool
  let sawCancelled: Bool
}

/// The parser retains at most one bounded output line and a short failure summary. It never reads
/// build inputs, source files, result bundles, or unrelated project directories.
private final class XcodeOutputParser: @unchecked Sendable {
  private static let maximumLineBytes = 8 * 1_024
  private static let progressExpression = try! NSRegularExpression(
    pattern: "^\\s*\\[(\\d+)\\s*/\\s*(\\d+)\\]")
  private static let testFailureExpression = try! NSRegularExpression(
    pattern: "Test Case ['‘](.+?)['’] failed", options: [.caseInsensitive])
  private static let fileFailureExpression = try! NSRegularExpression(
    pattern: "([^\\s/:]+\\.swift):(\\d+)(?::\\d+)?:\\s*(?:error|fatal error):",
    options: [.caseInsensitive])

  private let lock = NSLock()
  private var lineBytes: [UInt8] = []
  private var discardingLongLine = false
  private var progress: Double?
  private var failure: String?
  private var sawFailed = false
  private var sawCancelled = false

  func consume(_ data: Data) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    let oldProgress = progress
    for byte in data {
      if byte == 0x0A || byte == 0x0D {
        if !lineBytes.isEmpty { parseLine(lineBytes) }
        lineBytes.removeAll(keepingCapacity: true)
        discardingLongLine = false
      } else if !discardingLongLine {
        if lineBytes.count < Self.maximumLineBytes {
          lineBytes.append(byte)
        } else {
          parseLine(lineBytes)
          lineBytes.removeAll(keepingCapacity: true)
          discardingLongLine = true
        }
      }
    }
    return progress != oldProgress
  }

  func finish() {
    lock.lock()
    defer { lock.unlock() }
    if !lineBytes.isEmpty { parseLine(lineBytes) }
    lineBytes.removeAll()
  }

  func snapshot() -> ParserSnapshot {
    lock.lock()
    defer { lock.unlock() }
    return ParserSnapshot(
      progress: progress, failure: failure, sawFailed: sawFailed, sawCancelled: sawCancelled)
  }

  private func parseLine(_ bytes: [UInt8]) {
    let line = Sanitizer.text(String(decoding: bytes, as: UTF8.self), limit: 512)
    guard !line.isEmpty else { return }
    let range = NSRange(line.startIndex..<line.endIndex, in: line)
    if let match = Self.progressExpression.firstMatch(in: line, range: range),
      let completedRange = Range(match.range(at: 1), in: line),
      let totalRange = Range(match.range(at: 2), in: line),
      let completed = Double(line[completedRange]), let total = Double(line[totalRange]), total > 0
    {
      progress = min(1, max(0, completed / total))
    }
    let uppercased = line.uppercased()
    if uppercased.contains("** BUILD FAILED **") || uppercased.contains("** TEST FAILED **") {
      sawFailed = true
    }
    if uppercased.contains("** BUILD CANCELLED **")
      || uppercased.contains("** BUILD CANCELED **")
      || uppercased.contains("** TEST CANCELLED **")
      || uppercased.contains("** TEST CANCELED **")
    {
      sawCancelled = true
    }
    if failure == nil, let match = Self.testFailureExpression.firstMatch(in: line, range: range),
      let testRange = Range(match.range(at: 1), in: line)
    {
      failure = "Failed: " + Sanitizer.text(String(line[testRange]), limit: 160)
    } else if failure == nil,
      let match = Self.fileFailureExpression.firstMatch(in: line, range: range),
      let fileRange = Range(match.range(at: 1), in: line),
      let lineRange = Range(match.range(at: 2), in: line)
    {
      let file = Sanitizer.text(String(line[fileRange]), limit: 100)
      failure = "Failed: \(file):\(line[lineRange])"
    }
  }
}

private final class XcodeOutputDrainer: @unchecked Sendable {
  private static let readSize = 16 * 1_024
  private static let pollIntervalMilliseconds: Int32 = 100

  private let source: FileHandle
  private let destination: FileHandle
  private let parser: XcodeOutputParser
  private let outputLock: NSLock
  private let progressChanged: () -> Void
  private let shouldStop: () -> Bool

  init(
    source: FileHandle,
    destination: FileHandle,
    parser: XcodeOutputParser,
    outputLock: NSLock,
    progressChanged: @escaping () -> Void,
    shouldStop: @escaping () -> Bool
  ) {
    self.source = source
    self.destination = destination
    self.parser = parser
    self.outputLock = outputLock
    self.progressChanged = progressChanged
    self.shouldStop = shouldStop
  }

  func run() {
    let descriptor = source.fileDescriptor
    var pollDescriptor = pollfd(
      fd: descriptor, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)
    var buffer = [UInt8](repeating: 0, count: Self.readSize)
    while true {
      pollDescriptor.revents = 0
      let pollResult = Darwin.poll(&pollDescriptor, 1, Self.pollIntervalMilliseconds)
      if pollResult < 0 {
        if errno == EINTR { continue }
        break
      }
      if pollResult == 0 {
        if shouldStop() { break }
        continue
      }
      if pollDescriptor.revents & Int16(POLLIN) == 0 {
        if pollDescriptor.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 { break }
        continue
      }

      let count = buffer.withUnsafeMutableBytes { bytes in
        Darwin.read(descriptor, bytes.baseAddress, bytes.count)
      }
      if count < 0 {
        if errno == EINTR { continue }
        break
      }
      if count == 0 { break }
      let data = Data(buffer.prefix(count))
      outputLock.lock()
      destination.write(data)
      outputLock.unlock()
      if parser.consume(data) { progressChanged() }
    }
    parser.finish()
  }
}

private struct PulseStatus {
  let operation: String
  let title: String
  let subtitle: String
  let state: String
  let priority: String
  let progress: Double?
  let expiry: Int?
  let includeFailureAction: Bool
}

private struct PendingPulseStatus {
  let status: PulseStatus
  let force: Bool
  let completion: (() -> Void)?
}

private final class PulsePublisher: @unchecked Sendable {
  private let options: Options
  private let stateQueue = DispatchQueue(
    label: "dev.islet.xcode-pulse.publisher-state", qos: .utility)
  private let workerQueue = DispatchQueue(
    label: "dev.islet.xcode-pulse.publisher-worker", qos: .utility)
  private let reporterTimeout: TimeInterval
  private var pending: PendingPulseStatus?
  private var workerRunning = false
  private var acceptingUpdates = true
  private var lastFingerprint = ""
  private var lastUpdate = Date.distantPast

  init(options: Options) {
    self.options = options
    let environment = ProcessInfo.processInfo.environment
    if environment["ISLET_PULSE_EXECUTABLE"]?.isEmpty == false,
      let rawTimeout = environment["ISLET_PULSE_TIMEOUT_SECONDS"],
      let timeout = TimeInterval(rawTimeout), timeout.isFinite, timeout > 0
    {
      reporterTimeout = min(60, max(0.05, timeout))
    } else {
      reporterTimeout = 6
    }
  }

  func publish(_ status: PulseStatus, force: Bool = false) {
    stateQueue.async {
      guard self.acceptingUpdates else { return }
      self.pending = PendingPulseStatus(status: status, force: force, completion: nil)
      self.startNextIfNeeded()
    }
  }

  func finish(_ status: PulseStatus) {
    let completed = DispatchSemaphore(value: 0)
    stateQueue.async {
      self.acceptingUpdates = false
      self.pending = PendingPulseStatus(
        status: status, force: true, completion: { completed.signal() })
      self.startNextIfNeeded()
    }
    completed.wait()
  }

  private func startNextIfNeeded() {
    guard !workerRunning, let next = pending else { return }
    pending = nil
    workerRunning = true
    workerQueue.async {
      self.send(next.status, force: next.force)
      self.stateQueue.async {
        self.workerRunning = false
        next.completion?()
        self.startNextIfNeeded()
      }
    }
  }

  private func send(_ status: PulseStatus, force: Bool) {
    let fingerprint = "\(status.title)|\(status.subtitle)|\(status.state)|\(status.progress ?? -1)"
    let now = Date()
    guard force || (fingerprint != lastFingerprint && now.timeIntervalSince(lastUpdate) >= 2) else {
      return
    }
    lastFingerprint = fingerprint
    lastUpdate = now

    var arguments = [
      status.operation, options.identifier, status.title, status.subtitle,
      "--source", "xcode", "--state", status.state, "--priority", status.priority,
    ]
    if let progress = status.progress {
      arguments += ["--progress", String(format: "%.4f", min(1, max(0, progress)))]
    }
    if let expiry = status.expiry { arguments += ["--expires", "\(expiry)"] }
    if let projectURL = options.projectURL {
      arguments += ["--action", "Open project", projectURL]
    }
    if let reportURL = options.reportURL { arguments += ["--action", "Open report", reportURL] }
    if status.includeFailureAction, let failureURL = options.failureURL {
      arguments += ["--action", "Open failure", failureURL]
    }

    let process = Process()
    let environment = ProcessInfo.processInfo.environment
    if let override = environment["ISLET_PULSE_EXECUTABLE"], !override.isEmpty {
      process.executableURL = URL(fileURLWithPath: override)
      process.arguments = arguments
    } else {
      process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
      let providerURL = URL(fileURLWithPath: #filePath)
      let pulseURL = providerURL.deletingLastPathComponent().appendingPathComponent(
        "islet-pulse.swift")
      process.arguments = ["swift", pulseURL.path] + arguments
    }
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
      let exited = DispatchSemaphore(value: 0)
      process.terminationHandler = { _ in exited.signal() }
      try process.run()
      if exited.wait(timeout: .now() + reporterTimeout) == .timedOut {
        if process.isRunning { process.terminate() }
        if exited.wait(timeout: .now() + 0.25) == .timedOut, process.isRunning {
          kill(process.processIdentifier, SIGKILL)
          _ = exited.wait(timeout: .now() + 1)
        }
      }
    } catch {
      // Pulse reporting is best effort. A missing or stopped Islet must not change xcodebuild.
    }
  }
}

private func elapsed(_ interval: TimeInterval) -> String {
  let seconds = max(0, Int(interval.rounded(.down)))
  if seconds < 60 { return "\(seconds)s" }
  let minutes = seconds / 60
  let remainder = seconds % 60
  if minutes < 60 { return "\(minutes)m \(remainder)s" }
  return "\(minutes / 60)h \(minutes % 60)m"
}

private func processExitCode(_ status: Int32, reason: Process.TerminationReason) -> Int32 {
  if status < 0 { return 1 }
  if reason == .uncaughtSignal { return min(128 + status, 255) }
  return min(status, 255)
}

do {
  let options = try Options.parse(Array(CommandLine.arguments.dropFirst()))
  let stdoutParser = XcodeOutputParser()
  let stderrParser = XcodeOutputParser()
  let currentSnapshot = {
    let output = stdoutParser.snapshot()
    let errors = stderrParser.snapshot()
    return ParserSnapshot(
      progress: output.progress ?? errors.progress,
      failure: output.failure ?? errors.failure,
      sawFailed: output.sawFailed || errors.sawFailed,
      sawCancelled: output.sawCancelled || errors.sawCancelled)
  }
  let publisher = PulsePublisher(options: options)
  let start = Date()
  let noun = options.isTest ? "Tests" : "Build"
  publisher.publish(
    PulseStatus(
      operation: "show", title: "\(noun) running", subtitle: "\(options.label) · 0s",
      state: "active", priority: "normal", progress: nil, expiry: nil,
      includeFailureAction: false), force: true)

  let process = Process()
  let environment = ProcessInfo.processInfo.environment
  let signalGraceInterval: TimeInterval
  if let rawGraceInterval = environment["ISLET_XCODEBUILD_SIGNAL_GRACE_SECONDS"],
    let configuredGraceInterval = TimeInterval(rawGraceInterval),
    configuredGraceInterval.isFinite, configuredGraceInterval > 0
  {
    signalGraceInterval = min(60, max(0.05, configuredGraceInterval))
  } else {
    signalGraceInterval = 5
  }
  if let override = environment["ISLET_XCODEBUILD_EXECUTABLE"], !override.isEmpty {
    process.executableURL = URL(fileURLWithPath: override)
    process.arguments = options.xcodebuildArguments
  } else {
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = ["xcodebuild"] + options.xcodebuildArguments
  }
  let stdoutPipe = Pipe()
  let stderrPipe = Pipe()
  process.standardOutput = stdoutPipe
  process.standardError = stderrPipe
  let closeOutputPipeWriters = {
    try? stdoutPipe.fileHandleForWriting.close()
    try? stderrPipe.fileHandleForWriting.close()
  }
  let outputLock = NSLock()
  let processStateLock = NSLock()
  var processExited = false
  let shouldStopDraining = {
    processStateLock.lock()
    defer { processStateLock.unlock() }
    return processExited
  }
  let progressChanged = {
    let snapshot = currentSnapshot()
    publisher.publish(
      PulseStatus(
        operation: "update", title: "\(noun) running",
        subtitle: "\(options.label) · \(elapsed(Date().timeIntervalSince(start)))",
        state: snapshot.progress == nil ? "active" : "progress", priority: "normal",
        progress: snapshot.progress, expiry: nil, includeFailureAction: false))
  }
  let drainers = [
    XcodeOutputDrainer(
      source: stdoutPipe.fileHandleForReading, destination: FileHandle.standardOutput,
      parser: stdoutParser, outputLock: outputLock, progressChanged: progressChanged,
      shouldStop: shouldStopDraining),
    XcodeOutputDrainer(
      source: stderrPipe.fileHandleForReading, destination: FileHandle.standardError,
      parser: stderrParser, outputLock: outputLock, progressChanged: progressChanged,
      shouldStop: shouldStopDraining),
  ]
  let readers = DispatchGroup()

  let signalLock = NSLock()
  var receivedSignal: Int32?
  signal(SIGINT, SIG_IGN)
  signal(SIGTERM, SIG_IGN)
  let signalQueue = DispatchQueue(label: "dev.islet.xcode-pulse.signals")
  let interruptSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: signalQueue)
  let terminateSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: signalQueue)
  var signalEscalationScheduled = false
  let forwardSignal = { (forwardedSignal: Int32) in
    signalLock.lock()
    receivedSignal = forwardedSignal
    signalLock.unlock()
    guard process.isRunning else { return }
    kill(process.processIdentifier, forwardedSignal)
    signalLock.lock()
    let shouldScheduleEscalation = !signalEscalationScheduled
    signalEscalationScheduled = true
    signalLock.unlock()
    guard shouldScheduleEscalation else { return }
    signalQueue.asyncAfter(deadline: .now() + signalGraceInterval) {
      if process.isRunning {
        kill(process.processIdentifier, SIGKILL)
      }
    }
  }
  for source in [interruptSource, terminateSource] {
    source.setEventHandler {
      let forwardedSignal = source === interruptSource ? SIGINT : SIGTERM
      forwardSignal(forwardedSignal)
    }
    source.resume()
  }

  do {
    try process.run()
    closeOutputPipeWriters()
  } catch {
    closeOutputPipeWriters()
    interruptSource.cancel()
    terminateSource.cancel()
    publisher.finish(
      PulseStatus(
        operation: "event", title: "\(noun) failed",
        subtitle: "\(options.label) · could not start xcodebuild", state: "failed",
        priority: "critical", progress: nil, expiry: 60, includeFailureAction: false))
    throw error
  }
  for drainer in drainers {
    readers.enter()
    DispatchQueue.global(qos: .utility).async {
      drainer.run()
      readers.leave()
    }
  }
  signalLock.lock()
  let pendingSignal = receivedSignal
  signalLock.unlock()
  if let pendingSignal {
    signalQueue.sync { forwardSignal(pendingSignal) }
  }

  let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
  timer.schedule(deadline: .now() + 5, repeating: 5)
  timer.setEventHandler {
    guard process.isRunning else { return }
    let snapshot = currentSnapshot()
    publisher.publish(
      PulseStatus(
        operation: "update", title: "\(noun) running",
        subtitle: "\(options.label) · \(elapsed(Date().timeIntervalSince(start)))",
        state: snapshot.progress == nil ? "active" : "progress", priority: "normal",
        progress: snapshot.progress, expiry: nil, includeFailureAction: false))
  }
  timer.resume()

  process.waitUntilExit()
  processStateLock.lock()
  processExited = true
  processStateLock.unlock()
  timer.cancel()
  interruptSource.cancel()
  terminateSource.cancel()
  if readers.wait(timeout: .now() + 2) == .timedOut {
    stdoutParser.finish()
    stderrParser.finish()
  }

  let snapshot = currentSnapshot()
  signalLock.lock()
  let wasSignalled = receivedSignal != nil
  signalLock.unlock()
  let duration = elapsed(Date().timeIntervalSince(start))
  if wasSignalled || snapshot.sawCancelled || process.terminationReason == .uncaughtSignal
    || [130, 143].contains(process.terminationStatus)
  {
    publisher.finish(
      PulseStatus(
        operation: "event", title: "\(noun) cancelled",
        subtitle: "\(options.label) · \(duration)", state: "cancelled", priority: "normal",
        progress: snapshot.progress, expiry: 15, includeFailureAction: false))
  } else if process.terminationStatus == 0 && !snapshot.sawFailed {
    publisher.finish(
      PulseStatus(
        operation: "event", title: "\(noun) succeeded",
        subtitle: "\(options.label) · \(duration)", state: "succeeded", priority: "normal",
        progress: 1, expiry: 8, includeFailureAction: false))
  } else {
    publisher.finish(
      PulseStatus(
        operation: "event", title: "\(noun) failed",
        subtitle: snapshot.failure ?? "\(options.label) · \(duration)", state: "failed",
        priority: "critical", progress: snapshot.progress, expiry: 60,
        includeFailureAction: true))
  }
  exit(processExitCode(process.terminationStatus, reason: process.terminationReason))
} catch let error as ProviderError {
  FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
  exit(64)
} catch {
  FileHandle.standardError.write(
    Data("could not run xcodebuild: \(error.localizedDescription)\n".utf8))
  exit(70)
}
