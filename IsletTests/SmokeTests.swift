import Foundation
import SwiftUI
import Testing
import XCTest

@testable import Islet

final class SmokeTests: XCTestCase {
  func testTruth() { XCTAssertTrue(true) }

  func testAppUsesTheConfiguredProjectIdentity() throws {
    let bundleIdentifier = try XCTUnwrap(Bundle.main.bundleIdentifier)
    XCTAssertFalse(bundleIdentifier.isEmpty)
    XCTAssertFalse(bundleIdentifier.contains("$("))
    XCTAssertGreaterThanOrEqual(bundleIdentifier.split(separator: ".").count, 2)
  }

  func testNotchMarkUsesAThinHorizonAndCenteredNotch() {
    let path = IsletNotchMarkShape().path(in: CGRect(x: 0, y: 0, width: 18, height: 16))

    XCTAssertEqual(path.boundingRect, CGRect(x: 1.5, y: 2.5, width: 15, height: 6))
    XCTAssertTrue(path.contains(CGPoint(x: 2, y: 3), eoFill: false))
    XCTAssertFalse(path.contains(CGPoint(x: 2, y: 5), eoFill: false))
    XCTAssertTrue(path.contains(CGPoint(x: 9, y: 3), eoFill: false))
    XCTAssertTrue(path.contains(CGPoint(x: 9, y: 8), eoFill: false))
    XCTAssertFalse(path.contains(CGPoint(x: 9, y: 9), eoFill: false))
  }

  func testNotchMarkIsHorizontallySymmetric() {
    let path = IsletNotchMarkShape().path(in: CGRect(x: 0, y: 0, width: 18, height: 16))

    for point in [CGPoint(x: 6.75, y: 6), CGPoint(x: 7.5, y: 7.5), CGPoint(x: 8.5, y: 8)] {
      XCTAssertEqual(
        path.contains(point, eoFill: false),
        path.contains(CGPoint(x: 18 - point.x, y: point.y), eoFill: false))
    }
  }

  func testNotchMarkScalesAndTranslatesWithItsFrame() {
    let path = IsletNotchMarkShape().path(in: CGRect(x: 10, y: 20, width: 36, height: 32))

    XCTAssertEqual(path.boundingRect, CGRect(x: 13, y: 25, width: 30, height: 12))
    XCTAssertTrue(path.contains(CGPoint(x: 28, y: 26), eoFill: false))
    XCTAssertFalse(path.contains(CGPoint(x: 28, y: 39), eoFill: false))
  }
}

final class ClipboardPrivacyTests: XCTestCase {
  func testRejectsPasteboardsMarkedTransientOrConcealed() {
    XCTAssertFalse(ClipboardPrivacyPolicy.permits(types: ["org.nspasteboard.TransientType"]))
    XCTAssertFalse(ClipboardPrivacyPolicy.permits(types: ["org.nspasteboard.ConcealedType"]))
    XCTAssertTrue(ClipboardPrivacyPolicy.permits(types: ["public.utf8-plain-text"]))
  }

  func testRejectsHighConfidenceSecrets() {
    XCTAssertFalse(
      ClipboardPrivacyPolicy.permits(
        text: "-----BEGIN PRIVATE KEY-----\nnot-a-real-key\n-----END PRIVATE KEY-----"))
    XCTAssertFalse(ClipboardPrivacyPolicy.permits(text: "ghp_123456789012345678901234567890"))
    XCTAssertFalse(
      ClipboardPrivacyPolicy.permits(
        text: "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.signaturevalue"))
    XCTAssertFalse(ClipboardPrivacyPolicy.permits(text: "https://user:secret@example.com/path"))
  }

  func testOrdinaryTextAndShortCodesRemainCapturable() {
    XCTAssertTrue(ClipboardPrivacyPolicy.permits(text: "A normal copied paragraph."))
    XCTAssertTrue(ClipboardPrivacyPolicy.permits(text: "123456"))
  }
}

struct LocalizationTests {
  private static var repositoryRoot: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
  }

  private static func catalog(named name: String = "Localizable") throws -> [String: Any] {
    let url = repositoryRoot.appendingPathComponent("Islet/Resources/\(name).xcstrings")
    let data = try Data(contentsOf: url)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  @Test func catalogsAreValidAndPseudolocalized() throws {
    for name in ["Localizable", "InfoPlist"] {
      let catalog = try Self.catalog(named: name)
      #expect(catalog["sourceLanguage"] as? String == "en")
      #expect(catalog["version"] as? String == "1.0")
      let strings = try #require(catalog["strings"] as? [String: Any])
      #expect(!strings.isEmpty)
      for (key, rawEntry) in strings {
        let entry = try #require(rawEntry as? [String: Any])
        let localizations = try #require(entry["localizations"] as? [String: Any])
        #expect(localizations["en-XA"] != nil, "Missing en-XA for \(name): \(key)")
      }
    }
  }

  @Test func pseudolocalizationExpandsAndPreservesFormatArguments() throws {
    let strings = try #require(try Self.catalog()["strings"] as? [String: Any])
    for (key, rawEntry) in strings {
      let entry = try #require(rawEntry as? [String: Any])
      let localizations = try #require(entry["localizations"] as? [String: Any])
      let pseudo = try #require(localizations["en-XA"] as? [String: Any])
      for (source, value) in Self.sourceAndPseudoPairs(key: key, pseudo: pseudo) {
        #expect(
          value.count >= source.count + source.count / 5, "Pseudo string did not expand: \(key)")
        #expect(
          value.hasPrefix("［") && value.hasSuffix("］"), "Pseudo string is not bracketed: \(key)")
        #expect(Self.formatArguments(in: value) == Self.formatArguments(in: source))
      }
      if let unit = pseudo["stringUnit"] as? [String: Any],
        let value = unit["value"] as? String
      {
        #expect(value == Pseudolocalization.expand(key), "Non-deterministic pseudo string: \(key)")
      }
    }
  }

  @Test func pseudolocalizationPreservesCompletePrintfGrammar() {
    let source = "Unsigned %u positional %2$08X precise %1$.*3$f object %@ escaped %%"
    let expanded = Pseudolocalization.expand(source)
    #expect(Self.formatArguments(in: expanded) == Self.formatArguments(in: source))
    #expect(expanded.contains("%u"))
    #expect(!expanded.contains("%û"))
  }

  @Test func countStringsHaveEnglishPluralRules() throws {
    let strings = try #require(try Self.catalog()["strings"] as? [String: Any])
    let pluralKeys = [
      "%lld activity", "%lld agent", "%lld file", "%lld file sent", "%lld hour",
      "%lld item", "%lld minute", "%lld saved T3 Code pairing", "%lld screenshot",
      "%lld second", "%lld setting", "%lld source", "%lld system event",
      "Connected to %lld machine", "Saved %lld portable preference.",
    ]
    for key in pluralKeys {
      let entry = try #require(strings[key] as? [String: Any])
      let localizations = try #require(entry["localizations"] as? [String: Any])
      let english = try #require(localizations["en"] as? [String: Any])
      let variations = try #require(english["variations"] as? [String: Any])
      let plural = try #require(variations["plural"] as? [String: Any])
      #expect(plural["one"] != nil, "Missing one rule for \(key)")
      #expect(plural["other"] != nil, "Missing other rule for \(key)")
    }
  }

  @Test func staticLocalizationCallsHaveCatalogCoverage() throws {
    let strings = try #require(try Self.catalog()["strings"] as? [String: Any])
    let swiftFiles = try FileManager.default.subpathsOfDirectory(
      atPath: Self.repositoryRoot.appendingPathComponent("Islet").path
    ).filter { $0.hasSuffix(".swift") }
    #expect(swiftFiles.count >= 172)

    let patterns = [
      #"String\(localized:\s*"([^"\\]*(?:\\.[^"\\]*)*)""#,
      #"(?:Text|Label|Button|Toggle|Picker|Section|navigationTitle|help|accessibilityLabel|alert|confirmationDialog)\(\s*"([^"\\]*(?:\\.[^"\\]*)*)""#,
    ]
    let regularExpressions = try patterns.map { try NSRegularExpression(pattern: $0) }
    var checkedKeys = 0
    for relativePath in swiftFiles {
      let source = try String(
        contentsOf: Self.repositoryRoot.appendingPathComponent("Islet/\(relativePath)"),
        encoding: .utf8)
      let range = NSRange(source.startIndex..., in: source)
      for regex in regularExpressions {
        for match in regex.matches(in: source, range: range) {
          guard let keyRange = Range(match.range(at: 1), in: source) else { continue }
          let key = String(source[keyRange])
          guard !key.contains("\\") else { continue }
          checkedKeys += 1
          #expect(strings[key] != nil, "Missing catalog key \(key) from \(relativePath)")
        }
      }
    }
    #expect(checkedKeys >= 300, "Localization-aware literal scan unexpectedly shrank")
  }

  @Test func representativeFormattersRespectLocale() {
    let german = Locale(identifier: "de_DE")
    #expect(PowerFormat.wattsUnsigned(12.5, locale: german).contains(","))
    #expect(LocalizedFormat.bytes(1_500_000, locale: german).contains(","))
    #expect(LocalizedFormat.percent(0.5, locale: german).contains("50"))

    let date = Date(timeIntervalSince1970: 1_704_110_400)
    let american = date.formatted(
      .dateTime.month().day().year().locale(Locale(identifier: "en_US")))
    let germanDate = date.formatted(.dateTime.month().day().year().locale(german))
    #expect(american != germanDate)
  }

  @Test func providerAndUserContentPassesThroughVerbatim() throws {
    let title = "Ågent %@ 你好"
    let subtitle = "provider-supplied / not a key"
    let actionTitle = "Open Résumé"
    let item = try PulseItem(
      payload: PulsePayload(
        id: "provider-id", source: "provider", title: title, subtitle: subtitle,
        symbol: "bolt", accentHex: nil, progress: nil, state: .active, priority: .normal,
        expiresAt: nil,
        actions: [PulseAction(title: actionTitle, url: URL(string: "https://example.com")!)]),
      now: Date(), symbolAvailability: { _ in true })
    #expect(item.title == title)
    #expect(item.subtitle == subtitle)
    #expect(item.actions.first?.title == actionTitle)
  }

  private static func sourceAndPseudoPairs(
    key: String, pseudo: [String: Any]
  ) -> [(String, String)] {
    if let unit = pseudo["stringUnit"] as? [String: Any], let value = unit["value"] as? String {
      return [(key, value)]
    }
    guard let variations = pseudo["variations"] as? [String: Any],
      let plural = variations["plural"] as? [String: Any]
    else { return [] }
    return plural.values.compactMap { raw in
      guard let variant = raw as? [String: Any],
        let unit = variant["stringUnit"] as? [String: Any],
        let value = unit["value"] as? String
      else { return nil }
      return (key, value)
    }
  }

  private static func formatArguments(in value: String) -> [String] {
    let pattern =
      #"%(?:\d+\$)?[-+ #0']*(?:(?:\*\d*\$?)|\d+)?(?:\.(?:(?:\*\d*\$?)|\d*))?(?:hh|ll|h|l|L|z|j|t|q)?[diouxXfFeEgGaAcCsSp@%]"#
    let regex = try! NSRegularExpression(pattern: pattern)
    let range = NSRange(value.startIndex..., in: value)
    return regex.matches(in: value, range: range).compactMap { match in
      Range(match.range, in: value).map { String(value[$0]) }
    }
  }
}
