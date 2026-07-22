import XCTest

@testable import Islet

final class AdapterParserTests: XCTestCase {
  func fixtureLines() throws -> [String] {
    let url = try XCTUnwrap(
      Bundle(for: Self.self).url(forResource: "adapter-stream", withExtension: "jsonl"))
    return try String(contentsOf: url, encoding: .utf8)
      .split(separator: "\n").map(String.init)
  }

  func testEmptyFullPayloadMeansIdle() throws {
    let lines = try fixtureLines()
    XCTAssertEqual(AdapterParser.parse(line: lines[0], current: nil), .idle)
  }

  func testFullPayloadParses() throws {
    let lines = try fixtureLines()
    guard case .nowPlaying(let state) = AdapterParser.parse(line: lines[1], current: nil)
    else { return XCTFail("expected nowPlaying") }
    XCTAssertEqual(state.title, "Paranoid Android")
    XCTAssertEqual(state.artist, "Radiohead")
    XCTAssertEqual(state.bundleIdentifier, "com.apple.Music")
    XCTAssertTrue(state.isPlaying)
    XCTAssertEqual(state.duration, 386.466, accuracy: 0.001)
    XCTAssertNotNil(state.artwork)
  }

  func testDiffMergesOntoCurrent() throws {
    let lines = try fixtureLines()
    var state: PlaybackState?
    for line in lines[1...3] {
      if case .nowPlaying(let s) = AdapterParser.parse(line: line, current: state) {
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
      if case .nowPlaying(let s) = AdapterParser.parse(line: line, current: state) {
        state = s
      }
    }
    XCTAssertNil(try XCTUnwrap(state).artwork)
  }

  func testDiffWithoutCurrentIgnored() throws {
    let lines = try fixtureLines()
    XCTAssertEqual(AdapterParser.parse(line: lines[2], current: nil), .ignored)
  }

  func testGarbageLineIgnored() {
    XCTAssertEqual(AdapterParser.parse(line: "not json", current: nil), .ignored)
  }
}
