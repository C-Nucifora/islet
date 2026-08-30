import AppKit
import ScreenCaptureKit
import XCTest

@testable import Islet

final class ScreenCaptureExclusionTests: XCTestCase {
  func testEvidenceReportsOnlyAConfirmedCaptureCheckAsActive() {
    XCTAssertEqual(ScreenCaptureExclusionEvidence.captureCheckPassed.status, .active)
    XCTAssertEqual(ScreenCaptureExclusionEvidence.legacyPropertyOnly.status, .unverified)
    XCTAssertEqual(ScreenCaptureExclusionEvidence.unsupportedByPlatform.status, .unsupported)
  }

  func testCurrentPlatformReportsTheLegacyAPIAsUnsupported() {
    let policy = ScreenCaptureExclusionPolicy.current

    XCTAssertEqual(policy.status, .unsupported)
    XCTAssertEqual(policy.status.summary, "Unsupported")
    XCTAssertTrue(policy.status.detail.contains("can appear in screenshots"))
    XCTAssertTrue(policy.status.detail.contains("Enabled activities keep running"))
  }

  func testUnsupportedPolicyKeepsTheBestEffortRequestWithoutClaimingSupport() {
    let policy = ScreenCaptureExclusionPolicy(evidence: .unsupportedByPlatform)

    XCTAssertEqual(policy.sharingType(exclusionRequested: false), .readOnly)
    XCTAssertEqual(policy.sharingType(exclusionRequested: true), .none)
    XCTAssertEqual(policy.status, .unsupported)
  }

  func testUnverifiedPolicyCanApplyTheLegacyPropertyWithoutClaimingSuccess() {
    let policy = ScreenCaptureExclusionPolicy(evidence: .legacyPropertyOnly)

    XCTAssertEqual(policy.status, .unverified)
    XCTAssertEqual(policy.sharingType(exclusionRequested: false), .readOnly)
    XCTAssertEqual(policy.sharingType(exclusionRequested: true), .none)
  }

  func testActiveCopyLimitsTheClaimToTheCheckedSession() {
    let status = ScreenCaptureExclusionStatus.active

    XCTAssertTrue(status.detail.contains("for this session"))
    XCTAssertTrue(status.detail.contains("Other capture apps may behave differently"))
    XCTAssertTrue(status.detail.contains("Enabled activities keep running"))
  }

  /// The probe uses ScreenCaptureKit's current-process content list, which does not request access
  /// to other apps. A read-only control proves that the capture contains the test window. The
  /// `.none` result is attached rather than asserted because Apple does not promise that recorder
  /// path will honor the legacy property.
  @MainActor func testScreenCaptureKitProbeReportsLegacySharingBehavior() async throws {
    guard let screen = NSScreen.main else { throw XCTSkip("No active screen") }

    let capturedControlRed = try await capturedCenterRed(sharingType: .readOnly, on: screen)
    let controlRed = try XCTUnwrap(
      capturedControlRed,
      "ScreenCaptureKit did not list the read-only control window")
    XCTAssertGreaterThan(controlRed, 0.9, "The ScreenCaptureKit control did not capture the window")

    let legacyRed = try await capturedCenterRed(sharingType: .none, on: screen)
    let observation: String
    if let legacyRed {
      observation = legacyRed > 0.9 ? "captured" : "redacted"
      XCTAssertTrue((0...1).contains(legacyRed))
    } else {
      observation = "omitted from the shareable-content list"
    }
    let attachment = XCTAttachment(
      string: "NSWindow.SharingType.none window was \(observation)")
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  @MainActor private func capturedCenterRed(
    sharingType: NSWindow.SharingType, on screen: NSScreen
  ) async throws -> CGFloat? {
    let panel = NSPanel(
      contentRect: CGRect(x: screen.frame.midX, y: screen.frame.midY, width: 80, height: 80),
      styleMask: [.borderless], backing: .buffered, defer: false)
    let contentView = NSView(frame: CGRect(x: 0, y: 0, width: 80, height: 80))
    contentView.wantsLayer = true
    contentView.layer?.backgroundColor = NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1).cgColor
    panel.contentView = contentView
    panel.backgroundColor = .red
    panel.isOpaque = true
    panel.sharingType = sharingType
    panel.orderFrontRegardless()
    defer { panel.close() }

    try await Task.sleep(for: .milliseconds(250))
    let content = try await SCShareableContent.currentProcess
    let windowID = CGWindowID(panel.windowNumber)
    guard let capturedWindow = content.windows.first(where: { $0.windowID == windowID }) else {
      return nil
    }
    let configuration = SCStreamConfiguration()
    configuration.width = 80
    configuration.height = 80
    configuration.showsCursor = false
    let image = try await SCScreenshotManager.captureImage(
      contentFilter: SCContentFilter(desktopIndependentWindow: capturedWindow),
      configuration: configuration)
    let bitmap = NSBitmapImageRep(cgImage: image)
    let center = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2))
      .usingColorSpace(.deviceRGB)

    return try XCTUnwrap(center).redComponent
  }
}
