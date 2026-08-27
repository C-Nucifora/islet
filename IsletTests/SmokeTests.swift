import SwiftUI
import XCTest

@testable import Islet

final class SmokeTests: XCTestCase {
  func testTruth() { XCTAssertTrue(true) }

  func testMenuBarIconKeepsItsNotchCutoutAndRoundedBody() {
    let path = IsletMenuBarIconShape().path(in: CGRect(x: 0, y: 0, width: 18, height: 16))

    XCTAssertEqual(path.boundingRect, CGRect(x: 1, y: 2, width: 16, height: 12))
    XCTAssertTrue(path.contains(CGPoint(x: 3, y: 8), eoFill: true))
    XCTAssertTrue(path.contains(CGPoint(x: 9, y: 12), eoFill: true))
    XCTAssertFalse(path.contains(CGPoint(x: 9, y: 3), eoFill: true))
    XCTAssertFalse(path.contains(CGPoint(x: 0, y: 8), eoFill: true))
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
