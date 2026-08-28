import AppKit
import SwiftUI
import XCTest

@testable import Islet

/// Renders the power screen with real hardware data into /tmp/power_snapshot.png so its layout can
/// be reviewed without clicking through the island. The box matches what `ExpandedContainerView`
/// hands the tall tier after its side, notch-band and bottom padding.
@MainActor
final class PowerScreenSnapshotTests: XCTestCase {
  func testSnapshotPowerScreen() throws {
    let monitor = BatteryMonitor()
    monitor.refresh()  // one real read; no timers
    let contentSize = CGSize(
      width: Metrics.expandedSize.width - 28,
      height: Metrics.tallExpandedHeight - 32 - 12)

    let host = NSHostingView(
      rootView: BatteryExpandedView(monitor: monitor)
        .frame(width: contentSize.width, height: contentSize.height)
        .background(Color.black)
        .environment(\.colorScheme, .dark))
    host.frame = CGRect(origin: .zero, size: contentSize)

    // Far off screen: rendered by the window server, never visible.
    let window = NSWindow(
      contentRect: CGRect(origin: CGPoint(x: -4000, y: -4000), size: contentSize),
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
