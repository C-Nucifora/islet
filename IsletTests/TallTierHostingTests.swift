import AppKit
import SwiftUI
import XCTest

@testable import Islet

/// Hosts the real views in a real panel with the window server, because that is where both
/// "clicked a tall tab" crashes lived: an NSException thrown inside AppKit's display-cycle layout,
/// which no pure-logic test can reach.
@MainActor
final class TallTierHostingTests: XCTestCase {
  private final class MorphActivity: NotchActivity, ObservableObject {
    let id = "morph-test"
    let priority = ActivityPriority.media
    let isActive = true
    let activationDate: Date? = Date()
    var compactLeading: AnyView {
      AnyView(Image(systemName: "waveform").frame(width: 28, height: 20))
    }
    var compactTrailing: AnyView {
      AnyView(Text("Active").frame(width: 64, height: 20))
    }
    var expandedView: AnyView { AnyView(Color.clear) }
  }

  private func pump(_ seconds: TimeInterval) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
  }

  private var geometry: NotchGeometry {
    NotchGeometry(
      screenFrame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
      safeAreaTop: 32, auxLeftWidth: 716, auxRightWidth: 716, menuBarHeight: 37)
  }

  func testCompactHUDSlotKeepsUnderlyingActivityAsAWidthFloor() {
    let narrowerHUD = CompactHUDSlot(
      alignment: .leading,
      underlying: AnyView(Color.clear.frame(width: 180, height: 20)),
      hud: AnyView(Color.clear.frame(width: 40, height: 20)))
    let widerHUD = CompactHUDSlot(
      alignment: .trailing,
      underlying: AnyView(Color.clear.frame(width: 40, height: 20)),
      hud: AnyView(Color.clear.frame(width: 180, height: 20)))

    XCTAssertEqual(NSHostingView(rootView: narrowerHUD).fittingSize.width, 180)
    XCTAssertEqual(NSHostingView(rootView: widerHUD).fittingSize.width, 180)
  }

  func testClosingMorphSurvivesRealHostingWithCompactContent() {
    ActivityCenter.shared.register(MorphActivity())
    let vm = NotchViewModel(geometry: geometry, modeOverride: .clickToPin)
    let panel = NotchPanel(frame: vm.reservedPanelFrame)
    panel.contentView = NotchHosting.view(for: vm)
    panel.orderFrontRegardless()
    vm.setActualPanelFrame(panel.frame)
    pump(0.3)

    vm.apply(.clickedNotch)
    pump(0.6)

    vm.apply(.clickedOutside)
    for delay in [0.06, 0.08, 0.08, 0.08] { pump(delay) }
    pump(0.3)

    XCTAssertEqual(panel.frame, vm.reservedPanelFrame)
    XCTAssertEqual(vm.state, .closed)
    panel.close()
  }

  /// The power screen's content alone, at tall-tier size, with a real one-shot hardware read.
  func testBatteryExpandedViewSurvivesRealHosting() {
    let contentSize = CGSize(
      width: Metrics.expandedSize.width - 28,
      height: Metrics.tallExpandedHeight - 32 - 12)
    let panel = NSPanel(
      contentRect: CGRect(origin: CGPoint(x: 200, y: 200), size: contentSize),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isReleasedWhenClosed = false
    let monitor = BatteryMonitor()
    monitor.refresh()  // one real read; no timers started
    panel.contentView = NSHostingView(rootView: BatteryExpandedView(monitor: monitor))
    panel.orderFrontRegardless()
    pump(0.6)
    panel.close()
  }

  /// The whole island: expand, then switch to the tall tier inside the production reserved panel.
  func testTallTierSelectionSurvivesRealHosting() {
    let vm = NotchViewModel(geometry: geometry, modeOverride: .clickToPin)
    let panel = NotchPanel(frame: vm.reservedPanelFrame)
    panel.contentView = NotchHosting.view(for: vm)
    panel.orderFrontRegardless()
    vm.setActualPanelFrame(panel.frame)

    vm.apply(.clickedNotch)  // expand at the base tier
    pump(0.5)
    vm.setExpandedHeight(Metrics.tallExpandedHeight)  // the crashing step
    pump(1.2)
    vm.apply(.clickedOutside)  // collapse cleanly
    pump(0.6)

    XCTAssertEqual(panel.frame, vm.reservedPanelFrame)
    XCTAssertEqual(vm.expandedHeight, Metrics.expandedSize.height)
    panel.close()
  }

  /// T5 — the tall transition with NO window resize at all: the panel is created big enough for
  /// every tier and never touched again. Crash here = the SwiftUI content transition is the
  /// trigger; survival = the NSWindow.setFrame interaction is.
  func testTallTransitionWithAFixedOversizedWindow() {
    let vm = NotchViewModel(geometry: geometry, modeOverride: .clickToPin)
    let panel = NotchPanel(
      frame: geometry.panelFrame(
        width: vm.maximumExpandedWidth, height: Metrics.tallExpandedHeight
      ).insetBy(dx: -20, dy: -20))
    panel.contentView = NotchHosting.view(for: vm)
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
    let panel = NotchPanel(
      frame: geometry.panelFrame(
        width: vm.maximumExpandedWidth, height: Metrics.tallExpandedHeight))
    panel.contentView = NotchHosting.view(for: vm)
    panel.orderFrontRegardless()
    pump(1.0)
    panel.close()
  }

  /// Compact activities resize the drawn island, never its AppKit host. This is the production
  /// arrangement that prevents a geometry callback from racing NSHostingView's constraint pass.
  func testCompactWidthChangesSurviveRealHostingInAFixedPanel() {
    let vm = NotchViewModel(geometry: geometry, modeOverride: .clickToPin)
    let panel = NotchPanel(frame: vm.reservedPanelFrame)
    let hostingView = NotchHosting.view(for: vm)
    XCTAssertEqual(hostingView.sizingOptions.rawValue, 0)
    panel.contentView = hostingView
    panel.orderFrontRegardless()
    vm.setActualPanelFrame(panel.frame)

    for width in stride(from: CGFloat(20), through: 260, by: 12) {
      vm.updateCompactWidths(leading: width, trailing: width / 2)
      pump(0.01)
    }
    pump(0.5)

    XCTAssertEqual(panel.frame, vm.reservedPanelFrame)
    XCTAssertEqual(vm.actualPanelFrame, panel.frame)
    panel.close()
  }
}
