import SwiftUI

/// The power screen leads with the live story: what is supplying the Mac, and where that power is
/// going. Battery health and electrical diagnostics remain available in the compact strip below.
struct BatteryExpandedView: View {
  @ObservedObject var monitor: BatteryMonitor
  @Environment(\.appTheme) private var appTheme

  private var state: BatteryState? { monitor.state }
  private var metrics: BatteryMetrics? { monitor.metrics }
  private var percent: Int { state?.percent ?? 0 }
  private var onAC: Bool { state?.onAC ?? false }
  private var flow: PowerFlowSnapshot { PowerFlowSnapshot(metrics: metrics) }

  private var statusText: String {
    PowerStatus.text(
      onAC: onAC,
      isCharging: state?.isCharging ?? false,
      fullyCharged: metrics?.fullyCharged ?? false,
      batteryWatts: metrics?.batteryPowerWatts,
      notChargingReason: metrics?.notChargingReason)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      header
      powerGraph
      Divider().overlay(appTheme.color(for: .battery).opacity(0.18))
      detailStrip
    }
    .foregroundStyle(.white)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .liveSampling(monitor.liveGate)
  }

  // MARK: - Header

  private var header: some View {
    HStack(spacing: 9) {
      ZStack {
        Circle().fill(appTheme.color(for: .battery).opacity(0.16))
        Image(systemName: BatteryActivity.batterySymbol(for: percent))
          .font(.system(size: 14, weight: .semibold))
          .appThemeForeground(.battery)
      }
      .frame(width: 30, height: 30)
      .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 0) {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
          Text("\(percent)%")
            .font(.system(size: 19, weight: .bold, design: .rounded)).monospacedDigit()
            .appThemeForeground(.battery)
          Text(statusText)
            .font(.caption.weight(.medium)).foregroundStyle(.secondary)
            .lineLimit(1).minimumScaleFactor(0.8)
        }
        if let remaining {
          Text("\(remaining.label) \(remaining.value)")
            .font(.system(size: 9, weight: .medium)).foregroundStyle(.tertiary)
        }
      }
      .accessibilityElement(children: .combine)
      .accessibilityLabel("Battery \(percent) percent, \(statusText)")

      Spacer(minLength: 8)

      if metrics?.lowPowerMode == true {
        statusPill("Low Power", symbol: "leaf.fill", active: true)
      }
      statusPill("Live", symbol: "circle.fill", active: flow.hasLivePower)
    }
    .frame(height: 30)
  }

  private func statusPill(_ label: String, symbol: String, active: Bool) -> some View {
    HStack(spacing: 4) {
      Image(systemName: symbol).font(.system(size: symbol == "circle.fill" ? 5 : 9))
      Text(label).font(.system(size: 9, weight: .semibold))
    }
    .foregroundStyle(active ? appTheme.color(for: .battery) : .secondary)
    .padding(.horizontal, 7).frame(height: 20)
    .background(Capsule().fill(.white.opacity(active ? 0.09 : 0.05)))
  }

  // MARK: - Power graph

  private struct FlowItem: Identifiable {
    let id: String
    let label: String
    let note: String
    let symbol: String
    let watts: Double
    let role: BatteryFlowRole
  }

  private var inputItems: [FlowItem] {
    var items: [FlowItem] = []
    if let watts = flow.adapterInputWatts {
      let kind = PowerInputKind.detect(from: metrics)
      items.append(
        FlowItem(
          id: "adapter", label: kind.label, note: adapterNote,
          symbol: kind.symbol, watts: watts, role: .externalPower))
    }
    if let watts = flow.batteryInputWatts {
      items.append(
        FlowItem(
          id: "battery-source", label: "Battery", note: "system battery supplement",
          symbol: "battery.100percent", watts: watts, role: .batterySupplement))
    }
    return items
  }

  private var outputItems: [FlowItem] {
    var items: [FlowItem] = []
    if let watts = flow.cpuUseWatts, watts > 0.05 {
      items.append(
        FlowItem(
          id: "cpu", label: "CPU", note: "estimated processor power",
          symbol: "cpu", watts: watts, role: .systemLoad))
    }
    if let watts = flow.restOfMacWatts, watts > 0.05 {
      items.append(
        FlowItem(
          id: "rest-of-mac", label: "Rest of Mac", note: "display, memory and other hardware",
          symbol: "laptopcomputer", watts: watts, role: .systemLoad))
    } else if flow.cpuUseWatts == nil, let watts = flow.macUseWatts, watts > 0.05 {
      items.append(
        FlowItem(
          id: "mac", label: "Running the Mac", note: "internal system load",
          symbol: "laptopcomputer", watts: watts, role: .systemLoad))
    }
    for output in flow.usbOutputs where output.watts > 0.05 {
      items.append(
        FlowItem(
          id: "usb-output-\(output.portIndex)", label: "USB port \(output.portIndex)",
          note: usbOutputNote(output), symbol: "cable.connector", watts: output.watts,
          role: .usbOutput))
    }
    if let watts = flow.batteryChargeWatts {
      items.append(
        FlowItem(
          id: "battery-charge", label: "Charging battery", note: "stored in the system battery",
          symbol: "battery.100percent.bolt", watts: watts, role: .batteryCharge))
    }
    return items
  }

  private var adapterNote: String {
    switch (metrics?.adapterVolts, metrics?.adapterAmps, metrics?.adapterWatts) {
    case (let volts?, let amps?, _):
      return String(format: "%.0f V × %.2f A negotiated", volts, amps)
    case (_, _, let watts?): return "\(watts) W adapter rating"
    default: return "external power"
    }
  }

  private func usbOutputNote(_ output: USBPowerOutput) -> String {
    switch (output.volts, output.amps) {
    case (let volts?, let amps?): return String(format: "%.1f V × %.2f A output", volts, amps)
    case (let volts?, nil): return String(format: "%.1f V output", volts)
    case (nil, let amps?): return String(format: "%.2f A output", amps)
    case (nil, nil): return "external USB power"
    }
  }

  @ViewBuilder private var powerGraph: some View {
    if flow.hasLivePower {
      SankeyPowerGraph(
        inputs: inputItems,
        outputs: outputItems,
        totalWatts: flow.scaleWatts,
        lossWatts: metrics?.adapterLossWatts
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      VStack(spacing: 6) {
        Image(systemName: "bolt.horizontal.circle")
          .font(.system(size: 24, weight: .light)).foregroundStyle(.secondary)
        Text("Waiting for power data").font(.caption.weight(.semibold))
        Text(
          onAC
            ? "Power is connected; the next hardware sample will populate the flow."
            : "Battery flow will appear as the Mac reports it."
        )
        .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .accessibilityElement(children: .combine)
    }
  }

  private struct SankeyPowerGraph: View {
    let inputs: [FlowItem]
    let outputs: [FlowItem]
    let totalWatts: Double
    let lossWatts: Double?
    @Environment(\.appTheme) private var appTheme
    @Environment(\.batteryGraphStyle) private var graphStyle

    private struct Segment: Identifiable {
      let item: FlowItem
      let edgeY: CGFloat
      let busY: CGFloat
      let thickness: CGFloat

      var id: String { item.id }
    }

    var body: some View {
      GeometryReader { proxy in
        let size = proxy.size
        let endpointInset = min(82.0, size.width * 0.19)
        let sourceX = endpointInset
        let destinationX = size.width - endpointInset
        let busX = size.width / 2
        let ribbonHeight = min(76.0, max(34.0, size.height - 32))
        let sourceSegments = segments(for: inputs, height: size.height, ribbonHeight: ribbonHeight)
        let destinationSegments = segments(
          for: outputs, height: size.height, ribbonHeight: ribbonHeight)

        ZStack {
          Canvas { context, _ in
            for segment in sourceSegments {
              let tint = color(for: segment.item)
              let path = ribbon(
                from: CGPoint(x: sourceX, y: segment.edgeY),
                to: CGPoint(x: busX - 3, y: segment.busY),
                thickness: segment.thickness)
              context.fill(path, with: .color(tint.opacity(0.19)))
              context.stroke(path, with: .color(tint.opacity(0.48)), lineWidth: 0.65)
            }

            for segment in destinationSegments {
              let tint = color(for: segment.item)
              let path = ribbon(
                from: CGPoint(x: busX + 3, y: segment.busY),
                to: CGPoint(x: destinationX, y: segment.edgeY),
                thickness: segment.thickness)
              context.fill(path, with: .color(tint.opacity(0.25)))
              context.stroke(path, with: .color(tint.opacity(0.56)), lineWidth: 0.65)
            }

            for segment in sourceSegments {
              let tint = color(for: segment.item)
              context.fill(
                Path(roundedRect: nodeRect(x: sourceX, segment: segment), cornerRadius: 2),
                with: .color(tint.opacity(0.82)))
            }
            for segment in destinationSegments {
              let tint = color(for: segment.item)
              context.fill(
                Path(roundedRect: nodeRect(x: destinationX, segment: segment), cornerRadius: 2),
                with: .color(tint.opacity(0.92)))
            }

            let busTop = min(
              sourceSegments.map { $0.busY - $0.thickness / 2 }.min() ?? size.height / 2,
              destinationSegments.map { $0.busY - $0.thickness / 2 }.min() ?? size.height / 2)
            let busBottom = max(
              sourceSegments.map { $0.busY + $0.thickness / 2 }.max() ?? size.height / 2,
              destinationSegments.map { $0.busY + $0.thickness / 2 }.max() ?? size.height / 2)
            let busRect = CGRect(
              x: busX - 3, y: busTop, width: 6, height: max(5, busBottom - busTop))
            context.fill(
              Path(roundedRect: busRect, cornerRadius: 3),
              with: .color(.white.opacity(0.86)))
          }

          ForEach(sourceSegments) { segment in
            readout(for: segment.item, pointsRight: true)
              .position(x: sourceX / 2, y: segment.edgeY)
          }
          ForEach(destinationSegments) { segment in
            readout(for: segment.item, pointsRight: false)
              .position(x: destinationX + (size.width - destinationX) / 2, y: segment.edgeY)
          }

          HStack(spacing: 4) {
            Image(systemName: "bolt.fill")
              .font(.system(size: 8, weight: .bold))
              .foregroundStyle(.white)
            Text(PowerFormat.wattsUnsigned(totalWatts))
              .font(.system(size: 9, weight: .bold, design: .rounded))
              .monospacedDigit()
          }
          .padding(.horizontal, 6)
          .frame(height: 18)
          .background(.black.opacity(0.72), in: Capsule())
          .overlay(Capsule().stroke(.white.opacity(0.28), lineWidth: 0.5))
          .position(x: busX, y: 10)
          .accessibilityLabel("Total power flow, \(PowerFormat.wattsUnsigned(totalWatts))")

          if let lossWatts, lossWatts > 0.05 {
            HStack(spacing: 3) {
              Image(systemName: "heat.waves")
              Text(PowerFormat.wattsUnsigned(lossWatts))
                .monospacedDigit()
            }
            .font(.system(size: 7, weight: .medium))
            .foregroundStyle(.tertiary)
            .position(x: busX, y: size.height - 5)
            .help("Adapter efficiency loss")
            .accessibilityLabel(
              "Adapter efficiency loss, \(PowerFormat.wattsUnsigned(lossWatts))")
          }
        }
      }
    }

    private func color(for item: FlowItem) -> Color {
      guard graphStyle == .coloured else { return .white }
      return appTheme.powerFlowColor(for: item.role)
    }

    private func segments(
      for items: [FlowItem], height: CGFloat, ribbonHeight: CGFloat
    ) -> [Segment] {
      guard !items.isEmpty, totalWatts > 0 else { return [] }
      let gap: CGFloat = items.count > 3 ? 2 : 4
      let minimumLaneHeight: CGFloat = items.count > 3 ? 20 : 24
      let thicknesses = items.map { max(3, ribbonHeight * CGFloat($0.watts / totalWatts)) }
      let laneHeights = thicknesses.map { max(minimumLaneHeight, $0) }
      let occupiedHeight = laneHeights.reduce(0, +) + gap * CGFloat(max(0, items.count - 1))
      var edgeCursor = max(2, (height - occupiedHeight) / 2)

      let busThickness = thicknesses.reduce(0, +)
      var busCursor = (height - busThickness) / 2
      return zip(items, zip(thicknesses, laneHeights)).map { item, sizes in
        let (thickness, laneHeight) = sizes
        let segment = Segment(
          item: item,
          edgeY: edgeCursor + laneHeight / 2,
          busY: busCursor + thickness / 2,
          thickness: thickness)
        edgeCursor += laneHeight + gap
        busCursor += thickness
        return segment
      }
    }

    private func ribbon(from: CGPoint, to: CGPoint, thickness: CGFloat) -> Path {
      let half = thickness / 2
      let bend = (to.x - from.x) * 0.46
      var path = Path()
      path.move(to: CGPoint(x: from.x, y: from.y - half))
      path.addCurve(
        to: CGPoint(x: to.x, y: to.y - half),
        control1: CGPoint(x: from.x + bend, y: from.y - half),
        control2: CGPoint(x: to.x - bend, y: to.y - half))
      path.addLine(to: CGPoint(x: to.x, y: to.y + half))
      path.addCurve(
        to: CGPoint(x: from.x, y: from.y + half),
        control1: CGPoint(x: to.x - bend, y: to.y + half),
        control2: CGPoint(x: from.x + bend, y: from.y + half))
      path.closeSubpath()
      return path
    }

    private func nodeRect(x: CGFloat, segment: Segment) -> CGRect {
      CGRect(
        x: x - 2.5, y: segment.edgeY - max(5, segment.thickness) / 2,
        width: 5, height: max(5, segment.thickness))
    }

    private func readout(for item: FlowItem, pointsRight: Bool) -> some View {
      let tint = color(for: item)
      let metric = VStack(alignment: pointsRight ? .trailing : .leading, spacing: 0) {
        Text(PowerFormat.wattsUnsigned(item.watts))
          .font(.system(size: 9, weight: .bold, design: .rounded))
          .monospacedDigit()
        Text(PowerFormat.percentage(item.watts / totalWatts))
          .font(.system(size: 7, weight: .bold))
          .monospacedDigit()
          .foregroundStyle(.secondary)
      }

      return HStack(spacing: 5) {
        if pointsRight { metric }
        ZStack {
          Circle().fill(tint.opacity(0.08))
          Circle().stroke(tint.opacity(0.28), lineWidth: 0.6)
          Image(systemName: item.symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(tint)
        }
        .frame(width: 24, height: 24)
        if !pointsRight { metric }
      }
      .frame(width: 74, alignment: pointsRight ? .trailing : .leading)
      .contentShape(Rectangle())
      .help("\(item.label) · \(item.note)")
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(
        "\(item.label), \(PowerFormat.wattsUnsigned(item.watts)), "
          + "\(PowerFormat.percentage(item.watts / totalWatts)) of power. \(item.note)")
    }
  }

  // MARK: - Secondary readings

  private var remaining: (label: String, value: String)? {
    PowerFormat.remaining(
      timeToFull: metrics?.timeToFullMinutes, timeToEmpty: metrics?.timeToEmptyMinutes)
  }

  private var detailStrip: some View {
    ScrollView(.horizontal) {
      HStack(spacing: 16) {
        detail("Health", metrics?.healthPercent.map { "\($0)%" }, symbol: "heart.fill")
          .help(healthHelp)
        detail(
          "Temperature", metrics?.temperatureC.map(PowerFormat.temperature),
          symbol: "thermometer.medium")
        detail(
          "Cycles", metrics?.cycleCount.map(String.init), symbol: "arrow.triangle.2.circlepath")
        detail("Capacity", capacityValue, symbol: "battery.75percent")
        telemetryDiagnostics
        ForEach(monitor.peripherals) { device in
          detail(device.name, "\(device.percent)%", symbol: device.icon)
        }
      }
    }
    .scrollIndicators(.hidden)
    .frame(height: 29)
  }

  @ViewBuilder private var telemetryDiagnostics: some View {
    let unavailable = metrics?.unavailableTelemetry ?? []
    if !unavailable.isEmpty {
      Menu {
        ForEach(unavailable, id: \.field) { diagnostic in
          Label(
            "\(diagnostic.field.label): \(diagnostic.status.diagnosticReason)",
            systemImage: "exclamationmark.circle")
        }
      } label: {
        HStack(spacing: 5) {
          Image(systemName: "waveform.path.ecg")
            .font(.system(size: 9)).appThemeForeground(.battery)
          VStack(alignment: .leading, spacing: 0) {
            Text("Diagnostics").font(.system(size: 10, weight: .semibold)).lineLimit(1)
            Text("\(unavailable.count) unavailable")
              .font(.system(size: 8)).foregroundStyle(.tertiary).lineLimit(1)
          }
        }
      }
      .accessibilityLabel("Battery diagnostics, \(unavailable.count) unavailable readings")
      .help(
        unavailable
          .map { "\($0.field.label): \($0.status.diagnosticReason)" }
          .joined(separator: "\n"))
    }
  }

  @ViewBuilder private func detail(_ label: String, _ value: String?, symbol: String) -> some View {
    if let value {
      HStack(spacing: 5) {
        Image(systemName: symbol).font(.system(size: 9)).appThemeForeground(.battery)
        VStack(alignment: .leading, spacing: 0) {
          Text(value).font(.system(size: 10, weight: .semibold)).monospacedDigit().lineLimit(1)
          Text(label).font(.system(size: 8)).foregroundStyle(.tertiary).lineLimit(1)
        }
      }
      .accessibilityElement(children: .combine)
    }
  }

  private var healthHelp: String {
    var parts: [String] = []
    if let raw = metrics?.rawHealthPercent { parts.append("Raw health \(raw)%") }
    if let condition = metrics?.condition { parts.append("Condition: \(condition)") }
    return parts.isEmpty ? "Battery health" : parts.joined(separator: " · ")
  }

  private var capacityValue: String? {
    guard let current = metrics?.rawMaxCapacityMAh ?? metrics?.nominalCapacityMAh else {
      return nil
    }
    return "\(current) mAh"
  }

}
