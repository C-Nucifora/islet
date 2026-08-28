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
    if !metrics.pdLadder.isEmpty || description.contains("usb") || description.contains("pd charger") {
      return .usbC
    }
    return .adapter
  }
}

/// A balanced, display-ready view of instantaneous power. Battery discharge moves to the input
/// side, battery charge moves to the output side, and per-port USB output is subtracted from the
/// aggregate SystemLoad to leave the Mac's own draw.
struct PowerFlowSnapshot: Equatable {
  let adapterInputWatts: Double?
  let batteryInputWatts: Double?
  let macUseWatts: Double?
  let batteryChargeWatts: Double?
  let usbOutputs: [USBPowerOutput]
  let scaleWatts: Double

  init(metrics: BatteryMetrics?) {
    let adapter = Self.positive(metrics?.systemPowerInWatts)
    let pack = metrics?.batteryPowerWatts ?? metrics?.powerWatts
    let batteryIn = pack.flatMap { $0 < -0.05 ? -$0 : nil }
    let batteryCharge = pack.flatMap { $0 > 0.05 ? $0 : nil }
    let outputs = metrics?.usbPowerOutputs ?? []
    let usbTotal = outputs.reduce(0) { $0 + $1.watts }

    let reportedSystemUse = Self.positive(metrics?.systemLoadWatts)
    let inferredSystemUse: Double? = {
      let supplied = (adapter ?? 0) + (batteryIn ?? 0)
      guard supplied > 0 else { return nil }
      return max(0, supplied - (batteryCharge ?? 0))
    }()
    let totalSystemUse = reportedSystemUse ?? inferredSystemUse

    adapterInputWatts = adapter
    batteryInputWatts = batteryIn
    macUseWatts = totalSystemUse.map { max(0, $0 - usbTotal) }
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
