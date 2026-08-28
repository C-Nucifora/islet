import XCTest

@testable import Islet

final class AudioProcessReducerTests: XCTestCase {
  typealias Raw = AudioProcessReducer.RawProcess

  func reduce(_ raw: [Raw]) -> [SourceID] {
    AudioProcessReducer.reduce(processes: raw, runningAppBundleID: { _ in nil })
  }

  func testOnlyProcessesRunningOutputAreIncluded() {
    let out = reduce([
      Raw(bundleID: "com.spotify.client", pid: 1, isPlayingOutput: true),
      Raw(bundleID: "com.apple.Music", pid: 2, isPlayingOutput: false),
    ])
    XCTAssertEqual(out.map(\.displayBundleIdentifier), ["com.spotify.client"])
  }

  func testEmptyBundleIdentifiersAreDropped() {
    // Three process objects reported an empty bundle ID in the probe on this machine.
    XCTAssertTrue(reduce([Raw(bundleID: "", pid: 639, isPlayingOutput: true)]).isEmpty)
  }

  func testDenylistedProcessesAreDropped() {
    let out = reduce([
      Raw(bundleID: "systemsoundserverd", pid: 764, isPlayingOutput: true),
      Raw(bundleID: "com.apple.PowerChime", pid: 27375, isPlayingOutput: true),
      Raw(bundleID: "com.apple.controlcenter", pid: 726, isPlayingOutput: true),
    ])
    XCTAssertTrue(out.isEmpty)
  }

  func testIsletItselfIsDropped() {
    XCTAssertTrue(
      reduce([Raw(bundleID: "dev.islet", pid: 19449, isPlayingOutput: true)]).isEmpty)
  }

  func testDenylistAppliesAfterHelperCollapsing() {
    // com.apple.audio.Core-Audio-Driver-Service.helper collapses onto its denylisted parent.
    let out = reduce([
      Raw(
        bundleID: "com.apple.audio.Core-Audio-Driver-Service.helper", pid: 590,
        isPlayingOutput: true)
    ])
    XCTAssertTrue(out.isEmpty)
  }

  func testThreeWebKitGPUProcessesCollapseToOneSafariRow() {
    let out = reduce([
      Raw(bundleID: "com.apple.WebKit.GPU", pid: 17670, isPlayingOutput: true),
      Raw(bundleID: "com.apple.WebKit.GPU", pid: 1172, isPlayingOutput: true),
      Raw(bundleID: "com.apple.WebKit.GPU", pid: 1469, isPlayingOutput: true),
    ])
    XCTAssertEqual(out.count, 1)
    XCTAssertEqual(out[0].displayBundleIdentifier, "com.apple.Safari")
    XCTAssertEqual(out[0].pid, 1172)  // lowest pid wins, so the row is stable across refreshes
  }

  func testChromiumHelpersCollapseOntoTheParent() {
    let out = reduce([
      Raw(bundleID: "com.google.Chrome.helper", pid: 11407, isPlayingOutput: true)
    ])
    XCTAssertEqual(out.map(\.displayBundleIdentifier), ["com.google.Chrome"])
    XCTAssertEqual(out[0].bundleIdentifier, "com.google.Chrome.helper")
  }

  func testHelperAndParentBothPresentProduceOneRow() {
    let out = reduce([
      Raw(bundleID: "com.anthropic.claudefordesktop", pid: 49775, isPlayingOutput: true),
      Raw(bundleID: "com.anthropic.claudefordesktop.helper", pid: 50412, isPlayingOutput: true),
      Raw(bundleID: "com.anthropic.claudefordesktop.helper", pid: 50413, isPlayingOutput: true),
    ])
    XCTAssertEqual(out.map(\.displayBundleIdentifier), ["com.anthropic.claudefordesktop"])
  }

  func testResultIsSortedByDisplayIdentity() {
    let out = reduce([
      Raw(bundleID: "com.spotify.client", pid: 3, isPlayingOutput: true),
      Raw(bundleID: "com.apple.Music", pid: 1, isPlayingOutput: true),
      Raw(bundleID: "com.google.Chrome.helper", pid: 2, isPlayingOutput: true),
    ])
    XCTAssertEqual(
      out.map(\.displayBundleIdentifier),
      ["com.apple.Music", "com.google.Chrome", "com.spotify.client"])
  }

  func testUnknownProcessResolvesThroughTheRunningApplicationLookup() {
    let out = AudioProcessReducer.reduce(
      processes: [Raw(bundleID: "some.unknown.xpc", pid: 42, isPlayingOutput: true)],
      runningAppBundleID: { $0 == 42 ? "com.example.Host" : nil })
    XCTAssertEqual(out.map(\.displayBundleIdentifier), ["com.example.Host"])
  }
}
