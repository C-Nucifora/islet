import AppKit
import SwiftUI
import XCTest

@testable import Islet

/// Renders the power screen into /tmp so its layout and deterministic color fixtures can be reviewed
/// without clicking through the island. The box matches what `ExpandedContainerView` hands the tall
/// tier after its side, notch-band and bottom padding.
@MainActor
final class PowerScreenSnapshotTests: XCTestCase {
  func testSnapshotPowerScreen() throws {
    let monitor = BatteryMonitor()
    monitor.refresh()  // one real read; no timers
    let rep = try render(monitor)
    try write(rep, to: "/tmp/power_snapshot.png")
  }

  func testSankeyRendersSemanticColorsForChargingAndDischargingPowerFlows() throws {
    var charging = BatteryMetrics()
    charging.systemPowerInWatts = 60
    charging.systemLoadWatts = 35
    charging.batteryPowerWatts = 25
    charging.cpuPowerWatts = 12
    charging.usbPowerOutputs = [
      USBPowerOutput(portIndex: 2, watts: 5, volts: 5, amps: 1)
    ]

    let chargingRep = try render(
      BatteryMonitor(
        state: BatteryState(percent: 80, isCharging: true, onAC: true),
        metrics: charging))
    try write(chargingRep, to: "/tmp/power_snapshot_charging.png")
    XCTAssertGreaterThan(
      pixelCount(nearHue: 0.37, in: chargingRep), 20,
      "adapter and battery-charge lanes should render green")
    XCTAssertGreaterThan(
      pixelCount(nearHue: 0.55, in: chargingRep), 20,
      "CPU and Mac-load lanes should render cyan")
    XCTAssertGreaterThan(
      pixelCount(nearHue: 0.78, in: chargingRep), 20,
      "USB-output lanes should render purple")
    assertNeutralBus(in: chargingRep)

    var discharging = BatteryMetrics()
    discharging.systemPowerInWatts = 28.407
    discharging.systemLoadWatts = 34.122
    discharging.batteryPowerWatts = -5.715

    let dischargingRep = try render(
      BatteryMonitor(
        state: BatteryState(percent: 62, isCharging: false, onAC: true),
        metrics: discharging))
    try write(dischargingRep, to: "/tmp/power_snapshot_discharging.png")
    XCTAssertGreaterThan(
      pixelCount(nearHue: 0.10, in: dischargingRep), 20,
      "battery-supplement lanes should render orange")
    assertNeutralBus(in: dischargingRep)
  }

  private func render(_ monitor: BatteryMonitor) throws -> NSBitmapImageRep {
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
    window.close()
    return rep
  }

  private func pixelCount(nearHue expectedHue: CGFloat, in rep: NSBitmapImageRep) -> Int {
    let xRange = 0..<rep.pixelsWide
    let yRange = Int(Double(rep.pixelsHigh) * 0.20)..<Int(Double(rep.pixelsHigh) * 0.78)
    return yRange.reduce(into: 0) { count, y in
      for x in xRange {
        guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
        let hueDistance = min(
          abs(color.hueComponent - expectedHue),
          1 - abs(color.hueComponent - expectedHue))
        if hueDistance < 0.045, color.saturationComponent > 0.30,
          color.brightnessComponent > 0.15
        {
          count += 1
        }
      }
    }
  }

  private func write(_ rep: NSBitmapImageRep, to path: String) throws {
    let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    try png.write(to: URL(fileURLWithPath: path))
  }

  private func assertNeutralBus(
    in rep: NSBitmapImageRep, file: StaticString = #filePath, line: UInt = #line
  ) {
    let x = rep.pixelsWide / 2
    let y = rep.pixelsHigh / 2
    let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
    XCTAssertNotNil(color, file: file, line: line)
    XCTAssertLessThan(color?.saturationComponent ?? 1, 0.08, file: file, line: line)
    XCTAssertGreaterThan(color?.brightnessComponent ?? 0, 0.45, file: file, line: line)
  }
}
