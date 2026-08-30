import XCTest

@testable import Islet

final class MediaRemoteCommandsTests: XCTestCase {
  private actor Harness {
    private var sentCommands: [(MediaCommand, SourceID?)] = []
    var acceptsCommands = true

    func send(_ command: MediaCommand, to source: SourceID?) -> Bool {
      sentCommands.append((command, source))
      return acceptsCommands
    }

    func rejectCommands() { acceptsCommands = false }
    func commands() -> [(MediaCommand, SourceID?)] { sentCommands }
  }

  private func source(_ bundleID: String, _ pid: Int32) -> SourceID {
    SourceID(bundleIdentifier: bundleID, pid: pid, parentBundleIdentifier: "")
  }

  func testCurrentUnscopedTransportFailsClosedWithoutSending() async {
    let spotify = source("com.spotify.client", 10)
    let harness = Harness()

    let result = await MediaCommandRouter.perform(
      .togglePlayPause,
      shownSource: spotify,
      sourceIsAdapterBacked: true,
      supportsSourceScopedCommands: false,
      send: { command, source in await harness.send(command, to: source) })

    XCTAssertEqual(result, .sourceTargetingUnavailable(spotify))
    let commands = await harness.commands()
    XCTAssertTrue(commands.isEmpty)
  }

  func testExternalTargetSwitchCannotRaceAnUnscopedSend() async {
    let shownSource = source("com.spotify.client", 10)
    let harness = Harness()
    // The old implementation resolved a matching snapshot here, then sent a separate global
    // command. A player switch between those operations could target another app. The current
    // transport has no atomic targeting primitive, so the send closure must never be reached.
    let result = await MediaCommandRouter.perform(
      .next,
      shownSource: shownSource,
      sourceIsAdapterBacked: true,
      supportsSourceScopedCommands: false,
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
      supportsSourceScopedCommands: true,
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
      supportsSourceScopedCommands: true,
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
      supportsSourceScopedCommands: true,
      send: { command, source in await harness.send(command, to: source) })

    XCTAssertEqual(result, .rejected(target: music))
  }

  func testCurrentAdapterPresentationExplainsUnavailableControls() {
    XCTAssertEqual(
      MediaControlPresentation.scopeLabel(appName: "Music", sourceScoped: false),
      "Controls unavailable for Music")
    XCTAssertEqual(
      MediaControlPresentation.help(action: "Pause", appName: "Music", sourceScoped: false),
      "Pause unavailable because Islet cannot target Music safely")
    XCTAssertEqual(
      MediaControlPresentation.accessibilityLabel(action: "Pause", sourceScoped: false),
      "Pause unavailable")
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
