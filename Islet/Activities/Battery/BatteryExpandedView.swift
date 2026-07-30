import SwiftUI

/// The power screen: a charge ring, a four-row telemetry grid, the power-flow row and a footer of
/// peripheral batteries. Pinned to the top-left so rows do not shuffle vertically as tiles come and
/// go — the whole panel is optional-parsed and any tile can vanish between ticks.
struct BatteryExpandedView: View {
  @ObservedObject var monitor: BatteryMonitor

  private var state: BatteryState? { monitor.state }
  private var metrics: BatteryMetrics? { monitor.metrics }
  private var percent: Int { state?.percent ?? 0 }
  private var onAC: Bool { state?.onAC ?? false }

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
      HStack(alignment: .top, spacing: 14) {
        ringColumn.frame(width: 84)
        metricGrid
      }

      Spacer(minLength: 0)

      // The flow row (and the peripherals footer, when there is one) anchor to the bottom edge.
      // Between the grid and a mid-panel flow row sat ~60pt of nothing, which read as a layout
      // accident; the same slack above a bottom-anchored bar reads as breathing room.
      if !flowNodes.isEmpty {
        Divider().overlay(.white.opacity(0.12))
        powerFlowRow
      }

      // Peripherals only. Low Power lives on the flow row, so a machine with no Bluetooth
      // batteries does not spend a divider and a whole row on one glyph.
      if !monitor.peripherals.isEmpty {
        Divider().overlay(.white.opacity(0.12))
        footerRow
      }
    }
    .foregroundStyle(.white)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .liveSampling(monitor.liveGate)
  }

  // MARK: - Charge ring

  private var ringColumn: some View {
    VStack(spacing: 5) {
      ZStack {
        // Inset by half the stroke: a stroke is centred on the path, so an un-inset circle
        // overhangs its frame by 3.5pt and gets clipped against the top of the content box.
        Circle()
          .inset(by: 3.5)
          .stroke(.white.opacity(0.12), lineWidth: 7)
        Circle()
          .inset(by: 3.5)
          .trim(from: 0, to: max(0.001, Double(percent) / 100))
          .stroke(
            Self.tint(percent: percent, onAC: onAC),
            style: StrokeStyle(lineWidth: 7, lineCap: .round)
          )
          .rotationEffect(.degrees(-90))
          .animation(Motion.gated(Motion.compact), value: percent)
        Text("\(percent)%")
          .font(.system(size: 17, weight: .bold)).monospacedDigit()
      }
      .frame(width: 66, height: 66)

      statusLine
    }
    .frame(maxWidth: .infinity)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Battery \(percent) percent, \(statusText)")
  }

  /// The one-line state under the ring. The raw NotChargingReason bitfield is diagnostics, not
  /// prose — it lives in the tooltip, where it cannot truncate the line into "0x80000…".
  @ViewBuilder private var statusLine: some View {
    let text = Text(statusText)
      .font(.system(size: 9)).foregroundStyle(.secondary)
      .lineLimit(1).minimumScaleFactor(0.8)
    if let reason = metrics?.notChargingReason, reason != 0 {
      text.help("NotChargingReason \(NotChargingReason.code(reason))")
    } else {
      text
    }
  }

  private static func tint(percent: Int, onAC: Bool) -> Color {
    if onAC { return .green }
    return percent <= 20 ? .red : .white
  }

  // MARK: - Metric grid

  /// Fixed column widths, on purpose. `Grid` with `gridCellColumns` spans let the widest spanning
  /// cell blow a column out to ~220pt and strand its neighbours mid-air; three constant columns
  /// keep every label vertically aligned no matter which tiles are present. The grid box is
  /// 452 − 84 (ring) − 14 (gap) = 354pt: 132 + 100 + 108 + 2 × 7 spacing.
  private static let columnWidths: [CGFloat] = [132, 100, 108]
  private static let columnSpacing: CGFloat = 7

  private var metricGrid: some View {
    VStack(alignment: .leading, spacing: 8) {
      gridRow(
        ("Health", metrics?.healthPercent.map { "\($0)%" }),
        ("Raw", metrics?.rawHealthPercent.map { "\($0)%" }),
        ("Cycles", cyclesValue))
      gridRow(
        ("Temp", metrics?.temperatureC.map(PowerFormat.temperature)),
        ("Volt", metrics?.voltage.map(PowerFormat.volts)),
        ("Amps", metrics?.amperage.map(PowerFormat.amps)))
      gridRow(
        ("Capacity", capacityValue),
        ("Condition", metrics?.condition),
        (remaining?.label ?? "Left", remaining?.value))
      // The charger line runs the full grid width so "50 W · pd charger" never fights a column.
      chargerLine
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func gridRow(
    _ a: (String, String?), _ b: (String, String?), _ c: (String, String?)
  ) -> some View {
    HStack(alignment: .top, spacing: Self.columnSpacing) {
      tile(a.0, a.1).frame(width: Self.columnWidths[0], alignment: .leading)
      tile(b.0, b.1).frame(width: Self.columnWidths[1], alignment: .leading)
      tile(c.0, c.1).frame(width: Self.columnWidths[2], alignment: .leading)
    }
  }

  private var cyclesValue: String? {
    metrics?.cycleCount.map { PowerFormat.cycles($0, of: metrics?.designCycleCount) }
  }

  private var capacityValue: String? {
    PowerFormat.capacity(
      metrics?.rawMaxCapacityMAh ?? metrics?.nominalCapacityMAh, of: metrics?.designCapacityMAh)
  }

  private var remaining: (label: String, value: String)? {
    PowerFormat.remaining(
      timeToFull: metrics?.timeToFullMinutes, timeToEmpty: metrics?.timeToEmptyMinutes)
  }

  /// Charger wattage and description inline, the whole negotiated PD ladder in the tooltip — the
  /// ladder is five rungs and would not survive any column.
  @ViewBuilder private var chargerLine: some View {
    let summary = PowerFormat.chargerSummary(
      watts: metrics?.adapterWatts, description: metrics?.adapterDescription)
    if let ladder = PowerFormat.ladderSummary(metrics?.pdLadder ?? []) {
      tile("Charger", summary).help("Power Delivery ladder: \(ladder)")
    } else {
      tile("Charger", summary)
    }
  }

  /// A labelled reading, or an empty spacer that still holds the column when the key was absent.
  @ViewBuilder private func tile(_ label: String, _ value: String?) -> some View {
    if let value {
      VStack(alignment: .leading, spacing: 1) {
        Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
        Text(value).font(.caption.weight(.semibold)).monospacedDigit().lineLimit(1)
      }
      .accessibilityElement(children: .combine)
    } else {
      Color.clear.frame(height: 1)
    }
  }

  // MARK: - Power flow

  /// One stage of the wall-to-machine-to-pack chain. Identified by its label so `ForEach` does not
  /// churn every tick.
  private struct FlowNode: Identifiable {
    let label: String
    let value: String
    let tint: Color
    var id: String { label }
  }

  /// Built only from what `PowerTelemetryData` actually returned; the whole row disappears on a
  /// machine that does not publish the key.
  private var flowNodes: [FlowNode] {
    guard let m = metrics else { return [] }
    var nodes: [FlowNode] = []
    if let inW = m.systemPowerInWatts {
      nodes.append(FlowNode(label: "Adapter", value: PowerFormat.wattsUnsigned(inW), tint: .green))
    }
    if let load = m.systemLoadWatts {
      nodes.append(FlowNode(label: "System", value: PowerFormat.wattsUnsigned(load), tint: .white))
    }
    if let batt = m.batteryPowerWatts {
      nodes.append(
        FlowNode(
          label: "Battery", value: PowerFormat.watts(batt), tint: batt >= 0 ? .green : .orange))
    }
    return nodes
  }

  private var powerFlowRow: some View {
    let nodes = flowNodes
    return HStack(spacing: 6) {
      Image(systemName: "bolt.fill").font(.system(size: 10)).foregroundStyle(.yellow)
        .accessibilityHidden(true)
      ForEach(nodes) { node in
        if node.id != nodes.first?.id {
          Image(systemName: "arrow.right").font(.system(size: 9)).foregroundStyle(.secondary)
            .accessibilityHidden(true)
        }
        HStack(spacing: 4) {
          Text(node.label).font(.system(size: 9)).foregroundStyle(.secondary)
          Text(node.value).font(.caption.weight(.semibold)).monospacedDigit()
            .foregroundStyle(node.tint)
        }
        .accessibilityElement(children: .combine)
      }
      Spacer(minLength: 8)
      if let loss = metrics?.adapterLossWatts {
        HStack(spacing: 4) {
          Text("Loss").font(.system(size: 9)).foregroundStyle(.secondary)
          Text(PowerFormat.wattsUnsigned(loss)).font(.caption.weight(.semibold)).monospacedDigit()
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
      }
      if let m = metrics {
        HStack(spacing: 3) {
          Image(systemName: m.lowPowerMode ? "leaf.fill" : "leaf")
            .font(.system(size: 10))
            .foregroundStyle(m.lowPowerMode ? .yellow : .secondary)
          Text("Low Power").font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(m.lowPowerMode ? "Low Power Mode on" : "Low Power Mode off")
      }
    }
  }

  // MARK: - Footer

  private var footerRow: some View {
    HStack(spacing: 12) {
      ForEach(monitor.peripherals) { device in
        HStack(spacing: 4) {
          Image(systemName: device.icon).font(.caption2).foregroundStyle(.secondary)
          Text("\(device.percent)%").font(.caption2.weight(.semibold)).monospacedDigit()
            .foregroundStyle(device.percent <= 15 ? .red : .white)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(device.name) \(device.percent) percent")
      }
      Spacer(minLength: 0)
    }
  }
}
