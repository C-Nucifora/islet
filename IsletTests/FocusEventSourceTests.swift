import Darwin
import Foundation
import XCTest

@testable import Islet

final class FocusEventSourceTests: XCTestCase {
  func fixtureData(_ name: String) throws -> Data {
    let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json"))
    return try Data(contentsOf: url)
  }

  @MainActor
  func testKnownArraySchemaParsesTheActiveFocus() throws {
    let inspection = FocusEventSource.inspect(data: try fixtureData("focus-known-array"))

    XCTAssertTrue(inspection.isRecognised)
    XCTAssertEqual(inspection.activeIdentifier, "deep-work")
    XCTAssertNotNil(inspection.schemaSignature)
  }

  @MainActor
  func testKnownObjectSchemaReportsHealthyEmpty() throws {
    let inspection = FocusEventSource.inspect(data: try fixtureData("focus-known-object-empty"))

    XCTAssertTrue(inspection.isRecognised)
    XCTAssertNil(inspection.activeIdentifier)
    XCTAssertNotNil(inspection.schemaSignature)
  }

  @MainActor
  func testMalformedJSONHasNoSchemaSignature() throws {
    let inspection = FocusEventSource.inspect(data: try fixtureData("focus-malformed"))

    XCTAssertFalse(inspection.isRecognised)
    XCTAssertNil(inspection.schemaSignature)
  }

  @MainActor
  func testChangedKeysFailAndProduceADifferentSchemaSignature() throws {
    let known = FocusEventSource.inspect(data: try fixtureData("focus-known-array"))
    let changed = FocusEventSource.inspect(data: try fixtureData("focus-changed-keys"))

    XCTAssertFalse(changed.isRecognised)
    XCTAssertNotNil(changed.schemaSignature)
    XCTAssertNotEqual(changed.schemaSignature, known.schemaSignature)
  }

  @MainActor
  func testSourceReportsParseFailureWithoutAFalseSuccessTime() throws {
    let source = FocusEventSource(assertionsURL: try fixtureURL("focus-changed-keys"))
    source.start()
    defer { source.stop() }

    XCTAssertEqual(source.health, .parseFailed)
    XCTAssertNil(source.lastSuccessfulParse)
    XCTAssertNotNil(source.schemaSignature)
  }

  @MainActor
  func testMissingFileAndPermissionFailureRemainDistinct() {
    let missingURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString)
    let source = FocusEventSource(assertionsURL: missingURL)
    source.start()
    defer { source.stop() }

    XCTAssertEqual(source.health, .missingFile)
    XCTAssertEqual(
      FocusEventSource.health(
        forReadError: NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))),
      .permissionDenied)
  }

  @MainActor
  func testRetryDoesNotClaimAStoppedSourceIsWatching() throws {
    let source = FocusEventSource(assertionsURL: try fixtureURL("focus-known-array"))

    source.retry()

    XCTAssertEqual(source.health, .stopped)
    XCTAssertNil(source.lastSuccessfulParse)
    XCTAssertNil(source.schemaSignature)
  }

  @MainActor
  func testRetryReadsAnAtomicallyReplacedAssertionsFile() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let assertionsURL = root.appendingPathComponent("Assertions.json")
    let replacementURL = root.appendingPathComponent("Assertions.replacement.json")
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: root) }

    try fixtureData("focus-known-array").write(to: assertionsURL)
    let source = FocusEventSource(assertionsURL: assertionsURL)
    source.start()
    defer { source.stop() }
    XCTAssertEqual(source.health, .watching)
    let firstSuccessfulParse = try XCTUnwrap(source.lastSuccessfulParse)

    try fixtureData("focus-atomic-replacement").write(to: replacementURL)
    _ = try fileManager.replaceItemAt(assertionsURL, withItemAt: replacementURL)
    source.retry()

    XCTAssertEqual(source.health, .watching)
    XCTAssertNotNil(source.lastSuccessfulParse)
    XCTAssertGreaterThanOrEqual(try XCTUnwrap(source.lastSuccessfulParse), firstSuccessfulParse)
  }

  private func fixtureURL(_ name: String) throws -> URL {
    try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json"))
  }
}
