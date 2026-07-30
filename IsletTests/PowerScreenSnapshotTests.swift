import AppKit
import SwiftUI
import XCTest

@testable import Islet

/// Renders the power screen with real hardware data into /tmp/power_snapshot.png so its layout can
/// be reviewed without clicking through the island. The 452×206 box is exactly what
/// `ExpandedContainerView` hands the tall tier: 480 wide minus 14pt side padding, 250 tall minus
/// the 32pt notch band and 12pt bottom padding.
@MainActor
final class PowerScreenSnapshotTests: XCTestCase {
  func testSnapshotPowerScreen() throws {
    let monitor = BatteryMonitor()
    monitor.refresh()  // one real read; no timers

    let host = NSHostingView(
      rootView: BatteryExpandedView(monitor: monitor)
        .frame(width: 452, height: 206)
        .background(Color.black)
        .environment(\.colorScheme, .dark))
    host.frame = CGRect(x: 0, y: 0, width: 452, height: 206)

    // Far off screen: rendered by the window server, never visible.
    let window = NSWindow(
      contentRect: CGRect(x: -4000, y: -4000, width: 452, height: 206),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.orderFrontRegardless()
    RunLoop.main.run(until: Date().addingTimeInterval(0.6))

    let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: rep)
    let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    try png.write(to: URL(fileURLWithPath: "/tmp/power_snapshot.png"))
    window.close()
  }
}
