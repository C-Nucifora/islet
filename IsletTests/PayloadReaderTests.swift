import XCTest

@testable import Islet

final class PayloadValueTests: XCTestCase {
  func testDecodesJSONObject() throws {
    let data = Data(#"{"title":"Pizza","count":3,"done":true}"#.utf8)
    let value = try XCTUnwrap(PayloadValue.decode(data))
    XCTAssertEqual(
      value,
      .object(["title": .string("Pizza"), "count": .number(3), "done": .bool(true)]))
  }

  /// `NSNumber` erases `Bool`, so a naive bridge turns `true` into `1` and every boolean flag
  /// becomes a candidate progress value.
  func testBooleansSurviveAsBooleans() throws {
    let value = try XCTUnwrap(PayloadValue.decode(Data(#"{"live":true}"#.utf8)))
    XCTAssertEqual(value, .object(["live": .bool(true)]))
  }

  func testDecodesPropertyListWhenNotJSON() throws {
    let plist = try PropertyListSerialization.data(
      fromPropertyList: ["title": "Timer"], format: .binary, options: 0)
    XCTAssertEqual(PayloadValue.decode(plist), .object(["title": .string("Timer")]))
  }

  func testEmptyAndGarbageDecodeToNil() {
    XCTAssertNil(PayloadValue.decode(Data()))
    XCTAssertNil(PayloadValue.decode(Data([0xFF, 0xFE, 0x00, 0x01, 0x02])))
  }

  func testLeavesCarryKeyAndDepth() throws {
    let value = try XCTUnwrap(
      PayloadValue.decode(Data(#"{"a":"x","b":{"c":"y"}}"#.utf8)))
    let leaves = value.leaves
    XCTAssertEqual(leaves.first { $0.key == "a" }?.depth, 1)
    XCTAssertEqual(leaves.first { $0.key == "c" }?.depth, 2)
  }

  /// Leaf order feeds every tie-break in the reader; dictionary hashing must not leak into it.
  func testLeafOrderIsDeterministic() throws {
    let data = Data(#"{"z":"1","a":"2","m":"3"}"#.utf8)
    let first = try XCTUnwrap(PayloadValue.decode(data)).leaves.map(\.key)
    for _ in 0..<20 {
      XCTAssertEqual(try XCTUnwrap(PayloadValue.decode(data)).leaves.map(\.key), first)
    }
    XCTAssertEqual(first, ["a", "m", "z"])
  }

  func testNullsAreNotLeaves() throws {
    let value = try XCTUnwrap(PayloadValue.decode(Data(#"{"a":null,"b":"x"}"#.utf8)))
    XCTAssertEqual(value.leaves.map(\.key), ["b"])
  }
}

final class PayloadDateTests: XCTestCase {
  let now = Date(timeIntervalSince1970: 1_786_430_090)  // 2026-08-13

  func testReferenceDateSecondsAreRecognised() throws {
    let target = now.addingTimeInterval(600)
    let decoded = PayloadDate.interpret(
      .number(target.timeIntervalSinceReferenceDate), now: now)
    XCTAssertEqual(try XCTUnwrap(decoded).timeIntervalSince1970, target.timeIntervalSince1970,
      accuracy: 1)
  }

  func testEpochSecondsAreRecognised() throws {
    let target = now.addingTimeInterval(600)
    let decoded = PayloadDate.interpret(.number(target.timeIntervalSince1970), now: now)
    XCTAssertEqual(try XCTUnwrap(decoded).timeIntervalSince1970, target.timeIntervalSince1970,
      accuracy: 1)
  }

  func testEpochMillisecondsAreRecognised() throws {
    let target = now.addingTimeInterval(600)
    let decoded = PayloadDate.interpret(
      .number(target.timeIntervalSince1970 * 1000), now: now)
    XCTAssertEqual(try XCTUnwrap(decoded).timeIntervalSince1970, target.timeIntervalSince1970,
      accuracy: 1)
  }

  /// The three scales are orders of magnitude apart, so a real timestamp only reads as sane under
  /// the scale that produced it. This is the whole basis of the heuristic: each of these numbers
  /// is plausible under exactly one reading and decades away under the other two.
  func testScalesDoNotAliasOntoEachOther() {
    // 1.79e9 is today in epoch seconds, but the year 2057 in reference-date seconds.
    XCTAssertEqual(
      PayloadDate.interpret(.number(now.timeIntervalSince1970), now: now)?.timeIntervalSince1970
        ?? 0, now.timeIntervalSince1970, accuracy: 1)
    // 8.1e8 is today in reference-date seconds, but 1995 read as epoch seconds.
    XCTAssertEqual(
      PayloadDate.interpret(.number(now.timeIntervalSinceReferenceDate), now: now)?
        .timeIntervalSince1970 ?? 0, now.timeIntervalSince1970, accuracy: 1)
    // A number that is decades away under every reading has no sane interpretation at all.
    XCTAssertNil(PayloadDate.interpret(.number(5_000_000_000), now: now))
  }

  func testISO8601Strings() throws {
    let d = try XCTUnwrap(PayloadDate.interpret(.string("2026-08-13T12:00:00Z"), now: now))
    XCTAssertEqual(
      d, try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-13T12:00:00Z")))
  }

  func testISO8601WithFractionalSeconds() {
    XCTAssertNotNil(PayloadDate.interpret(.string("2026-08-13T12:00:00.250Z"), now: now))
  }

  func testImplausibleValuesAreRejected() {
    XCTAssertNil(PayloadDate.interpret(.number(0), now: now))
    XCTAssertNil(PayloadDate.interpret(.number(-1), now: now))
    XCTAssertNil(PayloadDate.interpret(.string("not a date"), now: now))
    XCTAssertNil(PayloadDate.interpret(.number(.infinity), now: now))
    XCTAssertNil(PayloadDate.interpret(.number(.nan), now: now))
  }
}

final class GenericPayloadReaderTests: XCTestCase {
  let now = Date(timeIntervalSince1970: 1_786_430_090)

  private func read(_ json: String, attributes: String? = nil) -> LiveActivityRender {
    GenericPayloadReader.read(
      content: PayloadValue.decode(Data(json.utf8)),
      attributes: attributes.flatMap { PayloadValue.decode(Data($0.utf8)) },
      now: now)
  }

  func testPicksTitleAndSubtitle() {
    let r = read(#"{"title":"Out for delivery","subtitle":"2 stops away"}"#)
    XCTAssertEqual(r.title, "Out for delivery")
    XCTAssertEqual(r.subtitle, "2 stops away")
  }

  func testSuffixedKeysAreFound() {
    let r = read(#"{"orderTitle":"Burrito","statusMessage":"Cooking"}"#)
    XCTAssertEqual(r.title, "Burrito")
    XCTAssertEqual(r.subtitle, "Cooking")
  }

  func testShallowerKeyWinsOverDeeperOne() {
    let r = read(#"{"title":"Top","nested":{"deeper":{"title":"Buried"}}}"#)
    XCTAssertEqual(r.title, "Top")
  }

  func testExactMatchBeatsSuffixMatchEvenWhenDeeper() {
    let r = read(#"{"gameTitle":"Suffix","inner":{"title":"Exact"}}"#)
    XCTAssertEqual(r.title, "Exact")
  }

  /// One string in the payload should be the headline, not a subtitle under a blank one.
  func testLoneSubtitleIsPromotedToTitle() {
    let r = read(#"{"message":"Delivered"}"#)
    XCTAssertEqual(r.title, "Delivered")
    XCTAssertNil(r.subtitle)
  }

  func testTitleIsNotAlsoUsedAsSubtitle() {
    let r = read(#"{"title":"Only one"}"#)
    XCTAssertEqual(r.title, "Only one")
    XCTAssertNil(r.subtitle)
  }

  func testFractionalProgress() {
    XCTAssertEqual(read(#"{"progress":0.42}"#).progress ?? 0, 0.42, accuracy: 0.001)
  }

  func testPercentagesAreScaled() {
    XCTAssertEqual(read(#"{"percentComplete":73}"#).progress ?? 0, 0.73, accuracy: 0.001)
  }

  /// 1 is ambiguous between "1%" and "100%"; treating it as a fraction is the safe reading.
  func testPercentOfOneIsTreatedAsComplete() {
    XCTAssertEqual(read(#"{"percent":1}"#).progress ?? 0, 1.0, accuracy: 0.001)
  }

  func testProgressIsDerivedFromRatioPairs() {
    XCTAssertEqual(read(#"{"elapsed":30,"total":120}"#).progress ?? 0, 0.25, accuracy: 0.001)
  }

  func testOutOfRangeProgressIsRejected() {
    XCTAssertNil(read(#"{"progress":8.5}"#).progress)
    XCTAssertNil(read(#"{"progress":-2}"#).progress)
  }

  func testBooleansAreNotMistakenForProgress() {
    XCTAssertNil(read(#"{"progressive":true}"#).progress)
  }

  func testEndDateIsFound() throws {
    let target = now.addingTimeInterval(900)
    let r = read(#"{"endDate":\#(target.timeIntervalSinceReferenceDate)}"#)
    XCTAssertEqual(
      try XCTUnwrap(r.endDate).timeIntervalSince1970, target.timeIntervalSince1970, accuracy: 1)
  }

  /// Payloads carry a start and an end; counting down to a start already in the past renders a
  /// permanently stuck 0:00.
  func testStartDatesAreNotUsedAsTheCountdown() throws {
    let start = now.addingTimeInterval(-600).timeIntervalSinceReferenceDate
    let end = now.addingTimeInterval(600)
    let r = read(#"{"startDate":\#(start),"endDate":\#(end.timeIntervalSinceReferenceDate)}"#)
    XCTAssertEqual(
      try XCTUnwrap(r.endDate).timeIntervalSince1970, end.timeIntervalSince1970, accuracy: 1)
  }

  func testSoonestFutureDateWins() throws {
    let soon = now.addingTimeInterval(300)
    let later = now.addingTimeInterval(9000)
    let r = read(
      #"{"eta":\#(soon.timeIntervalSinceReferenceDate),"deadline":\#(later.timeIntervalSinceReferenceDate)}"#
    )
    XCTAssertEqual(
      try XCTUnwrap(r.endDate).timeIntervalSince1970, soon.timeIntervalSince1970, accuracy: 1)
  }

  func testPastOnlyDatesYieldNoCountdown() {
    let past = now.addingTimeInterval(-600).timeIntervalSinceReferenceDate
    XCTAssertNil(read(#"{"endDate":\#(past)}"#).endDate)
  }

  func testSymbolsAreAcceptedOnlyWhenTheyLookLikeSymbols() {
    XCTAssertEqual(read(#"{"symbol":"figure.run"}"#).symbol, "figure.run")
    XCTAssertNil(read(#"{"icon":"Delivery Van"}"#).symbol)
    XCTAssertNil(read(#"{"image":"https://x.example/a.png"}"#).symbol)
  }

  func testAttributesOnlyFillGaps() {
    let r = read(#"{"title":"Live"}"#, attributes: #"{"title":"Static","subtitle":"From attrs"}"#)
    XCTAssertEqual(r.title, "Live")
    XCTAssertEqual(r.subtitle, "From attrs")
  }

  func testUrlsAndLongProseAreNotTitles() {
    XCTAssertNil(read(#"{"title":"https://example.com/order/12345"}"#).title)
    XCTAssertNil(read(#"{"title":"\#(String(repeating: "x", count: 200))"}"#).title)
  }

  func testUnreadablePayloadYieldsEmptyRender() {
    let r = GenericPayloadReader.read(content: nil, attributes: nil, now: now)
    XCTAssertTrue(r.isEmpty)
  }

  func testWhitespaceOnlyStringsAreIgnored() {
    XCTAssertNil(read(#"{"title":"   "}"#).title)
  }
}
