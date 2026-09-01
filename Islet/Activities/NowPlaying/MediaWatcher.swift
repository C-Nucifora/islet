import Darwin
import Foundation

/// Spawns the bundled mediaremote-adapter under /usr/bin/perl and streams updates.
/// The adapter is expected to die and respawn (macOS may kill it), so every process/pipe is
/// torn down cleanly on each restart to avoid leaking file handles or stale handlers.
final class MediaWatcher: @unchecked Sendable {
  enum HelperKind: String, Sendable {
    case stream
    case snapshot = "get"
  }

  struct HelperCommand: Sendable {
    let executableURL: URL
    let arguments: [String]
  }

  struct SnapshotTimeouts: Equatable, Sendable {
    let startup: TimeInterval
    let idle: TimeInterval
    let total: TimeInterval

    static let production = SnapshotTimeouts(startup: 2, idle: 2, total: 8)

    init(startup: TimeInterval, idle: TimeInterval, total: TimeInterval) {
      precondition(startup > 0 && idle > 0 && total > 0)
      self.startup = startup
      self.idle = idle
      self.total = total
    }
  }

  enum SnapshotTimeout: String, Equatable, Sendable {
    case startup
    case idle
    case total
  }

  /// Monotonic snapshot deadline state. Keeping this independent of Dispatch makes boundary and
  /// precedence tests deterministic; the watcher only supplies the current uptime.
  struct SnapshotDeadlineTracker: Equatable, Sendable {
    let startedAt: TimeInterval
    let timeouts: SnapshotTimeouts
    private(set) var lastOutputAt: TimeInterval?

    mutating func receivedOutput(at time: TimeInterval) {
      lastOutputAt = time
    }

    func expired(at time: TimeInterval) -> SnapshotTimeout? {
      if time >= startedAt + timeouts.total { return .total }
      guard let lastOutputAt else {
        return time >= startedAt + timeouts.startup ? .startup : nil
      }
      return time >= lastOutputAt + timeouts.idle ? .idle : nil
    }

    func nextDeadline(after time: TimeInterval) -> TimeInterval {
      let activityDeadline =
        lastOutputAt.map { $0 + timeouts.idle } ?? (startedAt + timeouts.startup)
      return max(time, min(startedAt + timeouts.total, activityDeadline))
    }
  }

  private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumBytes: Int
    private var storage = Data()
    private var exceededLimit = false

    init(maximumBytes: Int) {
      precondition(maximumBytes > 0)
      self.maximumBytes = maximumBytes
    }

    @discardableResult
    func append(_ data: Data) -> Bool {
      lock.lock()
      defer { lock.unlock() }
      let remaining = maximumBytes - storage.count
      if data.count > remaining {
        if remaining > 0 { storage.append(data.prefix(remaining)) }
        exceededLimit = true
      } else {
        storage.append(data)
      }
      return exceededLimit
    }

    var snapshot: (data: Data, exceededLimit: Bool) {
      lock.lock()
      defer { lock.unlock() }
      return (storage, exceededLimit)
    }
  }

  /// Keeps only redacted diagnostic text. Unlike stdout, where truncation makes the response
  /// invalid, the tail of stderr is normally where a helper puts its actionable error.
  final class StderrCapture: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumBytes: Int
    private var storage = Data()
    private var exceededLimit = false
    private var payloadNestingDepth = 0

    init(maximumBytes: Int) {
      precondition(maximumBytes > 0)
      self.maximumBytes = maximumBytes
    }

    func append(_ data: Data) {
      lock.lock()
      defer { lock.unlock() }
      appendRedacted(Self.redact(data, payloadNestingDepth: &payloadNestingDepth))
    }

    var snapshot: (data: Data, exceededLimit: Bool) {
      lock.lock()
      defer { lock.unlock() }
      return (storage, exceededLimit)
    }

    private func appendRedacted(_ data: Data) {
      guard !data.isEmpty else { return }
      if data.count >= maximumBytes {
        storage = Data(data.suffix(maximumBytes))
        exceededLimit = true
        return
      }
      let overflow = storage.count + data.count - maximumBytes
      if overflow > 0 {
        storage.removeFirst(overflow)
        exceededLimit = true
      }
      storage.append(data)
    }

    /// Stderr is copied into support reports, so retain only plain diagnostic text. A corrupted
    /// helper can write its JSON payload to stderr; once one begins, discard it across arbitrary
    /// pipe chunk boundaries instead of keeping track metadata or artwork in memory.
    private static func redact(_ data: Data, payloadNestingDepth: inout Int) -> Data {
      let text = String(decoding: data, as: UTF8.self)
      var result = ""
      for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = String(rawLine)
        let nestingDelta = line.reduce(into: 0) { depth, character in
          if character == "{" || character == "[" { depth += 1 }
          if character == "}" || character == "]" { depth -= 1 }
        }
        if payloadNestingDepth > 0 {
          payloadNestingDepth = max(0, payloadNestingDepth + nestingDelta)
          result += "[media payload redacted]\n"
          continue
        }

        let lowercased = line.lowercased()
        if line.contains("{") || line.contains("[")
          || ["title", "artist", "album", "artwork", "lyrics", "payload"].contains(where: {
            lowercased.contains("\"\($0)\"") || lowercased.contains("\($0)=")
              || lowercased.contains("\($0):")
          })
        {
          payloadNestingDepth = max(0, nestingDelta)
          result += "[media payload redacted]\n"
          continue
        }

        let printable = line.unicodeScalars.filter { scalar in
          scalar.value >= 0x20 && scalar.value != 0x7F
        }
        let cleaned = redactAbsolutePaths(in: String(String.UnicodeScalarView(printable)))
        if !cleaned.isEmpty { result += cleaned + "\n" }
      }
      return Data(result.utf8)
    }

    private static func redactAbsolutePaths(in text: String) -> String {
      var result = ""
      var index = text.startIndex
      while index < text.endIndex {
        let previous = index == text.startIndex ? nil : text[text.index(before: index)]
        let validPrefix = previous.map { $0.isWhitespace || "\"'(=".contains($0) } ?? true
        if text[index] != "/" || !validPrefix {
          result.append(text[index])
          index = text.index(after: index)
          continue
        }
        result += "<path>"
        index = text.index(after: index)
        // Spaces are valid path characters. Consume conservatively to punctuation or the end of
        // the line rather than exposing a user or media filename after the first space.
        while index < text.endIndex, !",;)]}".contains(text[index]) {
          index = text.index(after: index)
        }
      }
      return result
    }
  }

  static let maximumSnapshotOutputBytes = 1_048_576
  static let maximumHelperStderrBytes = 16_384

  private let queue = DispatchQueue(label: "dev.islet.mediawatcher")
  private let queueKey = DispatchSpecificKey<Void>()
  private let snapshotTimeouts: SnapshotTimeouts
  private let initialSnapshotDelay: TimeInterval
  private let commandProvider: @Sendable (HelperKind) -> HelperCommand?
  private let snapshotBackoff: @Sendable (Int) -> TimeInterval
  private let monotonicNow: @Sendable () -> TimeInterval
  private var process: Process?
  private var snapshotProcess: Process?
  private var snapshotPipe: Pipe?
  private var snapshotOutput: LockedData?
  private var snapshotStderrPipe: Pipe?
  private var snapshotStderr: StderrCapture?
  private var snapshotDeadlineTracker: SnapshotDeadlineTracker?
  private var snapshotDeadlineWorkItem: DispatchWorkItem?
  private var snapshotLaunchWorkItem: DispatchWorkItem?
  /// Nil for the startup snapshot; otherwise the stream generation captured for an audio-driven
  /// recovery snapshot.
  private var snapshotRecoveryGeneration: UInt64?
  private var pipe: Pipe?
  private var stderrPipe: Pipe?
  private var stderr: StderrCapture?
  private var restartTask: Task<Void, Never>?
  private var failureCount = 0
  private var snapshotFailureCount = 0
  /// Recovery launches spent for the current CoreAudio source set. This stays independent from
  /// snapshot failure diagnostics so repeated idle stream records cannot reopen the retry budget.
  private var recoverySnapshotAttemptCount = 0
  /// Diff base per source. The vendored adapter collapses concurrent players, so this holds at
  /// most one entry today. The shape is what the fork described in the design spec's
  /// "Upgrade path - fork the MediaRemote adapter for true per-source media" section needs.
  private var lastStates: [SourceID: PlaybackState] = [:]
  private var currentSource: SourceID?
  private var streamHasEmittedRecord = false
  private var streamGeneration: UInt64 = 0
  private var playbackRecoveryBundleIdentifiers: Set<String> = []
  private var buffer = Data()  // guarded by `queue`
  private var isRunning = false
  /// Human-readable adapter status for the Settings window.
  var onStatus: (@Sendable (String) -> Void)?
  /// The latest redacted helper failure for Copy Diagnostics. It persists across a successful
  /// restart so support reports still contain the reason a private framework failed.
  var onDiagnostic: (@Sendable (String?) -> Void)?

  // Created eagerly in init (not lazily by the consumer) so `continuation` is a `let` published
  // before any producer-queue work can read it. This avoids a cross-thread data race.
  let updates: AsyncStream<AdapterUpdate>
  private let continuation: AsyncStream<AdapterUpdate>.Continuation

  convenience init() {
    self.init(commandProvider: Self.bundledCommand)
  }

  init(
    snapshotTimeouts: SnapshotTimeouts = .production,
    initialSnapshotDelay: TimeInterval = 0.25,
    commandProvider: @escaping @Sendable (HelperKind) -> HelperCommand?,
    snapshotBackoff: @escaping @Sendable (Int) -> TimeInterval = MediaWatcher.backoffDelay,
    monotonicNow: @escaping @Sendable () -> TimeInterval = {
      ProcessInfo.processInfo.systemUptime
    }
  ) {
    precondition(initialSnapshotDelay >= 0)
    self.snapshotTimeouts = snapshotTimeouts
    self.initialSnapshotDelay = initialSnapshotDelay
    self.commandProvider = commandProvider
    self.snapshotBackoff = snapshotBackoff
    self.monotonicNow = monotonicNow
    var cont: AsyncStream<AdapterUpdate>.Continuation!
    updates = AsyncStream { cont = $0 }
    continuation = cont
    queue.setSpecific(key: queueKey, value: ())
  }

  private static func bundledCommand(for kind: HelperKind) -> HelperCommand? {
    guard
      let script = Bundle.main.url(forResource: "mediaremote-adapter", withExtension: "pl"),
      let frameworks = Bundle.main.privateFrameworksPath
    else { return nil }
    let framework = frameworks + "/MediaRemoteAdapter.framework"
    switch kind {
    case .stream:
      return HelperCommand(
        executableURL: URL(fileURLWithPath: "/usr/bin/perl"),
        arguments: [script.path, framework, kind.rawValue])
    case .snapshot:
      // The host deadline is authoritative because it can SIGKILL and reap the helper. The Perl
      // alarm is a later fallback if host scheduling is delayed or the watcher is disrupted.
      let scriptTimeout = Int(ceil(SnapshotTimeouts.production.total + 2))
      return HelperCommand(
        executableURL: URL(fileURLWithPath: "/usr/bin/perl"),
        arguments: [
          script.path, framework, kind.rawValue, "--no-artwork", "--timeout=\(scriptTimeout)",
        ])
    }
  }

  static func backoffDelay(failureCount: Int) -> TimeInterval {
    guard failureCount > 1 else { return 1 }
    return min(pow(2, Double(failureCount - 1)), 60)
  }

  func start() {
    queue.async { [self] in
      guard !isRunning else { return }
      isRunning = true
      launch()
    }
  }

  func stop() {
    onQueueSync { [self] in
      isRunning = false
      restartTask?.cancel()
      restartTask = nil
      cleanup(terminateStream: true)
      buffer.removeAll(keepingCapacity: false)
      lastStates.removeAll()
      currentSource = nil
      streamHasEmittedRecord = false
      streamGeneration = 0
      playbackRecoveryBundleIdentifiers = []
      failureCount = 0
      snapshotFailureCount = 0
      recoverySnapshotAttemptCount = 0
      onStatus?("Stopped")
      onDiagnostic?(nil)
    }
  }

  /// CoreAudio is independent of MediaRemote and can reveal that an idle stream missed playback.
  /// Keep the snapshot guarded by a stream generation so a newer live record always wins.
  func setPlaybackRecoverySources(_ bundleIdentifiers: Set<String>) {
    queue.async { [self] in
      if bundleIdentifiers != playbackRecoveryBundleIdentifiers {
        snapshotFailureCount = 0
        recoverySnapshotAttemptCount = 0
      }
      playbackRecoveryBundleIdentifiers = bundleIdentifiers
      if !bundleIdentifiers.isEmpty {
        scheduleRecoverySnapshot()
      } else if snapshotRecoveryGeneration != nil {
        snapshotLaunchWorkItem?.cancel()
        snapshotLaunchWorkItem = nil
        cleanupSnapshot(terminate: true)
      }
    }
  }

  private func onQueueSync(_ operation: () -> Void) {
    if DispatchQueue.getSpecific(key: queueKey) != nil {
      operation()
    } else {
      queue.sync(execute: operation)
    }
  }

  /// Detaches handlers and drops the current process/pipe. Must run on `queue`.
  private func cleanup(terminateStream: Bool) {
    snapshotLaunchWorkItem?.cancel()
    snapshotLaunchWorkItem = nil
    cleanupSnapshot(terminate: true)

    pipe?.fileHandleForReading.readabilityHandler = nil
    stderrPipe?.fileHandleForReading.readabilityHandler = nil
    let oldProcess = process
    process = nil
    pipe = nil
    stderrPipe = nil
    stderr = nil
    oldProcess?.terminationHandler = nil
    if let oldProcess {
      if terminateStream {
        terminateAndReap(oldProcess)
      } else {
        oldProcess.waitUntilExit()
      }
    }
  }

  private func cleanupSnapshot(terminate: Bool) {
    snapshotDeadlineWorkItem?.cancel()
    snapshotDeadlineWorkItem = nil
    snapshotDeadlineTracker = nil
    snapshotPipe?.fileHandleForReading.readabilityHandler = nil
    let oldStderrPipe = snapshotStderrPipe
    let oldStderr = snapshotStderr
    oldStderrPipe?.fileHandleForReading.readabilityHandler = nil

    let oldSnapshot = snapshotProcess
    snapshotProcess = nil
    snapshotPipe = nil
    snapshotOutput = nil
    snapshotStderrPipe = nil
    snapshotStderr = nil
    snapshotRecoveryGeneration = nil
    oldSnapshot?.terminationHandler = nil
    if let oldSnapshot {
      if terminate {
        terminateAndReap(oldSnapshot)
      } else {
        oldSnapshot.waitUntilExit()
      }
    }
    if let oldStderrPipe, let oldStderr {
      Self.drainAvailableData(from: oldStderrPipe.fileHandleForReading, into: oldStderr)
    }
  }

  private func terminateAndReap(_ process: Process) {
    if process.isRunning {
      process.terminate()
      // `applicationWillTerminate` has only a short synchronous window. Give cooperative adapters
      // a moment to exit, then guarantee that a wedged helper cannot be orphaned under launchd.
      // Process termination must not depend on the injectable snapshot clock. A fixed clock is
      // useful in deadline tests but would otherwise make this loop unbounded.
      let deadline = ProcessInfo.processInfo.systemUptime + 0.25
      while process.isRunning, ProcessInfo.processInfo.systemUptime < deadline {
        Thread.sleep(forTimeInterval: 0.01)
      }
      if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
    }
    // Always wait, including after a cooperative SIGTERM. This is the explicit reap point.
    process.waitUntilExit()
  }

  private func launch() {
    cleanup(terminateStream: true)  // never leave a stale process/handler before respawning
    restartTask = nil
    streamHasEmittedRecord = false
    guard let command = commandProvider(.stream) else {
      Log.media.error("Adapter script or framework missing from bundle")
      onStatus?("Adapter missing from bundle")
      isRunning = false  // allow a future start() to retry
      return
    }
    let launchedProcess = Process()
    launchedProcess.executableURL = command.executableURL
    launchedProcess.arguments = command.arguments
    let launchedPipe = Pipe()
    let launchedStderrPipe = Pipe()
    let launchedStderr = StderrCapture(maximumBytes: Self.maximumHelperStderrBytes)
    launchedProcess.standardOutput = launchedPipe
    launchedProcess.standardError = launchedStderrPipe

    launchedPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      guard let self else { return }
      if data.isEmpty {
        handle.readabilityHandler = nil  // EOF; terminationHandler drives the restart
        return
      }
      self.queue.async { self.consume(data, from: launchedProcess) }
    }
    launchedStderrPipe.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      if data.isEmpty {
        handle.readabilityHandler = nil
      } else {
        launchedStderr.append(data)
      }
    }
    launchedProcess.terminationHandler = { [weak self] terminatedProcess in
      launchedPipe.fileHandleForReading.readabilityHandler = nil
      launchedStderrPipe.fileHandleForReading.readabilityHandler = nil
      Self.drainAvailableData(from: launchedStderrPipe.fileHandleForReading, into: launchedStderr)
      guard let self else { return }
      self.queue.async { self.processDied(terminatedProcess, stderr: launchedStderr) }
    }
    do {
      try launchedProcess.run()
      process = launchedProcess
      pipe = launchedPipe
      stderrPipe = launchedStderrPipe
      stderr = launchedStderr
      Log.media.info("Adapter started (pid \(launchedProcess.processIdentifier))")
      onStatus?("Streaming")
      scheduleInitialSnapshot()
    } catch {
      launchedPipe.fileHandleForReading.readabilityHandler = nil
      launchedStderrPipe.fileHandleForReading.readabilityHandler = nil
      launchedProcess.terminationHandler = nil
      Log.media.error("Adapter launch failed: \(error)")
      scheduleStreamRestart(reason: "launch failed")
    }
  }

  /// The stream normally publishes the current track as its first full record. A notification can
  /// race that initial record during relaunch, leaving Islet with only a diff it cannot apply. The
  /// one-shot query supplies a fallback without replacing a newer record from the live stream.
  private func scheduleInitialSnapshot(after delay: TimeInterval? = nil) {
    snapshotLaunchWorkItem?.cancel()
    let workItem = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.snapshotLaunchWorkItem = nil
      guard self.isRunning, self.snapshotProcess == nil,
        Self.shouldAcceptInitialSnapshot(
          streamHasEmittedRecord: self.streamHasEmittedRecord, currentSource: self.currentSource)
      else { return }
      self.requestSnapshot(recoveryGeneration: nil)
    }
    snapshotLaunchWorkItem = workItem
    queue.asyncAfter(deadline: .now() + (delay ?? initialSnapshotDelay), execute: workItem)
  }

  private func scheduleRecoverySnapshot(after delay: TimeInterval? = nil) {
    guard isRunning, !playbackRecoveryBundleIdentifiers.isEmpty, currentSource == nil,
      snapshotProcess == nil, snapshotLaunchWorkItem == nil, recoverySnapshotAttemptCount < 3
    else { return }
    let generation = streamGeneration
    let workItem = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.snapshotLaunchWorkItem = nil
      guard self.isRunning,
        Self.shouldAcceptRecoverySnapshot(
          requestedGeneration: generation,
          currentGeneration: self.streamGeneration,
          currentSource: self.currentSource,
          playbackRecoveryActive: !self.playbackRecoveryBundleIdentifiers.isEmpty)
      else { return }
      self.requestSnapshot(recoveryGeneration: generation)
    }
    snapshotLaunchWorkItem = workItem
    queue.asyncAfter(deadline: .now() + (delay ?? initialSnapshotDelay), execute: workItem)
  }

  private func requestSnapshot(recoveryGeneration: UInt64?) {
    guard snapshotProcess == nil else { return }
    if recoveryGeneration != nil {
      guard recoverySnapshotAttemptCount < 3 else { return }
      recoverySnapshotAttemptCount += 1
    }
    guard let command = commandProvider(.snapshot) else {
      snapshotFailed(reason: "helper missing", recoveryGeneration: recoveryGeneration)
      return
    }
    let snapshot = Process()
    snapshot.executableURL = command.executableURL
    snapshot.arguments = command.arguments
    let output = Pipe()
    let errorPipe = Pipe()
    let outputData = LockedData(maximumBytes: Self.maximumSnapshotOutputBytes)
    let stderrData = StderrCapture(maximumBytes: Self.maximumHelperStderrBytes)
    snapshot.standardOutput = output
    snapshot.standardError = errorPipe
    output.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      if data.isEmpty {
        handle.readabilityHandler = nil
        return
      }
      outputData.append(data)
      guard let self else { return }
      self.queue.async { self.snapshotReceived(from: snapshot) }
    }
    errorPipe.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      if data.isEmpty {
        handle.readabilityHandler = nil
      } else {
        stderrData.append(data)
      }
    }
    snapshot.terminationHandler = { [weak self] terminatedProcess in
      output.fileHandleForReading.readabilityHandler = nil
      errorPipe.fileHandleForReading.readabilityHandler = nil
      Self.drainAvailableData(from: output.fileHandleForReading, into: outputData)
      Self.drainAvailableData(from: errorPipe.fileHandleForReading, into: stderrData)
      guard let self else { return }
      self.queue.async { self.snapshotFinished(terminatedProcess, stderr: stderrData) }
    }
    do {
      try snapshot.run()
      snapshotProcess = snapshot
      snapshotRecoveryGeneration = recoveryGeneration
      snapshotPipe = output
      snapshotOutput = outputData
      snapshotStderrPipe = errorPipe
      snapshotStderr = stderrData
      snapshotDeadlineTracker = SnapshotDeadlineTracker(
        startedAt: monotonicNow(), timeouts: snapshotTimeouts)
      scheduleSnapshotDeadline(for: snapshot)
    } catch {
      output.fileHandleForReading.readabilityHandler = nil
      errorPipe.fileHandleForReading.readabilityHandler = nil
      snapshot.terminationHandler = nil
      Log.media.error("Initial media snapshot launch failed: \(error)")
      snapshotFailed(reason: "launch failed", recoveryGeneration: recoveryGeneration)
    }
  }

  private func snapshotReceived(from sourceProcess: Process) {
    guard snapshotProcess === sourceProcess, var tracker = snapshotDeadlineTracker else { return }
    guard let snapshotOutput, !snapshotOutput.snapshot.exceededLimit else {
      let capturedStderr = snapshotStderr
      let recoveryGeneration = snapshotRecoveryGeneration
      Log.media.error("Initial media snapshot exceeded output limit")
      cleanupSnapshot(terminate: true)
      snapshotFailed(
        reason: "oversized output", stderr: capturedStderr,
        recoveryGeneration: recoveryGeneration)
      return
    }
    tracker.receivedOutput(at: monotonicNow())
    snapshotDeadlineTracker = tracker
    scheduleSnapshotDeadline(for: sourceProcess)
  }

  private func scheduleSnapshotDeadline(for sourceProcess: Process) {
    snapshotDeadlineWorkItem?.cancel()
    guard let tracker = snapshotDeadlineTracker else { return }
    let now = monotonicNow()
    let delay = max(0, tracker.nextDeadline(after: now) - now)
    let workItem = DispatchWorkItem { [weak self] in
      self?.snapshotDeadlineReached(for: sourceProcess)
    }
    snapshotDeadlineWorkItem = workItem
    queue.asyncAfter(deadline: .now() + delay, execute: workItem)
  }

  private func snapshotDeadlineReached(for sourceProcess: Process) {
    guard snapshotProcess === sourceProcess, let tracker = snapshotDeadlineTracker else { return }
    guard let timeout = tracker.expired(at: monotonicNow()) else {
      scheduleSnapshotDeadline(for: sourceProcess)
      return
    }
    let capturedStderr = snapshotStderr
    let recoveryGeneration = snapshotRecoveryGeneration
    cleanupSnapshot(terminate: true)
    snapshotFailureCount += 1
    let willRetry = recoveryGeneration == nil || recoverySnapshotAttemptCount < 3
    let delay = snapshotBackoff(snapshotFailureCount)
    let reason = "snapshot \(timeout.rawValue) timeout"
    recordHelperFailure(kind: .snapshot, reason: reason, stderr: capturedStderr)
    let action = willRetry ? "retrying in \(Self.secondsLabel(delay))" : "recovery stopped"
    Log.media.warning("MediaRemote \(reason); \(action) (failure #\(self.snapshotFailureCount))")
    onStatus?("Streaming (\(reason); \(action), failure #\(snapshotFailureCount))")
    guard willRetry else { return }
    scheduleSnapshotRetry(recoveryGeneration: recoveryGeneration, after: delay)
  }

  private func snapshotFinished(_ finishedProcess: Process, stderr: StderrCapture) {
    guard snapshotProcess === finishedProcess,
      let capture = snapshotOutput?.snapshot
    else { return }
    let status = finishedProcess.terminationStatus
    let recoveryGeneration = snapshotRecoveryGeneration
    cleanupSnapshot(terminate: false)
    guard isRunning else { return }
    let shouldAccept =
      recoveryGeneration.map {
        Self.shouldAcceptRecoverySnapshot(
          requestedGeneration: $0,
          currentGeneration: streamGeneration,
          currentSource: currentSource,
          playbackRecoveryActive: !playbackRecoveryBundleIdentifiers.isEmpty)
      }
      ?? Self.shouldAcceptInitialSnapshot(
        streamHasEmittedRecord: streamHasEmittedRecord, currentSource: currentSource)
    guard shouldAccept else { return }
    guard !capture.exceededLimit else {
      snapshotFailed(
        reason: "oversized output", stderr: stderr, recoveryGeneration: recoveryGeneration)
      return
    }
    guard status == 0 else {
      snapshotFailed(
        reason: "helper exited with status \(status)", stderr: stderr,
        recoveryGeneration: recoveryGeneration)
      return
    }
    guard let parsed = Self.parseInitialSnapshot(data: capture.data) else {
      snapshotFailed(
        reason: "invalid output", stderr: stderr, recoveryGeneration: recoveryGeneration)
      return
    }
    if recoveryGeneration != nil,
      !Self.shouldAcceptRecoveredUpdate(
        parsed, activeBundleIdentifiers: playbackRecoveryBundleIdentifiers)
    {
      snapshotFailed(
        reason: "recovered source is not an active audio app",
        stderr: stderr,
        recoveryGeneration: recoveryGeneration)
      return
    }
    snapshotFailureCount = 0
    recoverySnapshotAttemptCount = 0
    onStatus?("Streaming")
    accept(parsed)
  }

  static func parseInitialSnapshot(data: Data) -> AdapterUpdate? {
    guard let line = String(data: data, encoding: .utf8) else { return nil }
    let parsed = AdapterParser.parseSnapshot(line: line)
    return parsed == .ignored ? nil : parsed
  }

  /// Drains bytes already buffered by the kernel without waiting for EOF. A helper descendant can
  /// inherit stdout and keep it open after the direct child exits, so a blocking read-to-end is not
  /// safe even from a Process termination callback.
  private static func drainAvailableData(from handle: FileHandle, into output: LockedData) {
    let descriptor = handle.fileDescriptor
    let originalFlags = fcntl(descriptor, F_GETFL)
    guard originalFlags >= 0 else { return }
    guard fcntl(descriptor, F_SETFL, originalFlags | O_NONBLOCK) == 0 else { return }
    defer { _ = fcntl(descriptor, F_SETFL, originalFlags) }

    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
      let count = buffer.withUnsafeMutableBytes { bytes in
        Darwin.read(descriptor, bytes.baseAddress, bytes.count)
      }
      if count > 0 {
        if output.append(Data(buffer.prefix(count))) { return }
      } else if count == -1, errno == EINTR {
        continue
      } else {
        return
      }
    }
  }

  private static func drainAvailableData(from handle: FileHandle, into output: StderrCapture) {
    let descriptor = handle.fileDescriptor
    let originalFlags = fcntl(descriptor, F_GETFL)
    guard originalFlags >= 0 else { return }
    guard fcntl(descriptor, F_SETFL, originalFlags | O_NONBLOCK) == 0 else { return }
    defer { _ = fcntl(descriptor, F_SETFL, originalFlags) }

    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
      let count = buffer.withUnsafeMutableBytes { bytes in
        Darwin.read(descriptor, bytes.baseAddress, bytes.count)
      }
      if count > 0 {
        output.append(Data(buffer.prefix(count)))
      } else if count == -1, errno == EINTR {
        continue
      } else {
        return
      }
    }
  }

  private func snapshotFailed(
    reason: String, stderr: StderrCapture? = nil, recoveryGeneration: UInt64?
  ) {
    guard isRunning else { return }
    let shouldRetry =
      recoveryGeneration.map {
        Self.shouldAcceptRecoverySnapshot(
          requestedGeneration: $0,
          currentGeneration: streamGeneration,
          currentSource: currentSource,
          playbackRecoveryActive: !playbackRecoveryBundleIdentifiers.isEmpty)
      }
      ?? Self.shouldAcceptInitialSnapshot(
        streamHasEmittedRecord: streamHasEmittedRecord, currentSource: currentSource)
    guard shouldRetry else { return }
    snapshotFailureCount += 1
    let willRetry = recoveryGeneration == nil || recoverySnapshotAttemptCount < 3
    let delay = snapshotBackoff(snapshotFailureCount)
    recordHelperFailure(kind: .snapshot, reason: "snapshot \(reason)", stderr: stderr)
    let action = willRetry ? "retrying in \(Self.secondsLabel(delay))" : "recovery stopped"
    Log.media.warning("Media snapshot \(reason); \(action) (failure #\(self.snapshotFailureCount))")
    onStatus?("Streaming (snapshot \(reason); \(action), failure #\(snapshotFailureCount))")
    guard willRetry else { return }
    scheduleSnapshotRetry(recoveryGeneration: recoveryGeneration, after: delay)
  }

  private func scheduleSnapshotRetry(recoveryGeneration: UInt64?, after delay: TimeInterval) {
    if recoveryGeneration == nil {
      scheduleInitialSnapshot(after: delay)
    } else {
      scheduleRecoverySnapshot(after: delay)
    }
  }

  private static func secondsLabel(_ delay: TimeInterval) -> String {
    delay.rounded() == delay
      ? "\(Int(delay))s" : "\(delay.formatted(.number.precision(.fractionLength(2))))s"
  }

  private func consume(_ data: Data, from sourceProcess: Process) {
    guard process === sourceProcess else { return }
    buffer.append(data)
    // A malformed or incompatible helper must not grow the process indefinitely while never
    // producing a newline. Valid adapter records are tiny compared with this defensive ceiling.
    if buffer.count > 1_048_576, !buffer.contains(UInt8(ascii: "\n")) {
      buffer.removeAll(keepingCapacity: false)
      onStatus?("Discarded oversized adapter output")
      Log.media.error("Discarded oversized MediaRemote adapter record")
      return
    }
    while let nl = buffer.firstIndex(of: UInt8(ascii: "\n")) {
      let lineData = buffer[..<nl]
      buffer.removeSubrange(...nl)
      guard lineData.count <= 1_048_576 else {
        onStatus?("Discarded oversized adapter output")
        Log.media.error("Discarded oversized newline-terminated MediaRemote adapter record")
        continue
      }
      guard let line = String(data: lineData, encoding: .utf8) else { continue }
      handle(line: line)
    }
  }

  /// Sequences one parsed update into what downstream should actually see.
  ///
  /// `Vendor/mediaremote-adapter-src/src/adapter/stream.m:189` keeps a single `liveData` record and
  /// calls `resetAll()` whenever a notification arrives from a different process (`:396-408`,
  /// `:437-449`). A change of source key therefore means the previous source is gone, not
  /// backgrounded, and has to be evicted before the new one lands. Pure so the sequencing is
  /// testable without a process.
  static func expand(_ update: AdapterUpdate, current: SourceID?) -> [AdapterUpdate] {
    switch update {
    case .ignored:
      return []
    case .idle, .sourceGone:
      return [update]
    case .nowPlaying(let key, let state):
      guard let current, current != key else { return [update] }
      return [.sourceGone(current), .nowPlaying(key, state)]
    }
  }

  private func handle(line: String) {
    let base = currentSource.flatMap { lastStates[$0] }
    let parsed = AdapterParser.parse(line: line, current: base)
    guard parsed != .ignored else { return }
    streamGeneration &+= 1
    streamHasEmittedRecord = true
    snapshotFailureCount = 0
    if case .nowPlaying = parsed { recoverySnapshotAttemptCount = 0 }
    snapshotLaunchWorkItem?.cancel()
    snapshotLaunchWorkItem = nil
    cleanupSnapshot(terminate: true)
    onStatus?("Streaming")
    accept(parsed)
    if parsed == .idle, !playbackRecoveryBundleIdentifiers.isEmpty {
      scheduleRecoverySnapshot()
    }
  }

  static func shouldAcceptInitialSnapshot(
    streamHasEmittedRecord: Bool, currentSource: SourceID?
  ) -> Bool {
    !streamHasEmittedRecord && currentSource == nil
  }

  static func shouldAcceptRecoverySnapshot(
    requestedGeneration: UInt64,
    currentGeneration: UInt64,
    currentSource: SourceID?,
    playbackRecoveryActive: Bool
  ) -> Bool {
    playbackRecoveryActive && currentSource == nil && requestedGeneration == currentGeneration
  }

  static func shouldAcceptRecoveredUpdate(
    _ update: AdapterUpdate, activeBundleIdentifiers: Set<String>
  ) -> Bool {
    guard case .nowPlaying(let source, _) = update else { return false }
    return activeBundleIdentifiers.contains(source.displayBundleIdentifier)
  }

  private func accept(_ parsed: AdapterUpdate) {
    for update in Self.expand(parsed, current: currentSource) {
      switch update {
      case .ignored:
        continue
      case .idle:
        failureCount = 0
        lastStates.removeAll()
        currentSource = nil
      case .sourceGone(let key):
        lastStates[key] = nil
        if currentSource == key { currentSource = nil }
      case .nowPlaying(let key, let state):
        failureCount = 0
        lastStates[key] = state
        currentSource = key
      }
      continuation.yield(update)
    }
  }

  private func processDied(_ deadProcess: Process, stderr: StderrCapture) {
    guard process === deadProcess else { return }
    recordHelperFailure(
      kind: .stream,
      reason: "stream helper exited with status \(deadProcess.terminationStatus)",
      stderr: stderr)
    cleanup(terminateStream: false)
    buffer.removeAll(keepingCapacity: true)
    guard isRunning else { return }
    scheduleStreamRestart(reason: "died")
  }

  private func scheduleStreamRestart(reason: String) {
    guard isRunning, restartTask == nil else { return }
    failureCount += 1
    let delay = Self.backoffDelay(failureCount: failureCount)
    Log.media.warning(
      "Adapter \(reason); restarting in \(delay)s (failure #\(self.failureCount))")
    onStatus?("Restarting in \(Int(delay))s (failure #\(failureCount))")
    restartTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(delay))
      guard !Task.isCancelled else { return }
      self?.queue.async { [weak self] in
        guard let self, self.isRunning else { return }
        self.restartTask = nil
        self.launch()
      }
    }
  }

  private func recordHelperFailure(kind: HelperKind, reason: String, stderr: StderrCapture?) {
    let suffix: String
    if let stderr,
      let text = String(data: stderr.snapshot.data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines),
      !text.isEmpty
    {
      suffix = "; stderr: \(text)"
    } else {
      suffix = ""
    }
    let diagnostic = "\(kind.rawValue) \(reason)\(suffix)"
    Log.media.error("MediaRemote helper failure: \(diagnostic)")
    onDiagnostic?(diagnostic)
  }
}
