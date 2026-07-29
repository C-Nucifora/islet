import XCTest

@testable import Islet

final class SetDiffTests: XCTestCase {
  func testAddedAndRemoved() {
    let d = SetDiff.changes(from: ["a", "b", "c"], to: ["b", "c", "d"])
    XCTAssertEqual(d.added, ["d"])
    XCTAssertEqual(d.removed, ["a"])
  }

  func testNoChangeYieldsNothing() {
    let d = SetDiff.changes(from: ["a", "b"], to: ["b", "a"])
    XCTAssertTrue(d.added.isEmpty)
    XCTAssertTrue(d.removed.isEmpty)
  }

  /// The very first read has nothing to compare against. Reporting every device as newly attached
  /// on launch would fire a sneak per USB device every time Islet starts.
  func testFirstReadFromEmptyReportsEverythingAsAdded() {
    let d = SetDiff.changes(from: [], to: ["a", "b"])
    XCTAssertEqual(d.added.sorted(), ["a", "b"])
    XCTAssertTrue(d.removed.isEmpty)
  }

  func testEverythingRemoved() {
    let d = SetDiff.changes(from: ["a", "b"], to: [])
    XCTAssertTrue(d.added.isEmpty)
    XCTAssertEqual(d.removed.sorted(), ["a", "b"])
  }

  /// Order of the result follows the order of the input it came from, so a caller can render
  /// "Keyboard, Mouse" in the order the system reported them rather than in hash order.
  func testResultsPreserveInputOrder() {
    let d = SetDiff.changes(from: ["z"], to: ["c", "a", "b"])
    XCTAssertEqual(d.added, ["c", "a", "b"])
  }

  func testDuplicatesInInputDoNotDuplicateInOutput() {
    let d = SetDiff.changes(from: [], to: ["a", "a", "b"])
    XCTAssertEqual(d.added, ["a", "b"])
  }

  // MARK: - Identified overload

  private struct Device: Identifiable, Equatable {
    let id: String
    let name: String
  }

  /// USB devices are compared by locationID, not by value: a device that renegotiates its speed is
  /// the same device, and must not fire a detach followed by an attach.
  func testIdentifiedOverloadComparesByIDNotByValue() {
    let old = [Device(id: "0x1", name: "Keyboard")]
    let new = [Device(id: "0x1", name: "Keyboard (2.0)"), Device(id: "0x2", name: "Mouse")]
    let d = SetDiff.changes(from: old, to: new)
    XCTAssertEqual(d.added, [Device(id: "0x2", name: "Mouse")])
    XCTAssertTrue(d.removed.isEmpty)
  }

  func testIdentifiedOverloadReportsRemovals() {
    let old = [Device(id: "0x1", name: "Keyboard"), Device(id: "0x2", name: "Mouse")]
    let new = [Device(id: "0x2", name: "Mouse")]
    let d = SetDiff.changes(from: old, to: new)
    XCTAssertTrue(d.added.isEmpty)
    XCTAssertEqual(d.removed, [Device(id: "0x1", name: "Keyboard")])
  }

  // MARK: - Tunnel interfaces

  /// utun is the only tunnel family worth watching, and it must not match unrelated interfaces.
  func testTunnelClassifierMatchesOnlyUtun() {
    XCTAssertTrue(TunnelInterfaces.isTunnel("utun0"))
    XCTAssertTrue(TunnelInterfaces.isTunnel("utun12"))
    XCTAssertTrue(TunnelInterfaces.isTunnel("ipsec0"))
    XCTAssertFalse(TunnelInterfaces.isTunnel("en0"))
    XCTAssertFalse(TunnelInterfaces.isTunnel("lo0"))
    XCTAssertFalse(TunnelInterfaces.isTunnel("awdl0"))
    XCTAssertFalse(TunnelInterfaces.isTunnel("bridge0"))
    XCTAssertFalse(TunnelInterfaces.isTunnel("utunnel"))  // prefix must be followed by digits
  }

  /// The whole VPN source is this diff. If it reports a change when nothing changed, the island
  /// announces a tunnel every time the network reconfigures.
  func testTunnelDiffIsStableWhenNothingChanges() {
    let d = SetDiff.changes(from: ["utun0", "utun1"], to: ["utun1", "utun0"])
    XCTAssertTrue(d.added.isEmpty)
    XCTAssertTrue(d.removed.isEmpty)
  }
}
