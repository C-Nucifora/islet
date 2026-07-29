import XCTest

@testable import Islet

final class SourceStripTests: XCTestCase {
  func key(_ bundle: String, _ pid: Int32, parent: String = "") -> SourceID {
    SourceID(bundleIdentifier: bundle, pid: pid, parentBundleIdentifier: parent)
  }

  func testLayoutBelowTheCapShowsEverything() {
    let sources = [key("a", 1), key("b", 2)]
    let layout = SourceStrip.layout(sources)
    XCTAssertEqual(layout.shown, sources)
    XCTAssertEqual(layout.overflow, 0)
  }

  func testLayoutAtTheCapShowsEverything() {
    let sources = [key("a", 1), key("b", 2), key("c", 3)]
    let layout = SourceStrip.layout(sources)
    XCTAssertEqual(layout.shown.count, 3)
    XCTAssertEqual(layout.overflow, 0)
  }

  func testLayoutAboveTheCapShowsThreeAndCountsTheRest() {
    let sources = (1...7).map { key("app\($0)", Int32($0)) }
    let layout = SourceStrip.layout(sources)
    XCTAssertEqual(layout.shown, Array(sources.prefix(3)))
    XCTAssertEqual(layout.overflow, 4)
  }

  func testLayoutOfNothingIsEmpty() {
    let layout = SourceStrip.layout([])
    XCTAssertTrue(layout.shown.isEmpty)
    XCTAssertEqual(layout.overflow, 0)
  }

  func testSecondaryExcludesThePrimaryByDisplayIdentity() {
    // A different pid of the same app is still the same app, so it must not double up.
    let hero = key("com.apple.WebKit.GPU", 1172, parent: "com.apple.Safari")
    let sameApp = key("com.apple.WebKit.GPU", 1469, parent: "com.apple.Safari")
    let spotify = key("com.spotify.client", 9931)
    XCTAssertEqual(SourceStrip.secondary(all: [hero, sameApp, spotify], primary: hero), [spotify])
  }

  func testSecondaryReturnsEverythingWhenThereIsNoPrimary() {
    let sources = [key("a", 1), key("b", 2)]
    XCTAssertEqual(SourceStrip.secondary(all: sources, primary: nil), sources)
  }

  func testMergeKeepsAdapterSourcesFirst() {
    let adapter = [key("com.spotify.client", 1)]
    let audio = [key("com.google.Chrome.helper", 2, parent: "com.google.Chrome")]
    XCTAssertEqual(SourceStrip.merge(adapter: adapter, audio: audio), adapter + audio)
  }

  func testMergeDropsAudioDuplicatesOfAdapterSources() {
    // CoreAudio sees Spotify too; the adapter entry has metadata, so it wins.
    let adapter = [key("com.spotify.client", 1)]
    let audio = [key("com.spotify.client", 1), key("com.apple.Music", 3)]
    XCTAssertEqual(
      SourceStrip.merge(adapter: adapter, audio: audio),
      [key("com.spotify.client", 1), key("com.apple.Music", 3)])
  }
}
