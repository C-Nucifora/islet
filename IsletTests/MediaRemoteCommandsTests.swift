import XCTest

@testable import Islet

final class MediaRemoteCommandsTests: XCTestCase {
  private actor Harness {
    private var sentCommands: [(MediaCommand, SourceID?)] = []
    private var events: [String] = []
    private var currentTarget: SourceID?
    var acceptsCommands = true

    func setCurrentTarget(_ source: SourceID?) { currentTarget = source }

    func resolveCurrentTarget() -> SourceID? {
      events.append("resolve")
      return currentTarget
    }

    func send(_ command: MediaCommand, to source: SourceID?) -> Bool {
      events.append("send")
      sentCommands.append((command, source))
      return acceptsCommands
    }

    func rejectCommands() { acceptsCommands = false }
    func commands() -> [(MediaCommand, SourceID?)] { sentCommands }
    func recordedEvents() -> [String] { events }
  }

  private func source(_ bundleID: String, _ pid: Int32) -> SourceID {
    SourceID(bundleIdentifier: bundleID, pid: pid, parentBundleIdentifier: "")
  }

  func testVerifiedGlobalTransportResolvesTargetThenSendsGlobally() async {
    let spotify = source("com.spotify.client", 10)
    let harness = Harness()
    await harness.setCurrentTarget(spotify)

    let result = await MediaCommandRouter.perform(
      .togglePlayPause,
      shownSource: spotify,
      sourceIsAdapterBacked: true,
      targeting: .verifiedGlobal,
      resolveCurrentTarget: { await harness.resolveCurrentTarget() },
      send: { command, source in await harness.send(command, to: source) })

    XCTAssertEqual(result, .sent(target: spotify, sourceScoped: false))
    let commands = await harness.commands()
    XCTAssertEqual(commands.count, 1)
    XCTAssertEqual(commands.first?.0, .togglePlayPause)
    XCTAssertNil(commands.first?.1)
    let events = await harness.recordedEvents()
    XCTAssertEqual(events, ["resolve", "send"])
  }

  func testVerifiedGlobalTransportRefusesWhenCurrentTargetChanged() async {
    let shownSource = source("com.spotify.client", 10)
    let actualSource = source("com.apple.Music", 20)
    let harness = Harness()
    await harness.setCurrentTarget(actualSource)

    let result = await MediaCommandRouter.perform(
      .next,
      shownSource: shownSource,
      sourceIsAdapterBacked: true,
      targeting: .verifiedGlobal,
      resolveCurrentTarget: { await harness.resolveCurrentTarget() },
      send: { command, source in await harness.send(command, to: source) })

    XCTAssertEqual(result, .sourceTargetingUnavailable(shownSource))
    let commands = await harness.commands()
    XCTAssertTrue(commands.isEmpty)
    let events = await harness.recordedEvents()
    XCTAssertEqual(events, ["resolve"])
  }

  func testVerifiedGlobalTransportRequiresExactProcessIdentity() async {
    let shownSource = source("com.spotify.client", 10)
    let replacementProcess = source("com.spotify.client", 11)
    let harness = Harness()
    await harness.setCurrentTarget(replacementProcess)

    let result = await MediaCommandRouter.perform(
      .next,
      shownSource: shownSource,
      sourceIsAdapterBacked: true,
      targeting: .verifiedGlobal,
      resolveCurrentTarget: { await harness.resolveCurrentTarget() },
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
      resolveCurrentTarget: { await harness.resolveCurrentTarget() },
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
      resolveCurrentTarget: { await harness.resolveCurrentTarget() },
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
      resolveCurrentTarget: { await harness.resolveCurrentTarget() },
      send: { command, source in await harness.send(command, to: source) })

    XCTAssertEqual(result, .rejected(target: music))
  }

  func testCurrentAdapterPresentationLabelsVerifiedGlobalControlsHonestly() {
    XCTAssertEqual(
      MediaControlPresentation.scopeLabel(appName: "Music", targeting: .verifiedGlobal),
      "Global controls for Music")
    XCTAssertEqual(
      MediaControlPresentation.help(action: "Pause", appName: "Music", targeting: .verifiedGlobal),
      "Pause in Music after verifying the global media target")
    XCTAssertEqual(
      MediaControlPresentation.accessibilityLabel(action: "Pause", targeting: .verifiedGlobal),
      "Pause, verified global media control")
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
