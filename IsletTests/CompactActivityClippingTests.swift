import AppKit
import Defaults
import SwiftUI
import XCTest

@testable import Islet

@MainActor
final class CompactActivityClippingTests: XCTestCase {
  private final class MarkerActivity: NotchActivity, ObservableObject {
    let id = "compact-markers-\(UUID().uuidString)"
    let priority = ActivityPriority.media
    let activationDate: Date? = Date()
    @Published var isActive = false
    @Published var trailingCount = 1

    var compactLeading: AnyView {
      AnyView(Color.red.frame(width: 18, height: 18))
    }

    var compactTrailing: AnyView { AnyView(TrailingMarkers(activity: self)) }
    var expandedView: AnyView { AnyView(Color.clear) }
  }

  private struct TrailingMarkers: View {
    @ObservedObject var activity: MarkerActivity

    var body: some View {
      TimelineView(.animation(minimumInterval: 1.0 / 60)) { _ in
        HStack(spacing: 5) {
          ForEach(0..<activity.trailingCount, id: \.self) { _ in
            Color.green.frame(width: 18, height: 18)
          }
        }
      }
    }
  }

  func testCompactMarkersSurviveRepeatedPrimaryAndSecondaryChanges() throws {
    try exerciseRepeatedActivityTransitions(useFallbackNotch: false)
  }

  func testFallbackCompactMarkersSurviveRepeatedPrimaryAndSecondaryChanges() throws {
    try exerciseRepeatedActivityTransitions(useFallbackNotch: true)
  }

  private func exerciseRepeatedActivityTransitions(useFallbackNotch: Bool) throws {
    try withHostedActivities(useFallbackNotch: useFallbackNotch) { activities, panel, vm in
      activities[0].isActive = true
      pump(0.6)
      try assertMarkers(in: panel, activeCount: 1, trailingCount: 1, phase: "initial")

      // Keep the same activity objects alive while replacing the compact subtree's identity.
      for iteration in 0..<18 {
        let primaryIndex = iteration % activities.count
        let order = Array(activities[primaryIndex...] + activities[..<primaryIndex])
        Defaults[.activityOrder] = order.map(\.id)
        for (index, activity) in activities.enumerated() {
          activity.isActive = index == primaryIndex || iteration.isMultiple(of: 2)
        }
        order[0].trailingCount = iteration.isMultiple(of: 3) ? 5 : 1
        pump(0.025)
      }

      Defaults[.activityOrder] = activities.map(\.id)
      activities[0].trailingCount = 4
      for activity in activities { activity.isActive = true }
      pump(0.8)
      try assertMarkers(in: panel, activeCount: 4, trailingCount: 4, phase: "after-identity-churn")
      XCTAssertEqual(panel.frame, vm.panelFrame)

      // Repeatedly enter and leave a differently sized sneak before restoring the same activities.
      for iteration in 0..<6 {
        SneakQueue.shared.submit(
          Sneak(
            source: "compact-marker-sneak-\(iteration)", duration: 30,
            leading: AnyView(Color.blue.frame(width: 40, height: 18)),
            trailing: AnyView(Color.blue.frame(width: 120, height: 18))))
        pump(0.035)
        XCTAssertNotNil(SneakQueue.shared.current)
        SneakQueue.shared.dismissCurrent()
        pump(0.035)
      }
      pump(0.8)
      XCTAssertNil(SneakQueue.shared.current)
      try assertMarkers(in: panel, activeCount: 4, trailingCount: 4, phase: "after-sneaks")
      XCTAssertEqual(panel.frame, vm.panelFrame)
    }
  }

  func testCompactMarkersResizeWithoutChangingActivityIdentity() throws {
    try withHostedActivities { activities, panel, vm in
      for activity in activities { activity.isActive = true }
      pump(0.6)
      try assertMarkers(in: panel, activeCount: 4, trailingCount: 1, phase: "before-width-churn")

      for iteration in 0..<18 {
        activities[0].trailingCount = iteration.isMultiple(of: 2) ? 6 : 1
        pump(0.025)
      }
      activities[0].trailingCount = 5
      pump(0.8)
      try assertMarkers(in: panel, activeCount: 4, trailingCount: 5, phase: "after-width-churn")
      XCTAssertEqual(panel.frame, vm.panelFrame)
    }
  }

  private func withHostedActivities(
    useFallbackNotch: Bool = false,
    _ body: ([MarkerActivity], NotchPanel, NotchViewModel) throws -> Void
  ) throws {
    let center = ActivityCenter.shared
    let originalOrder = Defaults[.activityOrder]
    let originalDisabled = Defaults[.disabledActivities]
    let originalSuspension = SneakQueue.shared.isSuspended
    let existingIDs = center.activities.map(\.id)
    let activities = (0..<4).map { _ in MarkerActivity() }
    for activity in activities { center.register(activity) }
    Defaults[.disabledActivities] = Array(Set(originalDisabled + existingIDs))
    Defaults[.activityOrder] = activities.map(\.id)
    SneakQueue.shared.isSuspended = { false }
    SneakQueue.shared.dismissCurrent()
    pump(0.3)
    XCTAssertNil(HUDController.shared.hud, "An unrelated HUD would hide the marker fixture")

    let geometry = NotchGeometry(
      screenFrame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
      safeAreaTop: useFallbackNotch ? 0 : 32,
      auxLeftWidth: useFallbackNotch ? 0 : 716,
      auxRightWidth: useFallbackNotch ? 0 : 716, menuBarHeight: 37)
    let vm = NotchViewModel(geometry: geometry, modeOverride: .clickToPin)
    let panel = NotchPanel(frame: vm.panelFrame)
    panel.contentView = NotchHosting.view(for: vm)
    let instance = PanelInstance(
      display: ManagedDisplay(id: "compact-marker-test", hardwareIdentity: nil), panel: panel,
      viewModel: vm)
    panel.orderFrontRegardless()
    instance.syncActualFrame()
    defer {
      instance.stop()
      SneakQueue.shared.dismissCurrent()
      SneakQueue.shared.isSuspended = originalSuspension
      for activity in activities { activity.isActive = false }
      Defaults[.activityOrder] = originalOrder
      Defaults[.disabledActivities] = originalDisabled
      pump(0.3)
    }
    try body(activities, panel, vm)
  }

  private func assertMarkers(
    in panel: NotchPanel, activeCount: Int, trailingCount: Int, phase: String,
    file: StaticString = #filePath, line: UInt = #line
  ) throws {
    let container = try XCTUnwrap(panel.contentView as? NotchHostingContainer)
    container.layoutSubtreeIfNeeded()
    let bitmap = try XCTUnwrap(container.bitmapImageRepForCachingDisplay(in: container.bounds))
    container.cacheDisplay(in: container.bounds, to: bitmap)
    let scale = CGFloat(bitmap.pixelsWide) / container.bounds.width
    var redPixels = 0
    var greenPixels = 0
    for y in 0..<bitmap.pixelsHigh {
      for x in 0..<bitmap.pixelsWide {
        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
        if color.redComponent > 0.05 && color.redComponent > color.greenComponent * 1.4 {
          redPixels += 1
        }
        if color.greenComponent > 0.05 && color.greenComponent > color.redComponent * 1.4 {
          greenPixels += 1
        }
      }
    }
    let redArea = CGFloat(redPixels) / (scale * scale)
    let greenArea = CGFloat(greenPixels) / (scale * scale)
    let expectedRedArea = CGFloat(activeCount * 18 * 18)
    let expectedGreenArea = CGFloat(trailingCount * 18 * 18)
    let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
    attachment.name = "compact-markers-\(phase)"
    attachment.lifetime = .keepAlways
    add(attachment)
    XCTAssertGreaterThanOrEqual(
      redArea, expectedRedArea * 0.95, "Clipped leading or secondary markers: \(phase)",
      file: file, line: line)
    XCTAssertGreaterThanOrEqual(
      greenArea, expectedGreenArea * 0.95, "Clipped trailing markers: \(phase)",
      file: file, line: line)
  }

  private func pump(_ seconds: TimeInterval) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
  }
}
