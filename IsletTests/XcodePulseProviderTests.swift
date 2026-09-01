import Darwin
import Foundation
import XCTest

final class XcodePulseProviderTests: XCTestCase {
  private var temporaryDirectory: URL!
  private var xcodebuildURL: URL!
  private var pulseURL: URL!
  private var recordURL: URL!
  private var lingeringWriterPIDURL: URL!
  private var signalReadyURL: URL!
  private var signalChildPIDURL: URL!

  override func setUpWithError() throws {
    temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "islet-xcode-pulse-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: temporaryDirectory, withIntermediateDirectories: true)
    xcodebuildURL = temporaryDirectory.appendingPathComponent("fake-xcodebuild")
    pulseURL = temporaryDirectory.appendingPathComponent("record-pulse")
    recordURL = temporaryDirectory.appendingPathComponent("pulse-record.txt")
    lingeringWriterPIDURL = temporaryDirectory.appendingPathComponent("lingering-writer.pid")
    signalReadyURL = temporaryDirectory.appendingPathComponent("signal-ready")
    signalChildPIDURL = temporaryDirectory.appendingPathComponent("signal-child.pid")
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
          many-progress)
            index=1
            while [ "$index" -le 20 ]; do
              printf '[%d/20] Step %d\\n' "$index" "$index"
              index=$((index + 1))
            done
            printf '** BUILD SUCCEEDED **\\n'
            exit 0
            ;;
          signalled)
            kill -TERM $$
            ;;
          ignores-signals)
            trap '' INT TERM
            printf '%s\n' "$$" > "${SIGNAL_CHILD_PID_FILE:?}"
            : > "${SIGNAL_READY_FILE:?}"
            exec /bin/sleep 30
            ;;
          delayed-cancel)
            printf '** BUILD CANCELLED ** %07000d\n' 0 >&2
            exit 65
            ;;
          lingering-writer)
            printf '** BUILD SUCCEEDED **\n'
            /bin/sleep 30 &
            printf '%s\n' "$!" > "${LINGERING_WRITER_PID_FILE:?}"
            exit 0
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
        if [ "${MOCK_PULSE_SCENARIO-}" = hung ]; then
          while kill -0 "$PPID" 2>/dev/null; do
            sleep 0.05
          done
        fi
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

  func testSignalEscalatesWhenWrappedBuildDoesNotExit() throws {
    let launched = try makeProviderProcess(
      scenario: "ignores-signals",
      providerArguments: ["--id", "ignores-signals", "--", "build"],
      environmentOverrides: ["ISLET_XCODEBUILD_SIGNAL_GRACE_SECONDS": "0.25"])
    let exited = exitWaiter(for: launched.process)
    defer {
      terminateIfRunning(launched.process, exited: exited)
      XCTAssertTrue(
        terminateRecordedProcess(at: signalChildPIDURL),
        "signal-ignoring child did not terminate")
    }

    try launched.process.run()
    XCTAssertTrue(waitForFile(at: signalReadyURL, timeout: 5), "fake build did not become ready")
    kill(launched.process.processIdentifier, SIGTERM)
    try waitForExit(launched.process, exited: exited, timeout: 3)

    XCTAssertEqual(launched.process.terminationStatus, 137)
    let final = try XCTUnwrap(pulseRecords().last)
    XCTAssertTrue(final.contains("<cancelled>"), final)
  }

  func testLaunchFailureReplacesTheRunningItemWithAnExpiringFailure() throws {
    try FileManager.default.removeItem(at: xcodebuildURL)

    let result = try runProvider(
      scenario: "success",
      providerArguments: ["--id", "launch-failure", "--label", "Sample", "--", "build"])

    XCTAssertEqual(result.status, 70)
    let records = try pulseRecords()
    XCTAssertEqual(records.count, 2)
    XCTAssertTrue(records.first?.contains("<active>") == true)
    XCTAssertTrue(records.last?.contains("<failed>") == true)
    XCTAssertTrue(records.last?.contains("<--expires><60>") == true)
    XCTAssertFalse(records.last?.contains(temporaryDirectory.path) == true)
  }

  func testFinalOutputIsDrainedBeforeTerminalClassification() throws {
    var sockets = [Int32](repeating: -1, count: 2)
    XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
    var sendBuffer: Int32 = 1_024
    XCTAssertEqual(
      setsockopt(
        sockets[0], SOL_SOCKET, SO_SNDBUF, &sendBuffer,
        socklen_t(MemoryLayout.size(ofValue: sendBuffer))),
      0)
    let providerOutput = FileHandle(fileDescriptor: sockets[0], closeOnDealloc: true)
    let capturedOutput = FileHandle(fileDescriptor: sockets[1], closeOnDealloc: true)
    let launched = try makeProviderProcess(
      scenario: "delayed-cancel",
      providerArguments: ["--id", "delayed-cancel", "--", "build"])
    launched.process.standardOutput = providerOutput
    launched.process.standardError = providerOutput
    let exited = exitWaiter(for: launched.process)

    try launched.process.run()
    try providerOutput.close()
    Thread.sleep(forTimeInterval: 0.8)
    let capture = ThreadSafeDataCapture()
    let readFinished = DispatchSemaphore(value: 0)
    var readCompleted = false
    DispatchQueue.global(qos: .utility).async {
      capture.store(capturedOutput.readDataToEndOfFile())
      readFinished.signal()
    }
    defer {
      try? capturedOutput.close()
      if !readCompleted {
        _ = readFinished.wait(timeout: .now() + 1)
      }
    }
    try waitForExit(launched.process, exited: exited, timeout: 10)
    guard readFinished.wait(timeout: .now() + 2) == .success else {
      try? capturedOutput.close()
      _ = readFinished.wait(timeout: .now() + 1)
      XCTFail("provider output capture did not reach EOF")
      return
    }
    readCompleted = true

    XCTAssertEqual(launched.process.terminationStatus, 65)
    XCTAssertTrue(
      String(decoding: capture.data, as: UTF8.self).contains("** BUILD CANCELLED **"))
    let final = try XCTUnwrap(pulseRecords().last)
    XCTAssertTrue(final.contains("<cancelled>"), final)
  }

  func testInheritedPipeWriterCannotKeepProviderAliveAfterBuildExit() throws {
    let launched = try makeProviderProcess(
      scenario: "lingering-writer",
      providerArguments: ["--id", "lingering-writer", "--", "build"])
    defer {
      XCTAssertTrue(terminateLingeringWriter(), "lingering writer did not terminate")
    }

    try runToCompletion(launched.process, timeout: 6)

    XCTAssertEqual(launched.process.terminationStatus, 0)
    let output = try readToEnd(of: launched.output.fileHandleForReading, timeout: 2)
    XCTAssertTrue(String(decoding: output, as: UTF8.self).contains("** BUILD SUCCEEDED **"))
    let final = try XCTUnwrap(pulseRecords().last)
    XCTAssertTrue(final.contains("<succeeded>"), final)
  }

  func testHungPulseReporterIsBoundedAndProgressIsCoalesced() throws {
    let launched = try makeProviderProcess(
      scenario: "many-progress",
      providerArguments: ["--id", "hung-reporter", "--", "build"],
      environmentOverrides: [
        "ISLET_PULSE_TIMEOUT_SECONDS": "0.5",
        "MOCK_PULSE_SCENARIO": "hung",
      ])

    try runToCompletion(launched.process, timeout: 4)

    XCTAssertEqual(launched.process.terminationStatus, 0)
    let records = try pulseRecords()
    XCTAssertEqual(records.count, 2, records.joined(separator: "\n"))
    XCTAssertTrue(records.last?.contains("<succeeded>") == true)
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
    let firstExited = exitWaiter(for: first.process)
    let secondExited = exitWaiter(for: second.process)
    try first.process.run()
    defer { terminateIfRunning(first.process, exited: firstExited) }
    try second.process.run()
    defer { terminateIfRunning(second.process, exited: secondExited) }
    try waitForExit(first.process, exited: firstExited, timeout: 10)
    try waitForExit(second.process, exited: secondExited, timeout: 10)
    _ = try readToEnd(of: first.output.fileHandleForReading, timeout: 2)
    _ = try readToEnd(of: second.output.fileHandleForReading, timeout: 2)

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
    try runToCompletion(launched.process, timeout: 10)
    let data = try readToEnd(of: launched.output.fileHandleForReading, timeout: 2)
    return (launched.process.terminationStatus, String(decoding: data, as: UTF8.self))
  }

  private func runToCompletion(_ process: Process, timeout: TimeInterval) throws {
    let exited = exitWaiter(for: process)
    try process.run()
    try waitForExit(process, exited: exited, timeout: timeout)
  }

  private func exitWaiter(for process: Process) -> DispatchSemaphore {
    let exited = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in exited.signal() }
    return exited
  }

  private func waitForExit(
    _ process: Process, exited: DispatchSemaphore, timeout: TimeInterval
  ) throws {
    guard exited.wait(timeout: .now() + timeout) == .success else {
      kill(process.processIdentifier, SIGKILL)
      if exited.wait(timeout: .now() + 2) == .success {
        process.waitUntilExit()
      }
      throw ProviderProcessError.timedOut(timeout)
    }
    process.waitUntilExit()
  }

  private func terminateIfRunning(_ process: Process, exited: DispatchSemaphore) {
    guard process.isRunning else {
      process.waitUntilExit()
      return
    }
    kill(process.processIdentifier, SIGTERM)
    if exited.wait(timeout: .now() + 1) == .success {
      process.waitUntilExit()
      return
    }
    kill(process.processIdentifier, SIGKILL)
    if exited.wait(timeout: .now() + 1) == .success {
      process.waitUntilExit()
    }
  }

  private func readToEnd(of handle: FileHandle, timeout: TimeInterval) throws -> Data {
    let capture = ThreadSafeDataCapture()
    let finished = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .utility).async {
      capture.store(handle.readDataToEndOfFile())
      finished.signal()
    }
    guard finished.wait(timeout: .now() + timeout) == .success else {
      try? handle.close()
      _ = finished.wait(timeout: .now() + 1)
      throw ProviderProcessError.outputTimedOut(timeout)
    }
    return capture.data
  }

  private func makeProviderProcess(
    scenario: String,
    providerArguments: [String],
    environmentOverrides: [String: String] = [:]
  ) throws -> (
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
    environment["LINGERING_WRITER_PID_FILE"] = lingeringWriterPIDURL.path
    environment["SIGNAL_READY_FILE"] = signalReadyURL.path
    environment["SIGNAL_CHILD_PID_FILE"] = signalChildPIDURL.path
    for (key, value) in environmentOverrides { environment[key] = value }
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

  private func terminateLingeringWriter() -> Bool {
    terminateRecordedProcess(at: lingeringWriterPIDURL)
  }

  private func terminateRecordedProcess(at pidURL: URL) -> Bool {
    guard
      let rawPID = try? String(contentsOf: pidURL, encoding: .utf8),
      let pid = Int32(rawPID.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1
    else { return true }
    kill(pid, SIGTERM)
    let deadline = Date().addingTimeInterval(1)
    while kill(pid, 0) == 0 && Date() < deadline {
      Thread.sleep(forTimeInterval: 0.01)
    }
    if kill(pid, 0) != 0 { return true }
    kill(pid, SIGKILL)
    let killDeadline = Date().addingTimeInterval(1)
    while kill(pid, 0) == 0 && Date() < killDeadline {
      Thread.sleep(forTimeInterval: 0.01)
    }
    return kill(pid, 0) != 0
  }

  private func waitForFile(at url: URL, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !FileManager.default.fileExists(atPath: url.path) && Date() < deadline {
      Thread.sleep(forTimeInterval: 0.01)
    }
    return FileManager.default.fileExists(atPath: url.path)
  }
}

private enum ProviderProcessError: LocalizedError {
  case timedOut(TimeInterval)
  case outputTimedOut(TimeInterval)

  var errorDescription: String? {
    switch self {
    case .timedOut(let timeout):
      "provider did not exit within \(timeout) seconds"
    case .outputTimedOut(let timeout):
      "provider output did not reach EOF within \(timeout) seconds"
    }
  }
}

private final class ThreadSafeDataCapture: @unchecked Sendable {
  private let lock = NSLock()
  private var stored = Data()

  var data: Data {
    lock.lock()
    defer { lock.unlock() }
    return stored
  }

  func store(_ data: Data) {
    lock.lock()
    stored = data
    lock.unlock()
  }
}
