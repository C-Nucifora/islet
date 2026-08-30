import Foundation
import XCTest

final class XcodePulseProviderTests: XCTestCase {
  private var temporaryDirectory: URL!
  private var xcodebuildURL: URL!
  private var pulseURL: URL!
  private var recordURL: URL!

  override func setUpWithError() throws {
    temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "islet-xcode-pulse-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: temporaryDirectory, withIntermediateDirectories: true)
    xcodebuildURL = temporaryDirectory.appendingPathComponent("fake-xcodebuild")
    pulseURL = temporaryDirectory.appendingPathComponent("record-pulse")
    recordURL = temporaryDirectory.appendingPathComponent("pulse-record.txt")
    try Data().write(to: recordURL)
    try writeExecutable(
      at: xcodebuildURL,
      contents: """
        #!/bin/sh
        case "${MOCK_XCODE_SCENARIO:?}" in
          success)
            printf '[1/4] Compile App\\n[4/4] Link App\\n** BUILD SUCCEEDED **\\n'
            exit 0
            ;;
          failure)
            long_name=$(printf '%0200d' 0 | tr 0 A)
            printf "Test Case '-[AppTests.$long_name testLogin]' failed (0.01 seconds).\\n"
            printf '\\033[31m/Users/private/Secret Project/SecretTests.swift:42:7: error: source text that must not be published\\033[0m\\n'
            printf '** TEST FAILED **\\n'
            exit 65
            ;;
          cancelled)
            printf '** BUILD CANCELLED **\\n'
            exit 130
            ;;
          malformed)
            printf '\\377\\376\\033[31m malformed output\\033[0m \\033]0;private title\\007without a result marker\\n'
            exit 65
            ;;
          path-failure)
            printf '\\033]0;private title\\007/Users/private/Secret Project/SecretTests.swift:42:7: error: private source text\\n'
            printf '** BUILD FAILED **\\n'
            exit 65
            ;;
          concurrent)
            printf '[1/2] Compile\\n'
            sleep 0.1
            printf '[2/2] Link\\n** BUILD SUCCEEDED **\\n'
            exit 0
            ;;
          signalled)
            kill -TERM $$
            ;;
        esac
        """)
    try writeExecutable(
      at: pulseURL,
      contents: """
        #!/bin/sh
        line=
        for argument in "$@"; do
          line="${line}<${argument}>"
        done
        printf '%s\\n' "$line" >> "${PULSE_RECORD_FILE:?}"
        """)
  }

  override func tearDownWithError() throws {
    if let temporaryDirectory {
      try? FileManager.default.removeItem(at: temporaryDirectory)
    }
  }

  func testSuccessfulBuildUsesOneStableItemAndDocumentedExpiry() throws {
    let result = try runProvider(
      scenario: "success",
      providerArguments: ["--id", "success", "--label", "Sample", "--", "build"])

    XCTAssertEqual(result.status, 0)
    XCTAssertTrue(result.output.contains("** BUILD SUCCEEDED **"))
    let records = try pulseRecords()
    XCTAssertGreaterThanOrEqual(records.count, 2)
    XCTAssertTrue(records.allSatisfy { $0.contains("<xcode-success>") })
    XCTAssertTrue(records.first?.contains("<active>") == true)
    XCTAssertTrue(records.last?.contains("<succeeded>") == true)
    XCTAssertTrue(records.last?.contains("<--expires><8>") == true)
    XCTAssertTrue(records.last?.contains("<--progress><1.0000>") == true)
  }

  func testTestFailureIsTruncatedAndPublishesOnlySafeExplicitActions() throws {
    let result = try runProvider(
      scenario: "failure",
      providerArguments: [
        "--id", "failure", "--label", "Sample tests",
        "--project-url", "https://example.com/project",
        "--report-url", "https://example.com/report",
        "--failure-url", "https://example.com/failure", "--", "test",
      ])

    XCTAssertEqual(result.status, 65)
    let final = try XCTUnwrap(pulseRecords().last)
    XCTAssertTrue(final.contains("<failed>"))
    XCTAssertTrue(final.contains("<critical>"))
    XCTAssertTrue(final.contains("<--expires><60>"))
    XCTAssertTrue(final.contains("<--action><Open project><https://example.com/project>"))
    XCTAssertTrue(final.contains("<--action><Open report><https://example.com/report>"))
    XCTAssertTrue(final.contains("<--action><Open failure><https://example.com/failure>"))
    XCTAssertFalse(final.contains("/Users/private"))
    XCTAssertFalse(final.contains("source text that must not be published"))
    XCTAssertFalse(final.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) })
    XCTAssertLessThan(final.count, 1_000)
  }

  func testCancellationPublishesCancelledStateAndExpiry() throws {
    let result = try runProvider(
      scenario: "cancelled",
      providerArguments: ["--id", "cancelled", "--", "build"])

    XCTAssertEqual(result.status, 130)
    let final = try XCTUnwrap(pulseRecords().last)
    XCTAssertTrue(final.contains("<xcode-cancelled>"))
    XCTAssertTrue(final.contains("<cancelled>"))
    XCTAssertTrue(final.contains("<--expires><15>"))
  }

  func testMalformedOutputDoesNotCrashOrLeakControlSequences() throws {
    let result = try runProvider(
      scenario: "malformed",
      providerArguments: ["--id", "malformed", "--", "build"])

    XCTAssertEqual(result.status, 65)
    let final = try XCTUnwrap(pulseRecords().last)
    XCTAssertTrue(final.contains("<failed>"))
    XCTAssertFalse(final.contains("\\033"))
    XCTAssertFalse(final.contains("[31m"))
    XCTAssertFalse(final.contains("private title"))
  }

  func testSignalTerminationUsesTheConventionalShellExitStatus() throws {
    let result = try runProvider(
      scenario: "signalled",
      providerArguments: ["--id", "signalled", "--", "build"])

    XCTAssertEqual(result.status, 143)
    let final = try XCTUnwrap(pulseRecords().last)
    XCTAssertTrue(final.contains("<cancelled>"))
  }

  func testFailurePathPublishesOnlyTruncatedFilenameAndLine() throws {
    let result = try runProvider(
      scenario: "path-failure",
      providerArguments: ["--id", "path-failure", "--", "build"])

    XCTAssertEqual(result.status, 65)
    let final = try XCTUnwrap(pulseRecords().last)
    XCTAssertTrue(final.contains("<Failed: SecretTests.swift:42>"))
    XCTAssertFalse(final.contains("/Users/private"))
    XCTAssertFalse(final.contains("private title"))
    XCTAssertFalse(final.contains("private source text"))
  }

  func testConcurrentBuildsUseDistinctStableItems() throws {
    let first = try makeProviderProcess(
      scenario: "concurrent", providerArguments: ["--label", "First", "--", "build"])
    let second = try makeProviderProcess(
      scenario: "concurrent", providerArguments: ["--label", "Second", "--", "build"])
    try first.process.run()
    try second.process.run()
    first.process.waitUntilExit()
    second.process.waitUntilExit()
    _ = first.output.fileHandleForReading.readDataToEndOfFile()
    _ = second.output.fileHandleForReading.readDataToEndOfFile()

    XCTAssertEqual(first.process.terminationStatus, 0)
    XCTAssertEqual(second.process.terminationStatus, 0)
    let records = try pulseRecords()
    let identifiers = records.compactMap(Self.pulseIdentifier)
    let counts = Dictionary(grouping: identifiers, by: { $0 }).mapValues(\.count)
    XCTAssertEqual(counts.count, 2)
    XCTAssertTrue(counts.values.allSatisfy { $0 >= 2 })
  }

  private func runProvider(scenario: String, providerArguments: [String]) throws -> (
    status: Int32, output: String
  ) {
    let launched = try makeProviderProcess(
      scenario: scenario, providerArguments: providerArguments)
    try launched.process.run()
    launched.process.waitUntilExit()
    let data = launched.output.fileHandleForReading.readDataToEndOfFile()
    return (launched.process.terminationStatus, String(decoding: data, as: UTF8.self))
  }

  private func makeProviderProcess(scenario: String, providerArguments: [String]) throws -> (
    process: Process, output: Pipe
  ) {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
    let provider = root.appendingPathComponent("Tools/islet-xcode-pulse.swift")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["swift", provider.path] + providerArguments
    var environment = ProcessInfo.processInfo.environment
    environment["ISLET_XCODEBUILD_EXECUTABLE"] = xcodebuildURL.path
    environment["ISLET_PULSE_EXECUTABLE"] = pulseURL.path
    environment["PULSE_RECORD_FILE"] = recordURL.path
    environment["MOCK_XCODE_SCENARIO"] = scenario
    process.environment = environment
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    return (process, output)
  }

  private func pulseRecords() throws -> [String] {
    try String(contentsOf: recordURL, encoding: .utf8)
      .split(separator: "\n").map(String.init)
  }

  private static func pulseIdentifier(in record: String) -> String? {
    guard let start = record.range(of: "<xcode-")?.lowerBound,
      let end = record[start...].firstIndex(of: ">")
    else { return nil }
    return String(record[record.index(after: start)..<end])
  }

  private func writeExecutable(at url: URL, contents: String) throws {
    try contents.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: Int16(0o700))], ofItemAtPath: url.path)
  }
}
