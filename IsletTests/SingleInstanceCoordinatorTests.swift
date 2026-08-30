import Foundation
import XCTest

@testable import Islet

final class SingleInstanceCoordinatorTests: XCTestCase {
  private var temporaryDirectory: URL!

  override func setUpWithError() throws {
    temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString,
      isDirectory: true)
    try FileManager.default.createDirectory(
      at: temporaryDirectory,
      withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try FileManager.default.removeItem(at: temporaryDirectory)
    temporaryDirectory = nil
  }

  func testLaunchRaceHasOneOwnerAndOneSecondary() throws {
    let lockURL = temporaryDirectory.appendingPathComponent("instance.lock")
    let first = SingleInstanceCoordinator(lockURL: lockURL)
    let second = SingleInstanceCoordinator(lockURL: lockURL)
    let firstOwner = owner(processIdentifier: 101)
    let secondOwner = owner(processIdentifier: 202)

    XCTAssertEqual(try first.claim(owner: firstOwner), .primary)
    XCTAssertEqual(try second.claim(owner: secondOwner), .secondary(owner: firstOwner))
    XCTAssertEqual(first.readOwner(), firstOwner)
  }

  func testStaleOwnerMetadataDoesNotBlockAReplacement() throws {
    let lockURL = temporaryDirectory.appendingPathComponent("instance.lock")
    let staleOwner = owner(processIdentifier: 303, version: "0.9", executablePath: "/old/Islet")
    try JSONEncoder().encode(staleOwner).write(to: lockURL)

    let replacement = SingleInstanceCoordinator(lockURL: lockURL)
    let replacementOwner = owner(
      processIdentifier: 404,
      version: "1.0",
      executablePath: "/Applications/Islet.app/Contents/MacOS/Islet")

    XCTAssertEqual(try replacement.claim(owner: replacementOwner), .primary)
    XCTAssertEqual(replacement.readOwner(), replacementOwner)
  }

  func testReleasedOwnerCannotLeaveAStaleLock() throws {
    let lockURL = temporaryDirectory.appendingPathComponent("instance.lock")
    let first = SingleInstanceCoordinator(lockURL: lockURL)
    XCTAssertEqual(try first.claim(owner: owner(processIdentifier: 505)), .primary)

    first.release()

    let replacement = SingleInstanceCoordinator(lockURL: lockURL)
    XCTAssertEqual(try replacement.claim(owner: owner(processIdentifier: 606)), .primary)
  }

  func testVersionAndBundlePathChangesUseTheSameBundleLock() throws {
    let lockURL = temporaryDirectory.appendingPathComponent("instance.lock")
    let installed = SingleInstanceCoordinator(lockURL: lockURL)
    let installedOwner = owner(
      processIdentifier: 707,
      version: "1.0",
      executablePath: "/Applications/Islet.app/Contents/MacOS/Islet")
    XCTAssertEqual(try installed.claim(owner: installedOwner), .primary)

    let updated = SingleInstanceCoordinator(lockURL: lockURL)
    let updatedOwner = owner(
      processIdentifier: 808,
      version: "2.0",
      executablePath: "/private/tmp/Islet.app/Contents/MacOS/Islet")

    XCTAssertEqual(try updated.claim(owner: updatedOwner), .secondary(owner: installedOwner))
  }

  private func owner(
    processIdentifier: pid_t,
    version: String = "1.0",
    executablePath: String = "/Applications/Islet.app/Contents/MacOS/Islet"
  ) -> SingleInstanceOwner {
    SingleInstanceOwner(
      processIdentifier: processIdentifier,
      bundleIdentifier: "dev.islet",
      version: version,
      build: "1",
      executablePath: executablePath)
  }
}
