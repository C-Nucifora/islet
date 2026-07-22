import Foundation

/// Spawns the bundled mediaremote-adapter under /usr/bin/perl and streams updates.
final class MediaWatcher: @unchecked Sendable {
  private let queue = DispatchQueue(label: "dev.cnucifora.Islet.mediawatcher")
  private var process: Process?
  private var restartTask: Task<Void, Never>?
  private var failureCount = 0
  private var lastState: PlaybackState?
  private var buffer = Data()  // guarded by `queue`
  private var isRunning = false
  private var continuation: AsyncStream<AdapterUpdate>.Continuation?

  private(set) lazy var updates: AsyncStream<AdapterUpdate> = AsyncStream { cont in
    self.continuation = cont
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
      process?.terminate()
      process = nil
    }
  }

  private func launch() {
    guard
      let script = Bundle.main.url(forResource: "mediaremote-adapter", withExtension: "pl"),
      let frameworks = Bundle.main.privateFrameworksPath
    else {
      Log.media.error("Adapter script or framework missing from bundle")
      return
    }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
    p.arguments = [script.path, frameworks + "/MediaRemoteAdapter.framework", "stream"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice

    pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      self?.queue.async { self?.consume(data) }
    }
    p.terminationHandler = { [weak self] _ in
      self?.queue.async { self?.processDied() }
    }
    do {
      try p.run()
      process = p
      Log.media.info("Adapter started (pid \(p.processIdentifier))")
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
    continuation?.yield(update)
  }

  private func processDied() {
    process = nil
    guard isRunning else { return }
    failureCount += 1
    let delay = Self.backoffDelay(failureCount: failureCount)
    Log.media.warning("Adapter died; restarting in \(delay)s (failure #\(self.failureCount))")
    restartTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(delay))
      guard !Task.isCancelled else { return }
      self?.queue.async { self?.launch() }
    }
  }
}
