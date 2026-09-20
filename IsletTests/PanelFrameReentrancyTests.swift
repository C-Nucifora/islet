import AppKit
import XCTest

@testable import Islet

@MainActor
final class PanelFrameReentrancyTests: XCTestCase {
  private final class ReentrantPanel: NotchPanel {
    var onNextFrameChange: (() -> Void)?

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
      super.setFrame(frameRect, display: flag)
      let callback = onNextFrameChange
      onNextFrameChange = nil
      callback?()
    }
  }

  func testNewCompactMeasurementsDuringFrameApplicationAreNotLost() {
    let geometry = NotchGeometry(
      screenFrame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
      safeAreaTop: 0, auxLeftWidth: 0, auxRightWidth: 0, menuBarHeight: 37)
    let vm = NotchViewModel(geometry: geometry, modeOverride: .clickToPin)
    let panel = ReentrantPanel(frame: vm.panelFrame)
    let instance = PanelInstance(
      display: ManagedDisplay(id: "reentrant-frame-test", hardwareIdentity: nil),
      panel: panel, viewModel: vm)
    defer { instance.stop() }
    var injectedMeasurement = false
    panel.onNextFrameChange = {
      injectedMeasurement = true
      // Model the geometry callback that AppKit can deliver before setFrame returns.
      vm.updateCompactWidths(leading: 36, trailing: 112)
    }

    vm.updateCompactWidths(leading: 24, trailing: 40)
    RunLoop.main.run(until: Date().addingTimeInterval(0.8))

    let expected = geometry.collapsedPanelFrame(compactLeading: 36, compactTrailing: 112)
    XCTAssertTrue(injectedMeasurement, "The fixture must update widths inside setFrame")
    // Comparing only panel.frame with vm.panelFrame would miss both retaining an older frame.
    XCTAssertEqual(vm.panelFrame, expected, "The latest measured widths must remain authoritative")
    XCTAssertEqual(panel.frame, expected, "A reentrant frame publication must reach AppKit")
    XCTAssertEqual(vm.actualPanelFrame, expected)
  }
}
