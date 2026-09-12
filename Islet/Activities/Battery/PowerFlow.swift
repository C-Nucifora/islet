import Foundation

enum PowerInputKind: Equatable {
  case usbC, magSafe, wireless, adapter

  var label: String {
    switch self {
    case .usbC: String(localized: "USB-C")
    case .magSafe: String(localized: "MagSafe")
    case .wireless: String(localized: "Wireless")
    case .adapter: String(localized: "Power adapter")
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
    resolve(batteryWatts: metrics?.resolvedBatteryPower.watts)
  }

  static func resolve(batteryWatts: Double?) -> Self {
    guard let batteryWatts, abs(batteryWatts) > 0.05 else { return .idle }
    return batteryWatts > 0 ? .charging : .supplementing
  }
}

/// A balanced, display-ready view of instantaneous power. Battery discharge moves to the input
/// side, battery charge moves to the output side, and per-port USB output is subtracted from the
/// remaining input power to estimate the Mac's own draw. An optional CPU estimate subdivides it
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
    let pack = metrics?.resolvedBatteryPower.watts
    let direction = BatteryFlowDirection.resolve(metrics: metrics)
    let batteryMagnitude = Self.positive(pack.map { abs($0) })
    let batteryIn = direction == .supplementing ? batteryMagnitude : nil
    let batteryCharge = direction == .charging ? batteryMagnitude : nil
    let outputs = metrics?.usbPowerOutputs ?? []
    let usbTotal = outputs.reduce(0) { $0 + $1.watts }

    let reportedSystemUse = Self.positive(metrics?.systemLoadWatts)
    let inferredSystemUse: Double? = {
      let supplied = (adapter ?? 0) + (batteryIn ?? 0)
      guard supplied > 0, pack != nil else { return nil }
      return max(0, supplied - (batteryCharge ?? 0))
    }()
    // Derive the Mac share from input minus measured battery charge, or input plus discharge.
    // Do not mix a valid pack reading with the contradictory private SystemLoad estimate.
    let totalSystemUse =
      inferredSystemUse
      ?? (pack == nil && metrics?.batteryPowerWatts != nil ? nil : reportedSystemUse)

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
