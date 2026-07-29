# Phase 2 — Power Screen Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild Islet's battery tab into an AlDente-density read-only power screen on the tall 480×250 tier, with every derived number produced by a pure, unit-tested function.

**Architecture:** All parsing, formatting, status derivation and smoothing move out of the view and out of the IOKit call site into three pure files — `BatteryMetricsParser` (plain `[String: Any]` in, `BatteryMetrics` out), `PowerFormat` (numbers to strings, plus the status-text decision table and the `NotChargingReason` bitfield decode) and `PowerSmoothing` (exponential moving average over the volatile fields). `SmartBatteryReader` shrinks to a thin IO shim that does one bulk `IORegistryReader.properties(matching: "AppleSmartBattery")`, one `IOPSCopyExternalPowerAdapterDetails()`, one `IOPSGetPowerSourceDescription` and one `ProcessInfo.isLowPowerModeEnabled` read, then hands the dictionaries to the parser. `BatteryExpandedView` is rewritten as a `Grid` pinned `.topLeading` on the tall height tier.

**Tech Stack:** Swift 6, SwiftUI, AppKit, XcodeGen, XCTest, sindresorhus/Defaults

## Global Constraints

- Swift 6 strict concurrency: app types are `@MainActor`; every new type in this plan except `BatteryMonitor`/`BatteryActivity`/the views is actor-free so tests call it synchronously.
- XcodeGen: `Islet.xcodeproj` is generated. **Every task that creates a new `.swift` file must run `xcodegen generate` before building**, or the build fails with "cannot find X in scope". The warning about `Vendor/MediaRemoteAdapter.framework` is expected and harmless.
- Test command: `xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`
- Build command: `xcodebuild build -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`
- Commit after every green test run. Scope prefix, lowercase imperative summary — e.g. `Power: read voltage, amperage and capacity from AppleSmartBattery`.
- **Line numbers in every task below refer to the file as it stands at the start of that task.** Earlier edits in the same task shift them. Apply each edit by matching the quoted text, not by seeking to a line number.
- **No `Co-Authored-By` trailer. No mention of Claude, Anthropic or AI in any commit message.**
- Phase-specific invariant: **every undocumented registry key is optional-parsed and its tile is omitted when absent**, exactly as `BatteryMetrics.hasAny` already works. Nothing renders a zero for a value that was not read.
- Phase-specific invariant: **never shell out to `pmset`** or any other process. Low Power Mode comes from `ProcessInfo.processInfo.isLowPowerModeEnabled` plus `.NSProcessInfoPowerStateDidChange`.
- Phase-specific invariant: **no charge control.** Everything here is read-only telemetry.

### Phase 1 is assumed shipped. This plan consumes, and does not define:

```swift
enum Metrics { static let tallExpandedHeight: CGFloat = 250 }
extension NotchActivity { var preferredExpandedHeight: CGFloat { Metrics.expandedSize.height } }

@MainActor final class LiveSamplingGate { init(onChange: @escaping (Bool) -> Void); func retain(); func release() }
extension View { func liveSampling(_ gate: LiveSamplingGate) -> some View }
// BatteryMonitor already exposes `let liveGate: LiveSamplingGate` in place of setLiveMetrics(_:)

enum IORegistryReader {
  static func properties(matching serviceName: String) -> [String: Any]?
  static func allProperties(matching serviceName: String) -> [[String: Any]]
  static func signedInt(_ raw: Int?) -> Int?
}

enum Motion { static let compact: Animation; static func gated(_ animation: Animation) -> Animation? }
```

### Real hardware values used as test fixtures

Captured on this machine (`ioreg -r -c AppleSmartBattery`, and a Swift probe through
`IORegistryEntryCreateCFProperties`) on 2026-07-29. **These are real, not invented.** The probe also
established that `NSNumber.intValue` on these CFNumbers already returns the *signed* value
(`Amperage` prints as `18446744073709551294` in `ioreg` but reads back as `-322`), so
`IORegistryReader.signedInt` is an identity function on this path and a genuine converter only when
a value arrives as an unsigned 32-bit quantity widened into `Int`.

| Key | Value | Meaning |
|---|---|---|
| `Voltage` | `11203` | 11.203 V |
| `Amperage` / `InstantAmperage` | `-322` | −0.322 A (discharging) |
| `Temperature` | `3068` | 30.68 °C |
| `AppleRawMaxCapacity` | `5381` | raw health numerator |
| `NominalChargeCapacity` | `5533` | System Settings health numerator |
| `DesignCapacity` | `6249` | denominator for both |
| `CycleCount` | `224` | |
| `DesignCycleCount9C` | `1000` | |
| `AvgTimeToEmpty` | `142` | 2h 22m |
| `AvgTimeToFull` | `65535` | "still calculating" sentinel |
| `IsCharging` / `FullyCharged` | `false` | |
| `ExternalConnected` | `true` | |
| `ChargerData.NotChargingReason` | `36028797018963968` | `0x80000000000000`, bit 55 only |
| `AdapterDetails.Watts` | `30` | |
| `AdapterDetails.Description` | `"pd charger"` | |
| `AdapterDetails.AdapterVoltage` | `20000` | 20.0 V |
| `AdapterDetails.Current` | `1490` | 1.49 A |
| `AdapterDetails.UsbHvcHvcIndex` | `4` | negotiated rung |
| `AdapterDetails.UsbHvcMenu` | 5 rungs: 5000/2960, 9000/2980, 12000/2480, 15000/1990, 20000/1490 | the PD ladder |
| `PowerTelemetryData.SystemPowerIn` | `28407` | 28.407 W in from the wall |
| `PowerTelemetryData.SystemVoltageIn` | `19803` | 19.803 V |
| `PowerTelemetryData.SystemCurrentIn` | `1434` | 1.434 A |
| `PowerTelemetryData.SystemLoad` | `34122` | 34.122 W the machine is actually using |
| `PowerTelemetryData.BatteryPower` | `-5715` | −5.715 W, the pack covering the shortfall |
| `PowerTelemetryData.AdapterEfficiencyLoss` | `696` | 0.696 W |
| IOPS `BatteryHealth` | `"Good"` | |
| IOPS `BatteryHealthCondition` | `""` | empty string means Normal |

`28.407 − (−5.715) = 34.122` exactly: **`SystemLoad == SystemPowerIn − BatteryPower`**. That
identity is asserted in Task 5 and is what pins down the sign convention.

**On `NotChargingReason`:** Apple documents neither the field nor a single bit. Observed value here
is bit 55 alone, while the machine is at 21%, AC-attached, `ChargingCurrent = 0`, with a 30 W
adapter and `SystemLoad` (34.1 W) exceeding `SystemPowerIn` (28.4 W). The plan therefore **never
names a bit**. It reports the code, and it derives the human explanation ("Adapter can't keep up")
from `PowerTelemetryData.BatteryPower` being negative while AC-attached — a signal that can be
defended from numbers rather than guessed from an undocumented bitfield.

---

## File Structure

**Created**

| Path | Single responsibility |
|---|---|
| `Islet/Activities/Battery/BatteryMetricsParser.swift` | Pure `[String: Any]` → `BatteryMetrics`. No IOKit, no actor. |
| `Islet/Activities/Battery/PowerFormat.swift` | Pure number→string formatting, the status-text decision table, the `NotChargingReason` decode and `PowerSmoothing`. |
| `Islet/Activities/Battery/SmartBatteryReader.swift` | The only file in the battery stack that talks to IOKit/IOPS/ProcessInfo. |
| `Islet/Activities/Battery/BatteryExpandedView.swift` | The tall-tier power screen. Moved out of `BatteryActivity.swift`. |
| `IsletTests/BatteryMetricsTests.swift` | Every pure function above, fed plain dictionaries. No hardware. |

**Modified**

| Path | Change |
|---|---|
| `Islet/Activities/Battery/BatteryMetrics.swift` | Becomes the model only — the full field set plus `PDProfile`. `SmartBatteryReader` moves out. |
| `Islet/Activities/Battery/BatteryMonitor.swift` | Smooths metrics before publishing; observes `.NSProcessInfoPowerStateDidChange`. |
| `Islet/Activities/Battery/BatteryActivity.swift` | `isActive` drops `&& onAC`; compact slots reflect on-battery state; `preferredExpandedHeight` = tall tier; the view moves out. |

**Not touched:** `BatteryState.swift`, `PeripheralBattery.swift`, `IsletTests/BatteryEventDetectorTests.swift`.

---

## Task 1: The `BatteryMetrics` model

**Files:**
- Modify: `Islet/Activities/Battery/BatteryMetrics.swift:1-70` (whole file)
- Create: `Islet/Activities/Battery/SmartBatteryReader.swift`
- Create: `IsletTests/BatteryMetricsTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `struct PDProfile: Identifiable, Equatable`, `struct BatteryMetrics: Equatable` with the full field set, `var hasAny: Bool`.

- [ ] **Step 1: Write the failing test**

Create `IsletTests/BatteryMetricsTests.swift`:

```swift
import XCTest

@testable import Islet

final class BatteryMetricsTests: XCTestCase {

  // MARK: - Model

  func testEmptyMetricsHasNothing() {
    XCTAssertFalse(BatteryMetrics().hasAny)
    XCTAssertTrue(BatteryMetrics().pdLadder.isEmpty)
    XCTAssertFalse(BatteryMetrics().lowPowerMode)
  }

  func testAnySingleReadingMakesItPresent() {
    var m = BatteryMetrics()
    m.cycleCount = 224
    XCTAssertTrue(m.hasAny)

    var n = BatteryMetrics()
    n.batteryPowerWatts = -5.715
    XCTAssertTrue(n.hasAny)

    // Low Power Mode alone is not a battery reading — it must not resurrect an empty panel.
    var o = BatteryMetrics()
    o.lowPowerMode = true
    XCTAssertFalse(o.hasAny)
  }

  func testPDProfileComputesWatts() {
    let rung = PDProfile(index: 4, volts: 20.0, amps: 1.49)
    XCTAssertEqual(rung.id, 4)
    XCTAssertEqual(rung.watts, 29.8, accuracy: 0.0001)
  }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`

Expected: compilation failure — `cannot find 'PDProfile' in scope`, and
`value of type 'BatteryMetrics' has no member 'pdLadder'`.

- [ ] **Step 3: Rewrite the model**

Replace the entire contents of `Islet/Activities/Battery/BatteryMetrics.swift` with:

```swift
import Foundation

/// One rung of the USB-C Power Delivery ladder the attached charger advertises
/// (`AdapterDetails.UsbHvcMenu`), in volts and amps.
struct PDProfile: Identifiable, Equatable {
  let index: Int
  let volts: Double
  let amps: Double

  var id: Int { index }
  var watts: Double { volts * amps }
}

/// Deep battery, charger and power-flow telemetry, read from AppleSmartBattery, IOPS and
/// ProcessInfo.
///
/// Every reading is optional on purpose. Most of these registry keys are undocumented and several
/// are absent on machines other than the one this was developed against, so the panel omits a tile
/// rather than rendering a zero for something it never read. `hasAny` is the "did we read anything
/// worth showing at all" test that decides whether the metrics block appears.
struct BatteryMetrics: Equatable {
  // Health. Two numbers, deliberately: `healthPercent` matches System Settings → Battery,
  // `rawHealthPercent` matches AlDente and coconutBattery. They disagree by 2-3 points and both
  // are shown, labelled, so neither reads as a bug.
  var healthPercent: Int?  // NominalChargeCapacity / DesignCapacity
  var rawHealthPercent: Int?  // AppleRawMaxCapacity / DesignCapacity
  var rawMaxCapacityMAh: Int?
  var nominalCapacityMAh: Int?
  var designCapacityMAh: Int?
  var cycleCount: Int?
  var designCycleCount: Int?  // DesignCycleCount9C
  var condition: String?  // IOPS BatteryHealthCondition, else the BatteryHealth grade

  // Instantaneous pack readings.
  var temperatureC: Double?
  var voltage: Double?  // V
  var amperage: Double?  // A, negative while discharging
  var powerWatts: Double?  // voltage * amperage, negative while discharging
  var timeToFullMinutes: Int?
  var timeToEmptyMinutes: Int?

  // The attached charger.
  var adapterWatts: Int?
  var adapterDescription: String?
  var adapterVolts: Double?
  var adapterAmps: Double?
  var adapterIsWireless: Bool?
  var adapterPowerTier: Int?
  var pdLadder: [PDProfile] = []
  var pdSelectedIndex: Int?

  // Power flow, from the undocumented PowerTelemetryData dictionary. All watts.
  var systemPowerInWatts: Double?  // SystemPowerIn — what the wall is delivering
  var systemVoltageIn: Double?
  var systemCurrentIn: Double?
  var systemLoadWatts: Double?  // SystemLoad — what the machine is drawing
  var batteryPowerWatts: Double?  // BatteryPower — + into the pack, - out of it
  var adapterLossWatts: Double?  // AdapterEfficiencyLoss

  // Charge state.
  var isCharging: Bool?
  var fullyCharged: Bool?
  var externalConnected: Bool?
  var notChargingReason: UInt64?

  var lowPowerMode = false

  /// True when at least one real reading landed. Low Power Mode is excluded — it is a system flag,
  /// not a battery reading, and on its own it should not make an empty panel appear.
  var hasAny: Bool {
    healthPercent != nil || rawHealthPercent != nil || cycleCount != nil
      || temperatureC != nil || voltage != nil || amperage != nil || powerWatts != nil
      || timeToFullMinutes != nil || timeToEmptyMinutes != nil
      || adapterWatts != nil || adapterDescription != nil
      || systemPowerInWatts != nil || batteryPowerWatts != nil
  }
}
```

- [ ] **Step 4: Move the old reader into its own file so the build still links**

Create `Islet/Activities/Battery/SmartBatteryReader.swift` with a temporary, compiling shim. It is
replaced wholesale in Task 10; it exists now only so `BatteryMonitor.swift:54` keeps compiling.

```swift
import Foundation
import IOKit
import IOKit.ps

/// The only place in the battery stack that talks to IOKit. Everything it reads is handed to
/// `BatteryMetricsParser`, which is pure and tested.
enum SmartBatteryReader {
  static func read() -> BatteryMetrics? {
    let service = IOServiceGetMatchingService(
      kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
    guard service != 0 else { return nil }
    defer { IOObjectRelease(service) }
    guard let props = properties(of: service) else { return nil }

    var m = BatteryMetrics()
    if let design = (props["DesignCapacity"] as? NSNumber)?.intValue, design > 0,
      let nominal = (props["NominalChargeCapacity"] as? NSNumber)?.intValue
    {
      m.healthPercent = Int((Double(nominal) / Double(design) * 100).rounded())
    }
    m.cycleCount = (props["CycleCount"] as? NSNumber)?.intValue
    return m.hasAny ? m : nil
  }

  private static func properties(of service: io_service_t) -> [String: Any]? {
    var unmanaged: Unmanaged<CFMutableDictionary>?
    guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0)
      == KERN_SUCCESS
    else { return nil }
    return unmanaged?.takeRetainedValue() as? [String: Any]
  }
}
```

- [ ] **Step 5: Regenerate the project**

Run: `xcodegen generate`

Expected: `Generated project at Islet.xcodeproj`, preceded by a warning naming
`Vendor/MediaRemoteAdapter.framework`. That warning is expected.

- [ ] **Step 6: Fix the one call site that referenced removed fields**

`Islet/Activities/Battery/BatteryActivity.swift:139` reads `m.powerWatts` and `:145` reads
`m.adapterWatts` — both still exist. `:136` reads `m.healthPercent` — still exists. No edit needed;
this step is a check. Run:

`grep -n "m\.\(healthPercent\|cycleCount\|temperatureC\|powerWatts\|timeToFullMinutes\|timeToEmptyMinutes\|adapterWatts\)" Islet/Activities/Battery/BatteryActivity.swift`

Expected: six matches, on lines 136-145. If any other member is referenced, it no longer exists and
must be removed from the view now.

- [ ] **Step 7: Run tests to verify they pass**

Run: `xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`

Expected: `** TEST SUCCEEDED **`. `BatteryMetricsTests` reports 3 cases; suite total is the
pre-Phase-2 baseline + 3.

- [ ] **Step 8: Commit**

```bash
git add Islet/Activities/Battery/BatteryMetrics.swift Islet/Activities/Battery/SmartBatteryReader.swift IsletTests/BatteryMetricsTests.swift Islet.xcodeproj
git commit -m "Power: widen BatteryMetrics to the full telemetry field set"
```

---

## Task 2: Health, capacity and cycle parsing

**Files:**
- Create: `Islet/Activities/Battery/BatteryMetricsParser.swift`
- Test: `IsletTests/BatteryMetricsTests.swift`

**Interfaces:**
- Consumes: `struct BatteryMetrics`, `struct PDProfile`.
- Produces:
  ```swift
  enum BatteryMetricsParser {
    static func applyHealth(_ m: inout BatteryMetrics, from p: [String: Any])
    static func percentage(_ value: Int, of total: Int) -> Int?
  }
  ```

- [ ] **Step 1: Write the failing test**

Append to `IsletTests/BatteryMetricsTests.swift`, inside the class, after `testPDProfileComputesWatts`:

```swift
  // MARK: - Fixtures
  //
  // Real values captured from `ioreg -r -c AppleSmartBattery` on an M-series MacBook Pro,
  // 2026-07-29. Numbers read back through NSNumber.intValue, which already applies the sign.
  //
  // Computed, not stored: a `static let` of a non-Sendable `[String: Any]` is a Swift 6 strict
  // concurrency error ("not concurrency-safe because non-'Sendable' type may have shared mutable
  // state"). A computed static has no storage and no such diagnostic.

  static var smartBattery: [String: Any] {
    [
      "Voltage": 11203,
      "Amperage": -322,
      "InstantAmperage": -322,
      "Temperature": 3068,
      "AppleRawMaxCapacity": 5381,
      "NominalChargeCapacity": 5533,
      "DesignCapacity": 6249,
      "CycleCount": 224,
      "DesignCycleCount9C": 1000,
      "AvgTimeToEmpty": 142,
      "AvgTimeToFull": 65535,
      "IsCharging": false,
      "FullyCharged": false,
      "ExternalConnected": true,
      "ChargerData": [
        "NotChargingReason": 36_028_797_018_963_968,
        "ChargingCurrent": 0,
        "ChargingVoltage": 3795,
      ] as [String: Any],
      "PowerTelemetryData": [
        "SystemPowerIn": 28407,
        "SystemVoltageIn": 19803,
        "SystemCurrentIn": 1434,
        "SystemLoad": 34122,
        "BatteryPower": -5715,
        "AdapterEfficiencyLoss": 696,
      ] as [String: Any],
    ]
  }

  static var adapter: [String: Any] {
    [
      "Watts": 30,
      "Description": "pd charger",
      "AdapterVoltage": 20000,
      "Current": 1490,
      "IsWireless": false,
      "AdapterPowerTier": 1,
      "UsbHvcHvcIndex": 4,
      "UsbHvcMenu": [
        ["Index": 0, "MaxVoltage": 5000, "MaxCurrent": 2960],
        ["Index": 1, "MaxVoltage": 9000, "MaxCurrent": 2980],
        ["Index": 2, "MaxVoltage": 12000, "MaxCurrent": 2480],
        ["Index": 3, "MaxVoltage": 15000, "MaxCurrent": 1990],
        ["Index": 4, "MaxVoltage": 20000, "MaxCurrent": 1490],
      ] as [[String: Any]],
    ]
  }

  static var powerSource: [String: Any] {
    ["BatteryHealth": "Good", "BatteryHealthCondition": ""]
  }

  // MARK: - Health

  func testHealthUsesNominalChargeCapacityOverDesign() {
    var m = BatteryMetrics()
    BatteryMetricsParser.applyHealth(&m, from: Self.smartBattery)
    // 5533 / 6249 = 88.54% -> 89, which is what System Settings shows.
    XCTAssertEqual(m.healthPercent, 89)
  }

  func testRawHealthUsesAppleRawMaxCapacityOverDesign() {
    var m = BatteryMetrics()
    BatteryMetricsParser.applyHealth(&m, from: Self.smartBattery)
    // 5381 / 6249 = 86.11% -> 86, which is what AlDente and coconutBattery show.
    XCTAssertEqual(m.rawHealthPercent, 86)
  }

  func testCapacitiesAndCyclesCarryThrough() {
    var m = BatteryMetrics()
    BatteryMetricsParser.applyHealth(&m, from: Self.smartBattery)
    XCTAssertEqual(m.rawMaxCapacityMAh, 5381)
    XCTAssertEqual(m.nominalCapacityMAh, 5533)
    XCTAssertEqual(m.designCapacityMAh, 6249)
    XCTAssertEqual(m.cycleCount, 224)
    XCTAssertEqual(m.designCycleCount, 1000)
  }

  func testHealthIsAbsentWithoutDesignCapacity() {
    var m = BatteryMetrics()
    BatteryMetricsParser.applyHealth(
      &m, from: ["NominalChargeCapacity": 5533, "AppleRawMaxCapacity": 5381])
    XCTAssertNil(m.healthPercent)
    XCTAssertNil(m.rawHealthPercent)
    XCTAssertNil(m.designCapacityMAh)
    XCTAssertEqual(m.nominalCapacityMAh, 5533)
  }

  func testHealthIsAbsentWhenDesignCapacityIsZero() {
    var m = BatteryMetrics()
    BatteryMetricsParser.applyHealth(
      &m, from: ["NominalChargeCapacity": 5533, "DesignCapacity": 0, "DesignCycleCount9C": 0])
    XCTAssertNil(m.healthPercent)
    XCTAssertNil(m.designCapacityMAh)
    XCTAssertNil(m.designCycleCount)
    XCTAssertNil(BatteryMetricsParser.percentage(5533, of: 0))
  }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`

Expected: compilation failure — `cannot find 'BatteryMetricsParser' in scope`.

- [ ] **Step 3: Create the parser**

Create `Islet/Activities/Battery/BatteryMetricsParser.swift`:

```swift
import Foundation

/// Turns the raw AppleSmartBattery / IOPS dictionaries into `BatteryMetrics`.
///
/// Deliberately actor-free and IOKit-free: it takes plain dictionaries so every rule in here is a
/// pure function the tests can drive without hardware. `SmartBatteryReader` is the only thing that
/// knows where the dictionaries come from.
enum BatteryMetricsParser {

  // MARK: - Health, capacity, cycles

  static func applyHealth(_ m: inout BatteryMetrics, from p: [String: Any]) {
    let design = int(p, "DesignCapacity").flatMap { $0 > 0 ? $0 : nil }
    m.designCapacityMAh = design
    m.nominalCapacityMAh = int(p, "NominalChargeCapacity")
    m.rawMaxCapacityMAh = int(p, "AppleRawMaxCapacity")

    if let design {
      if let nominal = m.nominalCapacityMAh { m.healthPercent = percentage(nominal, of: design) }
      if let raw = m.rawMaxCapacityMAh { m.rawHealthPercent = percentage(raw, of: design) }
    }

    m.cycleCount = int(p, "CycleCount")
    m.designCycleCount = int(p, "DesignCycleCount9C").flatMap { $0 > 0 ? $0 : nil }
  }

  /// Rounded percentage, or nil when the denominator is unusable.
  static func percentage(_ value: Int, of total: Int) -> Int? {
    guard total > 0 else { return nil }
    return Int((Double(value) / Double(total) * 100).rounded())
  }

  // MARK: - Typed dictionary access

  static func int(_ p: [String: Any], _ key: String) -> Int? {
    (p[key] as? NSNumber)?.intValue
  }

  static func uint64(_ p: [String: Any], _ key: String) -> UInt64? {
    (p[key] as? NSNumber)?.uint64Value
  }

  static func bool(_ p: [String: Any], _ key: String) -> Bool? {
    (p[key] as? NSNumber)?.boolValue
  }
}
```

- [ ] **Step 4: Regenerate the project**

Run: `xcodegen generate`

Expected: `Generated project at Islet.xcodeproj`.

- [ ] **Step 5: Run tests to verify they pass**

Run: `xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`

Expected: `** TEST SUCCEEDED **`. `BatteryMetricsTests` reports 8 cases; suite total is the
pre-Phase-2 baseline + 8.

- [ ] **Step 6: Commit**

```bash
git add Islet/Activities/Battery/BatteryMetricsParser.swift IsletTests/BatteryMetricsTests.swift Islet.xcodeproj
git commit -m "Power: parse both battery health numbers, capacity and cycle counts"
```

---

## Task 3: Instantaneous readings — temperature, voltage, amperage, watts

**Files:**
- Modify: `Islet/Activities/Battery/BatteryMetricsParser.swift`
- Test: `IsletTests/BatteryMetricsTests.swift`

**Interfaces:**
- Consumes: `IORegistryReader.signedInt(_ raw: Int?) -> Int?` (Phase 1.5).
- Produces: `static func applyInstant(_ m: inout BatteryMetrics, from p: [String: Any])`.

- [ ] **Step 1: Write the failing test**

Append inside the class in `IsletTests/BatteryMetricsTests.swift`:

```swift
  // MARK: - Instantaneous readings

  func testTemperatureIsCentiDegrees() throws {
    var m = BatteryMetrics()
    BatteryMetricsParser.applyInstant(&m, from: Self.smartBattery)
    XCTAssertEqual(try XCTUnwrap(m.temperatureC), 30.68, accuracy: 0.0001)
  }

  func testVoltageIsMillivolts() throws {
    var m = BatteryMetrics()
    BatteryMetricsParser.applyInstant(&m, from: Self.smartBattery)
    XCTAssertEqual(try XCTUnwrap(m.voltage), 11.203, accuracy: 0.0001)
  }

  func testAmperageIsSignedAndPrefersTheInstantReading() throws {
    var m = BatteryMetrics()
    BatteryMetricsParser.applyInstant(
      &m, from: ["Voltage": 11203, "Amperage": -900, "InstantAmperage": -322])
    XCTAssertEqual(try XCTUnwrap(m.amperage), -0.322, accuracy: 0.0001)
  }

  func testAmperageFallsBackToTheAveragedReading() throws {
    var m = BatteryMetrics()
    BatteryMetricsParser.applyInstant(&m, from: ["Voltage": 11203, "Amperage": -900])
    XCTAssertEqual(try XCTUnwrap(m.amperage), -0.900, accuracy: 0.0001)
  }

  func testAmperageDecodesTwosComplement() throws {
    // Some machines widen an unsigned 32-bit amperage into Int rather than sign-extending it.
    // 4294967284 == 2^32 - 12, i.e. -12 mA.
    var m = BatteryMetrics()
    BatteryMetricsParser.applyInstant(
      &m, from: ["Voltage": 11203, "InstantAmperage": 4_294_967_284])
    XCTAssertEqual(try XCTUnwrap(m.amperage), -0.012, accuracy: 0.0001)
    XCTAssertEqual(IORegistryReader.signedInt(4_294_967_284), -12)
    XCTAssertEqual(IORegistryReader.signedInt(-322), -322)
  }

  func testPowerWattsIsVoltageTimesAmperageAndKeepsTheSign() throws {
    var m = BatteryMetrics()
    BatteryMetricsParser.applyInstant(&m, from: Self.smartBattery)
    // 11.203 V * -0.322 A = -3.607366 W, negative because the pack is supplying the machine.
    XCTAssertEqual(try XCTUnwrap(m.powerWatts), -3.607366, accuracy: 0.0001)
  }

  func testTimeRemainingSentinelsAreDropped() {
    var m = BatteryMetrics()
    BatteryMetricsParser.applyInstant(&m, from: Self.smartBattery)
    XCTAssertNil(m.timeToFullMinutes)  // 65535 is the "still calculating" sentinel
    XCTAssertEqual(m.timeToEmptyMinutes, 142)

    var zeroed = BatteryMetrics()
    BatteryMetricsParser.applyInstant(&zeroed, from: ["AvgTimeToEmpty": 0, "AvgTimeToFull": 0])
    XCTAssertNil(zeroed.timeToEmptyMinutes)
    XCTAssertNil(zeroed.timeToFullMinutes)
  }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`

Expected: compilation failure — `type 'BatteryMetricsParser' has no member 'applyInstant'`.

- [ ] **Step 3: Implement `applyInstant`**

In `Islet/Activities/Battery/BatteryMetricsParser.swift`, insert immediately after the
`percentage(_:of:)` function and before the `// MARK: - Typed dictionary access` comment:

```swift
  // MARK: - Instantaneous pack readings

  static func applyInstant(_ m: inout BatteryMetrics, from p: [String: Any]) {
    // Reported in centi-degrees Celsius.
    if let raw = int(p, "Temperature") { m.temperatureC = Double(raw) / 100.0 }
    if let mV = int(p, "Voltage") { m.voltage = Double(mV) / 1000.0 }

    // InstantAmperage is the un-averaged figure AlDente shows; Amperage is the smoothed one.
    // Both use the same two's-complement encoding.
    let mA =
      IORegistryReader.signedInt(int(p, "InstantAmperage"))
      ?? IORegistryReader.signedInt(int(p, "Amperage"))
    if let mA { m.amperage = Double(mA) / 1000.0 }

    if let v = m.voltage, let a = m.amperage { m.powerWatts = v * a }

    // 65535 is the "still calculating" sentinel; 0 means "not applicable right now".
    if let ttf = int(p, "AvgTimeToFull"), ttf > 0, ttf < 65535 { m.timeToFullMinutes = ttf }
    if let tte = int(p, "AvgTimeToEmpty"), tte > 0, tte < 65535 { m.timeToEmptyMinutes = tte }
  }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`

Expected: `** TEST SUCCEEDED **`. `BatteryMetricsTests` reports 15 cases; suite total is the
pre-Phase-2 baseline + 15.

- [ ] **Step 5: Commit**

```bash
git add Islet/Activities/Battery/BatteryMetricsParser.swift IsletTests/BatteryMetricsTests.swift
git commit -m "Power: parse voltage, instant amperage and temperature with signed decoding"
```

---

## Task 4: Charger parsing and the PD ladder

**Files:**
- Modify: `Islet/Activities/Battery/BatteryMetricsParser.swift`
- Test: `IsletTests/BatteryMetricsTests.swift`

**Interfaces:**
- Consumes: `struct PDProfile`.
- Produces:
  ```swift
  static func applyCharger(_ m: inout BatteryMetrics, from adapter: [String: Any]?)
  static func pdLadder(from raw: Any?) -> [PDProfile]
  ```

- [ ] **Step 1: Write the failing test**

Append inside the class in `IsletTests/BatteryMetricsTests.swift`:

```swift
  // MARK: - Charger

  func testAdapterWattsAndDescription() {
    var m = BatteryMetrics()
    BatteryMetricsParser.applyCharger(&m, from: Self.adapter)
    XCTAssertEqual(m.adapterWatts, 30)
    XCTAssertEqual(m.adapterDescription, "pd charger")
    XCTAssertEqual(m.adapterIsWireless, false)
    XCTAssertEqual(m.adapterPowerTier, 1)
    XCTAssertEqual(m.pdSelectedIndex, 4)
  }

  func testAdapterVoltageAndCurrent() throws {
    var m = BatteryMetrics()
    BatteryMetricsParser.applyCharger(&m, from: Self.adapter)
    XCTAssertEqual(try XCTUnwrap(m.adapterVolts), 20.0, accuracy: 0.0001)
    XCTAssertEqual(try XCTUnwrap(m.adapterAmps), 1.49, accuracy: 0.0001)
  }

  func testPDLadderParsesEveryRungInIndexOrder() throws {
    var m = BatteryMetrics()
    BatteryMetricsParser.applyCharger(&m, from: Self.adapter)
    XCTAssertEqual(m.pdLadder.count, 5)
    XCTAssertEqual(m.pdLadder.map(\.index), [0, 1, 2, 3, 4])
    XCTAssertEqual(try XCTUnwrap(m.pdLadder.first).volts, 5.0, accuracy: 0.0001)
    XCTAssertEqual(try XCTUnwrap(m.pdLadder.first).amps, 2.96, accuracy: 0.0001)
    XCTAssertEqual(try XCTUnwrap(m.pdLadder.last).volts, 20.0, accuracy: 0.0001)
    XCTAssertEqual(try XCTUnwrap(m.pdLadder.last).watts, 29.8, accuracy: 0.0001)
  }

  func testPDLadderSkipsMalformedRungs() {
    let ladder = BatteryMetricsParser.pdLadder(
      from: [
        ["Index": 1, "MaxVoltage": 9000, "MaxCurrent": 2980],
        ["Index": 0, "MaxVoltage": 0, "MaxCurrent": 2960],  // zero volts
        ["Index": 2, "MaxCurrent": 2480],  // no voltage key
        ["nonsense": true],
      ] as [[String: Any]])
    XCTAssertEqual(ladder.count, 1)
    XCTAssertEqual(ladder.first?.index, 1)
  }

  func testNoAdapterLeavesEveryChargerFieldEmpty() {
    var m = BatteryMetrics()
    BatteryMetricsParser.applyCharger(&m, from: nil)
    XCTAssertNil(m.adapterWatts)
    XCTAssertNil(m.adapterDescription)
    XCTAssertNil(m.adapterVolts)
    XCTAssertNil(m.adapterAmps)
    XCTAssertTrue(m.pdLadder.isEmpty)
    XCTAssertFalse(m.hasAny)
  }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`

Expected: compilation failure — `type 'BatteryMetricsParser' has no member 'applyCharger'`.

- [ ] **Step 3: Implement `applyCharger` and `pdLadder`**

In `Islet/Activities/Battery/BatteryMetricsParser.swift`, insert immediately after `applyInstant`
and before the `// MARK: - Typed dictionary access` comment:

```swift
  // MARK: - Charger

  static func applyCharger(_ m: inout BatteryMetrics, from adapter: [String: Any]?) {
    guard let adapter, !adapter.isEmpty else { return }
    if let w = int(adapter, "Watts"), w > 0 { m.adapterWatts = w }
    if let d = adapter["Description"] as? String, !d.isEmpty { m.adapterDescription = d }
    if let mV = int(adapter, "AdapterVoltage"), mV > 0 { m.adapterVolts = Double(mV) / 1000.0 }
    if let mA = int(adapter, "Current"), mA > 0 { m.adapterAmps = Double(mA) / 1000.0 }
    m.adapterIsWireless = bool(adapter, "IsWireless")
    m.adapterPowerTier = int(adapter, "AdapterPowerTier")
    m.pdSelectedIndex = int(adapter, "UsbHvcHvcIndex")
    m.pdLadder = pdLadder(from: adapter["UsbHvcMenu"])
  }

  /// The negotiated USB-C PD ladder. Undocumented and absent on non-PD chargers, so a missing or
  /// unexpectedly shaped value yields an empty ladder rather than a failure.
  static func pdLadder(from raw: Any?) -> [PDProfile] {
    guard let entries = raw as? [[String: Any]] else { return [] }
    return
      entries
      .compactMap { entry -> PDProfile? in
        guard let mV = int(entry, "MaxVoltage"), mV > 0,
          let mA = int(entry, "MaxCurrent"), mA > 0
        else { return nil }
        return PDProfile(
          index: int(entry, "Index") ?? 0,
          volts: Double(mV) / 1000.0,
          amps: Double(mA) / 1000.0)
      }
      .sorted { $0.index < $1.index }
  }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`

Expected: `** TEST SUCCEEDED **`. `BatteryMetricsTests` reports 20 cases; suite total is the
pre-Phase-2 baseline + 20.

- [ ] **Step 5: Commit**

```bash
git add Islet/Activities/Battery/BatteryMetricsParser.swift IsletTests/BatteryMetricsTests.swift
git commit -m "Power: parse adapter description, voltage, current and the negotiated PD ladder"
```

---

## Task 5: `PowerTelemetryData` — the power-flow numbers

**Files:**
- Modify: `Islet/Activities/Battery/BatteryMetricsParser.swift`
- Test: `IsletTests/BatteryMetricsTests.swift`

**Interfaces:**
- Consumes: `IORegistryReader.signedInt(_ raw: Int?) -> Int?`.
- Produces: `static func applyTelemetry(_ m: inout BatteryMetrics, from p: [String: Any])`.

- [ ] **Step 1: Write the failing test**

Append inside the class in `IsletTests/BatteryMetricsTests.swift`:

```swift
  // MARK: - Power flow

  func testPowerTelemetryConvertsMilliwattsToWatts() throws {
    var m = BatteryMetrics()
    BatteryMetricsParser.applyTelemetry(&m, from: Self.smartBattery)
    XCTAssertEqual(try XCTUnwrap(m.systemPowerInWatts), 28.407, accuracy: 0.0001)
    XCTAssertEqual(try XCTUnwrap(m.systemVoltageIn), 19.803, accuracy: 0.0001)
    XCTAssertEqual(try XCTUnwrap(m.systemCurrentIn), 1.434, accuracy: 0.0001)
    XCTAssertEqual(try XCTUnwrap(m.systemLoadWatts), 34.122, accuracy: 0.0001)
    XCTAssertEqual(try XCTUnwrap(m.adapterLossWatts), 0.696, accuracy: 0.0001)
  }

  func testBatteryPowerIsNegativeWhileTheAdapterFallsShort() throws {
    var m = BatteryMetrics()
    BatteryMetricsParser.applyTelemetry(&m, from: Self.smartBattery)
    XCTAssertEqual(try XCTUnwrap(m.batteryPowerWatts), -5.715, accuracy: 0.0001)
  }

  func testSystemLoadEqualsAdapterInputMinusBatteryPower() throws {
    // The identity that pins down the sign convention: 28.407 - (-5.715) = 34.122.
    var m = BatteryMetrics()
    BatteryMetricsParser.applyTelemetry(&m, from: Self.smartBattery)
    let inW = try XCTUnwrap(m.systemPowerInWatts)
    let battW = try XCTUnwrap(m.batteryPowerWatts)
    XCTAssertEqual(try XCTUnwrap(m.systemLoadWatts), inW - battW, accuracy: 0.0005)
  }

  func testBatteryPowerDecodesTwosComplement() throws {
    var m = BatteryMetrics()
    BatteryMetricsParser.applyTelemetry(
      &m, from: ["PowerTelemetryData": ["BatteryPower": 4_294_961_581] as [String: Any]])
    XCTAssertEqual(try XCTUnwrap(m.batteryPowerWatts), -5.715, accuracy: 0.0001)
  }

  func testTelemetryIsAbsentWhenTheKeyIsMissing() {
    var m = BatteryMetrics()
    BatteryMetricsParser.applyTelemetry(&m, from: ["Voltage": 11203])
    XCTAssertNil(m.systemPowerInWatts)
    XCTAssertNil(m.systemLoadWatts)
    XCTAssertNil(m.batteryPowerWatts)
    XCTAssertNil(m.adapterLossWatts)
  }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`

Expected: compilation failure — `type 'BatteryMetricsParser' has no member 'applyTelemetry'`.

- [ ] **Step 3: Implement `applyTelemetry`**

In `Islet/Activities/Battery/BatteryMetricsParser.swift`, insert immediately after `pdLadder(from:)`
and before the `// MARK: - Typed dictionary access` comment:

```swift
  // MARK: - Power flow

  /// `PowerTelemetryData` is entirely undocumented and absent on some machines. Everything in it is
  /// milli-units; `BatteryPower` is signed, positive into the pack and negative out of it.
  static func applyTelemetry(_ m: inout BatteryMetrics, from p: [String: Any]) {
    guard let t = p["PowerTelemetryData"] as? [String: Any] else { return }
    if let mW = int(t, "SystemPowerIn") { m.systemPowerInWatts = Double(mW) / 1000.0 }
    if let mV = int(t, "SystemVoltageIn") { m.systemVoltageIn = Double(mV) / 1000.0 }
    if let mA = int(t, "SystemCurrentIn") { m.systemCurrentIn = Double(mA) / 1000.0 }
    if let mW = int(t, "SystemLoad") { m.systemLoadWatts = Double(mW) / 1000.0 }
    if let mW = IORegistryReader.signedInt(int(t, "BatteryPower")) {
      m.batteryPowerWatts = Double(mW) / 1000.0
    }
    if let mW = int(t, "AdapterEfficiencyLoss") { m.adapterLossWatts = Double(mW) / 1000.0 }
  }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`

Expected: `** TEST SUCCEEDED **`. `BatteryMetricsTests` reports 25 cases; suite total is the
pre-Phase-2 baseline + 25.

- [ ] **Step 5: Commit**

```bash
git add Islet/Activities/Battery/BatteryMetricsParser.swift IsletTests/BatteryMetricsTests.swift
git commit -m "Power: read the adapter-in, system-load and battery-power flow from PowerTelemetryData"
```

---

## Task 6: Charge state, `NotChargingReason` and the status line

**Files:**
- Modify: `Islet/Activities/Battery/BatteryMetricsParser.swift`
- Create: `Islet/Activities/Battery/PowerFormat.swift`
- Test: `IsletTests/BatteryMetricsTests.swift`

**Interfaces:**
- Consumes: `struct BatteryMetrics`.
- Produces:
  ```swift
  static func applyChargeState(_ m: inout BatteryMetrics, from p: [String: Any])

  enum NotChargingReason {
    static func setBits(_ raw: UInt64) -> [Int]
    static func code(_ raw: UInt64) -> String
  }

  enum PowerStatus {
    static func text(onAC: Bool, isCharging: Bool, fullyCharged: Bool,
                     batteryWatts: Double?, notChargingReason: UInt64?) -> String
  }
  ```

- [ ] **Step 1: Write the failing test**

Append inside the class in `IsletTests/BatteryMetricsTests.swift`:

```swift
  // MARK: - Charge state

  func testChargeStateFlags() {
    var m = BatteryMetrics()
    BatteryMetricsParser.applyChargeState(&m, from: Self.smartBattery)
    XCTAssertEqual(m.isCharging, false)
    XCTAssertEqual(m.fullyCharged, false)
    XCTAssertEqual(m.externalConnected, true)
  }

  func testNotChargingReasonIsReadFromChargerData() {
    var m = BatteryMetrics()
    BatteryMetricsParser.applyChargeState(&m, from: Self.smartBattery)
    XCTAssertEqual(m.notChargingReason, 36_028_797_018_963_968)
  }

  func testNotChargingReasonIsAbsentWithoutChargerData() {
    var m = BatteryMetrics()
    BatteryMetricsParser.applyChargeState(&m, from: ["IsCharging": true])
    XCTAssertNil(m.notChargingReason)
    XCTAssertEqual(m.isCharging, true)
  }

  func testNotChargingReasonSetBits() {
    XCTAssertEqual(NotChargingReason.setBits(36_028_797_018_963_968), [55])
    XCTAssertEqual(NotChargingReason.setBits(0), [])
    XCTAssertEqual(NotChargingReason.setBits(0b1011), [0, 1, 3])
  }

  func testNotChargingReasonCode() {
    XCTAssertEqual(NotChargingReason.code(36_028_797_018_963_968), "0x80000000000000")
    XCTAssertEqual(NotChargingReason.code(0), "0x0")
    XCTAssertEqual(NotChargingReason.code(255), "0xFF")
  }

  // MARK: - Status line

  func testStatusOnBattery() {
    XCTAssertEqual(
      PowerStatus.text(
        onAC: false, isCharging: false, fullyCharged: false, batteryWatts: -3.6,
        notChargingReason: nil),
      "On battery")
  }

  func testStatusCharging() {
    XCTAssertEqual(
      PowerStatus.text(
        onAC: true, isCharging: true, fullyCharged: false, batteryWatts: 30.0,
        notChargingReason: 0),
      "Charging")
  }

  func testStatusCharged() {
    XCTAssertEqual(
      PowerStatus.text(
        onAC: true, isCharging: false, fullyCharged: true, batteryWatts: 0,
        notChargingReason: 0),
      "Charged")
  }

  func testStatusAdapterCannotKeepUp() {
    // The real state on the development machine: AC attached, not charging, and the pack is
    // supplying 5.7 W because the 30 W adapter is smaller than the 34 W load.
    XCTAssertEqual(
      PowerStatus.text(
        onAC: true, isCharging: false, fullyCharged: false, batteryWatts: -5.715,
        notChargingReason: 36_028_797_018_963_968),
      "Adapter can't keep up")
  }

  func testStatusNotChargingSurfacesTheRawCode() {
    // Held, but not because the adapter is undersized: report the code rather than invent a reason.
    XCTAssertEqual(
      PowerStatus.text(
        onAC: true, isCharging: false, fullyCharged: false, batteryWatts: -0.05,
        notChargingReason: 36_028_797_018_963_968),
      "Not charging · 0x80000000000000")
  }

  func testStatusNotChargingWithoutAReason() {
    XCTAssertEqual(
      PowerStatus.text(
        onAC: true, isCharging: false, fullyCharged: false, batteryWatts: 0,
        notChargingReason: 0),
      "Not charging")
    XCTAssertEqual(
      PowerStatus.text(
        onAC: true, isCharging: false, fullyCharged: false, batteryWatts: nil,
        notChargingReason: nil),
      "Not charging")
  }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`

Expected: compilation failure — `cannot find 'NotChargingReason' in scope` and
`cannot find 'PowerStatus' in scope`.

- [ ] **Step 3: Implement `applyChargeState`**

In `Islet/Activities/Battery/BatteryMetricsParser.swift`, insert immediately after `applyTelemetry`
and before the `// MARK: - Typed dictionary access` comment:

```swift
  // MARK: - Charge state

  static func applyChargeState(_ m: inout BatteryMetrics, from p: [String: Any]) {
    m.isCharging = bool(p, "IsCharging")
    m.fullyCharged = bool(p, "FullyCharged")
    m.externalConnected = bool(p, "ExternalConnected")
    if let charger = p["ChargerData"] as? [String: Any] {
      m.notChargingReason = uint64(charger, "NotChargingReason")
    }
  }
```

- [ ] **Step 4: Implement `NotChargingReason` and `PowerStatus`**

Create `Islet/Activities/Battery/PowerFormat.swift`:

```swift
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
    if isCharging { return "Charging" }
    if fullyCharged { return "Charged" }
    // AC attached, not charging, and the pack is still discharging: the adapter is smaller than the
    // current system load. Derived from PowerTelemetryData.BatteryPower, not from a guessed bit.
    if let batteryWatts, batteryWatts < -0.5 { return "Adapter can't keep up" }
    if let notChargingReason, notChargingReason != 0 {
      return "Not charging · \(NotChargingReason.code(notChargingReason))"
    }
    return "Not charging"
  }
}
```

- [ ] **Step 5: Regenerate the project**

Run: `xcodegen generate`

Expected: `Generated project at Islet.xcodeproj`.

- [ ] **Step 6: Run tests to verify they pass**

Run: `xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`

Expected: `** TEST SUCCEEDED **`. `BatteryMetricsTests` reports 36 cases; suite total is the
pre-Phase-2 baseline + 36.

- [ ] **Step 7: Commit**

```bash
git add Islet/Activities/Battery/BatteryMetricsParser.swift Islet/Activities/Battery/PowerFormat.swift IsletTests/BatteryMetricsTests.swift Islet.xcodeproj
git commit -m "Power: replace the misleading Plugged in status with a derived charge-hold reason"
```

---

## Task 7: Battery condition and the whole-snapshot `parse`

**Files:**
- Modify: `Islet/Activities/Battery/BatteryMetricsParser.swift`
- Test: `IsletTests/BatteryMetricsTests.swift`

**Interfaces:**
- Consumes: everything from Tasks 2-6.
- Produces:
  ```swift
  static func condition(health: String?, condition: String?) -> String?
  static func parse(smartBattery: [String: Any], adapter: [String: Any]?,
                    powerSource: [String: Any]?, lowPowerMode: Bool) -> BatteryMetrics
  ```

- [ ] **Step 1: Write the failing test**

Append inside the class in `IsletTests/BatteryMetricsTests.swift`:

```swift
  // MARK: - Condition

  func testConditionIsNormalWhenTheGradeIsGoodAndTheConditionIsBlank() {
    // IOPS reports BatteryHealthCondition as an empty string on a healthy pack; System Settings
    // renders that as "Normal".
    XCTAssertEqual(BatteryMetricsParser.condition(health: "Good", condition: ""), "Normal")
    XCTAssertEqual(BatteryMetricsParser.condition(health: "Good", condition: nil), "Normal")
  }

  func testConditionSurfacesARealFaultVerbatim() {
    XCTAssertEqual(
      BatteryMetricsParser.condition(health: "Poor", condition: "Service Recommended"),
      "Service Recommended")
    XCTAssertEqual(BatteryMetricsParser.condition(health: "Fair", condition: ""), "Fair")
  }

  func testConditionIsNilWhenNothingWasReported() {
    XCTAssertNil(BatteryMetricsParser.condition(health: nil, condition: nil))
    XCTAssertNil(BatteryMetricsParser.condition(health: "", condition: ""))
  }

  // MARK: - Whole snapshot

  func testParseOfTheRealSnapshot() throws {
    let m = BatteryMetricsParser.parse(
      smartBattery: Self.smartBattery,
      adapter: Self.adapter,
      powerSource: Self.powerSource,
      lowPowerMode: true)

    XCTAssertTrue(m.hasAny)
    XCTAssertEqual(m.healthPercent, 89)
    XCTAssertEqual(m.rawHealthPercent, 86)
    XCTAssertEqual(m.cycleCount, 224)
    XCTAssertEqual(m.designCycleCount, 1000)
    XCTAssertEqual(m.condition, "Normal")
    XCTAssertEqual(try XCTUnwrap(m.temperatureC), 30.68, accuracy: 0.0001)
    XCTAssertEqual(try XCTUnwrap(m.amperage), -0.322, accuracy: 0.0001)
    XCTAssertEqual(m.adapterWatts, 30)
    XCTAssertEqual(m.adapterDescription, "pd charger")
    XCTAssertEqual(m.pdLadder.count, 5)
    XCTAssertEqual(try XCTUnwrap(m.systemLoadWatts), 34.122, accuracy: 0.0001)
    XCTAssertEqual(m.notChargingReason, 36_028_797_018_963_968)
    XCTAssertTrue(m.lowPowerMode)
    XCTAssertEqual(m.externalConnected, true)
    XCTAssertNil(m.timeToFullMinutes)
    XCTAssertEqual(m.timeToEmptyMinutes, 142)
  }

  func testParseOfAnEmptyRegistryReadsNothing() {
    let m = BatteryMetricsParser.parse(
      smartBattery: [:], adapter: nil, powerSource: nil, lowPowerMode: false)
    XCTAssertFalse(m.hasAny)
    XCTAssertNil(m.condition)
    XCTAssertTrue(m.pdLadder.isEmpty)
  }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`

Expected: compilation failure — `type 'BatteryMetricsParser' has no member 'condition'`.

- [ ] **Step 3: Implement `condition` and `parse`**

In `Islet/Activities/Battery/BatteryMetricsParser.swift`, insert immediately after
`applyChargeState` and before the `// MARK: - Typed dictionary access` comment:

```swift
  // MARK: - Condition

  /// IOPS reports `BatteryHealthCondition` as an empty string on a healthy pack and a real string
  /// ("Service Recommended", "Permanent Battery Failure") when something is wrong. When it is blank
  /// we fall back to the `BatteryHealth` grade, translating the healthy grade into the word System
  /// Settings uses. Any non-"Good" grade is surfaced verbatim so a fault is never hidden.
  static func condition(health: String?, condition: String?) -> String? {
    if let condition, !condition.isEmpty { return condition }
    guard let health, !health.isEmpty else { return nil }
    return health == "Good" ? "Normal" : health
  }

  // MARK: - Whole snapshot

  static func parse(
    smartBattery: [String: Any],
    adapter: [String: Any]?,
    powerSource: [String: Any]?,
    lowPowerMode: Bool
  ) -> BatteryMetrics {
    var m = BatteryMetrics()
    applyHealth(&m, from: smartBattery)
    applyInstant(&m, from: smartBattery)
    applyCharger(&m, from: adapter)
    applyTelemetry(&m, from: smartBattery)
    applyChargeState(&m, from: smartBattery)
    if let powerSource {
      m.condition = condition(
        health: powerSource["BatteryHealth"] as? String,
        condition: powerSource["BatteryHealthCondition"] as? String)
    }
    m.lowPowerMode = lowPowerMode
    return m
  }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`

Expected: `** TEST SUCCEEDED **`. `BatteryMetricsTests` reports 41 cases; suite total is the
pre-Phase-2 baseline + 41.

- [ ] **Step 5: Commit**

```bash
git add Islet/Activities/Battery/BatteryMetricsParser.swift IsletTests/BatteryMetricsTests.swift
git commit -m "Power: parse a whole battery snapshot in one pure pass, including condition"
```

---

## Task 8: Display formatters

**Files:**
- Modify: `Islet/Activities/Battery/PowerFormat.swift`
- Test: `IsletTests/BatteryMetricsTests.swift`

**Interfaces:**
- Consumes: `struct PDProfile`.
- Produces:
  ```swift
  enum PowerFormat {
    static func time(minutes: Int) -> String
    static func capacity(_ current: Int?, of design: Int?) -> String?
    static func cycles(_ count: Int, of design: Int?) -> String
    static func watts(_ w: Double) -> String
    static func wattsUnsigned(_ w: Double) -> String
    static func amps(_ a: Double) -> String
    static func volts(_ v: Double) -> String
    static func temperature(_ c: Double) -> String
    static func chargerSummary(watts: Int?, description: String?) -> String?
    static func ladderSummary(_ ladder: [PDProfile]) -> String?
    static func remaining(timeToFull: Int?, timeToEmpty: Int?) -> (label: String, value: String)?
  }
  ```

- [ ] **Step 1: Write the failing test**

Append inside the class in `IsletTests/BatteryMetricsTests.swift`:

```swift
  // MARK: - Formatting

  func testTimeFormat() {
    XCTAssertEqual(PowerFormat.time(minutes: 0), "0m")
    XCTAssertEqual(PowerFormat.time(minutes: 45), "45m")
    XCTAssertEqual(PowerFormat.time(minutes: 59), "59m")
    XCTAssertEqual(PowerFormat.time(minutes: 60), "1h 00m")
    XCTAssertEqual(PowerFormat.time(minutes: 86), "1h 26m")
    XCTAssertEqual(PowerFormat.time(minutes: 142), "2h 22m")
    XCTAssertEqual(PowerFormat.time(minutes: 252), "4h 12m")
  }

  func testCapacityFormat() {
    XCTAssertEqual(PowerFormat.capacity(5381, of: 6249), "5381 / 6249 mAh")
    XCTAssertEqual(PowerFormat.capacity(5381, of: nil), "5381 mAh")
    XCTAssertEqual(PowerFormat.capacity(5381, of: 0), "5381 mAh")
    XCTAssertNil(PowerFormat.capacity(nil, of: 6249))
  }

  func testCyclesFormat() {
    XCTAssertEqual(PowerFormat.cycles(224, of: 1000), "224 / 1000")
    XCTAssertEqual(PowerFormat.cycles(224, of: nil), "224")
    XCTAssertEqual(PowerFormat.cycles(224, of: 0), "224")
  }

  func testWattsCarryTheirSign() {
    XCTAssertEqual(PowerFormat.watts(-3.607366), "-3.6 W")
    XCTAssertEqual(PowerFormat.watts(67.9), "+67.9 W")
    XCTAssertEqual(PowerFormat.watts(0), "+0.0 W")
    XCTAssertEqual(PowerFormat.wattsUnsigned(34.122), "34.1 W")
    XCTAssertEqual(PowerFormat.wattsUnsigned(0.696), "0.7 W")
  }

  func testAmpsVoltsAndTemperature() {
    XCTAssertEqual(PowerFormat.amps(-0.322), "-0.32 A")
    XCTAssertEqual(PowerFormat.amps(1.49), "+1.49 A")
    XCTAssertEqual(PowerFormat.volts(11.203), "11.20 V")
    XCTAssertEqual(PowerFormat.temperature(30.68), "30.7°C")
  }

  func testChargerSummary() {
    XCTAssertEqual(PowerFormat.chargerSummary(watts: 30, description: "pd charger"), "30 W · pd charger")
    XCTAssertEqual(PowerFormat.chargerSummary(watts: 30, description: nil), "30 W")
    XCTAssertEqual(PowerFormat.chargerSummary(watts: nil, description: "pd charger"), "pd charger")
    XCTAssertNil(PowerFormat.chargerSummary(watts: nil, description: nil))
  }

  func testLadderSummary() {
    let ladder = BatteryMetricsParser.pdLadder(from: Self.adapter["UsbHvcMenu"])
    XCTAssertEqual(
      PowerFormat.ladderSummary(ladder),
      "5V/2.96A · 9V/2.98A · 12V/2.48A · 15V/1.99A · 20V/1.49A")
    XCTAssertNil(PowerFormat.ladderSummary([]))
  }

  func testRemainingPrefersTimeToFullWhenCharging() {
    let full = PowerFormat.remaining(timeToFull: 86, timeToEmpty: 142)
    XCTAssertEqual(full?.label, "Full in")
    XCTAssertEqual(full?.value, "1h 26m")

    let empty = PowerFormat.remaining(timeToFull: nil, timeToEmpty: 142)
    XCTAssertEqual(empty?.label, "Left")
    XCTAssertEqual(empty?.value, "2h 22m")

    XCTAssertNil(PowerFormat.remaining(timeToFull: nil, timeToEmpty: nil))
  }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`

Expected: compilation failure — `cannot find 'PowerFormat' in scope`.

- [ ] **Step 3: Implement the formatters**

Append to `Islet/Activities/Battery/PowerFormat.swift`:

```swift
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
  static func amps(_ a: Double) -> String { String(format: "%+.2f A", a) }
  static func volts(_ v: Double) -> String { String(format: "%.2f V", v) }
  static func temperature(_ c: Double) -> String { String(format: "%.1f°C", c) }

  static func chargerSummary(watts: Int?, description: String?) -> String? {
    // Written with explicit returns: a switch *expression* whose branches mix String and nil does
    // not type-check against a String? contextual type.
    switch (watts, description) {
    case let (w?, d?): return "\(w) W · \(d)"
    case let (w?, nil): return "\(w) W"
    case let (nil, d?): return d
    case (nil, nil): return nil
    }
  }

  /// The whole negotiated PD ladder on one line, for the charger tile's tooltip.
  static func ladderSummary(_ ladder: [PDProfile]) -> String? {
    guard !ladder.isEmpty else { return nil }
    return ladder
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`

Expected: `** TEST SUCCEEDED **`. `BatteryMetricsTests` reports 49 cases; suite total is the
pre-Phase-2 baseline + 49.

- [ ] **Step 5: Commit**

```bash
git add Islet/Activities/Battery/PowerFormat.swift IsletTests/BatteryMetricsTests.swift
git commit -m "Power: add tested formatters for time, capacity, watts, amps and the PD ladder"
```

---

## Task 9: Smoothing the volatile readings

**Files:**
- Modify: `Islet/Activities/Battery/PowerFormat.swift`
- Test: `IsletTests/BatteryMetricsTests.swift`

**Interfaces:**
- Consumes: `struct BatteryMetrics`.
- Produces:
  ```swift
  enum PowerSmoothing {
    static let factor: Double
    static func blend(previous: Double?, sample: Double?, factor: Double) -> Double?
    static func smooth(_ old: BatteryMetrics?, into new: BatteryMetrics) -> BatteryMetrics
  }
  ```

- [ ] **Step 1: Write the failing test**

Append inside the class in `IsletTests/BatteryMetricsTests.swift`:

```swift
  // MARK: - Smoothing

  func testBlendWithoutAPreviousValueReturnsTheSample() throws {
    XCTAssertEqual(
      try XCTUnwrap(PowerSmoothing.blend(previous: nil, sample: 10)), 10, accuracy: 1e-9)
  }

  func testBlendMovesPartWayTowardTheSample() throws {
    XCTAssertEqual(
      try XCTUnwrap(PowerSmoothing.blend(previous: 10, sample: 20, factor: 0.5)), 15,
      accuracy: 1e-9)
    XCTAssertEqual(
      try XCTUnwrap(PowerSmoothing.blend(previous: 30.0, sample: 31.0, factor: 0.35)), 30.35,
      accuracy: 1e-9)
  }

  func testBlendDropsWhenTheSampleDisappears() {
    // Unplugging removes a key entirely; the panel must lose the tile, not keep a ghost value.
    XCTAssertNil(PowerSmoothing.blend(previous: 30, sample: nil))
  }

  func testBlendConvergesToExactEquality() throws {
    // An asymptote would defeat the Equatable diff in BatteryMonitor.refresh and republish forever,
    // so blend snaps to the sample once it is inside display precision.
    var value: Double? = 0
    for _ in 0..<40 { value = PowerSmoothing.blend(previous: value, sample: 100) }
    XCTAssertEqual(try XCTUnwrap(value), 100)
  }

  func testSmoothLeavesStableFieldsUntouched() throws {
    var old = BatteryMetrics()
    old.temperatureC = 30.0
    old.cycleCount = 224
    old.healthPercent = 89

    var new = BatteryMetrics()
    new.temperatureC = 31.0
    new.cycleCount = 225
    new.healthPercent = 88

    let out = PowerSmoothing.smooth(old, into: new)
    XCTAssertEqual(try XCTUnwrap(out.temperatureC), 30.35, accuracy: 1e-9)
    XCTAssertEqual(out.cycleCount, 225)
    XCTAssertEqual(out.healthPercent, 88)
  }

  func testSmoothWithNoPreviousSnapshotIsIdentity() {
    var new = BatteryMetrics()
    new.temperatureC = 31.0
    new.batteryPowerWatts = -5.715
    XCTAssertEqual(PowerSmoothing.smooth(nil, into: new), new)
  }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`

Expected: compilation failure — `cannot find 'PowerSmoothing' in scope`.

- [ ] **Step 3: Implement `PowerSmoothing`**

Append to `Islet/Activities/Battery/PowerFormat.swift`:

```swift
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
    out.batteryPowerWatts = blend(previous: old.batteryPowerWatts, sample: new.batteryPowerWatts)
    out.adapterLossWatts = blend(previous: old.adapterLossWatts, sample: new.adapterLossWatts)
    return out
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`

Expected: `** TEST SUCCEEDED **`. `BatteryMetricsTests` reports 55 cases; suite total is the
pre-Phase-2 baseline + 55.

- [ ] **Step 5: Commit**

```bash
git add Islet/Activities/Battery/PowerFormat.swift IsletTests/BatteryMetricsTests.swift
git commit -m "Power: smooth amperage, watts and temperature so the 1 Hz panel stops strobing"
```

---

## Task 10: Wire the real hardware in

**Files:**
- Modify: `Islet/Activities/Battery/SmartBatteryReader.swift` (whole file)
- Modify: `Islet/Activities/Battery/BatteryMonitor.swift:52-56` (the `refresh()` body) and `:17-35` (`start()`)

**Interfaces:**
- Consumes: `IORegistryReader.properties(matching:)`, `BatteryMetricsParser.parse(...)`,
  `PowerSmoothing.smooth(_:into:)`.
- Produces: `SmartBatteryReader.read() -> BatteryMetrics?` (unchanged signature).

**No unit test — verified by build plus the manual check in Step 5.** This task is pure IO; the
logic it feeds is already covered by 55 tests.

- [ ] **Step 1: Rewrite `SmartBatteryReader`**

Replace the entire contents of `Islet/Activities/Battery/SmartBatteryReader.swift` with:

```swift
import Foundation
import IOKit.ps

/// The only place in the battery stack that touches IOKit, IOPS or ProcessInfo. It gathers the
/// three dictionaries and hands them straight to `BatteryMetricsParser`, which is pure and tested.
///
/// One bulk `IORegistryEntryCreateCFProperties` replaces the per-key reads this used to do. That
/// call also drags in some large blobs (`RaTableRaw`, `PortControllerInfo`), but it is a single
/// round trip at 1 Hz and the alternative was a dozen.
enum SmartBatteryReader {
  static func read() -> BatteryMetrics? {
    guard let props = IORegistryReader.properties(matching: "AppleSmartBattery") else { return nil }

    // Prefer the public, documented adapter API; fall back to the raw registry key, which is what
    // it is derived from anyway and which survives when IOPS has not caught up yet.
    let adapter = externalAdapterDetails() ?? (props["AdapterDetails"] as? [String: Any])

    let metrics = BatteryMetricsParser.parse(
      smartBattery: props,
      adapter: adapter,
      powerSource: primaryPowerSource(),
      lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled)

    return metrics.hasAny ? metrics : nil
  }

  /// `IOPSCopyExternalPowerAdapterDetails` returns nil on battery power.
  private static func externalAdapterDetails() -> [String: Any]? {
    guard
      let details = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any],
      !details.isEmpty
    else { return nil }
    return details
  }

  /// The IOPS description of the internal battery, for `BatteryHealth` / `BatteryHealthCondition`.
  private static func primaryPowerSource() -> [String: Any]? {
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
      let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef],
      let source = list.first
    else { return nil }
    return IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any]
  }
}
```

- [ ] **Step 2: Smooth and diff in `BatteryMonitor.refresh()`**

In `Islet/Activities/Battery/BatteryMonitor.swift`, replace the whole body of `func refresh()`
(currently `Islet/Activities/Battery/BatteryMonitor.swift:52-56`, and reshaped by Phase 1.5 into a
diffing form) with exactly this body:

```swift
  func refresh() {
    let freshState = Self.readState()
    if freshState != state { state = freshState }

    let fresh = SmartBatteryReader.read()
    let smoothed = fresh.map { PowerSmoothing.smooth(metrics, into: $0) }
    if smoothed != metrics { metrics = smoothed }

    let freshPeripherals = PeripheralBatteryReader.read()
    if freshPeripherals != peripherals { peripherals = freshPeripherals }
  }
```

Leave every `liveGate` line exactly as Phase 1.4 left it. Do not reintroduce `setLiveMetrics(_:)`.

- [ ] **Step 3: Observe Low Power Mode**

In `Islet/Activities/Battery/BatteryMonitor.swift`, add a `cancellables` set next to the existing
`private var metricsTimer: AnyCancellable?` declaration (currently line 14) — **unless Phase 1.4
already added one, in which case reuse it and skip this declaration**:

```swift
  private var cancellables: Set<AnyCancellable> = []
```

Then, inside `func start()`, immediately before the closing brace of the function (after the
existing `restartMetricsTimer()` call at line 34), add:

```swift
    // Low Power Mode is a ProcessInfo flag, not an IOKit property, so nothing else wakes us when
    // it flips. Never shell out to pmset for this.
    NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in self?.refresh() }
      .store(in: &cancellables)
```

The `sink` closure inherits `@MainActor` isolation from the enclosing `@MainActor` type — the same
pattern as `BatteryActivity.start()` at `Islet/Activities/Battery/BatteryActivity.swift:22-26`.

- [ ] **Step 4: Build**

Run: `xcodebuild build -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Run tests, then check against real hardware**

Run: `xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`

Expected: `** TEST SUCCEEDED **`, same 55 Phase-2 cases as Task 9 (this task adds none).

Manual check — the numbers must match the hardware:

```bash
ioreg -r -c AppleSmartBattery -w0 | grep -o '"NominalChargeCapacity" = [0-9]*'
ioreg -r -c AppleSmartBattery -w0 | grep -o '"DesignCapacity" = [0-9]*' | head -1
ioreg -r -c AppleSmartBattery -w0 | grep -o '"CycleCount" = [0-9]*' | head -1
open ~/Library/Developer/Xcode/DerivedData/Islet-*/Build/Products/Debug/Islet.app
```

Then hover the notch, click the battery chip and confirm the Health tile equals
`round(NominalChargeCapacity / DesignCapacity * 100)` and the Cycles tile shows the `CycleCount`
value. (The grid is still the old two-column one at this point; it is rewritten in Task 12.)
Quit the app afterwards from the menu bar.

- [ ] **Step 6: Commit**

```bash
git add Islet/Activities/Battery/SmartBatteryReader.swift Islet/Activities/Battery/BatteryMonitor.swift
git commit -m "Power: read the full battery snapshot in one registry pass and smooth it before publishing"
```

---

## Task 11: The battery tab survives unplugging

**Files:**
- Modify: `Islet/Activities/Battery/BatteryActivity.swift:16-18` (`isActive`), `:29-40` (`handle`), `:69-79` (compact slots)
- Test: `IsletTests/BatteryMetricsTests.swift`

**Interfaces:**
- Consumes: `struct BatteryState`, `Defaults[.batteryEnabled]`.
- Produces:
  ```swift
  enum BatteryTint: Equatable { case charging, low, normal; var color: Color { get } }
  extension BatteryActivity {
    static func tint(for state: BatteryState?) -> BatteryTint
    static func batterySymbol(for percent: Int) -> String
  }
  ```

- [ ] **Step 1: Write the failing test**

Append inside the class in `IsletTests/BatteryMetricsTests.swift`:

```swift
  // MARK: - Compact island

  func testBatterySymbolBuckets() {
    // SF Symbols only ships 0/25/50/75/100 fills, so the buckets are centred on those.
    XCTAssertEqual(BatteryActivity.batterySymbol(for: 0), "battery.0percent")
    XCTAssertEqual(BatteryActivity.batterySymbol(for: 12), "battery.0percent")
    XCTAssertEqual(BatteryActivity.batterySymbol(for: 13), "battery.25percent")
    XCTAssertEqual(BatteryActivity.batterySymbol(for: 37), "battery.25percent")
    XCTAssertEqual(BatteryActivity.batterySymbol(for: 38), "battery.50percent")
    XCTAssertEqual(BatteryActivity.batterySymbol(for: 62), "battery.50percent")
    XCTAssertEqual(BatteryActivity.batterySymbol(for: 63), "battery.75percent")
    XCTAssertEqual(BatteryActivity.batterySymbol(for: 87), "battery.75percent")
    XCTAssertEqual(BatteryActivity.batterySymbol(for: 88), "battery.100percent")
    XCTAssertEqual(BatteryActivity.batterySymbol(for: 100), "battery.100percent")
  }

  func testTintIsGreenWheneverPowerIsComingIn() {
    XCTAssertEqual(
      BatteryActivity.tint(for: BatteryState(percent: 8, isCharging: true, onAC: true)), .charging)
    XCTAssertEqual(
      BatteryActivity.tint(for: BatteryState(percent: 100, isCharging: false, onAC: true)),
      .charging)
  }

  func testTintIsRedOnBatteryUnderTwentyPercent() {
    XCTAssertEqual(
      BatteryActivity.tint(for: BatteryState(percent: 20, isCharging: false, onAC: false)), .low)
    XCTAssertEqual(
      BatteryActivity.tint(for: BatteryState(percent: 21, isCharging: false, onAC: false)),
      .normal)
  }

  func testTintIsNeutralWithoutAReading() {
    XCTAssertEqual(BatteryActivity.tint(for: nil), .normal)
  }

  @MainActor func testBatteryTabStaysActiveOffAC() {
    let saved = Defaults[.batteryEnabled]
    defer { Defaults[.batteryEnabled] = saved }

    // The monitor has never produced a state, so `onAC` is false. The tab must still be active.
    let activity = BatteryActivity()
    Defaults[.batteryEnabled] = true
    XCTAssertTrue(activity.isActive)
    Defaults[.batteryEnabled] = false
    XCTAssertFalse(activity.isActive)
  }
```

Add `import Defaults` and `import SwiftUI` to the top of
`IsletTests/BatteryMetricsTests.swift`, so the file header reads:

```swift
import Defaults
import SwiftUI
import XCTest

@testable import Islet
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`

Expected: compilation failure — `type 'BatteryActivity' has no member 'batterySymbol'` and
`cannot find 'BatteryTint' in scope`.

- [ ] **Step 3: Drop the `onAC` gate and give the compact island a real off-AC look**

In `Islet/Activities/Battery/BatteryActivity.swift`, replace lines 14-18:

```swift
  // Show the persistent indicator whenever on AC power (charging OR plugged-in-and-full),
  // so the power status is visible the whole time you're plugged in — not only while charging.
  var isActive: Bool {
    Defaults[.batteryEnabled] && (monitor.state?.onAC ?? false)
  }
```

with:

```swift
  // The tab is available whenever the feature is on. Gating it on AC power made the whole power
  // screen vanish the moment you unplugged — which is exactly when you want to read it.
  var isActive: Bool { Defaults[.batteryEnabled] }
```

Then replace lines 29-40 (`private func handle`):

```swift
  private func handle(_ new: BatteryState) {
    let events = BatteryEventDetector.events(from: lastState, to: new)
    let wasActive = lastState?.onAC ?? false
    lastState = new
    if !wasActive, new.onAC { activationDate = Date() }
    objectWillChange.send()

    guard Defaults[.batteryEnabled] else { return }
    for event in events {
      SneakQueue.shared.submit(Self.sneak(for: event))
    }
  }
```

with:

```swift
  private func handle(_ new: BatteryState) {
    let events = BatteryEventDetector.events(from: lastState, to: new)
    lastState = new
    // Now that the tab is always active, its activation date is simply when it first had a reading.
    if activationDate == nil { activationDate = Date() }
    objectWillChange.send()

    guard Defaults[.batteryEnabled] else { return }
    for event in events {
      SneakQueue.shared.submit(Self.sneak(for: event))
    }
  }
```

Then replace lines 69-79 (`tabIcon` through `compactTrailing`):

```swift
  let tabIcon = "battery.100percent.bolt"
  var compactLeading: AnyView {
    let charging = monitor.state?.isCharging ?? false
    return AnyView(
      Image(systemName: charging ? "bolt.fill" : "powerplug.fill")
        .foregroundStyle(.green).font(.caption2))
  }

  var compactTrailing: AnyView {
    AnyView(BatteryPercentText(percent: monitor.state?.percent ?? 0, color: .green))
  }
```

with:

```swift
  let tabIcon = "battery.100percent.bolt"

  var compactLeading: AnyView {
    AnyView(
      Image(systemName: Self.compactSymbol(for: monitor.state))
        .foregroundStyle(Self.tint(for: monitor.state).color)
        .font(.caption2))
  }

  var compactTrailing: AnyView {
    AnyView(
      BatteryPercentText(
        percent: monitor.state?.percent ?? 0,
        color: Self.tint(for: monitor.state).color))
  }

  // These three are pure and marked `nonisolated` so the tests can call them without hopping to the
  // main actor — `BatteryActivity` is @MainActor, which would otherwise isolate its statics too.

  /// Bolt while charging, plug while topped up on AC, a filled battery on battery power.
  nonisolated static func compactSymbol(for state: BatteryState?) -> String {
    guard let state else { return "battery.100percent" }
    if state.isCharging { return "bolt.fill" }
    if state.onAC { return "powerplug.fill" }
    return batterySymbol(for: state.percent)
  }

  /// SF Symbols only ships 0/25/50/75/100 battery fills.
  nonisolated static func batterySymbol(for percent: Int) -> String {
    switch percent {
    case ..<13: "battery.0percent"
    case ..<38: "battery.25percent"
    case ..<63: "battery.50percent"
    case ..<88: "battery.75percent"
    default: "battery.100percent"
    }
  }

  /// Green while power is coming in, red under 20% on battery, neutral otherwise.
  nonisolated static func tint(for state: BatteryState?) -> BatteryTint {
    guard let state else { return .normal }
    if state.onAC { return .charging }
    return state.percent <= 20 ? .low : .normal
  }
```

Finally, add this type at the end of `Islet/Activities/Battery/BatteryActivity.swift`, after the
`BatteryPercentText` struct:

```swift
/// The compact island's colour states, kept as an enum rather than a `Color` so the rule that picks
/// them is testable without comparing opaque style values.
enum BatteryTint: Equatable {
  case charging, low, normal

  var color: Color {
    switch self {
    case .charging: .green
    case .low: .red
    case .normal: .secondary
    }
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`

Expected: `** TEST SUCCEEDED **`. `BatteryMetricsTests` reports 60 cases; suite total is the
pre-Phase-2 baseline + 60.

- [ ] **Step 5: Commit**

```bash
git add Islet/Activities/Battery/BatteryActivity.swift IsletTests/BatteryMetricsTests.swift
git commit -m "Power: keep the battery tab available on battery power, not only on AC"
```

---

## Task 12: The tall-tier power screen — ring and metric grid

**Files:**
- Create: `Islet/Activities/Battery/BatteryExpandedView.swift`
- Modify: `Islet/Activities/Battery/BatteryActivity.swift` (add `preferredExpandedHeight`, delete the old `BatteryExpandedView`)
- Test: `IsletTests/BatteryMetricsTests.swift`

**Interfaces:**
- Consumes: `Metrics.tallExpandedHeight`, `LiveSamplingGate` via `.liveSampling(_:)`,
  `Motion.gated(_:)`, `PowerFormat.*`, `PowerStatus.text(...)`.
- Produces: `extension BatteryActivity { var preferredExpandedHeight: CGFloat }`,
  `struct BatteryExpandedView: View`.

**Layout target:** 480 × 250 panel; `ExpandedContainerView` gives content
`.padding(.horizontal, 14)` and `.padding(.bottom, 12)` below the notch band, so the content box is
~452 × 206. Pinned `.topLeading` — the same treatment as
`Islet/Activities/Ports/PortsActivity.swift:81`.

- [ ] **Step 1: Write the failing test**

Append inside the class in `IsletTests/BatteryMetricsTests.swift`:

```swift
  // MARK: - Height tier

  @MainActor func testBatteryRequestsTheTallTier() {
    XCTAssertEqual(BatteryActivity().preferredExpandedHeight, Metrics.tallExpandedHeight)
    XCTAssertEqual(Metrics.tallExpandedHeight, 250)
  }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`

Expected: assertion failure — `XCTAssertEqual failed: ("190.0") is not equal to ("250.0")`, because
`BatteryActivity` is still on the default tier from `NotchActivity`'s extension.

- [ ] **Step 3: Delete the old view and request the tall tier**

In `Islet/Activities/Battery/BatteryActivity.swift`, delete the entire `struct BatteryExpandedView`
— everything from the line `struct BatteryExpandedView: View {` down to and including the closing
brace after its `private func timeString(_ minutes: Int) -> String` helper (85 lines, `:97-181` in
the pre-Phase-2 file). Leave `BatteryActivity`, `BatteryPercentText` and `BatteryTint` in place.
Verify with `grep -c "BatteryExpandedView" Islet/Activities/Battery/BatteryActivity.swift` —
expected: `1`, the reference inside `expandedView`.

Then, in the `BatteryActivity` class body, immediately after the `tabIcon` line, add:

```swift
  /// The power screen needs the tall tier; the base 190pt tier cannot hold the grid plus the
  /// power-flow row.
  var preferredExpandedHeight: CGFloat { Metrics.tallExpandedHeight }
```

- [ ] **Step 4: Create the new view with its ring and grid**

Create `Islet/Activities/Battery/BatteryExpandedView.swift`:

```swift
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
}
```

- [ ] **Step 5: Regenerate the project**

Run: `xcodegen generate`

Expected: `Generated project at Islet.xcodeproj`.

- [ ] **Step 6: Run tests to verify they pass**

Run: `xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`

Expected: `** TEST SUCCEEDED **`. `BatteryMetricsTests` reports 61 cases; suite total is the
pre-Phase-2 baseline + 61.

- [ ] **Step 7: Manual check — no unit test covers layout**

```bash
open ~/Library/Developer/Xcode/DerivedData/Islet-*/Build/Products/Debug/Islet.app
```

Hover the notch to expand, click the battery chip. Confirm all four of these:

1. The panel is visibly taller than on the other tabs (250pt vs 190pt) and does not clip the grid.
2. The ring sits hard against the top-left of the content box — no vertical centring.
3. Health and Raw show two different numbers, both labelled.
4. Hovering the Charger tile shows a tooltip listing five `NV/N.NNA` rungs.

Then click another tab and back; the panel height must animate between tiers without leaving a gap.
Quit the app from the menu bar afterwards.

- [ ] **Step 8: Commit**

```bash
git add Islet/Activities/Battery/BatteryExpandedView.swift Islet/Activities/Battery/BatteryActivity.swift IsletTests/BatteryMetricsTests.swift Islet.xcodeproj
git commit -m "Power: rebuild the battery screen on the tall tier with a charge ring and telemetry grid"
```

---

## Task 13: The power-flow row and the footer

**Files:**
- Modify: `Islet/Activities/Battery/BatteryExpandedView.swift`

**Interfaces:**
- Consumes: `BatteryMetrics.systemPowerInWatts / systemLoadWatts / batteryPowerWatts /
  adapterLossWatts / lowPowerMode`, `PowerFormat.watts`, `PowerFormat.wattsUnsigned`,
  `struct PeripheralBattery`.
- Produces: nothing consumed elsewhere.

**No unit test — verified by build plus the manual check in Step 4.** The numbers this row renders
are already covered by Task 5's telemetry tests and Task 8's formatter tests; only the arrangement
is new.

- [ ] **Step 1: Add the flow row and the footer**

In `Islet/Activities/Battery/BatteryExpandedView.swift`, replace the `body` property:

```swift
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .top, spacing: 14) {
        ringColumn.frame(width: 84)
        metricGrid
      }
      Spacer(minLength: 0)
    }
    .foregroundStyle(.white)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .liveSampling(monitor.liveGate)
  }
```

with:

```swift
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
```

- [ ] **Step 2: Build**

Run: `xcodebuild build -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Run tests**

Run: `xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`

Expected: `** TEST SUCCEEDED **`, still 61 Phase-2 cases (this task adds none).

- [ ] **Step 4: Manual check — no unit test covers layout**

```bash
ioreg -r -c AppleSmartBattery -w0 | grep -o '"SystemPowerIn"=[0-9]*'
ioreg -r -c AppleSmartBattery -w0 | grep -o '"SystemLoad"=[0-9]*'
open ~/Library/Developer/Xcode/DerivedData/Islet-*/Build/Products/Debug/Islet.app
```

Expand the notch, click the battery chip and confirm:

1. The flow row reads `Adapter <W> → System <W> → Battery ±<W>` and the first two match the `ioreg`
   values divided by 1000, to one decimal.
2. The Battery figure is orange with a `-` while discharging and green with a `+` while charging.
3. Nothing overflows the 452pt content box — no clipped text on the right edge.
4. The numbers tick once a second without the last digit flickering back and forth (this is the
   smoothing from Task 9). Watch for ten seconds.
5. Unplug the charger. The tab stays present, the flow row's Adapter node disappears, and the status
   under the ring changes to "On battery". Replug and confirm it comes back.
6. Toggle Low Power Mode in System Settings → Battery; the leaf in the footer fills and turns yellow
   within a second, with no `pmset` process spawned (`ps aux | grep pmset` shows nothing).

Quit the app from the menu bar afterwards.

- [ ] **Step 5: Commit**

```bash
git add Islet/Activities/Battery/BatteryExpandedView.swift
git commit -m "Power: add the adapter-to-system-to-battery flow row and the Low Power footer"
```

---

## Done criteria

- `xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`
  ends in `** TEST SUCCEEDED **` with 61 new `BatteryMetricsTests` cases on top of the pre-Phase-2
  baseline, and `IsletTests/BatteryEventDetectorTests.swift` unchanged and still passing.
- `git status` is clean.
- The battery tab is present on battery power and on AC.
- Health and Raw both render, labelled and different.
- No `pmset`, no shell-outs, no charge control, nothing writing to the SMC.
