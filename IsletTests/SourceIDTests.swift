import XCTest

@testable import Islet

final class SourceIDTests: XCTestCase {
  func testDisplayIdentityPrefersTheParentApp() {
    let id = SourceID(
      bundleIdentifier: "com.apple.WebKit.GPU", pid: 6712,
      parentBundleIdentifier: "com.apple.Safari")
    XCTAssertEqual(id.displayBundleIdentifier, "com.apple.Safari")
    XCTAssertEqual(id.bundleIdentifier, "com.apple.WebKit.GPU")
    XCTAssertEqual(id.pid, 6712)
  }

  func testDisplayIdentityFallsBackToTheBundleIdentifier() {
    let id = SourceID(
      bundleIdentifier: "com.spotify.client", pid: 9931, parentBundleIdentifier: "")
    XCTAssertEqual(id.displayBundleIdentifier, "com.spotify.client")
  }

  func testInitFromPlaybackStateUsesTheParentField() {
    var state = PlaybackState()
    state.bundleIdentifier = "com.apple.WebKit.GPU"
    state.parentBundleIdentifier = "com.apple.Safari"
    state.processIdentifier = 1172
    let id = SourceID(state: state)
    XCTAssertEqual(id.displayBundleIdentifier, "com.apple.Safari")
    XCTAssertEqual(id.pid, 1172)
  }

  func testSameBundleDifferentPidAreDistinctKeys() {
    // Three com.apple.WebKit.GPU processes coexist on a real machine; the pid is what tells
    // them apart.
    let a = SourceID(
      bundleIdentifier: "com.apple.WebKit.GPU", pid: 1172,
      parentBundleIdentifier: "com.apple.Safari")
    let b = SourceID(
      bundleIdentifier: "com.apple.WebKit.GPU", pid: 1469,
      parentBundleIdentifier: "com.apple.Safari")
    XCTAssertNotEqual(a, b)
    XCTAssertEqual(Set([a, b]).count, 2)
  }

  func testWebKitHelperCollapsesOntoSafari() {
    let display = AudioSourceResolver.displayBundleID(
      bundleID: "com.apple.WebKit.GPU", pid: 1172, runningAppBundleID: { _ in nil })
    XCTAssertEqual(display, "com.apple.Safari")
  }

  func testChromiumHelperSuffixCollapsesOntoTheParent() {
    let display = AudioSourceResolver.displayBundleID(
      bundleID: "com.google.Chrome.helper", pid: 11407, runningAppBundleID: { _ in nil })
    XCTAssertEqual(display, "com.google.Chrome")
  }

  func testNestedHelperSuffixCollapsesOntoTheParent() {
    let display = AudioSourceResolver.displayBundleID(
      bundleID: "com.anthropic.claudefordesktop.helper.Renderer", pid: 50412,
      runningAppBundleID: { _ in nil })
    XCTAssertEqual(display, "com.anthropic.claudefordesktop")
  }

  func testFallsBackToTheRunningApplicationLookup() {
    let display = AudioSourceResolver.displayBundleID(
      bundleID: "some.unknown.xpc", pid: 42,
      runningAppBundleID: { $0 == 42 ? "com.example.Host" : nil })
    XCTAssertEqual(display, "com.example.Host")
  }

  func testFallsBackToTheBundleIdentifierWhenNothingResolves() {
    let display = AudioSourceResolver.displayBundleID(
      bundleID: "com.spotify.client", pid: 9931, runningAppBundleID: { _ in nil })
    XCTAssertEqual(display, "com.spotify.client")
  }
}
