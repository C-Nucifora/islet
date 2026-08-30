import XCTest

@testable import Islet

final class AdapterParserTests: XCTestCase {
  func fixtureLines() throws -> [String] {
    let url = try XCTUnwrap(
      Bundle(for: Self.self).url(forResource: "adapter-stream", withExtension: "jsonl"))
    return try String(contentsOf: url, encoding: .utf8)
      .split(separator: "\n").map(String.init)
  }

  func twoSourceLines() throws -> [String] {
    let url = try XCTUnwrap(
      Bundle(for: Self.self).url(
        forResource: "adapter-stream-two-sources", withExtension: "jsonl"))
    return try String(contentsOf: url, encoding: .utf8)
      .split(separator: "\n").map(String.init)
  }

  func testEmptyFullPayloadMeansIdle() throws {
    let lines = try fixtureLines()
    XCTAssertEqual(AdapterParser.parse(line: lines[0], current: nil), .idle)
  }

  func testFullPayloadParses() throws {
    let lines = try fixtureLines()
    guard case .nowPlaying(_, let state) = AdapterParser.parse(line: lines[1], current: nil)
    else { return XCTFail("expected nowPlaying") }
    XCTAssertEqual(state.title, "Paranoid Android")
    XCTAssertEqual(state.artist, "Radiohead")
    XCTAssertEqual(state.bundleIdentifier, "com.apple.WebKit.GPU")
    XCTAssertTrue(state.isPlaying)
    XCTAssertEqual(state.duration, 386.466, accuracy: 0.001)
    XCTAssertNotNil(state.artwork)
    // Depth-pack fields
    XCTAssertEqual(state.parentBundleIdentifier, "com.apple.Safari")
    XCTAssertEqual(state.sourceBundleIdentifier, "com.apple.Safari")  // parent preferred
    XCTAssertTrue(state.isShuffleOn)
    XCTAssertEqual(state.repeatMode, 2)
    XCTAssertTrue(state.supportsSkip15)
    XCTAssertFalse(state.isAdvertisement)
  }

  func testDiffMergesOntoCurrent() throws {
    let lines = try fixtureLines()
    var state: PlaybackState?
    for line in lines[1...3] {
      if case .nowPlaying(_, let s) = AdapterParser.parse(line: line, current: state) {
        state = s
      }
    }
    let final = try XCTUnwrap(state)
    XCTAssertEqual(final.title, "Paranoid Android")  // survives diffs
    XCTAssertEqual(final.elapsed, 14.7, accuracy: 0.001)
    XCTAssertFalse(final.isPlaying)  // updated by diff
  }

  func testNullValueClearsField() throws {
    let lines = try fixtureLines()
    var state: PlaybackState?
    for line in lines[1...4] {
      if case .nowPlaying(_, let s) = AdapterParser.parse(line: line, current: state) {
        state = s
      }
    }
    XCTAssertNil(try XCTUnwrap(state).artwork)
  }

  func testArtworkOverEncodedDataBudgetIsDropped() throws {
    let artwork = String(
      repeating: "A", count: ArtworkDecodePolicy.standard.maximumBase64Characters + 4)
    let data = try JSONSerialization.data(withJSONObject: [
      "type": "data",
      "diff": false,
      "payload": ["title": "Track", "artworkData": artwork],
    ])
    let line = try XCTUnwrap(String(data: data, encoding: .utf8))

    guard case .nowPlaying(_, let state) = AdapterParser.parse(line: line, current: nil)
    else { return XCTFail("expected nowPlaying") }
    XCTAssertNil(state.artwork)
  }

  func testDiffWithoutCurrentIgnored() throws {
    let lines = try fixtureLines()
    XCTAssertEqual(AdapterParser.parse(line: lines[2], current: nil), .ignored)
  }

  func testGarbageLineIgnored() {
    XCTAssertEqual(AdapterParser.parse(line: "not json", current: nil), .ignored)
  }

  func testOneShotSnapshotParsesCurrentTrack() {
    let line =
      #"{"title":"Already Playing","bundleIdentifier":"com.spotify.client","processIdentifier":42,"playing":true}"#
    guard case .nowPlaying(let key, let state) = AdapterParser.parseSnapshot(line: line)
    else { return XCTFail("expected nowPlaying snapshot") }
    XCTAssertEqual(key.bundleIdentifier, "com.spotify.client")
    XCTAssertEqual(key.pid, 42)
    XCTAssertEqual(state.title, "Already Playing")
    XCTAssertTrue(state.isPlaying)
  }

  func testEmptyOneShotSnapshotMeansIdle() {
    XCTAssertEqual(AdapterParser.parseSnapshot(line: "{}"), .idle)
  }

  func testMalformedOneShotSnapshotIsIgnored() {
    XCTAssertEqual(AdapterParser.parseSnapshot(line: "not json"), .ignored)
  }

  func testSourceKeyResolvesParentAsDisplayIdentity() throws {
    let lines = try fixtureLines()
    guard case .nowPlaying(let key, _) = AdapterParser.parse(line: lines[1], current: nil)
    else { return XCTFail("expected nowPlaying") }
    XCTAssertEqual(key.bundleIdentifier, "com.apple.WebKit.GPU")
    XCTAssertEqual(key.pid, 6712)
    XCTAssertEqual(key.displayBundleIdentifier, "com.apple.Safari")
  }

  func testTwoSourcesParseToDistinctKeys() throws {
    let lines = try twoSourceLines()
    guard
      case .nowPlaying(let safari, let safariState) =
        AdapterParser.parse(line: lines[0], current: nil)
    else { return XCTFail("expected nowPlaying for Safari") }
    guard
      case .nowPlaying(let spotify, let spotifyState) =
        AdapterParser.parse(line: lines[2], current: nil)
    else { return XCTFail("expected nowPlaying for Spotify") }

    XCTAssertNotEqual(safari, spotify)
    XCTAssertEqual(safari.displayBundleIdentifier, "com.apple.Safari")
    XCTAssertEqual(spotify.displayBundleIdentifier, "com.spotify.client")
    XCTAssertEqual(safariState.title, "Paranoid Android")
    XCTAssertEqual(spotifyState.title, "Weird Fishes")
  }

  func testSameBundleDifferentPidIsADistinctSource() throws {
    let lines = try twoSourceLines()
    guard case .nowPlaying(let first, _) = AdapterParser.parse(line: lines[0], current: nil),
      case .nowPlaying(let second, _) = AdapterParser.parse(line: lines[4], current: nil)
    else { return XCTFail("expected two nowPlaying updates") }
    XCTAssertEqual(first.bundleIdentifier, second.bundleIdentifier)
    XCTAssertNotEqual(first.pid, second.pid)
    XCTAssertNotEqual(first, second)
  }

  func testDiffMergesOntoTheSourceItWasGivenAsCurrent() throws {
    let lines = try twoSourceLines()
    guard
      case .nowPlaying(let spotify, let base) =
        AdapterParser.parse(line: lines[2], current: nil)
    else { return XCTFail("expected nowPlaying for Spotify") }
    guard
      case .nowPlaying(let merged, let state) =
        AdapterParser.parse(line: lines[3], current: base)
    else { return XCTFail("expected nowPlaying after diff") }
    XCTAssertEqual(merged, spotify)  // the diff inherits the key it merged onto
    XCTAssertEqual(state.title, "Weird Fishes")
    XCTAssertEqual(state.elapsed, 9.5, accuracy: 0.001)
  }
}
