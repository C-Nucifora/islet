import Foundation

/// Spawns the bundled mediaremote-adapter under /usr/bin/perl and streams updates.
/// The adapter is expected to die and respawn (macOS may kill it), so every process/pipe is
/// torn down cleanly on each restart to avoid leaking file handles or stale handlers.
final class MediaWatcher: @unchecked Sendable {
  private let queue = DispatchQueue(label: "dev.cnucifora.Islet.mediawatcher")
  private var process: Process?
  private var pipe: Pipe?
  private var restartTask: Task<Void, Never>?
  private var failureCount = 0
  private var lastState: PlaybackState?
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
  }

  static func backoffDelay(failureCount: Int) -> TimeInterval {
    min(pow(2, Double(failureCount - 1)), 60)
  }

  func start() {
    queue.async { [self] in
      guard !isRunning else { return }
      isRunning = true
      launch()
    }
  }

  func stop() {
    queue.async { [self] in
      isRunning = false
      restartTask?.cancel()
      cleanup(terminate: true)
    }
  }

  /// Detaches handlers and drops the current process/pipe. Must run on `queue`.
  private func cleanup(terminate: Bool) {
    pipe?.fileHandleForReading.readabilityHandler = nil
    process?.terminationHandler = nil
    if terminate { process?.terminate() }
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
    while let nl = buffer.firstIndex(of: UInt8(ascii: "\n")) {
      let lineData = buffer[..<nl]
      buffer.removeSubrange(...nl)
      guard let line = String(data: lineData, encoding: .utf8) else { continue }
      handle(line: line)
    }
  }

  private func handle(line: String) {
    let update = AdapterParser.parse(line: line, current: lastState)
    switch update {
    case .ignored:
      return
    case .idle:
      failureCount = 0
      lastState = nil
    case .nowPlaying(let state):
      failureCount = 0
      lastState = state
    }
    continuation.yield(update)
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
