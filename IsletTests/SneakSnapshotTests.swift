import AppKit
import SwiftUI
import XCTest

@testable import Islet

/// Renders the collapsed island with a Bluetooth-shaped sneak through the REAL pipeline —
/// SneakQueue, measured slot widths, panel-frame sink, shape mask — into /tmp/sneak_snapshot.png.
@MainActor
final class SneakSnapshotTests: XCTestCase {
  func testLongEventTrailingViewHasBoundedWidth() {
    let event = SystemEvent(
      sourceID: "bluetooth", icon: "dot.radiowaves.right",
      title: "Christian's extraordinarily long Bluetooth headphone device name",
      subtitle: "Connected")
    let host = NSHostingView(rootView: EventTrailingView(event: event))

    host.layoutSubtreeIfNeeded()

    XCTAssertEqual(host.fittingSize.width, 120, accuracy: 0.5)
  }

  func testSnapshotBluetoothSneak() throws {
    let geometry = NotchGeometry(
      screenFrame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
      safeAreaTop: 32, auxLeftWidth: 716, auxRightWidth: 716, menuBarHeight: 37)
    let vm = NotchViewModel(geometry: geometry, modeOverride: .clickToPin)

    let window = NSWindow(
      contentRect: vm.panelFrame.offsetBy(dx: -6000, dy: -6000),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.isOpaque = false
    window.backgroundColor = .clear
    // A desktop-grey backdrop so the black island's edges are reviewable.
    let host = NSHostingView(
      rootView: ZStack {
        Color(white: 0.4)
        NotchRootView(vm: vm)
      }
      .environment(\.colorScheme, .dark))
    window.contentView = host
    window.orderFrontRegardless()

    // Mirror ScreenManager: apply every published frame to the window, feed the real one back.
    let sink = vm.$panelFrame
      .removeDuplicates()
      .sink { [weak window] frame in
        guard let window else { return }
        window.setFrame(frame.offsetBy(dx: -6000, dy: -6000), display: false)
        vm.setActualPanelFrame(frame)
      }

    // Short duration, and fully drained below: SneakQueue is a shared singleton, and a sneak left
    // in flight bleeds into whichever hosting test runs next — its expiry re-measures the compact
    // slots mid-test and crashed TallTierHostingTests from a different suite.
    SystemEventBus.shared.emit(
      SystemEvent(
        sourceID: "bluetooth", icon: "dot.radiowaves.right", title: "Christians Px8 S2",
        subtitle: "Connected", accentHex: EventAccent.info, motion: .bluetooth, duration: 1))
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))

    let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: rep)
    let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    try png.write(to: URL(fileURLWithPath: "/tmp/sneak_snapshot.png"))

    // Drain the shared queue completely (duration + inter-sneak gap) before handing the runloop
    // to the next suite.
    RunLoop.main.run(until: Date().addingTimeInterval(1.2))
    XCTAssertNil(SneakQueue.shared.current, "the sneak must be fully drained before the test ends")

    _ = sink
    window.close()
  }
}
