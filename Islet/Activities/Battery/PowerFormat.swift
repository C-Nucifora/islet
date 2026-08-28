import Foundation

/// `ChargerData.NotChargingReason` is an undocumented bitfield. Apple publishes neither the field
/// nor the meaning of any bit, so this decoder deliberately never *names* one — it reports the raw
/// code and which bits are set, and lets `PowerStatus` explain the situation from telemetry that
/// can actually be defended. Printing "0x80000000000000" is honest; printing a made-up label is not.
enum NotChargingReason {
  static func setBits(_ raw: UInt64) -> [Int] {
    (0..<64).filter { raw & (UInt64(1) << UInt64($0)) != 0 }
  }

  static func code(_ raw: UInt64) -> String {
    "0x" + String(raw, radix: 16, uppercase: true)
  }
}

/// The single line under the charge ring. Pure so every branch is covered by a test rather than by
/// unplugging a laptop.
enum PowerStatus {
  static func text(
    onAC: Bool, isCharging: Bool, fullyCharged: Bool,
    batteryWatts: Double?, notChargingReason: UInt64?
  ) -> String {
    if !onAC { return "On battery" }
    // IOPS's `IsCharging` describes the requested charger state and can remain true while the
    // pack is momentarily supplying the shortfall. Prefer the same signed live measurement used
    // by the flow graph so the headline can never claim that a left-side battery ribbon is charge.
    if let batteryWatts, batteryWatts < -0.05 { return "Adapter can't keep up" }
    if isCharging { return "Charging" }
    if fullyCharged { return "Charged" }
    // The reason bitfield is undocumented diagnostics, not prose — the view offers it in a
    // tooltip. Putting the hex in this line truncated it into "Not charging · 0x80000…".
    return "Not charging"
  }
}

/// Number-to-string rules for the power screen. `String(format:)` with no locale argument is
/// non-localised, so the decimal separator is always "." and these results are stable in tests.
enum PowerFormat {
  static func time(minutes: Int) -> String {
    minutes < 60 ? "\(minutes)m" : String(format: "%dh %02dm", minutes / 60, minutes % 60)
  }

  static func capacity(_ current: Int?, of design: Int?) -> String? {
    guard let current else { return nil }
    guard let design, design > 0 else { return "\(current) mAh" }
    return "\(current) / \(design) mAh"
  }

  static func cycles(_ count: Int, of design: Int?) -> String {
    guard let design, design > 0 else { return "\(count)" }
    return "\(count) / \(design)"
  }

  /// Signed: the sign is the information — into the pack or out of it.
  static func watts(_ w: Double) -> String { String(format: "%+.1f W", w) }
  static func wattsUnsigned(_ w: Double) -> String { String(format: "%.1f W", w) }
  static func percentage(_ fraction: Double) -> String {
    "\(Int((min(1, max(0, fraction)) * 100).rounded()))%"
  }
  static func amps(_ a: Double) -> String { String(format: "%+.2f A", a) }
  static func volts(_ v: Double) -> String { String(format: "%.2f V", v) }
  static func temperature(_ c: Double) -> String { String(format: "%.1f°C", c) }

  static func chargerSummary(watts: Int?, description: String?) -> String? {
    // Written with explicit returns: a switch *expression* whose branches mix String and nil does
    // not type-check against a String? contextual type.
    switch (watts, description) {
    case (let w?, let d?): return "\(w) W · \(d)"
    case (let w?, nil): return "\(w) W"
    case (nil, let d?): return d
    case (nil, nil): return nil
    }
  }

  /// The whole negotiated PD ladder on one line, for the charger tile's tooltip.
  static func ladderSummary(_ ladder: [PDProfile]) -> String? {
    guard !ladder.isEmpty else { return nil }
    return
      ladder
      .map { String(format: "%.0fV/%.2fA", $0.volts, $0.amps) }
      .joined(separator: " · ")
  }

  /// The time tile: counting up to full while charging, down to empty otherwise.
  static func remaining(timeToFull: Int?, timeToEmpty: Int?) -> (label: String, value: String)? {
    if let timeToFull { return ("Full in", time(minutes: timeToFull)) }
    if let timeToEmpty { return ("Left", time(minutes: timeToEmpty)) }
    return nil
  }
}

/// Exponential moving average over the readings that move on every sample. Without it the 1 Hz
/// panel repaints amperage, watts and temperature with a different last digit every tick and the
/// whole grid strobes.
enum PowerSmoothing {
  static let factor = 0.35
  /// Once the blend lands inside display precision it snaps to the sample, so a steady reading
  /// converges exactly instead of asymptotically — otherwise the `Equatable` diff in
  /// `BatteryMonitor.refresh` never settles and republishes on every tick forever.
  static let snapThreshold = 0.005

  static func blend(previous: Double?, sample: Double?, factor: Double = factor) -> Double? {
    guard let sample else { return nil }
    guard let previous else { return sample }
    let next = previous + (sample - previous) * factor
    return abs(next - sample) < snapThreshold ? sample : next
  }

  /// Smooths only the volatile fields of `new` against the last published snapshot. Capacities,
  /// cycle counts, health and every string pass through untouched so they never lag.
  static func smooth(_ old: BatteryMetrics?, into new: BatteryMetrics) -> BatteryMetrics {
    guard let old else { return new }
    var out = new
    out.temperatureC = blend(previous: old.temperatureC, sample: new.temperatureC)
    out.voltage = blend(previous: old.voltage, sample: new.voltage)
    out.amperage = blend(previous: old.amperage, sample: new.amperage)
    out.powerWatts = blend(previous: old.powerWatts, sample: new.powerWatts)
    out.systemPowerInWatts = blend(
      previous: old.systemPowerInWatts, sample: new.systemPowerInWatts)
    out.systemVoltageIn = blend(previous: old.systemVoltageIn, sample: new.systemVoltageIn)
    out.systemCurrentIn = blend(previous: old.systemCurrentIn, sample: new.systemCurrentIn)
    out.systemLoadWatts = blend(previous: old.systemLoadWatts, sample: new.systemLoadWatts)
    out.cpuPowerWatts = blend(previous: old.cpuPowerWatts, sample: new.cpuPowerWatts)
    out.batteryPowerWatts = blend(previous: old.batteryPowerWatts, sample: new.batteryPowerWatts)
    out.adapterLossWatts = blend(previous: old.adapterLossWatts, sample: new.adapterLossWatts)
    out.usbPowerOutputs = new.usbPowerOutputs.map { sample in
      guard let previous = old.usbPowerOutputs.first(where: { $0.portIndex == sample.portIndex })
      else { return sample }
      var smoothed = sample
      smoothed.watts = blend(previous: previous.watts, sample: sample.watts) ?? sample.watts
      return smoothed
    }
    return out
  }
}
