import AppKit
import XCTest

@testable import Islet

final class ClipboardPrivacyPolicyTests: XCTestCase {
  func testSensitivePasteboardTypesAreRejectedCaseInsensitively() {
    XCTAssertFalse(ClipboardPrivacyPolicy.permits(types: ["org.nspasteboard.ConcealedType"]))
    XCTAssertFalse(ClipboardPrivacyPolicy.permits(types: ["ORG.NSPASTEBOARD.CONCEALEDTYPE"]))
    XCTAssertTrue(ClipboardPrivacyPolicy.permits(types: ["public.utf8-plain-text"]))
  }

  func testHighConfidenceSecretsAreRejected() {
    // Assemble provider-like examples at runtime so repository secret scanning never sees a
    // credential-shaped literal, even though every value here is synthetic test data.
    XCTAssertFalse(
      ClipboardPrivacyPolicy.permits(text: ["gh", "p_", "abcdefghijklmnopqrstuvwxyz1234"].joined()))
    XCTAssertFalse(
      ClipboardPrivacyPolicy.permits(text: ["AS", "IA", "1234567890123456"].joined()))
    XCTAssertFalse(
      ClipboardPrivacyPolicy.permits(text: ["xo", "xb-", "1234567890-abcdefghijklmnop"].joined()))
    XCTAssertFalse(
      ClipboardPrivacyPolicy.permits(text: ["sk", "_live_", "abcdefghijklmnopqrstuv"].joined()))
  }

  func testOrdinaryTextIsPermitted() {
    XCTAssertTrue(ClipboardPrivacyPolicy.permits(text: "Meet me at 9:30 tomorrow"))
    XCTAssertTrue(ClipboardPrivacyPolicy.permits(text: "123456"))
  }

  func testImagePayloadRetainsRepresentationType() {
    let payload = ClipboardItem.ImagePayload(
      data: Data([1, 2, 3]), pasteboardTypeRawValue: "public.png")
    let item = ClipboardItem(kind: .image(payload), date: .distantPast)
    XCTAssertEqual(item.retainedByteCount, 3)
    XCTAssertEqual(payload.pasteboardTypeRawValue, "public.png")
  }

  func testMultipleFileURLsRoundTripInOrder() throws {
    let source = NSPasteboard(name: NSPasteboard.Name("islet-tests-source-\(UUID().uuidString)"))
    let destination = NSPasteboard(
      name: NSPasteboard.Name("islet-tests-destination-\(UUID().uuidString)"))
    let urls = [
      URL(fileURLWithPath: "/tmp/first file.txt"),
      URL(fileURLWithPath: "/tmp/second file.txt"),
      URL(fileURLWithPath: "/tmp/third file.txt"),
    ]

    source.clearContents()
    XCTAssertTrue(ClipboardFileURLs.write(urls, to: source))
    let capturedURLs = ClipboardFileURLs.read(from: source)
    XCTAssertEqual(capturedURLs, urls)
    XCTAssertTrue(ClipboardPrivacyPolicy.permits(fileURLs: capturedURLs))

    destination.clearContents()
    XCTAssertTrue(
      ClipboardPasteboardTransaction.replace(on: destination) {
        ClipboardFileURLs.write(capturedURLs, to: destination)
      })
    XCTAssertEqual(ClipboardFileURLs.read(from: destination), urls)
  }

  func testFileSetPreviewAndRetentionUseOnlyURLMetadata() {
    let urls = [
      URL(fileURLWithPath: "/tmp/first.txt"),
      URL(fileURLWithPath: "/tmp/second.txt"),
    ]
    let item = ClipboardItem(kind: .fileURLs(urls), date: .distantPast)

    XCTAssertEqual(item.preview, "first.txt")
    XCTAssertEqual(item.detail, "2 files")
    XCTAssertEqual(
      item.retainedByteCount,
      urls.reduce(0) { $0 + ClipboardPrivacyPolicy.fileURLByteCount($1) })
  }

  func testFileSetPolicyRejectsEmptyRemoteAndOversizedURLLists() {
    XCTAssertFalse(ClipboardPrivacyPolicy.permits(fileURLs: []))
    XCTAssertFalse(
      ClipboardPrivacyPolicy.permits(fileURLs: [URL(string: "https://example.com/file")!]))

    let oversizedPath =
      "/tmp/" + String(repeating: "a", count: ClipboardPrivacyPolicy.maximumFileURLBytes)
    XCTAssertFalse(
      ClipboardPrivacyPolicy.permits(fileURLs: [URL(fileURLWithPath: oversizedPath)]))
  }

  func testMixedLocalAndRemoteURLPasteboardIsRejectedAsAWhole() throws {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("islet-tests-mixed-\(UUID().uuidString)"))
    let urls = [
      URL(fileURLWithPath: "/tmp/local.txt"),
      try XCTUnwrap(URL(string: "https://example.com/remote.txt")),
    ]

    pasteboard.clearContents()
    XCTAssertTrue(ClipboardFileURLs.write(urls, to: pasteboard))
    let capturedURLs = ClipboardFileURLs.read(from: pasteboard)

    XCTAssertEqual(capturedURLs, urls)
    XCTAssertFalse(ClipboardPrivacyPolicy.permits(fileURLs: capturedURLs))
  }

  func testFailedHistoryWriteRestoresTheExistingClipboard() throws {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("islet-tests-\(UUID().uuidString)"))
    pasteboard.clearContents()
    XCTAssertTrue(pasteboard.setString("keep me", forType: .string))

    XCTAssertFalse(
      ClipboardPasteboardTransaction.replace(on: pasteboard) {
        _ = pasteboard.setString("replacement", forType: .string)
        return false
      })
    XCTAssertEqual(pasteboard.string(forType: .string), "keep me")
  }
}
