import Darwin
import XCTest

@testable import Islet

final class MediaWatcherTests: XCTestCase {
  private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
      lock.lock()
      count += 1
      lock.unlock()
    }

    var value: Int {
      lock.lock()
      defer { lock.unlock() }
      return count
    }
  }

  func testBackoffDoublesAndCaps() {
    XCTAssertEqual(MediaWatcher.backoffDelay(failureCount: 1), 1)
    XCTAssertEqual(MediaWatcher.backoffDelay(failureCount: 2), 2)
    XCTAssertEqual(MediaWatcher.backoffDelay(failureCount: 4), 8)
    XCTAssertEqual(MediaWatcher.backoffDelay(failureCount: 10), 60)
  }

  func testStderrCaptureRedactsPathsAndPayloads() {
    let capture = MediaWatcher.StderrCapture(maximumBytes: 256)
    capture.append(Data("Failed to load /Users/nedlane/Library/Private.framework\n".utf8))
    capture.append(Data("{\"title\":\"Private Track\",\"artworkData\":\"secret\"}".utf8))

    let diagnostic = String(decoding: capture.snapshot.data, as: UTF8.self)
    XCTAssertTrue(diagnostic.contains("Failed to load <path>"))
    XCTAssertTrue(diagnostic.contains("[media payload redacted]"))
    XCTAssertFalse(diagnostic.contains("/Users/nedlane"))
    XCTAssertFalse(diagnostic.contains("Private Track"))
    XCTAssertFalse(diagnostic.contains("secret"))
  }

  func testStderrCaptureRedactsNestedPayloadsAndPathsContainingSpacesAcrossChunks() {
    let capture = MediaWatcher.StderrCapture(maximumBytes: 512)
    capture.append(Data("{\"payload\": {\n\"customField\": \"private ".utf8))
    capture.append(Data("value\"\n}\n}\nFailed at /Users/Ned Lane/Private Track.mp3".utf8))

    let diagnostic = String(decoding: capture.snapshot.data, as: UTF8.self)
    XCTAssertFalse(diagnostic.contains("customField"))
    XCTAssertFalse(diagnostic.contains("private value"))
    XCTAssertFalse(diagnostic.contains("Ned Lane"))
    XCTAssertFalse(diagnostic.contains("Private Track"))
    XCTAssertTrue(diagnostic.contains("Failed at <path>"))
  }

  func testStderrCaptureRotatesNoisyOutputWithinItsByteLimit() {
    let capture = MediaWatcher.StderrCapture(maximumBytes: 32)
    capture.append(Data("first diagnostic\n".utf8))
    capture.append(Data("012345678901234567890123456789\nlatest\n".utf8))

    let snapshot = capture.snapshot
    let diagnostic = String(decoding: snapshot.data, as: UTF8.self)
    XCTAssertLessThanOrEqual(snapshot.data.count, 32)
    XCTAssertTrue(snapshot.exceededLimit)
    XCTAssertFalse(diagnostic.contains("first diagnostic"))
    XCTAssertTrue(diagnostic.contains("latest"))
  }

  func testStderrCaptureCapsOversizedOutput() {
    let capture = MediaWatcher.StderrCapture(maximumBytes: 64)
    capture.append(Data(repeating: UInt8(ascii: "x"), count: 8_192))

    let snapshot = capture.snapshot
    XCTAssertEqual(snapshot.data.count, 64)
    XCTAssertTrue(snapshot.exceededLimit)
  }

  func testSnapshotStartupDeadlineBeforeOutput() {
    let tracker = MediaWatcher.SnapshotDeadlineTracker(
      startedAt: 10,
      timeouts: .init(startup: 2, idle: 3, total: 8))

    XCTAssertNil(tracker.expired(at: 11.999))
    XCTAssertEqual(tracker.expired(at: 12), .startup)
    XCTAssertEqual(tracker.nextDeadline(after: 10), 12)
  }

  func testSnapshotIdleDeadlineMovesWithOutput() {
    var tracker = MediaWatcher.SnapshotDeadlineTracker(
      startedAt: 10,
      timeouts: .init(startup: 2, idle: 3, total: 8))
    tracker.receivedOutput(at: 11)

    XCTAssertNil(tracker.expired(at: 13.999))
    XCTAssertEqual(tracker.expired(at: 14), .idle)
    XCTAssertEqual(tracker.nextDeadline(after: 11), 14)
  }

  func testSnapshotTotalDeadlineCannotBeExtendedByOutput() {
    var tracker = MediaWatcher.SnapshotDeadlineTracker(
      startedAt: 10,
      timeouts: .init(startup: 2, idle: 3, total: 8))
    tracker.receivedOutput(at: 17.5)

    XCTAssertNil(tracker.expired(at: 17.999))
    XCTAssertEqual(tracker.expired(at: 18), .total)
    XCTAssertEqual(tracker.nextDeadline(after: 17.5), 18)
  }

  func testInitialSnapshotRejectsMalformedOutput() {
    XCTAssertNil(MediaWatcher.parseInitialSnapshot(data: Data("not json".utf8)))
  }

  func testInitialSnapshotAcceptsIdlePayload() {
    XCTAssertEqual(MediaWatcher.parseInitialSnapshot(data: Data("{}".utf8)), .idle)
  }

  func testHangingSnapshotTimesOutReapsAndRetriesWithoutOverlap() throws {
    let helper = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .appendingPathComponent("Fixtures/hanging-media-helper.pl")
    XCTAssertTrue(FileManager.default.fileExists(atPath: helper.path))
    let log = FileManager.default.temporaryDirectory.appendingPathComponent(
      "media-watcher-\(UUID().uuidString).log")
    defer {
      try? FileManager.default.removeItem(at: log)
      try? FileManager.default.removeItem(atPath: log.path + ".stream.lock")
      try? FileManager.default.removeItem(atPath: log.path + ".get.lock")
    }

    let snapshotAttempts = LockedCounter()
    let secondTimeout = expectation(description: "two snapshot attempts time out")
    secondTimeout.expectedFulfillmentCount = 2
    let watcher = MediaWatcher(
      snapshotTimeouts: .init(startup: 2, idle: 0.15, total: 3),
      initialSnapshotDelay: 0,
      commandProvider: { kind in
        if case .snapshot = kind { snapshotAttempts.increment() }
        return MediaWatcher.HelperCommand(
          executableURL: URL(fileURLWithPath: "/usr/bin/perl"),
          arguments: [helper.path, kind.rawValue, log.path])
      },
      snapshotBackoff: { _ in 0.05 })
    watcher.onStatus = { status in
      if status.contains("snapshot idle timeout") { secondTimeout.fulfill() }
    }
    watcher.start()
    wait(for: [secondTimeout], timeout: 5)
    watcher.stop()

    let records = try String(contentsOf: log, encoding: .utf8)
      .split(separator: "\n").map(String.init)
    let snapshotStarts = records.filter { $0.hasPrefix("started get ") }
    XCTAssertGreaterThanOrEqual(snapshotAttempts.value, 2)
    XCTAssertGreaterThanOrEqual(snapshotStarts.count, 2)
    XCTAssertLessThanOrEqual(snapshotStarts.count, snapshotAttempts.value)
    XCTAssertFalse(records.contains { $0.hasPrefix("overlap ") })

    for record in records where record.hasPrefix("started ") {
      let pid = try XCTUnwrap(Int32(record.split(separator: " ").last ?? ""))
      XCTAssertEqual(Darwin.kill(pid, 0), -1, "helper pid \(pid) is still present")
      XCTAssertEqual(errno, ESRCH, "helper pid \(pid) was not reaped")
    }
  }

  func testInitialSnapshotIsRejectedAfterIdleStreamRecord() {
    XCTAssertFalse(
      MediaWatcher.shouldAcceptInitialSnapshot(
        streamHasEmittedRecord: true, currentSource: nil))
  }

  func testInitialSnapshotIsAcceptedBeforeAnyStreamRecord() {
    XCTAssertTrue(
      MediaWatcher.shouldAcceptInitialSnapshot(
        streamHasEmittedRecord: false, currentSource: nil))
  }

  func testInitialSnapshotIsRejectedWhenStreamHasCurrentSource() {
    XCTAssertFalse(
      MediaWatcher.shouldAcceptInitialSnapshot(
        streamHasEmittedRecord: false, currentSource: key("com.spotify.client", 1)))
  }

  func testRecoverySnapshotIsAcceptedWhileAudioRemainsActive() {
    XCTAssertTrue(
      MediaWatcher.shouldAcceptRecoverySnapshot(
        requestedGeneration: 4,
        currentGeneration: 4,
        currentSource: nil,
        playbackRecoveryActive: true))
  }

  func testRecoverySnapshotIsRejectedAfterANewerStreamRecord() {
    XCTAssertFalse(
      MediaWatcher.shouldAcceptRecoverySnapshot(
        requestedGeneration: 4,
        currentGeneration: 5,
        currentSource: nil,
        playbackRecoveryActive: true))
  }

  func testRecoverySnapshotIsRejectedWhenAudioStopsOrAStreamSourceWins() {
    XCTAssertFalse(
      MediaWatcher.shouldAcceptRecoverySnapshot(
        requestedGeneration: 4,
        currentGeneration: 4,
        currentSource: nil,
        playbackRecoveryActive: false))
    XCTAssertFalse(
      MediaWatcher.shouldAcceptRecoverySnapshot(
        requestedGeneration: 4,
        currentGeneration: 4,
        currentSource: key("com.spotify.client", 1),
        playbackRecoveryActive: true))
  }

  func testActiveAudioRecoversMetadataAfterTheStreamEmitsIdle() {
    let helper = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .appendingPathComponent("Fixtures/recovering-media-helper.pl")
    XCTAssertTrue(FileManager.default.fileExists(atPath: helper.path))
    let idle = expectation(description: "stream reports idle")
    let recovered = expectation(description: "snapshot recovers current source")
    let watcher = MediaWatcher(
      initialSnapshotDelay: 1,
      commandProvider: { kind in
        MediaWatcher.HelperCommand(
          executableURL: URL(fileURLWithPath: "/usr/bin/perl"),
          arguments: [helper.path, kind.rawValue])
      },
      snapshotBackoff: { _ in 0.05 })
    let updates = Task {
      for await update in watcher.updates {
        switch update {
        case .idle:
          idle.fulfill()
          watcher.setPlaybackRecoverySources(["company.thebrowser.Browser"])
        case .nowPlaying(let source, let state):
          XCTAssertEqual(source.displayBundleIdentifier, "company.thebrowser.Browser")
          XCTAssertEqual(state.title, "Recovered video")
          recovered.fulfill()
          return
        case .ignored, .sourceGone:
          continue
        }
      }
    }
    watcher.start()
    wait(for: [idle, recovered], timeout: 5, enforceOrder: true)
    watcher.stop()
    updates.cancel()
  }

  func testNonActiveRecoverySnapshotRetriesBeforeAcceptingTheActiveApp() throws {
    let helper = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .appendingPathComponent("Fixtures/wrong-app-recovery-helper.pl")
    let stateFile = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("wrong-app-recovery-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: stateFile) }

    XCTAssertTrue(FileManager.default.fileExists(atPath: helper.path))
    let idle = expectation(description: "stream reports idle")
    let recovered = expectation(description: "active app is recovered after wrong snapshot")
    let snapshotAttempts = LockedCounter()
    let watcher = MediaWatcher(
      initialSnapshotDelay: 1,
      commandProvider: { kind in
        if case .snapshot = kind { snapshotAttempts.increment() }
        return MediaWatcher.HelperCommand(
          executableURL: URL(fileURLWithPath: "/usr/bin/perl"),
          arguments: [helper.path, kind.rawValue, stateFile.path])
      },
      snapshotBackoff: { _ in 0.05 })
    let updates = Task {
      for await update in watcher.updates {
        switch update {
        case .idle:
          idle.fulfill()
          watcher.setPlaybackRecoverySources(["company.thebrowser.Browser"])
        case .nowPlaying(let source, let playback):
          XCTAssertEqual(source.displayBundleIdentifier, "company.thebrowser.Browser")
          XCTAssertEqual(playback.title, "Recovered video")
          recovered.fulfill()
          return
        case .ignored, .sourceGone:
          continue
        }
      }
    }

    watcher.start()
    wait(for: [idle, recovered], timeout: 5, enforceOrder: true)
    XCTAssertEqual(snapshotAttempts.value, 2)
    watcher.stop()
    updates.cancel()
  }

  func testNonActiveRecoverySnapshotStopsAfterThreeMismatches() throws {
    let helper = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .appendingPathComponent("Fixtures/wrong-app-recovery-helper.pl")
    let stateFile = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("wrong-app-recovery-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: stateFile) }

    XCTAssertTrue(FileManager.default.fileExists(atPath: helper.path))
    let idle = expectation(description: "stream reports idle")
    let recoveryStopped = expectation(description: "recovery stops after three mismatches")
    let snapshotAttempts = LockedCounter()
    let watcher = MediaWatcher(
      initialSnapshotDelay: 1,
      commandProvider: { kind in
        if case .snapshot = kind { snapshotAttempts.increment() }
        return MediaWatcher.HelperCommand(
          executableURL: URL(fileURLWithPath: "/usr/bin/perl"),
          arguments: [helper.path, kind.rawValue, stateFile.path])
      },
      snapshotBackoff: { _ in 0.05 })
    watcher.onStatus = { status in
      if status.contains("recovery stopped") { recoveryStopped.fulfill() }
    }
    let updates = Task {
      for await update in watcher.updates {
        guard case .idle = update else { continue }
        idle.fulfill()
        watcher.setPlaybackRecoverySources(["com.example.NeverMatches"])
        return
      }
    }

    watcher.start()
    wait(for: [idle, recoveryStopped], timeout: 5, enforceOrder: true)
    XCTAssertEqual(snapshotAttempts.value, 3)
    watcher.stop()
    updates.cancel()
  }

  func testRepeatedIdleDoesNotReopenExhaustedRecoveryBudget() throws {
    let helper = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .appendingPathComponent("Fixtures/wrong-app-recovery-helper.pl")
    let stateFile = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("wrong-app-recovery-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: stateFile) }

    XCTAssertTrue(FileManager.default.fileExists(atPath: helper.path))
    let firstIdle = expectation(description: "stream reports its first idle record")
    let recoveryStopped = expectation(description: "recovery budget is exhausted")
    let secondIdle = expectation(description: "stream repeats idle with the same audio source")
    let unexpectedFourthAttempt = expectation(description: "a fourth recovery attempt starts")
    unexpectedFourthAttempt.isInverted = true
    let idleRecords = LockedCounter()
    let recoverySnapshotAttempts = LockedCounter()
    let watcher = MediaWatcher(
      initialSnapshotDelay: 0.05,
      commandProvider: { kind in
        if case .snapshot = kind, idleRecords.value > 0 {
          recoverySnapshotAttempts.increment()
          if recoverySnapshotAttempts.value > 3 { unexpectedFourthAttempt.fulfill() }
        }
        return MediaWatcher.HelperCommand(
          executableURL: URL(fileURLWithPath: "/usr/bin/perl"),
          arguments: [helper.path, kind.rawValue, stateFile.path, "100", "2"])
      },
      snapshotBackoff: { _ in 0.01 })
    watcher.onStatus = { status in
      if status.contains("recovery stopped") { recoveryStopped.fulfill() }
    }
    let updates = Task {
      for await update in watcher.updates {
        guard case .idle = update else { continue }
        idleRecords.increment()
        if idleRecords.value == 1 {
          firstIdle.fulfill()
        } else if idleRecords.value == 2 {
          secondIdle.fulfill()
        }
        watcher.setPlaybackRecoverySources(["company.thebrowser.Browser"])
      }
    }

    watcher.start()
    wait(for: [firstIdle, recoveryStopped, secondIdle], timeout: 5, enforceOrder: true)
    wait(for: [unexpectedFourthAttempt], timeout: 0.3)
    XCTAssertEqual(recoverySnapshotAttempts.value, 3)
    watcher.stop()
    updates.cancel()
  }

  func testRecoveryRetryBudgetResetsWhenAudioSourcesChange() throws {
    let helper = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .appendingPathComponent("Fixtures/wrong-app-recovery-helper.pl")
    let stateFile = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("wrong-app-recovery-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: stateFile) }

    XCTAssertTrue(FileManager.default.fileExists(atPath: helper.path))
    let idle = expectation(description: "stream reports idle")
    let firstRecoveryStopped = expectation(description: "first recovery budget is exhausted")
    let recovered = expectation(description: "changed audio sources receive a fresh retry budget")
    let snapshotAttempts = LockedCounter()
    let watcher = MediaWatcher(
      initialSnapshotDelay: 1,
      commandProvider: { kind in
        if case .snapshot = kind { snapshotAttempts.increment() }
        return MediaWatcher.HelperCommand(
          executableURL: URL(fileURLWithPath: "/usr/bin/perl"),
          arguments: [helper.path, kind.rawValue, stateFile.path, "4"])
      },
      snapshotBackoff: { _ in 0.05 })
    watcher.onStatus = { status in
      guard status.contains("recovery stopped"), snapshotAttempts.value == 3 else { return }
      firstRecoveryStopped.fulfill()
      watcher.setPlaybackRecoverySources([])
      watcher.setPlaybackRecoverySources(["company.thebrowser.Browser"])
    }
    let updates = Task {
      for await update in watcher.updates {
        switch update {
        case .idle:
          idle.fulfill()
          watcher.setPlaybackRecoverySources(["company.thebrowser.Browser"])
        case .nowPlaying(let source, _):
          XCTAssertEqual(source.displayBundleIdentifier, "company.thebrowser.Browser")
          recovered.fulfill()
          return
        case .ignored, .sourceGone:
          continue
        }
      }
    }

    watcher.start()
    wait(for: [idle, firstRecoveryStopped, recovered], timeout: 5, enforceOrder: true)
    XCTAssertEqual(snapshotAttempts.value, 5)
    watcher.stop()
    updates.cancel()
  }

  func testRecoveryOnlyAcceptsMetadataForAnActiveAudioApp() {
    let browser = key("company.thebrowser.Browser", 1)
    let music = key("com.apple.Music", 2)
    let browserUpdate = AdapterUpdate.nowPlaying(browser, state("Video"))

    XCTAssertTrue(
      MediaWatcher.shouldAcceptRecoveredUpdate(
        browserUpdate, activeBundleIdentifiers: ["company.thebrowser.Browser"]))
    XCTAssertFalse(
      MediaWatcher.shouldAcceptRecoveredUpdate(
        browserUpdate, activeBundleIdentifiers: ["com.apple.Music"]))
    XCTAssertFalse(
      MediaWatcher.shouldAcceptRecoveredUpdate(
        .nowPlaying(music, state("Song")), activeBundleIdentifiers: ["company.thebrowser.Browser"]))
    XCTAssertFalse(
      MediaWatcher.shouldAcceptRecoveredUpdate(
        .idle, activeBundleIdentifiers: ["company.thebrowser.Browser"]))
  }

  func key(_ bundle: String, _ pid: Int32) -> SourceID {
    SourceID(bundleIdentifier: bundle, pid: pid, parentBundleIdentifier: "")
  }

  /// Build the state ONCE per test and reuse it. `PlaybackState.elapsedAt` defaults to `Date()`,
  /// so two separate constructions are never equal.
  func state(_ title: String) -> PlaybackState {
    var s = PlaybackState()
    s.title = title
    s.isPlaying = true
    return s
  }

  func testIgnoredExpandsToNothing() {
    XCTAssertEqual(MediaWatcher.expand(.ignored, current: nil), [])
    XCTAssertEqual(
      MediaWatcher.expand(.ignored, current: key("com.spotify.client", 1)), [])
  }

  func testFirstSourceJustPublishes() {
    let spotify = key("com.spotify.client", 1)
    let playing = state("A")
    XCTAssertEqual(
      MediaWatcher.expand(.nowPlaying(spotify, playing), current: nil),
      [.nowPlaying(spotify, playing)])
  }

  func testSameSourceDoesNotEvict() {
    let spotify = key("com.spotify.client", 1)
    let playing = state("B")
    XCTAssertEqual(
      MediaWatcher.expand(.nowPlaying(spotify, playing), current: spotify),
      [.nowPlaying(spotify, playing)])
  }

  func testSourceChangeEvictsThePreviousSourceFirst() {
    // The vendored adapter calls resetAll() on a process change, so the previous source is not
    // backgrounded — it is gone.
    let spotify = key("com.spotify.client", 1)
    let music = key("com.apple.Music", 2)
    let playing = state("B")
    XCTAssertEqual(
      MediaWatcher.expand(.nowPlaying(music, playing), current: spotify),
      [.sourceGone(spotify), .nowPlaying(music, playing)])
  }

  func testIdlePassesThrough() {
    XCTAssertEqual(MediaWatcher.expand(.idle, current: key("com.spotify.client", 1)), [.idle])
    XCTAssertEqual(MediaWatcher.expand(.idle, current: nil), [.idle])
  }

  func testSourceGonePassesThrough() {
    let spotify = key("com.spotify.client", 1)
    XCTAssertEqual(
      MediaWatcher.expand(.sourceGone(spotify), current: spotify), [.sourceGone(spotify)])
  }
}
