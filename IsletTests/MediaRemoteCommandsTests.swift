import XCTest

@testable import Islet

final class MediaRemoteCommandsTests: XCTestCase {
  private actor Harness {
    private var sentCommands: [(MediaCommand, SourceID?)] = []
    var acceptsCommands = true

    func send(_ command: MediaCommand, to source: SourceID?) -> MediaCommandDelivery {
      sentCommands.append((command, source))
      return acceptsCommands ? .accepted : .rejected
    }

    func rejectCommands() { acceptsCommands = false }
    func commands() -> [(MediaCommand, SourceID?)] { sentCommands }
  }

  private func source(_ bundleID: String, _ pid: Int32) -> SourceID {
    SourceID(bundleIdentifier: bundleID, pid: pid, parentBundleIdentifier: "")
  }

  func testCurrentGlobalTransportFailsClosedWithoutSending() async {
    let spotify = source("com.spotify.client", 10)
    let harness = Harness()

    let result = await MediaCommandRouter.perform(
      .togglePlayPause,
      shownSource: spotify,
      sourceIsAdapterBacked: true,
      targeting: .unavailable,
      send: { command, source in await harness.send(command, to: source) })

    XCTAssertEqual(result, .sourceTargetingUnavailable(spotify))
    let commands = await harness.commands()
    XCTAssertTrue(commands.isEmpty)
  }

  func testGlobalTargetSwitchAfterResolutionNeverReachesSend() async {
    let shownSource = source("com.spotify.client", 10)
    let harness = Harness()

    // The current adapter exposes only a separate global target read and global command. Since an
    // external player can switch between them, the router must never enter the send closure.
    let result = await MediaCommandRouter.perform(
      .next,
      shownSource: shownSource,
      sourceIsAdapterBacked: true,
      targeting: MediaRemoteCommands.shared.targeting,
      send: { command, source in await harness.send(command, to: source) })

    XCTAssertEqual(result, .sourceTargetingUnavailable(shownSource))
    let commands = await harness.commands()
    XCTAssertTrue(commands.isEmpty)
  }

  func testCoreAudioOnlySourceNeverSendsACommand() async {
    let call = source("com.example.Call", 40)
    let harness = Harness()

    let result = await MediaCommandRouter.perform(
      .togglePlayPause,
      shownSource: call,
      sourceIsAdapterBacked: false,
      targeting: .sourceScoped,
      send: { command, source in await harness.send(command, to: source) })

    XCTAssertEqual(result, .sourceNotControllable(call))
    let commands = await harness.commands()
    XCTAssertTrue(commands.isEmpty)
  }

  func testSourceScopedTransportReceivesTheSelectedSource() async {
    let music = source("com.apple.Music", 20)
    let harness = Harness()

    let result = await MediaCommandRouter.perform(
      .seek(to: 42),
      shownSource: music,
      sourceIsAdapterBacked: true,
      targeting: .sourceScoped,
      send: { command, source in await harness.send(command, to: source) })

    XCTAssertEqual(result, .sent(target: music, sourceScoped: true))
    let commands = await harness.commands()
    XCTAssertEqual(commands.count, 1)
    XCTAssertEqual(commands.first?.0, .seek(to: 42))
    XCTAssertEqual(commands.first?.1, music)
  }

  func testSourceScopedTransportRejectionIsReported() async {
    let music = source("com.apple.Music", 20)
    let harness = Harness()
    await harness.rejectCommands()

    let result = await MediaCommandRouter.perform(
      .next,
      shownSource: music,
      sourceIsAdapterBacked: true,
      targeting: .sourceScoped,
      send: { command, source in await harness.send(command, to: source) })

    XCTAssertEqual(result, .rejected(target: music))
  }

  func testSourceScopedTransportPreservesUnconfirmedDelivery() async {
    let music = source("com.apple.Music", 20)

    let result = await MediaCommandRouter.perform(
      .seek(to: 42),
      shownSource: music,
      sourceIsAdapterBacked: true,
      targeting: .sourceScoped,
      send: { _, _ in .unconfirmed })

    XCTAssertEqual(result, .unconfirmed(target: music))
  }

  func testVoidSeekTransportReportsUnconfirmedDelivery() {
    var requestedPositions: [Double] = []

    let delivery = MediaCommandDispatch.send(
      .seek(to: 42),
      sendCommand: { _ in true },
      setElapsed: { requestedPositions.append($0) })

    XCTAssertEqual(delivery, .unconfirmed)
    XCTAssertEqual(requestedPositions, [42])
  }

  func testCurrentAdapterPresentationExplainsUnavailableControls() {
    XCTAssertEqual(
      MediaControlPresentation.scopeLabel(appName: "Music", targeting: .unavailable),
      "Controls unavailable for Music")
    XCTAssertEqual(
      MediaControlPresentation.help(action: "Pause", appName: "Music", targeting: .unavailable),
      "Pause unavailable because Islet cannot target Music safely")
    XCTAssertEqual(
      MediaControlPresentation.accessibilityLabel(action: "Pause", targeting: .unavailable),
      "Pause unavailable")
  }

  func testCommandQueueDoesNotOverlapOperations() async {
    let queue = MediaCommandQueue()
    let probe = QueueOverlapProbe()
    let spotify = source("com.spotify.client", 10)

    await withTaskGroup(of: MediaCommandResult.self) { group in
      for _ in 0..<8 {
        group.addTask {
          await queue.enqueue {
            await probe.begin()
            try? await Task.sleep(for: .milliseconds(20))
            await probe.end()
            return .sent(target: spotify, sourceScoped: false)
          }
        }
      }
      for await _ in group {}
    }

    let maximumConcurrentOperations = await probe.maximumConcurrentOperations
    XCTAssertEqual(maximumConcurrentOperations, 1)
  }

  func testFeedbackNamesTheAttemptedActionWithoutLeakingSourceIdentity() {
    let privateSource = source("com.example.private-player", 20)
    let message = MediaControlFeedback.message(
      for: .seek(to: 42), result: .rejected(target: privateSource))

    XCTAssertEqual(message, "Can't seek: the player rejected it")
    XCTAssertFalse(message?.contains(privateSource.displayBundleIdentifier) == true)
    XCTAssertEqual(
      MediaControlFeedback.logReason(for: .rejected(target: privateSource)), "rejected")
  }

  func testFeedbackExplainsUnavailableAtomicTargeting() {
    let privateSource = source("com.example.private-player", 20)
    XCTAssertEqual(
      MediaControlFeedback.message(
        for: .togglePlayPause, result: .sourceTargetingUnavailable(privateSource)),
      "Can't change playback: Islet can't target this player safely")
    XCTAssertEqual(
      MediaControlFeedback.logReason(for: .sourceTargetingUnavailable(privateSource)),
      "source-targeting-unavailable")
  }

  func testFeedbackExplainsUnconfirmedSeek() {
    let source = source("com.example.Player", 20)

    XCTAssertEqual(
      MediaControlFeedback.message(for: .seek(to: 42), result: .unconfirmed(target: source)),
      "Couldn't confirm seek: the player didn't report a result")
    XCTAssertEqual(
      MediaControlFeedback.logReason(for: .unconfirmed(target: source)), "unconfirmed")
  }
}

private actor QueueOverlapProbe {
  private var activeOperations = 0
  private(set) var maximumConcurrentOperations = 0

  func begin() {
    activeOperations += 1
    maximumConcurrentOperations = max(maximumConcurrentOperations, activeOperations)
  }

  func end() { activeOperations -= 1 }
}
