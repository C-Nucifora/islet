import AppKit
import SwiftUI
import XCTest

@testable import Islet

private struct LocalizationAlertProbe: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label("Screenshot detection unavailable", systemImage: "exclamationmark.triangle.fill")
        .font(.headline)
      Text(
        "Islet could not monitor the screenshot folder. Check Files and Folders access in Privacy & Security."
      )
      Button("Open Privacy Settings") {}
    }
    .padding(20)
    .frame(width: Metrics.expandedSize.width)
  }
}

private struct LocalizationAccessibilityProbe: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("System thermal pressure serious.")
      Text("Battery temperature unavailable.")
      Text("The readings do not map directly.")
      Button("Allow Accessibility access") {}
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(
      "System thermal pressure and battery sensor temperature are separate readings and do not map directly."
    )
    .padding(20)
  }
}

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

  private func pump(until condition: () -> Bool, timeout: TimeInterval = 2) {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
      RunLoop.main.run(until: min(deadline, Date().addingTimeInterval(0.05)))
    }
  }

  private var geometry: NotchGeometry {
    NotchGeometry(
      screenFrame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
      safeAreaTop: 32, auxLeftWidth: 716, auxRightWidth: 716, menuBarHeight: 37)
  }

  private func host(_ vm: NotchViewModel) -> (NotchPanel, PanelInstance) {
    let panel = NotchPanel(frame: vm.panelFrame)
    panel.contentView = NotchHosting.view(for: vm)
    let instance = PanelInstance(
      display: ManagedDisplay(id: "hosting-test", hardwareIdentity: nil), panel: panel,
      viewModel: vm)
    panel.orderFrontRegardless()
    instance.syncActualFrame()
    return (panel, instance)
  }

  private func assertRendererAligned(
    panel: NotchPanel, viewModel: NotchViewModel, file: StaticString = #filePath,
    line: UInt = #line
  ) {
    guard let container = panel.contentView as? NotchHostingContainer else {
      XCTFail("Missing notch hosting container", file: file, line: line)
      return
    }
    XCTAssertEqual(container.frame.size, panel.frame.size, file: file, line: line)
    XCTAssertEqual(
      container.hostingView.frame.size, viewModel.renderingFrame.size, file: file, line: line)
    XCTAssertEqual(
      container.hostingView.frame.origin.x + panel.frame.minX,
      viewModel.renderingFrame.minX, accuracy: 0.01, file: file, line: line)
    XCTAssertEqual(
      container.hostingView.frame.origin.y + panel.frame.minY,
      viewModel.renderingFrame.minY, accuracy: 0.01, file: file, line: line)
  }

  private var pseudolocale: Locale { Locale(identifier: Pseudolocalization.localeIdentifier) }

  private func assertPseudolocalizedLayoutFits<V: View>(
    _ view: V, in supportedSize: CGSize, file: StaticString = #filePath, line: UInt = #line
  ) {
    let host = NSHostingView(rootView: view.environment(\.locale, pseudolocale))
    let fittingSize = host.fittingSize
    XCTAssertLessThanOrEqual(fittingSize.width, supportedSize.width + 0.5, file: file, line: line)
    XCTAssertLessThanOrEqual(fittingSize.height, supportedSize.height + 0.5, file: file, line: line)

    host.frame = CGRect(origin: .zero, size: supportedSize)
    host.layoutSubtreeIfNeeded()
    XCTAssertFalse(host.hasAmbiguousLayout, file: file, line: line)
    XCTAssertEqual(
      host.bounds.size.width, supportedSize.width, accuracy: 0.5, file: file, line: line)
    XCTAssertEqual(
      host.bounds.size.height, supportedSize.height, accuracy: 0.5, file: file, line: line)
  }

  func testPseudolocalizedCompactEventUsesItsBoundedMarquee() {
    let event = SystemEvent(
      sourceID: "localization-qa", icon: "exclamationmark.triangle.fill",
      title: Pseudolocalization.expand("Screenshot detection unavailable"),
      subtitle: Pseudolocalization.expand("Open Privacy Settings"))
    assertPseudolocalizedLayoutFits(
      EventTrailingView(event: event), in: CGSize(width: 120, height: 34))
  }

  func testPseudolocalizedTallPowerSurfaceFitsTheSupportedTier() {
    let contentSize = CGSize(
      width: Metrics.expandedSize.width - 28,
      height: Metrics.tallExpandedHeight - 32 - 12)
    let monitor = BatteryMonitor(
      state: BatteryState(percent: 80, isCharging: true, onAC: true),
      metrics: BatteryMetrics())
    assertPseudolocalizedLayoutFits(
      BatteryExpandedView(monitor: monitor), in: contentSize)
  }

  func testPseudolocalizedSettingsSurfaceFitsItsSupportedWindow() {
    assertPseudolocalizedLayoutFits(SettingsView(), in: CGSize(width: 900, height: 650))
  }

  func testPseudolocalizedOnboardingSurfaceFitsItsFixedWindow() {
    assertPseudolocalizedLayoutFits(OnboardingView(), in: CGSize(width: 720, height: 560))
  }

  func testPseudolocalizedAlertAndErrorSurfaceFitsExpandedBounds() {
    assertPseudolocalizedLayoutFits(
      LocalizationAlertProbe(), in: CGSize(width: Metrics.expandedSize.width, height: 190))
  }

  func testPseudolocalizedAccessibilitySurfaceFitsPermissionBounds() {
    let host = NSHostingView(
      rootView: LocalizationAccessibilityProbe().environment(\.locale, pseudolocale))
    let panel = NSPanel(
      contentRect: CGRect(x: 200, y: 200, width: 620, height: 220),
      styleMask: [.borderless], backing: .buffered, defer: false)
    panel.isReleasedWhenClosed = false
    panel.contentView = host
    panel.orderFrontRegardless()
    defer { panel.close() }
    pump(until: { !(host.accessibilityChildren()?.isEmpty ?? true) })
    let expectedLabel = Pseudolocalization.expand(
      "System thermal pressure and battery sensor temperature are separate readings and do not map directly."
    )
    let accessibilityLabelSelector = NSSelectorFromString("accessibilityLabel")
    let labels = (host.accessibilityChildren() ?? []).compactMap { element -> String? in
      guard let object = element as? NSObject,
        object.responds(to: accessibilityLabelSelector)
      else { return nil }
      return object.perform(accessibilityLabelSelector)?.takeUnretainedValue() as? String
    }
    XCTAssertTrue(labels.contains(expectedLabel), "Rendered accessibility labels: \(labels)")
    assertPseudolocalizedLayoutFits(
      LocalizationAccessibilityProbe(), in: CGSize(width: 620, height: 220))
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
    let (panel, instance) = host(vm)
    defer { instance.stop() }
    pump(0.3)

    vm.apply(.clickedNotch)
    pump(0.6)

    vm.apply(.clickedOutside)
    for delay in [0.06, 0.08, 0.08, 0.08] { pump(delay) }
    pump(0.3)

    XCTAssertEqual(panel.frame, vm.panelFrame)
    XCTAssertEqual(vm.state, .closed)
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

  /// The whole island follows the production frame coordinator through base, tall and closed tiers.
  func testTallTierSelectionSurvivesRealHosting() {
    ActivityCenter.shared.register(MorphActivity())
    let vm = NotchViewModel(geometry: geometry, modeOverride: .clickToPin)
    vm.selectActivity("morph-test")
    let (panel, instance) = host(vm)
    defer { instance.stop() }

    vm.apply(.clickedNotch)  // expand at the base tier
    pump(0.5)
    assertRendererAligned(panel: panel, viewModel: vm)
    XCTAssertEqual(
      panel.frame,
      geometry.panelFrame(width: vm.expandedWidth, height: Metrics.expandedSize.height))

    vm.setExpandedHeight(Metrics.tallExpandedHeight)  // the crashing step
    pump(1.2)
    assertRendererAligned(panel: panel, viewModel: vm)
    XCTAssertEqual(
      panel.frame,
      geometry.panelFrame(width: vm.expandedWidth, height: Metrics.tallExpandedHeight))

    vm.apply(.clickedOutside)  // collapse cleanly
    pump(0.6)
    assertRendererAligned(panel: panel, viewModel: vm)

    XCTAssertEqual(panel.frame, vm.panelFrame)
    XCTAssertEqual(vm.expandedHeight, Metrics.expandedSize.height)
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
    let container = NotchHosting.view(for: vm)
    panel.contentView = container
    container.alignRenderer(toWindowFrame: panel.frame)
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
    let container = NotchHosting.view(for: vm)
    panel.contentView = container
    container.alignRenderer(toWindowFrame: panel.frame)
    panel.orderFrontRegardless()
    pump(1.0)
    panel.close()
  }

  /// Compact width measurements originate in the hosted SwiftUI tree. This exercises the exact
  /// adaptive frame coordinator while those geometry callbacks are arriving.
  func testCompactWidthChangesSurviveRealHostingInAnAdaptivePanel() {
    let vm = NotchViewModel(geometry: geometry, modeOverride: .clickToPin)
    let (panel, instance) = host(vm)
    defer { instance.stop() }
    guard let container = panel.contentView as? NotchHostingContainer else {
      XCTFail("NotchHosting did not install the expected view")
      return
    }
    let hostingView = container.hostingView
    XCTAssertEqual(hostingView.sizingOptions.rawValue, 0)

    for width in stride(from: CGFloat(20), through: 260, by: 12) {
      vm.updateCompactWidths(leading: width, trailing: width / 2)
      pump(0.01)
    }
    pump(0.5)

    XCTAssertEqual(panel.frame, vm.panelFrame)
    XCTAssertEqual(vm.actualPanelFrame, panel.frame)
    XCTAssertLessThan(
      panel.frame.width,
      geometry.panelFrame(
        width: vm.maximumExpandedWidth, height: Metrics.tallExpandedHeight
      ).width)
  }

  /// Repeated tier changes used to hit `_postWindowNeedsUpdateConstraints`. Keep the window-server
  /// test noisy enough to catch frame ownership slipping back to NSHostingView.
  func testRapidAdaptiveTierChangesSurviveRealHosting() {
    let vm = NotchViewModel(geometry: geometry, modeOverride: .clickToPin)
    let (panel, instance) = host(vm)
    defer { instance.stop() }

    vm.apply(.clickedNotch)
    pump(0.3)
    for index in 0..<12 {
      vm.setExpandedWidth(index.isMultiple(of: 2) ? 700 : Metrics.expandedSize.width)
      vm.setExpandedHeight(
        index.isMultiple(of: 2) ? Metrics.tallExpandedHeight : Metrics.expandedSize.height)
      pump(0.08)
    }
    let settledFrame = geometry.panelFrame(
      width: Metrics.expandedSize.width, height: Metrics.expandedSize.height)
    pump(until: { panel.frame == settledFrame && vm.panelFrame == settledFrame })

    XCTAssertEqual(panel.frame, vm.panelFrame)
    XCTAssertEqual(panel.frame, settledFrame)
  }

  func testAdaptiveRendererAlignmentOnAnOffsetDisplay() {
    let offsetGeometry = NotchGeometry(
      screenFrame: CGRect(x: -1440, y: 200, width: 1440, height: 900),
      safeAreaTop: 0, auxLeftWidth: 0, auxRightWidth: 0, menuBarHeight: 24)
    let vm = NotchViewModel(geometry: offsetGeometry, modeOverride: .clickToPin)
    let (panel, instance) = host(vm)
    defer { instance.stop() }

    assertRendererAligned(panel: panel, viewModel: vm)
    vm.apply(.clickedNotch)
    vm.setExpandedHeight(Metrics.tallExpandedHeight)
    pump(0.5)

    assertRendererAligned(panel: panel, viewModel: vm)
    XCTAssertEqual(panel.frame.maxY, offsetGeometry.screenFrame.maxY, accuracy: 0.01)
    XCTAssertEqual(panel.frame.midX, offsetGeometry.notchRect.midX, accuracy: 0.01)
  }
}
