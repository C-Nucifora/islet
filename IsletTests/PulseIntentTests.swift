import XCTest

@testable import Islet

final class PulseIntentTests: XCTestCase {
  func testPulseIntentStateMapsEveryShortcutState() {
    XCTAssertEqual(PulseIntentState.active.pulseValue, .active)
    XCTAssertEqual(PulseIntentState.progress.pulseValue, .progress)
    XCTAssertEqual(PulseIntentState.needsAction.pulseValue, .needsAction)
    XCTAssertEqual(PulseIntentState.succeeded.pulseValue, .succeeded)
    XCTAssertEqual(PulseIntentState.failed.pulseValue, .failed)
  }

  func testShortcutsGalleryLinksToEveryStarterExample() throws {
    let shortcuts = try XCTUnwrap(PulseProviderDescriptor.gallery.first { $0.id == "shortcuts" })

    XCTAssertEqual(
      shortcuts.documentationLinks.map(\.url.absoluteString),
      [
        "https://github.com/C-Nucifora/islet/releases/latest/download/01-transient-event.shortcut",
        "https://github.com/C-Nucifora/islet/releases/latest/download/02-progress-task.shortcut",
        "https://github.com/C-Nucifora/islet/releases/latest/download/03-failed-task.shortcut",
        "https://github.com/C-Nucifora/islet/releases/latest/download/04-guarded-completion.shortcut",
        "https://github.com/C-Nucifora/islet/releases/latest/download/05-focus-profile.shortcut",
        "https://github.com/C-Nucifora/islet/releases/latest/download/06-focus-timer.shortcut",
      ])
    XCTAssertTrue(shortcuts.capabilities.contains(.events))
    XCTAssertTrue(shortcuts.capabilities.contains(.progress))
  }
}
