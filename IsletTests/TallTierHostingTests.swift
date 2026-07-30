import AppKit
import SwiftUI
import XCTest

@testable import Islet

/// Hosts the real views in a real panel with the window server, because that is where both
/// "clicked a tall tab" crashes lived: an NSException thrown inside AppKit's display-cycle layout,
/// which no pure-logic test can reach.
@MainActor
final class TallTierHostingTests: XCTestCase {
  private func pump(_ seconds: TimeInterval) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
  }

  private var geometry: NotchGeometry {
    NotchGeometry(
      screenFrame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
      safeAreaTop: 32, auxLeftWidth: 716, auxRightWidth: 716, menuBarHeight: 37)
  }

  /// The power screen's content alone, at tall-tier size, with a real one-shot hardware read.
  func testBatteryExpandedViewSurvivesRealHosting() {
    let panel = NSPanel(
      contentRect: CGRect(x: 200, y: 200, width: 452, height: 206),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isReleasedWhenClosed = false
    let monitor = BatteryMonitor()
    monitor.refresh()  // one real read; no timers started
    panel.contentView = NSHostingView(rootView: BatteryExpandedView(monitor: monitor))
    panel.orderFrontRegardless()
    pump(0.6)
    panel.close()
  }

  /// The whole island: expand, then switch to the tall tier while a ScreenManager-style sink
  /// applies every published frame to the real window — the exact sequence a chip click runs.
  func testTallTierSelectionSurvivesRealHosting() {
    let vm = NotchViewModel(geometry: geometry, modeOverride: .clickToPin)
    let panel = NotchPanel(frame: vm.panelFrame)
    panel.contentView = NSHostingView(rootView: NotchRootView(vm: vm))
    panel.orderFrontRegardless()
    let sink = vm.$panelFrame
      .removeDuplicates()
      .sink { [weak panel] frame in
        guard let panel, panel.frame != frame else { return }
        panel.setFrame(frame, display: false)
        vm.setActualPanelFrame(panel.frame)
      }

    vm.apply(.clickedNotch)  // expand at the base tier
    pump(0.5)
    vm.setExpandedHeight(Metrics.tallExpandedHeight)  // the crashing step
    pump(1.2)
    vm.apply(.clickedOutside)  // collapse cleanly
    pump(0.6)

    _ = sink
    panel.close()
    XCTAssertEqual(vm.expandedHeight, Metrics.expandedSize.height)
  }

  /// T5 — the tall transition with NO window resize at all: the panel is created big enough for
  /// every tier and never touched again. Crash here = the SwiftUI content transition is the
  /// trigger; survival = the NSWindow.setFrame interaction is.
  func testTallTransitionWithAFixedOversizedWindow() {
    let vm = NotchViewModel(geometry: geometry, modeOverride: .clickToPin)
    let panel = NotchPanel(
      frame: geometry.panelFrame(height: Metrics.tallExpandedHeight).insetBy(dx: -20, dy: -20))
    panel.contentView = NSHostingView(rootView: NotchRootView(vm: vm))
    panel.orderFrontRegardless()

    vm.apply(.clickedNotch)
    pump(0.5)
    vm.setExpandedHeight(Metrics.tallExpandedHeight)
    pump(1.2)
    panel.close()
  }

  /// T6 — tall tier from the very first frame: no transition, no resize. Crash here = something in
  /// tall-tier hosting is broken outright; survival = only the TRANSITION is.
  func testTallTierFromTheFirstFrame() {
    let vm = NotchViewModel(geometry: geometry, modeOverride: .clickToPin)
    vm.apply(.clickedNotch)
    vm.setExpandedHeight(Metrics.tallExpandedHeight)
    let panel = NotchPanel(frame: geometry.panelFrame(height: Metrics.tallExpandedHeight))
    panel.contentView = NSHostingView(rootView: NotchRootView(vm: vm))
    panel.orderFrontRegardless()
    pump(1.0)
    panel.close()
  }
}
