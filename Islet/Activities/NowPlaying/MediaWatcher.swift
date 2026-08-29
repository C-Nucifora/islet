import Darwin
import Foundation

/// Spawns the bundled mediaremote-adapter under /usr/bin/perl and streams updates.
/// The adapter is expected to die and respawn (macOS may kill it), so every process/pipe is
/// torn down cleanly on each restart to avoid leaking file handles or stale handlers.
final class MediaWatcher: @unchecked Sendable {
  private let queue = DispatchQueue(label: "dev.islet.mediawatcher")
  private let queueKey = DispatchSpecificKey<Void>()
  private var process: Process?
  private var pipe: Pipe?
  private var restartTask: Task<Void, Never>?
  private var failureCount = 0
  /// Diff base per source. The vendored adapter collapses concurrent players, so this holds at
  /// most one entry today — the shape is what the fork described in the design spec's
  /// "Upgrade path — fork the MediaRemote adapter for true per-source media" section needs.
  private var lastStates: [SourceID: PlaybackState] = [:]
  private var currentSource: SourceID?
  private var buffer = Data()  // guarded by `queue`
  private var isRunning = false
  /// Human-readable adapter status for the Settings window.
  var onStatus: (@Sendable (String) -> Void)?

  // Created eagerly in init (not lazily by the consumer) so `continuation` is a `let` published
  // before any producer-queue work can read it — no cross-thread data race.
  let updates: AsyncStream<AdapterUpdate>
  private let continuation: AsyncStream<AdapterUpdate>.Continuation

  init() {
    var cont: AsyncStream<AdapterUpdate>.Continuation!
    updates = AsyncStream { cont = $0 }
    continuation = cont
    queue.setSpecific(key: queueKey, value: ())
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
      cleanup(terminate: true)
      buffer.removeAll(keepingCapacity: false)
      lastStates.removeAll()
      currentSource = nil
      failureCount = 0
      onStatus?("Stopped")
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
  private func cleanup(terminate: Bool) {
    pipe?.fileHandleForReading.readabilityHandler = nil
    process?.terminationHandler = nil
    if terminate, let process, process.isRunning {
      process.terminate()
      // `applicationWillTerminate` has only a short synchronous window. Give cooperative adapters
      // a moment to exit, then guarantee that a wedged helper cannot be orphaned under launchd.
      let deadline = Date().addingTimeInterval(0.25)
      while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
      if process.isRunning {
        Darwin.kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
      }
    }
    process = nil
    pipe = nil
  }

  private func launch() {
    cleanup(terminate: true)  // never leave a stale process/handler around before respawning
    guard
      let script = Bundle.main.url(forResource: "mediaremote-adapter", withExtension: "pl"),
      let frameworks = Bundle.main.privateFrameworksPath
    else {
      Log.media.error("Adapter script or framework missing from bundle")
      onStatus?("Adapter missing from bundle")
      isRunning = false  // allow a future start() to retry
      return
    }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
    p.arguments = [script.path, frameworks + "/MediaRemoteAdapter.framework", "stream"]
    let pp = Pipe()
    p.standardOutput = pp
    p.standardError = FileHandle.nullDevice

    pp.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      guard let self else { return }
      if data.isEmpty {
        handle.readabilityHandler = nil  // EOF — terminationHandler drives the restart
        return
      }
      self.queue.async { self.consume(data) }
    }
    p.terminationHandler = { [weak self] _ in
      self?.queue.async { self?.processDied() }
    }
    do {
      try p.run()
      process = p
      pipe = pp
      Log.media.info("Adapter started (pid \(p.processIdentifier))")
      onStatus?("Streaming")
    } catch {
      Log.media.error("Adapter launch failed: \(error)")
      processDied()
    }
  }

  private func consume(_ data: Data) {
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
  /// `:437-449`). A change of source key therefore means the previous source is *gone*, not
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
    for update in Self.expand(
      AdapterParser.parse(line: line, current: base), current: currentSource)
    {
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

  private func processDied() {
    cleanup(terminate: false)  // already dead; just detach handlers
    buffer.removeAll(keepingCapacity: true)
    guard isRunning else { return }
    failureCount += 1
    let delay = Self.backoffDelay(failureCount: failureCount)
    Log.media.warning("Adapter died; restarting in \(delay)s (failure #\(self.failureCount))")
    onStatus?("Restarting in \(Int(delay))s (failure #\(failureCount))")
    restartTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(delay))
      guard !Task.isCancelled else { return }
      self?.queue.async { self?.launch() }
    }
  }
}
