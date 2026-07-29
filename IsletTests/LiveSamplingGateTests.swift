import XCTest

@testable import Islet

@MainActor
final class LiveSamplingGateTests: XCTestCase {
  /// Records every transition the gate announces, in order.
  final class Recorder {
    var transitions: [Bool] = []
  }

  func testFirstRetainGoesLive() {
    let r = Recorder()
    let gate = LiveSamplingGate { live in r.transitions.append(live) }
    XCTAssertFalse(gate.isLive)
    gate.retain()
    XCTAssertTrue(gate.isLive)
    XCTAssertEqual(r.transitions, [true])
  }

  func testSecondRetainDoesNotAnnounceAgain() {
    let r = Recorder()
    let gate = LiveSamplingGate { live in r.transitions.append(live) }
    gate.retain()
    gate.retain()
    XCTAssertTrue(gate.isLive)
    XCTAssertEqual(r.transitions, [true])
  }

  func testPartialReleaseStaysLive() {
    let r = Recorder()
    let gate = LiveSamplingGate { live in r.transitions.append(live) }
    gate.retain()
    gate.retain()
    gate.release()
    XCTAssertTrue(gate.isLive)
    XCTAssertEqual(r.transitions, [true])
  }

  func testReleaseToZeroGoesIdle() {
    let r = Recorder()
    let gate = LiveSamplingGate { live in r.transitions.append(live) }
    gate.retain()
    gate.release()
    XCTAssertFalse(gate.isLive)
    XCTAssertEqual(r.transitions, [true, false])
  }

  func testReleaseBelowZeroIsANoOp() {
    let r = Recorder()
    let gate = LiveSamplingGate { live in r.transitions.append(live) }
    gate.release()
    gate.release()
    XCTAssertFalse(gate.isLive)
    XCTAssertEqual(r.transitions, [])
    // The count must not have gone negative: an unbalanced onDisappear would otherwise poison
    // every later retain().
    gate.retain()
    XCTAssertTrue(gate.isLive)
    XCTAssertEqual(r.transitions, [true])
  }

  func testCrossFadeKeepsSamplingLive() {
    let r = Recorder()
    let gate = LiveSamplingGate { live in r.transitions.append(live) }
    // SwiftUI's cross-fade order: the incoming view's onAppear lands BEFORE the outgoing view's
    // onDisappear. A plain Bool would switch sampling off with a subscriber still on screen.
    gate.retain()  // battery tab appears
    gate.retain()  // power tab appears (incoming)
    gate.release()  // battery tab disappears (outgoing)
    XCTAssertTrue(gate.isLive)
    XCTAssertEqual(r.transitions, [true])
    gate.release()  // power tab finally goes away too
    XCTAssertFalse(gate.isLive)
    XCTAssertEqual(r.transitions, [true, false])
  }
}
