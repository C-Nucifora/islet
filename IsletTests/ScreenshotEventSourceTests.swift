import XCTest

@testable import Islet

final class ScreenshotEventSourceTests: XCTestCase {
  private let start = Date(timeIntervalSince1970: 1_800_000_000)

  func testLargeHistoryIsExcludedBeforeTheLiveGather() {
    let historical = (0..<10_000).map { index in
      record(
        path: "/Users/test/Pictures/Archive/shot-\(index).png",
        createdAt: start.addingTimeInterval(TimeInterval(-index - 1)))
    }
    let current = record(
      path: "/Users/test/Pictures/Captures/current.png", createdAt: start)

    let accepted = ScreenshotQueryPlan.accepted(from: historical + [current], startedAt: start)

    XCTAssertEqual(accepted, [current])
    let predicate = ScreenshotQueryPlan.predicate(startedAt: start)
    XCTAssertTrue(predicate.predicateFormat.contains(kMDItemContentCreationDate as String))
    XCTAssertTrue(predicate.predicateFormat.contains(kMDItemContentTypeTree as String))
    XCTAssertTrue(predicate.predicateFormat.contains(ScreenshotQueryPlan.screenCaptureAttribute))
    XCTAssertTrue(predicate.predicateFormat.contains(">="))
  }

  func testScreenshotInRelocatedFolderIsAccepted() {
    let relocated = record(
      path: "/Users/test/Documents/Work Captures/relocated.png", createdAt: start)

    XCTAssertTrue(ScreenshotQueryPlan.accepts(relocated, startedAt: start))
  }

  func testImportedImageWithScreenCaptureMetadataIsRejected() {
    let originalCaptureDate = start.addingTimeInterval(-3_600)
    let imported = record(
      path: "/Users/test/Pictures/Imports/copied.png",
      createdAt: originalCaptureDate,
      fileCreatedAt: start)

    XCTAssertFalse(ScreenshotQueryPlan.accepts(imported, startedAt: start))
  }

  func testNonImageAndMissingPathAreRejected() {
    let nonImage = ScreenshotMetadataRecord(
      path: "/Users/test/file.txt", displayName: "file.txt", isScreenCapture: true,
      contentCreationDate: start, fileCreationDate: start, contentTypeTree: ["public.text"])
    let missingPath = ScreenshotMetadataRecord(
      path: nil, displayName: "shot.png", isScreenCapture: true,
      contentCreationDate: start, fileCreationDate: start,
      contentTypeTree: ["public.png", "public.image"])

    XCTAssertFalse(ScreenshotQueryPlan.accepts(nonImage, startedAt: start))
    XCTAssertFalse(ScreenshotQueryPlan.accepts(missingPath, startedAt: start))
  }

  func testDuplicatePathIsReportedOnlyOnce() {
    let screenshot = record(path: "/Users/test/Pictures/shot.png", createdAt: start)

    let accepted = ScreenshotQueryPlan.accepted(
      from: [screenshot, screenshot], startedAt: start)

    XCTAssertEqual(accepted, [screenshot])
  }

  @MainActor
  func testQueryKeepsTheUserHomeScopeForRelocatedFolders() {
    var scopes: [Any] = []
    let source = ScreenshotEventSource(
      now: { self.start },
      startQuery: { query in
        scopes = query.searchScopes
        return true
      },
      emit: { _ in })

    source.start()
    defer { source.stop() }

    XCTAssertEqual(scopes.count, 1)
    XCTAssertEqual(scopes.first as? String, NSMetadataQueryUserHomeScope)
  }

  @MainActor
  func testQueryStartFailureIsExposedAndSourceCanRetry() {
    var attempts = 0
    var events: [SystemEvent] = []
    let source = ScreenshotEventSource(
      now: { self.start },
      startQuery: { _ in
        attempts += 1
        return false
      },
      emit: { events.append($0) })

    source.start()

    XCTAssertEqual(attempts, 1)
    XCTAssertEqual(
      source.status, .failed("Spotlight could not start the screenshot query."))
    XCTAssertEqual(events.map(\.title), ["Screenshot detection unavailable"])

    source.start()
    XCTAssertEqual(attempts, 2, "a failed query left the source unable to restart")
  }

  func testMonitoringStartRoundsDownForSpotlightSecondPrecision() {
    let date = Date(timeIntervalSince1970: 1_800_000_000.75)
    XCTAssertEqual(
      ScreenshotQueryPlan.monitoringStart(for: date),
      Date(timeIntervalSince1970: 1_800_000_000))
  }

  private func record(
    path: String,
    createdAt: Date,
    fileCreatedAt: Date? = nil
  ) -> ScreenshotMetadataRecord {
    ScreenshotMetadataRecord(
      path: path, displayName: URL(fileURLWithPath: path).lastPathComponent,
      isScreenCapture: true, contentCreationDate: createdAt,
      fileCreationDate: fileCreatedAt ?? createdAt,
      contentTypeTree: ["public.png", "public.image"])
  }
}
