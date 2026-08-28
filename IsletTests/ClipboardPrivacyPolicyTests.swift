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
}
