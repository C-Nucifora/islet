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
    VStack(alignment: .leading, spacing: 7) {
      HStack(alignment: .top, spacing: 14) {
        ringColumn.frame(width: 84)
        metricGrid
      }

      if !flowNodes.isEmpty {
        Divider().overlay(.white.opacity(0.12))
        powerFlowRow
      }

      Spacer(minLength: 0)

      if !monitor.peripherals.isEmpty || metrics != nil {
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
    VStack(spacing: 4) {
      ZStack {
        Circle()
          .stroke(.white.opacity(0.12), lineWidth: 7)
        Circle()
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
      .frame(width: 62, height: 62)

      Text(statusText)
        .font(.system(size: 9)).foregroundStyle(.secondary)
        .lineLimit(1).minimumScaleFactor(0.7)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Battery \(percent) percent, \(statusText)")
  }

  private static func tint(percent: Int, onAC: Bool) -> Color {
    if onAC { return .green }
    return percent <= 20 ? .red : .white
  }

  // MARK: - Metric grid

  private var metricGrid: some View {
    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
      GridRow {
        tile("Health", metrics?.healthPercent.map { "\($0)%" })
        tile("Raw", metrics?.rawHealthPercent.map { "\($0)%" })
        tile("Cycles", cyclesValue)
      }
      GridRow {
        tile("Temp", metrics?.temperatureC.map(PowerFormat.temperature))
        tile("Volt", metrics?.voltage.map(PowerFormat.volts))
        tile("Amps", metrics?.amperage.map(PowerFormat.amps))
      }
      GridRow {
        tile("Capacity", capacityValue).gridCellColumns(2)
        tile("Condition", metrics?.condition)
      }
      GridRow {
        tile(remaining?.label ?? "Left", remaining?.value)
        chargerTile.gridCellColumns(2)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
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

  /// The charger tile carries the rated wattage and description inline, and the whole negotiated PD
  /// ladder in its tooltip — the ladder is five rungs and would not survive the row width.
  @ViewBuilder private var chargerTile: some View {
    let summary = PowerFormat.chargerSummary(
      watts: metrics?.adapterWatts, description: metrics?.adapterDescription)
    if let ladder = PowerFormat.ladderSummary(metrics?.pdLadder ?? []) {
      tile("Charger", summary).help("Power Delivery ladder: \(ladder)")
    } else {
      tile("Charger", summary)
    }
  }

  /// A labelled reading, or an empty cell that still holds the column width when the key was not
  /// present in the registry.
  @ViewBuilder private func tile(_ label: String, _ value: String?) -> some View {
    if let value {
      VStack(alignment: .leading, spacing: 0) {
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
      if let loss = metrics?.adapterLossWatts {
        Spacer(minLength: 8)
        HStack(spacing: 4) {
          Text("Loss").font(.system(size: 9)).foregroundStyle(.secondary)
          Text(PowerFormat.wattsUnsigned(loss)).font(.caption.weight(.semibold)).monospacedDigit()
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
      } else {
        Spacer(minLength: 0)
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
      if let m = metrics {
        HStack(spacing: 4) {
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
}
