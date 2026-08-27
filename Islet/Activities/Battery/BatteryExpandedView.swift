import SwiftUI

/// The power screen leads with the live story: what is supplying the Mac, and where that power is
/// going. Battery health and electrical diagnostics remain available in the compact strip below.
struct BatteryExpandedView: View {
  @ObservedObject var monitor: BatteryMonitor

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
      Divider().overlay(.white.opacity(0.12))
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
        Circle().fill(batteryTint.opacity(0.14))
        Image(systemName: BatteryActivity.batterySymbol(for: percent))
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(batteryTint)
      }
      .frame(width: 30, height: 30)
      .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 0) {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
          Text("\(percent)%")
            .font(.system(size: 19, weight: .bold, design: .rounded)).monospacedDigit()
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
        statusPill("Low Power", symbol: "leaf.fill", tint: .yellow)
      }
      statusPill("Live", symbol: "circle.fill", tint: flow.hasLivePower ? .green : .secondary)
    }
    .frame(height: 30)
  }

  private func statusPill(_ label: String, symbol: String, tint: Color) -> some View {
    HStack(spacing: 4) {
      Image(systemName: symbol).font(.system(size: symbol == "circle.fill" ? 5 : 9))
      Text(label).font(.system(size: 9, weight: .semibold))
    }
    .foregroundStyle(tint)
    .padding(.horizontal, 7).frame(height: 20)
    .background(Capsule().fill(tint.opacity(0.11)))
  }

  // MARK: - Power graph

  private struct FlowItem: Identifiable {
    let id: String
    let label: String
    let note: String
    let symbol: String
    let watts: Double
    let tint: Color
  }

  private var inputItems: [FlowItem] {
    var items: [FlowItem] = []
    if let watts = flow.adapterInputWatts {
      let kind = PowerInputKind.detect(from: metrics)
      items.append(
        FlowItem(
          id: "adapter", label: kind.label, note: adapterNote,
          symbol: kind.symbol, watts: watts, tint: .green))
    }
    if let watts = flow.batteryInputWatts {
      items.append(
        FlowItem(
          id: "battery-source", label: "Battery", note: "system battery supplement",
          symbol: "battery.100percent", watts: watts, tint: .orange))
    }
    return items
  }

  private var outputItems: [FlowItem] {
    var items: [FlowItem] = []
    if let watts = flow.macUseWatts, watts > 0.05 {
      items.append(
        FlowItem(
          id: "mac", label: "Running the Mac", note: "internal system load",
          symbol: "laptopcomputer", watts: watts, tint: .cyan))
    }
    if flow.usbOutputWatts > 0.05 {
      let ports = flow.usbOutputs.count
      items.append(
        FlowItem(
          id: "usb-output", label: "USB output",
          note: ports == 1 ? "powering port \(flow.usbOutputs[0].portIndex)" : "powering \(ports) ports",
          symbol: "cable.connector", watts: flow.usbOutputWatts, tint: .purple))
    }
    if let watts = flow.batteryChargeWatts {
      items.append(
        FlowItem(
          id: "battery-charge", label: "Charging battery", note: "stored in the system battery",
          symbol: "battery.100percent.bolt", watts: watts, tint: .green))
    }
    return items
  }

  private var adapterNote: String {
    switch (metrics?.adapterVolts, metrics?.adapterAmps, metrics?.adapterWatts) {
    case let (volts?, amps?, _): return String(format: "%.0f V × %.2f A negotiated", volts, amps)
    case let (_, _, watts?): return "\(watts) W adapter rating"
    default: return "external power"
    }
  }

  @ViewBuilder private var powerGraph: some View {
    if flow.hasLivePower {
      HStack(alignment: .top, spacing: 8) {
        flowColumn(title: "COMING IN", items: inputItems)
          .frame(width: 166)
        flowBridge.frame(width: 58)
        flowColumn(title: "GOING TO", items: outputItems)
          .frame(maxWidth: .infinity)
      }
      .frame(maxHeight: .infinity, alignment: .top)
    } else {
      VStack(spacing: 6) {
        Image(systemName: "bolt.horizontal.circle")
          .font(.system(size: 24, weight: .light)).foregroundStyle(.secondary)
        Text("Waiting for live power telemetry").font(.caption.weight(.semibold))
        Text(onAC ? "Power is connected; the next hardware sample will populate the flow." : "Battery flow will appear as the Mac reports it.")
          .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .accessibilityElement(children: .combine)
    }
  }

  private func flowColumn(title: String, items: [FlowItem]) -> some View {
    let compact = items.count > 2
    return VStack(alignment: .leading, spacing: 4) {
      Text(title)
        .font(.system(size: 8, weight: .bold)).tracking(0.8)
        .foregroundStyle(.tertiary)
      ForEach(items) { item in flowBar(item, compact: compact) }
    }
  }

  private func flowBar(_ item: FlowItem, compact: Bool) -> some View {
    let fraction = flow.proportion(of: item.watts)
    return VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: 4) {
        Image(systemName: item.symbol)
          .font(.system(size: 9, weight: .semibold)).foregroundStyle(item.tint)
          .frame(width: 12)
        Text(item.label).font(.system(size: 9, weight: .semibold)).lineLimit(1)
        Spacer(minLength: 3)
        Text(PowerFormat.wattsUnsigned(item.watts))
          .font(.system(size: 9, weight: .bold, design: .rounded)).monospacedDigit()
        Text(PowerFormat.percentage(fraction))
          .font(.system(size: 8, weight: .bold)).monospacedDigit().foregroundStyle(item.tint)
          .lineLimit(1).minimumScaleFactor(0.75)
          .frame(width: 27, alignment: .trailing)
      }
      GeometryReader { proxy in
        ZStack(alignment: .leading) {
          Capsule().fill(.white.opacity(0.08))
          Capsule()
            .fill(
              LinearGradient(
                colors: [item.tint.opacity(0.45), item.tint],
                startPoint: .leading, endPoint: .trailing)
            )
            .frame(width: max(4, proxy.size.width * fraction))
            .animation(Motion.gated(Motion.compact), value: fraction)
        }
      }
      .frame(height: 5)
      if !compact {
        Text(item.note).font(.system(size: 7.5)).foregroundStyle(.tertiary).lineLimit(1)
      }
    }
    .padding(.horizontal, 6).padding(.vertical, 4)
    .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.045)))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      "\(item.label), \(PowerFormat.wattsUnsigned(item.watts)), \(PowerFormat.percentage(fraction)) of power")
  }

  private var flowBridge: some View {
    VStack(spacing: 3) {
      Spacer(minLength: 13)
      ZStack {
        Circle().fill(Color.green.opacity(0.12))
        Circle().stroke(Color.green.opacity(0.28), lineWidth: 1)
        Image(systemName: "arrow.right")
          .font(.system(size: 11, weight: .bold)).foregroundStyle(.green)
      }
      .frame(width: 30, height: 30)
      Text(PowerFormat.wattsUnsigned(flow.scaleWatts))
        .font(.system(size: 10, weight: .bold, design: .rounded)).monospacedDigit()
      Text("FLOWING")
        .font(.system(size: 7, weight: .bold)).tracking(0.5).foregroundStyle(.tertiary)
      Spacer(minLength: 0)
      if let loss = metrics?.adapterLossWatts, loss > 0.05 {
        Text("\(PowerFormat.wattsUnsigned(loss)) loss")
          .font(.system(size: 7)).foregroundStyle(.tertiary).lineLimit(1)
          .help("Adapter efficiency loss")
      }
    }
    .accessibilityElement(children: .combine)
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
        detail("Temperature", metrics?.temperatureC.map(PowerFormat.temperature), symbol: "thermometer.medium")
        detail("Cycles", metrics?.cycleCount.map(String.init), symbol: "arrow.triangle.2.circlepath")
        detail("Capacity", capacityValue, symbol: "battery.75percent")
        ForEach(monitor.peripherals) { device in
          detail(device.name, "\(device.percent)%", symbol: device.icon)
        }
      }
    }
    .scrollIndicators(.hidden)
    .frame(height: 29)
  }

  @ViewBuilder private func detail(_ label: String, _ value: String?, symbol: String) -> some View {
    if let value {
      HStack(spacing: 5) {
        Image(systemName: symbol).font(.system(size: 9)).foregroundStyle(.secondary)
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
    guard let current = metrics?.rawMaxCapacityMAh ?? metrics?.nominalCapacityMAh else { return nil }
    return "\(current) mAh"
  }

  private var batteryTint: Color {
    if onAC { return .green }
    return percent <= 20 ? .red : .white
  }
}
