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
    text(
      onAC: onAC,
      isCharging: isCharging,
      fullyCharged: fullyCharged,
      batteryDirection: BatteryFlowDirection.resolve(batteryWatts: batteryWatts),
      notChargingReason: notChargingReason)
  }

  static func text(
    onAC: Bool, isCharging: Bool, fullyCharged: Bool,
    batteryDirection: BatteryFlowDirection, notChargingReason: UInt64?
  ) -> String {
    if !onAC { return String(localized: "On battery") }
    if batteryDirection == .supplementing {
      return String(localized: "Adapter can't keep up")
    }
    if batteryDirection == .charging || isCharging { return String(localized: "Charging") }
    if fullyCharged { return String(localized: "Charged") }
    // The reason bitfield is undocumented diagnostics, not prose — the view offers it in a
    // tooltip. Putting the hex in this line truncated it into "Not charging · 0x80000…".
    return String(localized: "Not charging")
  }
}

/// Locale-aware number-to-string rules for the power screen.
enum PowerFormat {
  static func time(minutes: Int, locale: Locale = .current) -> String {
    if minutes < 60 {
      return String(localized: "\(LocalizedFormat.integer(minutes, locale: locale))m")
    }
    return String(
      localized:
        "\(LocalizedFormat.integer(minutes / 60, locale: locale))h \(LocalizedFormat.integer(minutes % 60, minimumDigits: 2, locale: locale))m"
    )
  }

  static func capacity(_ current: Int?, of design: Int?) -> String? {
    guard let current else { return nil }
    let currentText = LocalizedFormat.integer(current)
    guard let design, design > 0 else { return String(localized: "\(currentText) mAh") }
    return String(localized: "\(currentText) / \(LocalizedFormat.integer(design)) mAh")
  }

  static func cycles(_ count: Int, of design: Int?) -> String {
    guard let design, design > 0 else { return LocalizedFormat.integer(count) }
    return String(
      localized: "\(LocalizedFormat.integer(count)) / \(LocalizedFormat.integer(design))")
  }

  /// Signed: the sign is the information — into the pack or out of it.
  static func watts(_ w: Double, locale: Locale = .current) -> String {
    String(localized: "\(LocalizedFormat.signedNumber(w, fractionDigits: 1, locale: locale)) W")
  }
  static func wattsUnsigned(_ w: Double, locale: Locale = .current) -> String {
    LocalizedFormat.measurement(w, unit: UnitPower.watts, fractionDigits: 1...1, locale: locale)
  }
  static func percentage(_ fraction: Double) -> String {
    LocalizedFormat.percent(min(1, max(0, fraction)))
  }
  static func amps(_ a: Double, locale: Locale = .current) -> String {
    String(localized: "\(LocalizedFormat.signedNumber(a, fractionDigits: 2, locale: locale)) A")
  }
  static func volts(_ v: Double, locale: Locale = .current) -> String {
    LocalizedFormat.measurement(
      v, unit: UnitElectricPotentialDifference.volts, fractionDigits: 2...2, locale: locale)
  }
  static func temperature(_ c: Double, locale: Locale = .current) -> String {
    LocalizedFormat.measurement(
      c, unit: UnitTemperature.celsius, fractionDigits: 1...1, locale: locale)
  }
  static func temperatureAccessibility(_ c: Double, locale: Locale = .current) -> String {
    LocalizedFormat.measurement(
      c, unit: UnitTemperature.celsius, fractionDigits: 1...1, width: .wide, locale: locale)
  }

  static func chargerSummary(watts: Int?, description: String?) -> String? {
    // Written with explicit returns: a switch *expression* whose branches mix String and nil does
    // not type-check against a String? contextual type.
    switch (watts, description) {
    case (let w?, let d?): return String(localized: "\(w) W · \(d)")
    case (let w?, nil): return String(localized: "\(w) W")
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
    if let timeToFull { return (String(localized: "Full in"), time(minutes: timeToFull)) }
    if let timeToEmpty { return (String(localized: "Left"), time(minutes: timeToEmpty)) }
    return nil
  }

  static func remaining(
    batteryDirection: BatteryFlowDirection, timeToFull: Int?, timeToEmpty: Int?
  ) -> (label: String, value: String)? {
    remaining(
      timeToFull: batteryDirection == .charging ? timeToFull : nil,
      timeToEmpty: timeToEmpty)
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
