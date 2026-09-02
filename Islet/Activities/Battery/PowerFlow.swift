import Foundation

enum PowerInputKind: Equatable {
  case usbC, magSafe, wireless, adapter

  var label: String {
    switch self {
    case .usbC: "USB-C"
    case .magSafe: "MagSafe"
    case .wireless: "Wireless"
    case .adapter: "Power adapter"
    }
  }

  var symbol: String {
    switch self {
    case .usbC: "cable.connector"
    case .magSafe: "bolt.horizontal.fill"
    case .wireless: "wave.3.right"
    case .adapter: "powerplug.fill"
    }
  }

  static func detect(from metrics: BatteryMetrics?) -> PowerInputKind {
    guard let metrics else { return .adapter }
    let port = metrics.inputPortType?.lowercased() ?? ""
    let description = metrics.adapterDescription?.lowercased() ?? ""
    if port.contains("magsafe") || description.contains("magsafe") { return .magSafe }
    if port.contains("usb-c") || port.contains("usb c") { return .usbC }
    if metrics.adapterIsWireless == true { return .wireless }
    if !metrics.pdLadder.isEmpty || description.contains("usb")
      || description.contains("pd charger")
    {
      return .usbC
    }
    return .adapter
  }
}

enum BatteryFlowDirection: Equatable {
  case idle
  case charging
  case supplementing

  static func resolve(metrics: BatteryMetrics?) -> Self {
    let confirmedCharging =
      metrics?.externalConnected == true
      && metrics?.isCharging == true
      && metrics?.timeToFullMinutes != nil
    if confirmedCharging { return .charging }
    return resolve(batteryWatts: metrics?.batteryPowerWatts ?? metrics?.powerWatts)
  }

  static func resolve(batteryWatts: Double?) -> Self {
    guard let batteryWatts, abs(batteryWatts) > 0.05 else { return .idle }
    return batteryWatts > 0 ? .charging : .supplementing
  }
}

/// A balanced, display-ready view of instantaneous power. Battery discharge moves to the input
/// side, battery charge moves to the output side, and per-port USB output is subtracted from the
/// aggregate SystemLoad to leave the Mac's own draw. An optional CPU estimate subdivides that draw
/// without changing the graph's total.
struct PowerFlowSnapshot: Equatable {
  let batteryDirection: BatteryFlowDirection
  let adapterInputWatts: Double?
  let batteryInputWatts: Double?
  let macUseWatts: Double?
  let cpuUseWatts: Double?
  let restOfMacWatts: Double?
  let batteryChargeWatts: Double?
  let usbOutputs: [USBPowerOutput]
  let scaleWatts: Double

  init(metrics: BatteryMetrics?) {
    let adapter = Self.positive(metrics?.systemPowerInWatts)
    let pack = metrics?.batteryPowerWatts ?? metrics?.powerWatts
    let direction = BatteryFlowDirection.resolve(metrics: metrics)
    let batteryMagnitude = Self.positive(pack.map { abs($0) })
    let batteryIn = direction == .supplementing ? batteryMagnitude : nil
    let batteryCharge = direction == .charging ? batteryMagnitude : nil
    let outputs = metrics?.usbPowerOutputs ?? []
    let usbTotal = outputs.reduce(0) { $0 + $1.watts }

    let reportedSystemUse = Self.positive(metrics?.systemLoadWatts)
    let inferredSystemUse: Double? = {
      let supplied = (adapter ?? 0) + (batteryIn ?? 0)
      guard supplied > 0 else { return nil }
      return max(0, supplied - (batteryCharge ?? 0))
    }()
    let directionOverridesTelemetry = direction == .charging && (pack ?? 0) < -0.05
    let totalSystemUse =
      directionOverridesTelemetry
      ? inferredSystemUse ?? reportedSystemUse
      : reportedSystemUse ?? inferredSystemUse

    batteryDirection = direction
    adapterInputWatts = adapter
    batteryInputWatts = batteryIn
    let macUse = totalSystemUse.map { max(0, $0 - usbTotal) }
    macUseWatts = macUse
    if let macUse, let reportedCPU = Self.positive(metrics?.cpuPowerWatts) {
      let cpu = min(macUse, reportedCPU)
      cpuUseWatts = cpu
      restOfMacWatts = max(0, macUse - cpu)
    } else {
      cpuUseWatts = nil
      restOfMacWatts = nil
    }
    batteryChargeWatts = batteryCharge
    usbOutputs = outputs

    let incoming = (adapter ?? 0) + (batteryIn ?? 0)
    let outgoing = (macUseWatts ?? 0) + usbTotal + (batteryCharge ?? 0)
    scaleWatts = max(incoming, outgoing)
  }

  var hasLivePower: Bool { scaleWatts > 0.05 }
  var usbOutputWatts: Double { usbOutputs.reduce(0) { $0 + $1.watts } }

  func proportion(of watts: Double) -> Double {
    guard scaleWatts > 0 else { return 0 }
    return min(1, max(0, watts / scaleWatts))
  }

  private static func positive(_ value: Double?) -> Double? {
    value.flatMap { $0 > 0.05 ? $0 : nil }
  }
}
