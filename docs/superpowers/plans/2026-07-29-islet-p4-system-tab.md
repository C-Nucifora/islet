# Phase 4 — System Tab Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Stats-style System tab to the expanded island — CPU, GPU, RAM, disk, network and thermal — sampled at 1 Hz while visible and 5 s while hidden, with every display style configurable per metric.

**Architecture:** All counter deltas live in pure free functions (`cpuUtilisation`, `ratePerSecond`, `sparklinePoints`, `systemMetricsSample`) so `IsletTests` can cover ticks, byte rates, 32/64-bit wraparound and sampling gaps synchronously. `SystemMetricsReader` wraps the raw kernel calls and returns Sendable snapshot structs; `SystemMetricsMonitor` is the only `@MainActor` piece — it samples off the main thread via `Task.detached`, publishes on it, and holds a 60-sample ring per series plus the Phase 1.4 `LiveSamplingGate`. `SystemActivity.isActive` runs through a pure `SystemPresenceGate` with hysteresis and a sustain window so the collapsed island's width cannot churn once a second.

**Tech Stack:** Swift 6, SwiftUI, AppKit, XcodeGen, XCTest, sindresorhus/Defaults

## Global Constraints

- **Swift 6 strict concurrency.** `SystemMetricsMonitor`, `SystemActivity` and the views are `@MainActor`. Everything else in this phase — `SystemMetricsReader`, `RawCounters`, `CPUTopology`, `MetricRing`, `SystemPresenceGate`, `Sparkline` and every free function — is deliberately actor-free and `Sendable` so tests call them synchronously and the sampler can call them off the main thread.
- **XcodeGen is mandatory.** `Islet.xcodeproj` is generated from `project.yml`, which globs `- path: Islet` and `- path: IsletTests`. Any step that CREATES a new `.swift` file must be immediately followed by `xcodegen generate` before building, or the build fails with "cannot find X in scope". `xcodegen generate` prints a warning about `Vendor/MediaRemoteAdapter.framework`; that is expected and harmless.
- **Test command:** `xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`
- **Build command:** `xcodebuild build -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`
- **Baseline: 75 passing tests, ~11 s.** This plan adds 58, finishing at 133.
- **Commit after every green test run.** Scope prefix, then a lowercase imperative summary — e.g. `System: read CPU ticks without leaking the host_processor_info array`.
- **Never put `Co-Authored-By`, or any mention of Claude / Anthropic / AI, in a commit message.**
- **Phase-specific invariant — the collapsed island must never resize on a timer.** `SystemActivity`'s compact slots are fixed-width SF Symbols with no digits, and it sends `objectWillChange` only when `SystemPresenceGate` flips. A per-second width change would drive `onGeometryChange` → `NotchViewModel.updateCompactWidths` (`NotchViewModel.swift:75-80`) → `NSPanel.setFrame` once per second forever.
- **`host_processor_info`'s array must be `vm_deallocate`d.** Measured on this machine: `count = 12`, `infoCount = 48`, `MemoryLayout<integer_t>.stride = 4` → 192 bytes per sample, ~11 MB/day at 1 Hz.

## Deliberately excluded — do not add these

State this to anyone who asks for them. All four were assessed in the design spec (`docs/superpowers/specs/2026-07-29-power-stats-events-media-design.md:340-351`) and rejected on evidence, not taste:

- **SMC** (fan RPM, die temperatures, `PSTR` system watts) — needs a hand-laid-out 80-byte kernel struct with no header; a natural Swift struct lays out at 76 bytes and every call returns `kIOReturnBadArgument`. Key names are per-SoC with no published list. Battery temperature is already available without it.
- **IOReport** — dyld-cache-only, no header. Its unique value is CPU/GPU watts and per-cluster frequency residency. GPU utilisation, the thing actually wanted, comes from `PerformanceStatistics` with no private symbols.
- **CPU frequency on Apple Silicon** — no public API. `sysctl hw.cpufrequency` is Intel-only and is absent on this machine (verified: `sysctl hw.cpufrequency` returns nothing).
- **Public IP** — requires an outbound HTTP call to a third party.

## Verified facts this plan is built on

Everything below was read off this machine (M3 Pro, macOS 26) while writing the plan. Do not re-derive it; do re-verify Task 8.

| Fact | Measured value |
|---|---|
| `ioreg -r -c IOAccelerator` | one node, `AGXAcceleratorG15X`. `"PerformanceStatistics" = {… "Device Utilization %"=25, "Renderer Utilization %"=25, "Tiler Utilization %"=25 …}`. Value bridges as `__NSCFNumber`. |
| `ioreg -r -c IOBlockStorageDriver` | **four** matching nodes. Node 0 is all-zero (`"Bytes (Read)"=0`, `"Bytes (Write)"=0`). Node 1 is the internal SSD (`"Bytes (Read)"=843126730752`, `"Bytes (Write)"=667672817664`). Nodes 2 and 3 are small read-only images (`3030016` / `3021824` bytes read, zero written). |
| `host_processor_info` | `count = 12`, `infoCount = 48`, `CPU_STATE_MAX = 4`. |
| `hw.nperflevels` | `2`; `hw.perflevel0.name = Performance` (6), `hw.perflevel1.name = Efficiency` (6). |
| **Cluster ordering (Task 8)** | `host_processor_info` orders the **least performant cluster first**. A `.background`-QoS spin saturates indices 0–5 (avg 0.95) while a `.userInteractive` spin saturates indices 6–11 (avg 0.93). Reproduced twice. The naive "perflevel0 first" convention is **wrong on this hardware**. |
| `host_statistics64(HOST_VM_INFO64)` | `kr = 0`, `active=769804 wired=252791 compressor=479827`, `vm_kernel_page_size = 16384`. |
| `sysctl kern.memorystatus_vm_pressure_level` | `1` (normal). |
| `sysctl vm.swapusage` | `total = 1024.00M  used = 12.00M`; `xsw_usage.xsu_used` is `UInt64`. |
| `getloadavg` | returns 3, `[4.71, 4.34, 4.59]`. |
| `getifaddrs` → `if_data.ifi_ibytes` | type is **`UInt32`**. `en6` reads `2934579200` — two thirds of the way to a 2^32 wrap, so 32-bit wraparound handling is not theoretical. |
| `SCDynamicStoreCopyValue("State:/Network/Global/IPv4")["PrimaryInterface"]` | `"en6"`. |
| `AppleSmartBattery` → `Temperature` | `3056` (centi-degrees → 30.56 °C). |
| `volumeAvailableCapacityForImportantUsage` on `/` | `1542075087195`. |

## Interfaces consumed from Phase 1

This plan does not create these; the Phase 1 plan does. If any is missing, stop and land Phase 1 first.

```swift
// Phase 1.2
enum Metrics { static let tallExpandedHeight: CGFloat = 250 }
extension NotchActivity { var preferredExpandedHeight: CGFloat { Metrics.expandedSize.height } }

// Phase 1.4
@MainActor final class LiveSamplingGate {
  init(onChange: @escaping (Bool) -> Void)
  var isLive: Bool { get }
  func retain()
  func release()
}
extension View { func liveSampling(_ gate: LiveSamplingGate) -> some View }

// Phase 1.5
enum IORegistryReader {
  static func properties(matching serviceName: String) -> [String: Any]?
  static func allProperties(matching serviceName: String) -> [[String: Any]]
  static func signedInt(_ raw: Int?) -> Int?
}

// Phase 1.6
struct ThresholdDetector: Equatable {
  enum Direction { case falling, rising }
  init(thresholds: [Double], direction: Direction)
  func crossings(from old: Double?, to new: Double) -> [Double]
}
```

**Hard requirement on `IORegistryReader`:** it must be non-isolated (a plain `enum` of `static func`s, per the codebase rule that pure logic types stay actor-free). `RawCounters.read()` calls it from a `Task.detached`. If Phase 1 landed it annotated `@MainActor`, remove the annotation — it holds no state.

---

## File Structure

**Created — source (`Islet/Activities/System/`)**

| File | Single responsibility |
|---|---|
| `SystemMetricsSample.swift` | The three contract types (`SystemMetricKind`, `MetricDisplayStyle`, `SystemMetricsSample`) and their display-name / style-resolution helpers. No logic beyond pure enum mapping. |
| `SystemMetricsMath.swift` | Pure delta maths and the ring buffer: `CPUTicks`, `cpuUtilisation`, `CounterWidth`, `ratePerSecond`, `metricsMaxSampleGap`, `MetricRing`. |
| `Sparkline.swift` | `SparklineScale`, the pure `sparklinePoints` normaliser, the `Sparkline` Shape and the `SparklineView` wrapper. |
| `CPUTopology.swift` | `PerfLevel`, `CPUCluster` and the pure perf-level → array-index-range mapping, with a documented degrade-to-no-split path. |
| `SystemMetricsReader.swift` | One free function per kernel source, plus `RawCounters` — the raw, un-differenced snapshot. Non-isolated, safe off the main thread. |
| `SystemSampleBuilder.swift` | `systemMetricsSample(...)` — the single pure function that turns two `RawCounters` plus elapsed time into a publishable `SystemMetricsSample`. |
| `SystemMetricsMonitor.swift` | The only `@MainActor` sampling type: timer cadence, previous-snapshot retention, 60-sample rings, `LiveSamplingGate`. |
| `SystemPresenceGate.swift` | Pure hysteresis + sustain gate deciding whether the System tab earns a slot in the island. |
| `SystemActivity.swift` | `NotchActivity` conformance: tall expanded height, fixed-width compact glyphs, gate-driven `isActive`. |
| `SystemExpandedView.swift` | The six-row readout and all five `MetricDisplayStyle` renderings. |

**Created — tests**

| File | Single responsibility |
|---|---|
| `IsletTests/SystemMetricsTests.swift` | Every pure metric function: style resolution, CPU tick deltas, byte rates, wraparound, gap discard, ring semantics, sparkline normalisation, topology mapping, sample building, and three live-hardware sanity checks. |
| `IsletTests/SystemActivityGateTests.swift` | `SystemPresenceGate` hysteresis, sustain window and thermal precedence. |

**Modified**

| File | Change |
|---|---|
| `Islet/Settings/DefaultsKeys.swift:33` | Add `systemEnabled`, `systemAlwaysVisible`, `metricStyles`. |
| `Islet/Activities/ActivityCatalog.swift:5-13` | Add the `("system", "System", "cpu")` entry. |
| `Islet/App/IsletApp.swift:12` | Add `static let system = SystemActivity()`. |
| `Islet/App/AppDelegate.swift:26` | Start and register `AppState.system`. |
| `Islet/Settings/SettingsView.swift:54, :132` | Bump the menu-order list height for the eighth row; add the "System stats" section. |

---

### Task 1: Contract types for the System tab

**Files:**
- Create: `Islet/Activities/System/SystemMetricsSample.swift`
- Create: `IsletTests/SystemMetricsTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `enum SystemMetricKind: String, CaseIterable, Codable { case cpu, gpu, memory, disk, network, thermal }`
  - `enum MetricDisplayStyle: String, CaseIterable, Codable { case number, numberAndBar, sparkline, sparklineAndNumber, combined }`
  - `struct SystemMetricsSample: Equatable, Sendable` (all 18 contract fields)
  - `var SystemMetricKind.displayName: String`
  - `var MetricDisplayStyle.displayName: String`
  - `var MetricDisplayStyle.needsHistory: Bool`
  - `static func MetricDisplayStyle.resolve(_ raw: String?) -> MetricDisplayStyle`
  - `static func MetricDisplayStyle.effective(for kind: SystemMetricKind, requested: MetricDisplayStyle) -> MetricDisplayStyle`

- [ ] **Step 1: Write the failing test**

Create `IsletTests/SystemMetricsTests.swift`:

```swift
import XCTest

@testable import Islet

final class SystemMetricsTests: XCTestCase {

  // MARK: - Contract types

  func testMetricKindRawValuesAreStable() {
    // These raw values are the keys of Defaults[.metricStyles]; renaming one silently resets a
    // user's configured style, so they are locked here.
    XCTAssertEqual(
      SystemMetricKind.allCases.map(\.rawValue),
      ["cpu", "gpu", "memory", "disk", "network", "thermal"])
  }

  func testDisplayStyleRawValuesAreStable() {
    XCTAssertEqual(
      MetricDisplayStyle.allCases.map(\.rawValue),
      ["number", "numberAndBar", "sparkline", "sparklineAndNumber", "combined"])
  }

  func testResolveFallsBackForUnknownAndMissingRawValues() {
    XCTAssertEqual(MetricDisplayStyle.resolve("combined"), .combined)
    XCTAssertEqual(MetricDisplayStyle.resolve(nil), MetricDisplayStyle.fallback)
    XCTAssertEqual(MetricDisplayStyle.resolve("nonsense"), MetricDisplayStyle.fallback)
    XCTAssertEqual(MetricDisplayStyle.resolve(""), MetricDisplayStyle.fallback)
  }

  func testNeedsHistoryOnlyForSparklineStyles() {
    XCTAssertFalse(MetricDisplayStyle.number.needsHistory)
    XCTAssertFalse(MetricDisplayStyle.numberAndBar.needsHistory)
    XCTAssertTrue(MetricDisplayStyle.sparkline.needsHistory)
    XCTAssertTrue(MetricDisplayStyle.sparklineAndNumber.needsHistory)
    XCTAssertTrue(MetricDisplayStyle.combined.needsHistory)
  }

  func testThermalDegradesSparklineStylesToNumber() {
    // Thermal state is an enum with four values, not a series — a sparkline of it is noise.
    XCTAssertEqual(MetricDisplayStyle.effective(for: .thermal, requested: .sparkline), .number)
    XCTAssertEqual(
      MetricDisplayStyle.effective(for: .thermal, requested: .sparklineAndNumber), .number)
    XCTAssertEqual(
      MetricDisplayStyle.effective(for: .thermal, requested: .combined), .combined)
    XCTAssertEqual(
      MetricDisplayStyle.effective(for: .cpu, requested: .sparkline), .sparkline)
  }
}
```

- [ ] **Step 2: Regenerate the project so the new test file joins the target**

Run: `cd /Users/christiannucifora/Documents/dev/personal/islet && xcodegen generate`

Expected: `Loaded project`, then `Created project at .../Islet.xcodeproj`. A warning mentioning `Vendor/MediaRemoteAdapter.framework` is expected and harmless.

- [ ] **Step 3: Run the test to verify it fails**

Run: `cd /Users/christiannucifora/Documents/dev/personal/islet && xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`

Expected: compilation fails. The tail contains `error: cannot find 'SystemMetricKind' in scope` and does **not** contain `** TEST SUCCEEDED **`.

- [ ] **Step 4: Create the contract types**

Create `Islet/Activities/System/SystemMetricsSample.swift`:

```swift
import Foundation

/// The six series the System tab can render. Raw values are the keys of `Defaults[.metricStyles]`.
enum SystemMetricKind: String, CaseIterable, Codable { case cpu, gpu, memory, disk, network, thermal }

extension SystemMetricKind {
  var displayName: String {
    switch self {
    case .cpu: "CPU"
    case .gpu: "GPU"
    case .memory: "Memory"
    case .disk: "Disk"
    case .network: "Network"
    case .thermal: "Thermal"
    }
  }
}

/// How one metric is drawn. Configurable per metric in Settings.
enum MetricDisplayStyle: String, CaseIterable, Codable {
  case number  // 38%
  case numberAndBar  // 38%  ▓▓▓▓░░░░░░
  case sparkline  //      ▁▂▅▃▂▁▄█▅▃
  case sparklineAndNumber  // 38%  ▁▂▅▃▂▁▄█▅▃
  case combined  // 38%  ▁▂▅▃▂▁▄█▅▃  P 44%  E 18%  load 3.51
}

extension MetricDisplayStyle {
  /// Used when the stored string is missing or no longer a known case.
  static let fallback: MetricDisplayStyle = .sparklineAndNumber

  var displayName: String {
    switch self {
    case .number: "Number"
    case .numberAndBar: "Number + bar"
    case .sparkline: "Sparkline"
    case .sparklineAndNumber: "Number + sparkline"
    case .combined: "Everything"
    }
  }

  /// True when the style reads the monitor's ring buffer. `.number` and `.numberAndBar` are the
  /// cheap path and need no history at all.
  var needsHistory: Bool {
    switch self {
    case .number, .numberAndBar: false
    case .sparkline, .sparklineAndNumber, .combined: true
    }
  }

  static func resolve(_ raw: String?) -> MetricDisplayStyle {
    guard let raw, let style = MetricDisplayStyle(rawValue: raw) else { return fallback }
    return style
  }

  /// Thermal state is a four-value enum, not a series, so the sparkline-only styles collapse to
  /// `.number` for it. `.combined` survives because its extra detail (the battery temperature) is
  /// the whole point of the thermal row.
  static func effective(for kind: SystemMetricKind, requested: MetricDisplayStyle)
    -> MetricDisplayStyle
  {
    guard kind == .thermal else { return requested }
    switch requested {
    case .sparkline, .sparklineAndNumber: return .number
    case .number, .numberAndBar, .combined: return requested
    }
  }
}

/// One published snapshot. Every field is optional because every source can independently fail or
/// be unavailable, and rate fields are additionally nil on the first sample and after a gap.
struct SystemMetricsSample: Equatable, Sendable {
  var cpuTotal: Double?
  var cpuPerformance: Double?
  var cpuEfficiency: Double?
  var loadAverage: Double?
  var gpu: Double?
  var memoryUsedBytes: UInt64?
  var memoryTotalBytes: UInt64?
  var memoryWiredBytes: UInt64?
  var memoryCompressedBytes: UInt64?
  var memoryPressureLevel: Int?
  var swapUsedBytes: UInt64?
  var diskReadBytesPerSec: Double?
  var diskWriteBytesPerSec: Double?
  var diskFreeBytes: UInt64?
  var netInBytesPerSec: Double?
  var netOutBytesPerSec: Double?
  var primaryInterface: String?
  var thermalState: Int?  // ProcessInfo.ThermalState.rawValue
  var batteryTemperatureC: Double?
}
```

- [ ] **Step 5: Regenerate the project so the new source file joins the target**

Run: `cd /Users/christiannucifora/Documents/dev/personal/islet && xcodegen generate`

Expected: `Created project at .../Islet.xcodeproj`.

- [ ] **Step 6: Run tests to verify they pass**

Run: `cd /Users/christiannucifora/Documents/dev/personal/islet && xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`

Expected: `** TEST SUCCEEDED **`, 80 tests.

- [ ] **Step 7: Commit**

```bash
cd /Users/christiannucifora/Documents/dev/personal/islet
git add Islet/Activities/System/SystemMetricsSample.swift IsletTests/SystemMetricsTests.swift Islet.xcodeproj
git commit -m "System: add the metric kind, display style and sample contract types"
```

---

### Task 2: CPU tick delta → utilisation fraction

**Files:**
- Create: `Islet/Activities/System/SystemMetricsMath.swift`
- Modify: `IsletTests/SystemMetricsTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `struct CPUTicks: Equatable, Sendable { var user: UInt32; var system: UInt32; var idle: UInt32; var nice: UInt32 }`
  - `func cpuUtilisation(from old: CPUTicks, to new: CPUTicks) -> Double?`
  - `func cpuUtilisation(from old: [CPUTicks], to new: [CPUTicks], indices: Range<Int>) -> Double?`

- [ ] **Step 1: Write the failing tests**

Append to `IsletTests/SystemMetricsTests.swift`, inside `final class SystemMetricsTests`, before the closing brace:

```swift
  // MARK: - CPU tick deltas

  private func ticks(_ user: UInt32, _ system: UInt32, _ idle: UInt32, _ nice: UInt32 = 0)
    -> CPUTicks
  {
    CPUTicks(user: user, system: system, idle: idle, nice: nice)
  }

  func testCPUUtilisationHalfBusy() {
    let a = ticks(100, 100, 800)
    let b = ticks(150, 150, 900)  // busy +100, idle +100
    XCTAssertEqual(cpuUtilisation(from: a, to: b) ?? -1, 0.5, accuracy: 1e-9)
  }

  func testCPUUtilisationCountsNiceAsBusy() {
    let a = ticks(0, 0, 0, 0)
    let b = ticks(0, 0, 100, 100)  // 100 nice, 100 idle
    XCTAssertEqual(cpuUtilisation(from: a, to: b) ?? -1, 0.5, accuracy: 1e-9)
  }

  func testCPUUtilisationFullyIdle() {
    XCTAssertEqual(cpuUtilisation(from: ticks(5, 5, 5), to: ticks(5, 5, 105)) ?? -1, 0)
  }

  func testCPUUtilisationIsNilWhenNoTicksElapsed() {
    // A duplicate read must not render as 0% — it is not a measurement at all.
    XCTAssertNil(cpuUtilisation(from: ticks(9, 9, 9), to: ticks(9, 9, 9)))
  }

  func testCPUTickWraparoundIsHandled() {
    // The kernel hands these back as 32-bit counters. Widening before subtracting would produce a
    // ~4-billion-tick negative delta and a nonsense fraction.
    let a = ticks(UInt32.max - 49, 0, UInt32.max - 49)
    let b = ticks(50, 0, 50)  // each wrapped by 100
    XCTAssertEqual(cpuUtilisation(from: a, to: b) ?? -1, 0.5, accuracy: 1e-9)
  }

  func testCPUUtilisationOverAnIndexRange() {
    let old = [ticks(0, 0, 0), ticks(0, 0, 0), ticks(0, 0, 0), ticks(0, 0, 0)]
    let new = [ticks(100, 0, 0), ticks(100, 0, 0), ticks(0, 0, 100), ticks(0, 0, 100)]
    XCTAssertEqual(cpuUtilisation(from: old, to: new, indices: 0..<2) ?? -1, 1.0, accuracy: 1e-9)
    XCTAssertEqual(cpuUtilisation(from: old, to: new, indices: 2..<4) ?? -1, 0.0, accuracy: 1e-9)
    XCTAssertEqual(cpuUtilisation(from: old, to: new, indices: 0..<4) ?? -1, 0.5, accuracy: 1e-9)
  }

  func testCPUUtilisationIsNilForAnOutOfBoundsRange() {
    let old = [ticks(0, 0, 0)]
    let new = [ticks(100, 0, 100)]
    XCTAssertNil(cpuUtilisation(from: old, to: new, indices: 0..<2))
    XCTAssertNil(cpuUtilisation(from: old, to: new, indices: 0..<0))
  }

  func testCPUUtilisationIsNilForMismatchedArrayLengths() {
    // A core count change mid-run means the two snapshots cannot be differenced at all.
    XCTAssertNil(
      cpuUtilisation(from: [ticks(0, 0, 0)], to: [ticks(1, 1, 1), ticks(1, 1, 1)], indices: 0..<1))
  }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd /Users/christiannucifora/Documents/dev/personal/islet && xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`

Expected: compilation fails. The tail contains `error: cannot find 'CPUTicks' in scope` and does **not** contain `** TEST SUCCEEDED **`.

- [ ] **Step 3: Create the pure CPU delta functions**

Create `Islet/Activities/System/SystemMetricsMath.swift`:

```swift
import Foundation

/// One core's cumulative CPU_STATE counters, exactly as `host_processor_info` reports them.
/// Held at their native 32-bit width so deltas can be taken in the domain they wrap in.
struct CPUTicks: Equatable, Sendable {
  var user: UInt32
  var system: UInt32
  var idle: UInt32
  var nice: UInt32
}

/// Fraction of elapsed ticks one core spent busy. Nil when no ticks elapsed — a duplicate read is
/// not a 0% measurement, it is the absence of one.
func cpuUtilisation(from old: CPUTicks, to new: CPUTicks) -> Double? {
  let user = UInt64(new.user &- old.user)
  let system = UInt64(new.system &- old.system)
  let nice = UInt64(new.nice &- old.nice)
  let idle = UInt64(new.idle &- old.idle)
  let busy = user + system + nice
  let total = busy + idle
  guard total > 0 else { return nil }
  return Double(busy) / Double(total)
}

/// Fraction of elapsed ticks a contiguous run of cores spent busy. Nil when the two snapshots
/// cannot be differenced (different core counts, an out-of-bounds or empty range, no ticks).
func cpuUtilisation(from old: [CPUTicks], to new: [CPUTicks], indices: Range<Int>) -> Double? {
  guard old.count == new.count, !indices.isEmpty,
    indices.lowerBound >= 0, indices.upperBound <= new.count
  else { return nil }
  var busy: UInt64 = 0
  var total: UInt64 = 0
  for i in indices {
    // Subtract at 32 bits so a wrapped counter still yields the true elapsed count.
    let user = UInt64(new[i].user &- old[i].user)
    let system = UInt64(new[i].system &- old[i].system)
    let nice = UInt64(new[i].nice &- old[i].nice)
    let idle = UInt64(new[i].idle &- old[i].idle)
    busy += user + system + nice
    total += user + system + nice + idle
  }
  guard total > 0 else { return nil }
  return Double(busy) / Double(total)
}
```

- [ ] **Step 4: Regenerate the project so the new source file joins the target**

Run: `cd /Users/christiannucifora/Documents/dev/personal/islet && xcodegen generate`

Expected: `Created project at .../Islet.xcodeproj`.

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd /Users/christiannucifora/Documents/dev/personal/islet && xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`

Expected: `** TEST SUCCEEDED **`, 87 tests.

- [ ] **Step 6: Commit**

```bash
cd /Users/christiannucifora/Documents/dev/personal/islet
git add Islet/Activities/System/SystemMetricsMath.swift IsletTests/SystemMetricsTests.swift Islet.xcodeproj
git commit -m "System: turn CPU tick deltas into a utilisation fraction, wraparound included"
```

---

### Task 3: Byte-counter delta → bytes per second, with wraparound and gap detection

**Files:**
- Modify: `Islet/Activities/System/SystemMetricsMath.swift`
- Modify: `IsletTests/SystemMetricsTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `let metricsMaxSampleGap: TimeInterval` (10)
  - `enum CounterWidth: Sendable { case bits32, bits64 }`
  - `func ratePerSecond(from old: UInt64, to new: UInt64, elapsed: TimeInterval, width: CounterWidth) -> Double?`

- [ ] **Step 1: Write the failing tests**

Append to `IsletTests/SystemMetricsTests.swift`, inside the class, before the closing brace:

```swift
  // MARK: - Byte counter rates

  func testRatePerSecondForASimpleDelta() {
    XCTAssertEqual(
      ratePerSecond(from: 1000, to: 3000, elapsed: 2, width: .bits64) ?? -1, 1000,
      accuracy: 1e-9)
  }

  func testRateIsNilForZeroElapsed() {
    XCTAssertNil(ratePerSecond(from: 0, to: 100, elapsed: 0, width: .bits64))
  }

  func testRateIsNilForNegativeElapsed() {
    // A backwards clock must discard the sample, not divide by a negative.
    XCTAssertNil(ratePerSecond(from: 0, to: 100, elapsed: -1, width: .bits64))
  }

  func testRateIsNilWhenTheGapExceedsTheCeiling() {
    // Sleep/wake, or a stalled run loop. Rendering this delta would draw a huge fake spike.
    XCTAssertNil(
      ratePerSecond(
        from: 0, to: 5_000_000_000, elapsed: metricsMaxSampleGap + 0.001, width: .bits64))
  }

  func testRateAtExactlyTheGapCeilingIsAccepted() {
    XCTAssertEqual(
      ratePerSecond(from: 0, to: 100, elapsed: metricsMaxSampleGap, width: .bits64) ?? -1,
      100 / metricsMaxSampleGap, accuracy: 1e-9)
  }

  func testThirtyTwoBitCounterWraparound() {
    // getifaddrs' ifi_ibytes is UInt32 and wraps in ~34 s on a saturated 1 Gb/s link.
    // 4_294_967_000 + 1296 == 2^32 + 1000, so the true delta is 1296.
    XCTAssertEqual(
      ratePerSecond(from: 4_294_967_000, to: 1000, elapsed: 1, width: .bits32) ?? -1, 1296,
      accuracy: 1e-9)
  }

  func testSixtyFourBitCounterWraparound() {
    XCTAssertEqual(
      ratePerSecond(from: UInt64.max - 99, to: 100, elapsed: 1, width: .bits64) ?? -1, 200,
      accuracy: 1e-9)
  }

  func testThirtyTwoBitWidthTruncatesWideInputs() {
    // Inputs are widened to UInt64 at the call site; .bits32 must narrow both before subtracting.
    XCTAssertEqual(
      ratePerSecond(from: 0x1_0000_0000 + 500, to: 0x1_0000_0000 + 900, elapsed: 2, width: .bits32)
        ?? -1, 200, accuracy: 1e-9)
  }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd /Users/christiannucifora/Documents/dev/personal/islet && xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`

Expected: compilation fails. The tail contains `error: cannot find 'ratePerSecond' in scope` and does **not** contain `** TEST SUCCEEDED **`.

- [ ] **Step 3: Add the rate function**

Append to `Islet/Activities/System/SystemMetricsMath.swift`:

```swift
/// Longest gap between two counter reads that still produces a rate. Anything longer — sleep/wake,
/// a stalled run loop, the app being suspended — is discarded rather than rendered as a spike.
let metricsMaxSampleGap: TimeInterval = 10

/// The native width of a cumulative counter, which is the width its wraparound happens at.
enum CounterWidth: Sendable {
  /// `if_data.ifi_ibytes` / `ifi_obytes` — wraps in about 34 s on a saturated 1 Gb/s link.
  case bits32
  /// `IOBlockStorageDriver` → `Statistics` → `Bytes (Read)` / `Bytes (Write)`.
  case bits64
}

/// Units per second between two cumulative counter reads.
/// Nil when `elapsed` is not positive, or when the gap exceeds `metricsMaxSampleGap`.
func ratePerSecond(
  from old: UInt64, to new: UInt64, elapsed: TimeInterval, width: CounterWidth
) -> Double? {
  guard elapsed > 0, elapsed <= metricsMaxSampleGap else { return nil }
  let delta: UInt64
  switch width {
  case .bits32:
    delta = UInt64(UInt32(truncatingIfNeeded: new) &- UInt32(truncatingIfNeeded: old))
  case .bits64:
    delta = new &- old
  }
  return Double(delta) / elapsed
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/christiannucifora/Documents/dev/personal/islet && xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`

Expected: `** TEST SUCCEEDED **`, 95 tests.

- [ ] **Step 5: Commit**

```bash
cd /Users/christiannucifora/Documents/dev/personal/islet
git add Islet/Activities/System/SystemMetricsMath.swift IsletTests/SystemMetricsTests.swift
git commit -m "System: convert byte counters to rates, discarding gaps instead of spiking"
```

---

### Task 4: The 60-sample ring buffer

**Files:**
- Modify: `Islet/Activities/System/SystemMetricsMath.swift`
- Modify: `IsletTests/SystemMetricsTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `struct MetricRing: Equatable, Sendable { let capacity: Int; private(set) var values: [Double]; init(capacity: Int); mutating func push(_ value: Double); var latest: Double? }`

- [ ] **Step 1: Write the failing tests**

Append to `IsletTests/SystemMetricsTests.swift`, inside the class, before the closing brace:

```swift
  // MARK: - Ring buffer

  func testRingStartsEmpty() {
    let ring = MetricRing(capacity: 60)
    XCTAssertTrue(ring.values.isEmpty)
    XCTAssertNil(ring.latest)
    XCTAssertEqual(ring.capacity, 60)
  }

  func testPushKeepsInsertionOrder() {
    var ring = MetricRing(capacity: 4)
    ring.push(1)
    ring.push(2)
    ring.push(3)
    XCTAssertEqual(ring.values, [1, 2, 3])
  }

  func testPushOverwritesOldestOnceFull() {
    var ring = MetricRing(capacity: 3)
    for v in [1.0, 2, 3, 4, 5] { ring.push(v) }
    XCTAssertEqual(ring.values, [3, 4, 5])
    XCTAssertEqual(ring.values.count, ring.capacity)
  }

  func testCapacityOfOneKeepsOnlyTheNewest() {
    var ring = MetricRing(capacity: 1)
    ring.push(7)
    ring.push(8)
    XCTAssertEqual(ring.values, [8])
  }

  func testNonPositiveCapacityClampsToOne() {
    var ring = MetricRing(capacity: 0)
    XCTAssertEqual(ring.capacity, 1)
    ring.push(3)
    ring.push(4)
    XCTAssertEqual(ring.values, [4])
    XCTAssertEqual(MetricRing(capacity: -5).capacity, 1)
  }

  func testLatestIsTheMostRecentPush() {
    var ring = MetricRing(capacity: 60)
    ring.push(0.1)
    ring.push(0.9)
    XCTAssertEqual(ring.latest, 0.9)
  }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd /Users/christiannucifora/Documents/dev/personal/islet && xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`

Expected: compilation fails. The tail contains `error: cannot find 'MetricRing' in scope` and does **not** contain `** TEST SUCCEEDED **`.

- [ ] **Step 3: Add the ring buffer**

Append to `Islet/Activities/System/SystemMetricsMath.swift`:

```swift
/// A bounded, oldest-first history of one series. Backed by a plain array rather than a rotating
/// index because every consumer wants the values in draw order and 60 elements is nothing.
struct MetricRing: Equatable, Sendable {
  let capacity: Int
  private(set) var values: [Double] = []

  init(capacity: Int) {
    self.capacity = max(1, capacity)
  }

  mutating func push(_ value: Double) {
    values.append(value)
    if values.count > capacity { values.removeFirst(values.count - capacity) }
  }

  var latest: Double? { values.last }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/christiannucifora/Documents/dev/personal/islet && xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`

Expected: `** TEST SUCCEEDED **`, 101 tests.

- [ ] **Step 5: Commit**

```bash
cd /Users/christiannucifora/Documents/dev/personal/islet
git add Islet/Activities/System/SystemMetricsMath.swift IsletTests/SystemMetricsTests.swift
git commit -m "System: add a bounded per-series history ring"
```

---

### Task 5: Sparkline normalisation and the Shape

**Files:**
- Create: `Islet/Activities/System/Sparkline.swift`
- Modify: `IsletTests/SystemMetricsTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `enum SparklineScale: Equatable, Sendable { case fixed(min: Double, max: Double); case auto }`
  - `func sparklinePoints(_ values: [Double], scale: SparklineScale) -> [CGPoint]`
  - `struct Sparkline: Shape { let values: [Double]; let scale: SparklineScale }`
  - `struct SparklineView: View { let values: [Double]; let scale: SparklineScale }`

- [ ] **Step 1: Write the failing tests**

Append to `IsletTests/SystemMetricsTests.swift`, inside the class, before the closing brace:

```swift
  // MARK: - Sparkline normalisation

  func testEmptySeriesHasNoPoints() {
    XCTAssertTrue(sparklinePoints([], scale: .fixed(min: 0, max: 1)).isEmpty)
    XCTAssertTrue(sparklinePoints([], scale: .auto).isEmpty)
  }

  func testSingleSampleDrawsAFlatLineAcrossTheFullWidth() {
    // One reading cannot describe a slope. Two points at the same height is the honest render;
    // a single point would draw nothing at all.
    let points = sparklinePoints([0.25], scale: .fixed(min: 0, max: 1))
    XCTAssertEqual(points.count, 2)
    XCTAssertEqual(points[0].x, 0, accuracy: 1e-9)
    XCTAssertEqual(points[1].x, 1, accuracy: 1e-9)
    XCTAssertEqual(points[0].y, 0.25, accuracy: 1e-9)
    XCTAssertEqual(points[1].y, 0.25, accuracy: 1e-9)
  }

  func testXCoordinatesSpanZeroToOne() {
    let points = sparklinePoints([0, 0.5, 1, 0.5, 0], scale: .fixed(min: 0, max: 1))
    XCTAssertEqual(points.map(\.x), [0, 0.25, 0.5, 0.75, 1])
  }

  func testFixedScaleNormalisesToTheGivenRange() {
    let points = sparklinePoints([10, 20, 30], scale: .fixed(min: 10, max: 30))
    XCTAssertEqual(points.map(\.y), [0, 0.5, 1])
  }

  func testFixedScaleClampsOutOfRangeValues() {
    let points = sparklinePoints([-5, 0.5, 42], scale: .fixed(min: 0, max: 1))
    XCTAssertEqual(points.map(\.y), [0, 0.5, 1])
  }

  func testFixedScaleWithACollapsedRangeSitsAtMidHeight() {
    let points = sparklinePoints([3, 3, 3], scale: .fixed(min: 5, max: 5))
    XCTAssertEqual(points.map(\.y), [0.5, 0.5, 0.5])
  }

  func testAutoScaleStretchesToTheSeriesExtremes() {
    let points = sparklinePoints([100, 150, 200], scale: .auto)
    XCTAssertEqual(points.map(\.y), [0, 0.5, 1])
  }

  func testAutoScaleWithAllEqualValuesSitsAtMidHeight() {
    // Auto-scaling a flat series would otherwise divide by zero or pin every point to the top.
    let points = sparklinePoints([7, 7, 7, 7], scale: .auto)
    XCTAssertEqual(points.map(\.y), [0.5, 0.5, 0.5, 0.5])
  }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd /Users/christiannucifora/Documents/dev/personal/islet && xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`

Expected: compilation fails. The tail contains `error: cannot find 'sparklinePoints' in scope` and does **not** contain `** TEST SUCCEEDED **`.

- [ ] **Step 3: Create the normaliser, the Shape and the view**

Create `Islet/Activities/System/Sparkline.swift`:

```swift
import SwiftUI

/// How a series maps onto the sparkline's vertical extent.
enum SparklineScale: Equatable, Sendable {
  /// A known range — CPU, GPU and memory are all fractions of 1.
  case fixed(min: Double, max: Double)
  /// Stretch to the window's own extremes. Disk and network throughput have no ceiling, so the
  /// only useful reference is the last 60 samples.
  case auto
}

/// Normalises a series into the unit square: x runs 0 (oldest) to 1 (newest), y runs 0 (bottom)
/// to 1 (top). Empty input yields no points; a single sample yields a flat two-point line, since
/// one reading describes a level and not a slope.
func sparklinePoints(_ values: [Double], scale: SparklineScale) -> [CGPoint] {
  guard !values.isEmpty else { return [] }

  let lo: Double
  let hi: Double
  switch scale {
  case .fixed(let min, let max):
    lo = min
    hi = max
  case .auto:
    lo = values.min() ?? 0
    hi = values.max() ?? 0
  }
  let span = hi - lo

  func normalise(_ value: Double) -> Double {
    // A collapsed range has no meaningful shape; mid-height reads as "flat", which is the truth.
    guard span > 0 else { return 0.5 }
    return Swift.min(Swift.max((value - lo) / span, 0), 1)
  }

  guard values.count > 1 else {
    let y = normalise(values[0])
    return [CGPoint(x: 0, y: y), CGPoint(x: 1, y: y)]
  }

  let step = 1.0 / Double(values.count - 1)
  return values.enumerated().map { CGPoint(x: Double($0.offset) * step, y: normalise($0.element)) }
}

/// Draws a normalised series. Unit space is y-up; the SwiftUI rect is y-down, so y is flipped here.
struct Sparkline: Shape {
  let values: [Double]
  let scale: SparklineScale

  func path(in rect: CGRect) -> Path {
    var path = Path()
    let points = sparklinePoints(values, scale: scale)
    guard points.count >= 2 else { return path }
    for (index, point) in points.enumerated() {
      let mapped = CGPoint(
        x: rect.minX + point.x * rect.width,
        y: rect.maxY - point.y * rect.height)
      if index == 0 { path.move(to: mapped) } else { path.addLine(to: mapped) }
    }
    return path
  }
}

/// The sparkline as it appears in a metric row: 28 × 14 pt over a faint plate.
struct SparklineView: View {
  let values: [Double]
  let scale: SparklineScale

  var body: some View {
    Sparkline(values: values, scale: scale)
      .stroke(.white.opacity(0.85), style: StrokeStyle(lineWidth: 1, lineJoin: .round))
      .padding(.vertical, 1)
      .frame(width: 28, height: 14)
      .background(RoundedRectangle(cornerRadius: 3).fill(.white.opacity(0.06)))
      // The number beside it already carries the value; a path of 60 points is noise to VoiceOver.
      .accessibilityHidden(true)
  }
}
```

- [ ] **Step 4: Regenerate the project so the new source file joins the target**

Run: `cd /Users/christiannucifora/Documents/dev/personal/islet && xcodegen generate`

Expected: `Created project at .../Islet.xcodeproj`.

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd /Users/christiannucifora/Documents/dev/personal/islet && xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`

Expected: `** TEST SUCCEEDED **`, 109 tests.

- [ ] **Step 6: Commit**

```bash
cd /Users/christiannucifora/Documents/dev/personal/islet
git add Islet/Activities/System/Sparkline.swift IsletTests/SystemMetricsTests.swift Islet.xcodeproj
git commit -m "System: normalise a 60-sample series into a sparkline path"
```

---

### Task 6: CPU perf-level → array index mapping

**Files:**
- Create: `Islet/Activities/System/CPUTopology.swift`
- Modify: `IsletTests/SystemMetricsTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `struct PerfLevel: Equatable, Sendable { let name: String; let logicalCPUs: Int }`
  - `struct CPUCluster: Equatable, Sendable { let perfLevelIndex: Int; let name: String; let range: Range<Int>; var isPerformance: Bool }`
  - `enum CPUTopology { static func perfLevels() -> [PerfLevel]; static func clusters(perfLevels: [PerfLevel], totalCores: Int) -> [CPUCluster]; static func current() -> [CPUCluster] }`

- [ ] **Step 1: Write the failing tests**

Append to `IsletTests/SystemMetricsTests.swift`, inside the class, before the closing brace:

```swift
  // MARK: - CPU topology

  func testTwoLevelSplitPutsEfficiencyAtTheStartOfTheArray() {
    // host_processor_info orders the LEAST performant cluster first — verified empirically on
    // M3 Pro, where a .background-QoS spin saturates indices 0...5 and hw.perflevel1 is
    // "Efficiency". Ranges are returned most-performant-first for display.
    let clusters = CPUTopology.clusters(
      perfLevels: [PerfLevel(name: "Performance", logicalCPUs: 6),
                   PerfLevel(name: "Efficiency", logicalCPUs: 6)],
      totalCores: 12)
    XCTAssertEqual(
      clusters,
      [
        CPUCluster(perfLevelIndex: 0, name: "Performance", range: 6..<12),
        CPUCluster(perfLevelIndex: 1, name: "Efficiency", range: 0..<6),
      ])
    XCTAssertTrue(clusters[0].isPerformance)
    XCTAssertFalse(clusters[1].isPerformance)
  }

  func testThreeLevelSplitAssignsFromLeastPerformant() {
    let clusters = CPUTopology.clusters(
      perfLevels: [PerfLevel(name: "A", logicalCPUs: 4), PerfLevel(name: "B", logicalCPUs: 4),
                   PerfLevel(name: "C", logicalCPUs: 4)],
      totalCores: 12)
    XCTAssertEqual(clusters.map(\.range), [8..<12, 4..<8, 0..<4])
    XCTAssertEqual(clusters.map(\.name), ["A", "B", "C"])
  }

  func testMismatchedCoreCountDegradesToNoSplit() {
    // The counts not summing to the array length means the index ranges cannot be established.
    // Degrade to total-only rather than mislabel half the cores.
    XCTAssertTrue(
      CPUTopology.clusters(
        perfLevels: [PerfLevel(name: "Performance", logicalCPUs: 6),
                     PerfLevel(name: "Efficiency", logicalCPUs: 4)],
        totalCores: 12
      ).isEmpty)
  }

  func testSingleLevelDegradesToNoSplit() {
    XCTAssertTrue(
      CPUTopology.clusters(
        perfLevels: [PerfLevel(name: "Performance", logicalCPUs: 8)], totalCores: 8
      ).isEmpty)
  }

  func testEmptyLevelsDegradeToNoSplit() {
    XCTAssertTrue(CPUTopology.clusters(perfLevels: [], totalCores: 12).isEmpty)
  }

  func testZeroSizedLevelDegradesToNoSplit() {
    XCTAssertTrue(
      CPUTopology.clusters(
        perfLevels: [PerfLevel(name: "Performance", logicalCPUs: 12),
                     PerfLevel(name: "Efficiency", logicalCPUs: 0)],
        totalCores: 12
      ).isEmpty)
  }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd /Users/christiannucifora/Documents/dev/personal/islet && xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`

Expected: compilation fails. The tail contains `error: cannot find 'CPUTopology' in scope` and does **not** contain `** TEST SUCCEEDED **`.

- [ ] **Step 3: Create the topology mapping**

Create `Islet/Activities/System/CPUTopology.swift`:

```swift
import Darwin
import Foundation

/// One `hw.perflevelN` entry: its label and how many logical CPUs it owns.
struct PerfLevel: Equatable, Sendable {
  let name: String
  let logicalCPUs: Int
}

/// A perf level mapped onto a contiguous run of indices in `host_processor_info`'s array.
struct CPUCluster: Equatable, Sendable {
  /// Index into `hw.perflevelN.*`. 0 is always the most performant cluster.
  let perfLevelIndex: Int
  let name: String
  /// Indices into `host_processor_info`'s per-core array.
  let range: Range<Int>

  var isPerformance: Bool { perfLevelIndex == 0 }
}

enum CPUTopology {
  /// Reads `hw.nperflevels` and each level's name and logical CPU count.
  static func perfLevels() -> [PerfLevel] {
    guard let count = sysctlInt32("hw.nperflevels"), count > 0 else { return [] }
    var out: [PerfLevel] = []
    for index in 0..<count {
      guard let name = sysctlString("hw.perflevel\(index).name"),
        let logical = sysctlInt32("hw.perflevel\(index).logicalcpu")
      else { return [] }
      out.append(PerfLevel(name: name, logicalCPUs: logical))
    }
    return out
  }

  /// Maps perf levels onto index ranges.
  ///
  /// `hw.perflevelN` gives labels and counts but NOT the index ranges. Verified empirically on
  /// M3 Pro (see Task 8 of the Phase 4 plan): `host_processor_info` orders the LEAST performant
  /// cluster FIRST — a `.background`-QoS spin saturates indices 0...5 while `hw.perflevel1` is
  /// "Efficiency", and a `.userInteractive` spin saturates 6...11. So level N-1 occupies
  /// `[0, count(N-1))` and level 0 occupies the tail.
  ///
  /// Returns `[]` — total-only, no split — whenever the mapping cannot be established: fewer than
  /// two levels, a zero-sized level, or counts that do not sum to `totalCores`.
  static func clusters(perfLevels: [PerfLevel], totalCores: Int) -> [CPUCluster] {
    guard perfLevels.count >= 2, totalCores > 0,
      perfLevels.allSatisfy({ $0.logicalCPUs > 0 }),
      perfLevels.reduce(0, { $0 + $1.logicalCPUs }) == totalCores
    else { return [] }

    var out: [CPUCluster] = []
    var cursor = 0
    for index in stride(from: perfLevels.count - 1, through: 0, by: -1) {
      let level = perfLevels[index]
      out.append(
        CPUCluster(
          perfLevelIndex: index, name: level.name,
          range: cursor..<(cursor + level.logicalCPUs)))
      cursor += level.logicalCPUs
    }
    // Built least-performant-first to walk the array; returned most-performant-first for display.
    return out.reversed()
  }

  /// This machine's clusters, or `[]` when the split cannot be established.
  static func current() -> [CPUCluster] {
    clusters(perfLevels: perfLevels(), totalCores: ProcessInfo.processInfo.processorCount)
  }
}

/// Reads a 32-bit integer sysctl. Nil when the name does not exist on this hardware.
func sysctlInt32(_ name: String) -> Int? {
  var value: Int32 = 0
  var size = MemoryLayout<Int32>.size
  guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
  return Int(value)
}

/// Reads a string sysctl. Nil when the name does not exist on this hardware.
func sysctlString(_ name: String) -> String? {
  var size = 0
  guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
  var buffer = [CChar](repeating: 0, count: size)
  guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
  return String(cString: buffer)
}
```

- [ ] **Step 4: Regenerate the project so the new source file joins the target**

Run: `cd /Users/christiannucifora/Documents/dev/personal/islet && xcodegen generate`

Expected: `Created project at .../Islet.xcodeproj`.

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd /Users/christiannucifora/Documents/dev/personal/islet && xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`

Expected: `** TEST SUCCEEDED **`, 115 tests.

- [ ] **Step 6: Commit**

```bash
cd /Users/christiannucifora/Documents/dev/personal/islet
git add Islet/Activities/System/CPUTopology.swift IsletTests/SystemMetricsTests.swift Islet.xcodeproj
git commit -m "System: map hw.perflevel clusters onto host_processor_info index ranges"
```

---

### Task 7: SystemMetricsReader — one free function per kernel source

**Files:**
- Create: `Islet/Activities/System/SystemMetricsReader.swift`
- Modify: `IsletTests/SystemMetricsTests.swift`

**Interfaces:**
- Consumes: `CPUTicks`, `IORegistryReader.properties(matching:)`, `IORegistryReader.allProperties(matching:)`, `sysctlInt32(_:)`.
- Produces:
  - `struct MemorySnapshot: Equatable, Sendable { var usedBytes: UInt64; var totalBytes: UInt64; var wiredBytes: UInt64; var compressedBytes: UInt64 }`
  - `struct DiskCounters: Equatable, Sendable { var readBytes: UInt64; var writeBytes: UInt64 }`
  - `struct NetworkCounters: Equatable, Sendable { var inBytes: UInt64; var outBytes: UInt64; var interface: String }`
  - `struct RawCounters: Equatable, Sendable { … static func read() -> RawCounters }`
  - `enum SystemMetricsReader` with `cpuTicks()`, `memory()`, `memoryPressureLevel()`, `swapUsedBytes()`, `loadAverage()`, `gpuUtilisation()`, `diskCounters()`, `diskFreeBytes()`, `primaryInterfaceName()`, `networkCounters()`, `thermalState()`, `batteryTemperatureC()`

- [ ] **Step 1: Write the failing tests**

These are live-hardware sanity checks with deliberately loose bounds — they prove the kernel calls return something usable, not that a particular number is correct. Append to `IsletTests/SystemMetricsTests.swift`, inside the class, before the closing brace:

```swift
  // MARK: - Live reader sanity

  func testCPUTicksReturnsOnePerLogicalCore() {
    let ticks = SystemMetricsReader.cpuTicks()
    XCTAssertFalse(ticks.isEmpty)
    XCTAssertEqual(ticks.count, ProcessInfo.processInfo.processorCount)
  }

  func testMemorySnapshotIsPlausible() {
    guard let memory = SystemMetricsReader.memory() else {
      return XCTFail("host_statistics64 returned nothing")
    }
    XCTAssertGreaterThan(memory.totalBytes, 0)
    XCTAssertGreaterThan(memory.usedBytes, 0)
    XCTAssertLessThanOrEqual(memory.usedBytes, memory.totalBytes)
    XCTAssertLessThanOrEqual(memory.wiredBytes, memory.usedBytes)
  }

  func testThermalStateIsAValidRawValue() {
    XCTAssertTrue((0...3).contains(SystemMetricsReader.thermalState()))
  }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd /Users/christiannucifora/Documents/dev/personal/islet && xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`

Expected: compilation fails. The tail contains `error: cannot find 'SystemMetricsReader' in scope` and does **not** contain `** TEST SUCCEEDED **`.

- [ ] **Step 3: Create the reader**

Create `Islet/Activities/System/SystemMetricsReader.swift`:

```swift
import Darwin
import Foundation
import IOKit
import SystemConfiguration

struct MemorySnapshot: Equatable, Sendable {
  var usedBytes: UInt64
  var totalBytes: UInt64
  var wiredBytes: UInt64
  var compressedBytes: UInt64
}

struct DiskCounters: Equatable, Sendable {
  var readBytes: UInt64
  var writeBytes: UInt64
}

struct NetworkCounters: Equatable, Sendable {
  var inBytes: UInt64
  var outBytes: UInt64
  var interface: String
}

/// One un-differenced read of every source. Sendable and actor-free so the monitor can gather it
/// on a background task and hand it back to the main actor.
struct RawCounters: Equatable, Sendable {
  var cpu: [CPUTicks] = []
  var memory: MemorySnapshot?
  var memoryPressureLevel: Int?
  var swapUsedBytes: UInt64?
  var loadAverage: Double?
  var gpu: Double?
  var disk: DiskCounters?
  var diskFreeBytes: UInt64?
  var network: NetworkCounters?
  var thermalState: Int = 0
  var batteryTemperatureC: Double?

  /// Measured at ~0.10 ms total on M3 Pro. Safe to call off the main thread.
  static func read() -> RawCounters {
    RawCounters(
      cpu: SystemMetricsReader.cpuTicks(),
      memory: SystemMetricsReader.memory(),
      memoryPressureLevel: SystemMetricsReader.memoryPressureLevel(),
      swapUsedBytes: SystemMetricsReader.swapUsedBytes(),
      loadAverage: SystemMetricsReader.loadAverage(),
      gpu: SystemMetricsReader.gpuUtilisation(),
      disk: SystemMetricsReader.diskCounters(),
      diskFreeBytes: SystemMetricsReader.diskFreeBytes(),
      network: SystemMetricsReader.networkCounters(),
      thermalState: SystemMetricsReader.thermalState(),
      batteryTemperatureC: SystemMetricsReader.batteryTemperatureC())
  }
}

/// Raw kernel reads. No state, no isolation, no differencing — every rate is derived elsewhere.
enum SystemMetricsReader {

  // MARK: - CPU

  static func cpuTicks() -> [CPUTicks] {
    var count: natural_t = 0
    var info: processor_info_array_t?
    var infoCount: mach_msg_type_number_t = 0
    guard
      host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount)
        == KERN_SUCCESS,
      let info
    else { return [] }
    // MANDATORY. The kernel vm_allocate's this array on every call. Measured on M3 Pro:
    // infoCount = 48 integer_t = 192 bytes a sample, ~11 MB a day at 1 Hz if this is skipped.
    defer {
      vm_deallocate(
        mach_task_self_, vm_address_t(UInt(bitPattern: info)),
        vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
    }
    var out: [CPUTicks] = []
    out.reserveCapacity(Int(count))
    for core in 0..<Int(count) {
      let base = core * Int(CPU_STATE_MAX)
      // The array is integer_t (Int32) but the counters are unsigned; reinterpret the bits so a
      // counter past 2^31 does not read as negative.
      out.append(
        CPUTicks(
          user: UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]),
          system: UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]),
          idle: UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]),
          nice: UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)])))
    }
    return out
  }

  static func loadAverage() -> Double? {
    var loads = [Double](repeating: 0, count: 3)
    guard getloadavg(&loads, 3) == 3 else { return nil }
    return loads[0]
  }

  // MARK: - Memory

  static func memory() -> MemorySnapshot? {
    var size = mach_msg_type_number_t(
      MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
    var stats = vm_statistics64_data_t()
    let result = withUnsafeMutablePointer(to: &stats) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
        host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &size)
      }
    }
    guard result == KERN_SUCCESS else { return nil }
    let page = UInt64(vm_kernel_page_size)
    let wired = UInt64(stats.wire_count) * page
    let compressed = UInt64(stats.compressor_page_count) * page
    let active = UInt64(stats.active_count) * page
    // active + wired + compressed is the figure Activity Monitor calls "Memory Used".
    return MemorySnapshot(
      usedBytes: active + wired + compressed,
      totalBytes: ProcessInfo.processInfo.physicalMemory,
      wiredBytes: wired,
      compressedBytes: compressed)
  }

  /// 1 = normal, 2 = warning, 4 = critical.
  static func memoryPressureLevel() -> Int? { sysctlInt32("kern.memorystatus_vm_pressure_level") }

  static func swapUsedBytes() -> UInt64? {
    var usage = xsw_usage()
    var size = MemoryLayout<xsw_usage>.size
    guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return nil }
    return usage.xsu_used
  }

  // MARK: - GPU

  /// `IOAccelerator` → `PerformanceStatistics` → `Device Utilization %`. Verified against
  /// `ioreg -r -c IOAccelerator`, which reports one `AGXAcceleratorG15X` node on M3 Pro.
  static func gpuUtilisation() -> Double? {
    guard let properties = IORegistryReader.properties(matching: "IOAccelerator"),
      let statistics = properties["PerformanceStatistics"] as? [String: Any],
      let value = statistics["Device Utilization %"] as? NSNumber
    else { return nil }
    return min(max(value.doubleValue / 100, 0), 1)
  }

  // MARK: - Disk

  /// Sums `Bytes (Read)` / `Bytes (Write)` across every `IOBlockStorageDriver` node.
  ///
  /// Deliberate choice: SUM, do not filter. `ioreg -r -c IOBlockStorageDriver` returns four nodes
  /// on this machine — one all-zero placeholder, the internal SSD, and two small read-only images.
  /// The all-zero node contributes nothing to a delta by construction, and the read-only images
  /// are real I/O that belongs in the total. Filtering by "biggest node" would silently drop a
  /// second physical drive.
  static func diskCounters() -> DiskCounters? {
    let nodes = IORegistryReader.allProperties(matching: "IOBlockStorageDriver")
    var read: UInt64 = 0
    var write: UInt64 = 0
    var found = false
    for node in nodes {
      guard let statistics = node["Statistics"] as? [String: Any] else { continue }
      found = true
      read &+= (statistics["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
      write &+= (statistics["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
    }
    return found ? DiskCounters(readBytes: read, writeBytes: write) : nil
  }

  static func diskFreeBytes() -> UInt64? {
    guard
      let values = try? URL(fileURLWithPath: "/").resourceValues(
        forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
      let available = values.volumeAvailableCapacityForImportantUsage, available > 0
    else { return nil }
    return UInt64(available)
  }

  // MARK: - Network

  /// The interface holding the default IPv4 route, via public SystemConfiguration. Verified to
  /// return "en6" on this machine.
  static func primaryInterfaceName() -> String? {
    guard let store = SCDynamicStoreCreate(nil, "dev.cnucifora.Islet" as CFString, nil, nil),
      let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString)
        as? [String: Any],
      let name = global["PrimaryInterface"] as? String
    else { return nil }
    return name
  }

  static func networkCounters() -> NetworkCounters? {
    guard let name = primaryInterfaceName() ?? fallbackInterfaceName() else { return nil }
    var addresses: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&addresses) == 0, let first = addresses else { return nil }
    defer { freeifaddrs(addresses) }
    var cursor: UnsafeMutablePointer<ifaddrs>? = first
    while let node = cursor {
      let entry = node.pointee
      defer { cursor = entry.ifa_next }
      guard entry.ifa_addr?.pointee.sa_family == UInt8(AF_LINK),
        String(cString: entry.ifa_name) == name,
        let data = entry.ifa_data
      else { continue }
      let stats = data.assumingMemoryBound(to: if_data.self).pointee
      // ifi_ibytes / ifi_obytes are UInt32 and wrap. Widen here; difference at 32 bits later.
      return NetworkCounters(
        inBytes: UInt64(stats.ifi_ibytes), outBytes: UInt64(stats.ifi_obytes), interface: name)
    }
    return nil
  }

  /// Used only when SystemConfiguration has no primary interface (no route, or a captive setup):
  /// the busiest `en*` link that is up and running.
  private static func fallbackInterfaceName() -> String? {
    var addresses: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&addresses) == 0, let first = addresses else { return nil }
    defer { freeifaddrs(addresses) }
    var best: (name: String, bytes: UInt32)?
    var cursor: UnsafeMutablePointer<ifaddrs>? = first
    while let node = cursor {
      let entry = node.pointee
      defer { cursor = entry.ifa_next }
      let name = String(cString: entry.ifa_name)
      guard entry.ifa_addr?.pointee.sa_family == UInt8(AF_LINK), name.hasPrefix("en"),
        entry.ifa_flags & UInt32(IFF_UP) != 0, entry.ifa_flags & UInt32(IFF_RUNNING) != 0,
        let data = entry.ifa_data
      else { continue }
      let bytes = data.assumingMemoryBound(to: if_data.self).pointee.ifi_ibytes
      if let current = best {
        if bytes > current.bytes { best = (name, bytes) }
      } else {
        best = (name, bytes)
      }
    }
    return best?.name
  }

  // MARK: - Thermal

  /// 0 nominal, 1 fair, 2 serious, 3 critical.
  static func thermalState() -> Int { ProcessInfo.processInfo.thermalState.rawValue }

  /// `AppleSmartBattery` → `Temperature`, in centi-degrees. Verified: 3056 → 30.56 °C.
  static func batteryTemperatureC() -> Double? {
    guard let properties = IORegistryReader.properties(matching: "AppleSmartBattery"),
      let raw = (properties["Temperature"] as? NSNumber)?.doubleValue, raw > 0
    else { return nil }
    return raw / 100
  }
}
```

- [ ] **Step 4: Regenerate the project so the new source file joins the target**

Run: `cd /Users/christiannucifora/Documents/dev/personal/islet && xcodegen generate`

Expected: `Created project at .../Islet.xcodeproj`.

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd /Users/christiannucifora/Documents/dev/personal/islet && xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`

Expected: `** TEST SUCCEEDED **`, 118 tests.

If the build fails with `error: call to main actor-isolated static method 'properties(matching:)' in a synchronous nonisolated context`, Phase 1 landed `IORegistryReader` as `@MainActor`. Remove that annotation from `Islet/Core/IORegistryReader.swift` — it is a stateless enum of static functions and the codebase rule is that pure logic types stay actor-free — then re-run.

- [ ] **Step 6: Commit**

```bash
cd /Users/christiannucifora/Documents/dev/personal/islet
git add Islet/Activities/System/SystemMetricsReader.swift IsletTests/SystemMetricsTests.swift Islet.xcodeproj
git commit -m "System: read CPU, memory, GPU, disk, network and thermal counters"
```

---

### Task 8: Verify the P-core / E-core index ordering empirically

**Files:**
- Create: `/private/tmp/claude-501/-Users-christiannucifora-Documents-dev-personal-islet/a0567d25-d2f1-4dfe-8eb9-1177c26dd3e4/scratchpad/p4cluster.swift` (scratch only — never committed)
- Possibly modify: `Islet/Activities/System/CPUTopology.swift:60-75`

**Interfaces:**
- Consumes: nothing (standalone script).
- Produces: nothing. This task either confirms Task 6's mapping or inverts it.

**No unit test — this is a hardware property, not program logic.** A CI-run load test would be flaky. Verified by running a controlled load and reading the per-core deltas.

- [ ] **Step 1: Write the probe**

Write this to the scratchpad as `p4cluster.swift`:

```swift
import Darwin
import Foundation

func ticks() -> [(busy: UInt64, total: UInt64)] {
  var count: natural_t = 0
  var info: processor_info_array_t?
  var infoCount: mach_msg_type_number_t = 0
  guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount)
    == KERN_SUCCESS, let info
  else { return [] }
  defer {
    vm_deallocate(
      mach_task_self_, vm_address_t(UInt(bitPattern: info)),
      vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
  }
  var out: [(UInt64, UInt64)] = []
  for i in 0..<Int(count) {
    let b = i * Int(CPU_STATE_MAX)
    let user = UInt64(UInt32(bitPattern: info[b + Int(CPU_STATE_USER)]))
    let sys = UInt64(UInt32(bitPattern: info[b + Int(CPU_STATE_SYSTEM)]))
    let idle = UInt64(UInt32(bitPattern: info[b + Int(CPU_STATE_IDLE)]))
    let nice = UInt64(UInt32(bitPattern: info[b + Int(CPU_STATE_NICE)]))
    out.append((user + sys + nice, user + sys + nice + idle))
  }
  return out
}

func spin(qos: DispatchQoS.QoSClass, threads: Int, seconds: Double) {
  for _ in 0..<threads {
    DispatchQueue.global(qos: qos).async {
      let end = Date().addingTimeInterval(seconds)
      var x = 0.0
      while Date() < end { x += Double.random(in: 0...1).squareRoot() }
      if x < 0 { print(x) }
    }
  }
}

func measure(label: String, qos: DispatchQoS.QoSClass) {
  let a = ticks()
  spin(qos: qos, threads: 6, seconds: 3.0)
  Thread.sleep(forTimeInterval: 3.2)
  let b = ticks()
  var deltas: [Double] = []
  for i in 0..<min(a.count, b.count) {
    let db = Double(b[i].busy &- a[i].busy)
    let dt = Double(b[i].total &- a[i].total)
    deltas.append(dt > 0 ? db / dt : 0)
  }
  print("\(label): \(deltas.map { String(format: "%.2f", $0) }.joined(separator: " "))")
  let half = deltas.count / 2
  let lower = deltas[0..<half].reduce(0, +) / Double(half)
  let upper = deltas[half...].reduce(0, +) / Double(deltas.count - half)
  print(String(format: "   lower-half avg=%.2f  upper-half avg=%.2f", lower, upper))
}

measure(label: "userInteractive (P-cores)", qos: .userInteractive)
measure(label: "background      (E-cores)", qos: .background)
```

- [ ] **Step 2: Compile and run it twice**

Run (substituting your scratchpad path):

```bash
cd /private/tmp/claude-501/-Users-christiannucifora-Documents-dev-personal-islet/a0567d25-d2f1-4dfe-8eb9-1177c26dd3e4/scratchpad
swiftc -O p4cluster.swift -o p4cluster && ./p4cluster && ./p4cluster
```

Expected on this machine (measured twice while writing this plan):

```
userInteractive (P-cores): 0.56 0.41 0.31 0.27 0.20 0.16 0.92 0.93 0.93 0.92 0.93 0.92
   lower-half avg=0.32  upper-half avg=0.93
background      (E-cores): 0.97 0.96 0.95 0.95 0.94 0.93 0.10 0.23 0.26 0.06 0.26 0.07
   lower-half avg=0.95  upper-half avg=0.16
```

The interpretation: `.background` QoS runs on efficiency cores and it saturates the LOWER half. `hw.perflevel0.name` is "Performance". Therefore `host_processor_info` orders the least performant cluster first, which is what `CPUTopology.clusters` implements.

- [ ] **Step 3: Decide**

- **If both runs show `lower-half avg ≥ 0.85` under `background` and `upper-half avg ≥ 0.85` under `userInteractive`:** the mapping in `CPUTopology.clusters` is correct. Change nothing. Tick this step and move on.
- **If the halves are reversed:** this hardware orders the most performant cluster first. In `Islet/Activities/System/CPUTopology.swift`, change the loop to `for index in perfLevels.indices {` (dropping the `stride(...)`) and delete the trailing `.reversed()` on the return, then update `testTwoLevelSplitPutsEfficiencyAtTheStartOfTheArray` and `testThreeLevelSplitAssignsFromLeastPerformant` in `IsletTests/SystemMetricsTests.swift` to the forward ranges, and rename the first test to `testTwoLevelSplitPutsPerformanceAtTheStartOfTheArray`.
- **If neither half saturates, or the two runs disagree:** the mapping cannot be established on this hardware. Make `CPUTopology.current()` return `[]` unconditionally (`static func current() -> [CPUCluster] { [] }`) with a comment recording what was measured. The P/E row degrades to total-only, which is exactly the designed fallback.

- [ ] **Step 4: Run the full suite to confirm nothing regressed**

Run: `cd /Users/christiannucifora/Documents/dev/personal/islet && xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`

Expected: `** TEST SUCCEEDED **`, 118 tests.

- [ ] **Step 5: Commit (only if Step 3 changed a file)**

If nothing changed, skip this step. Otherwise:

```bash
cd /Users/christiannucifora/Documents/dev/personal/islet
git add Islet/Activities/System/CPUTopology.swift IsletTests/SystemMetricsTests.swift
git commit -m "System: correct the perf-level to core-index mapping against measured load"
```

---

### Task 9: The sample builder

**Files:**
- Create: `Islet/Activities/System/SystemSampleBuilder.swift`
- Modify: `IsletTests/SystemMetricsTests.swift`

**Interfaces:**
- Consumes: `RawCounters`, `CPUCluster`, `CPUTicks`, `SystemMetricsSample`, `cpuUtilisation(from:to:indices:)`, `ratePerSecond(from:to:elapsed:width:)`, `metricsMaxSampleGap`.
- Produces:
  - `func systemMetricsSample(previous: RawCounters?, previousDate: Date?, current: RawCounters, currentDate: Date, clusters: [CPUCluster]) -> SystemMetricsSample`

- [ ] **Step 1: Write the failing tests**

Append to `IsletTests/SystemMetricsTests.swift`, inside the class, before the closing brace:

```swift
  // MARK: - Sample building

  private func raw(
    cpu: [CPUTicks] = [], disk: DiskCounters? = nil, network: NetworkCounters? = nil
  ) -> RawCounters {
    RawCounters(
      cpu: cpu,
      memory: MemorySnapshot(
        usedBytes: 8_000_000_000, totalBytes: 16_000_000_000,
        wiredBytes: 2_000_000_000, compressedBytes: 1_000_000_000),
      memoryPressureLevel: 1,
      swapUsedBytes: 12_582_912,
      loadAverage: 3.51,
      gpu: 0.12,
      disk: disk,
      diskFreeBytes: 412_000_000_000,
      network: network,
      thermalState: 0,
      batteryTemperatureC: 30.56)
  }

  func testLevelsArePresentEvenWithoutAPreviousSample() {
    let now = Date()
    let sample = systemMetricsSample(
      previous: nil, previousDate: nil, current: raw(), currentDate: now, clusters: [])
    XCTAssertEqual(sample.memoryUsedBytes, 8_000_000_000)
    XCTAssertEqual(sample.memoryTotalBytes, 16_000_000_000)
    XCTAssertEqual(sample.gpu, 0.12)
    XCTAssertEqual(sample.loadAverage, 3.51)
    XCTAssertEqual(sample.thermalState, 0)
    XCTAssertEqual(sample.diskFreeBytes, 412_000_000_000)
    XCTAssertEqual(sample.swapUsedBytes, 12_582_912)
    XCTAssertEqual(sample.memoryPressureLevel, 1)
    XCTAssertEqual(sample.batteryTemperatureC, 30.56)
  }

  func testFirstSampleHasNoRates() {
    let now = Date()
    let sample = systemMetricsSample(
      previous: nil, previousDate: nil,
      current: raw(
        cpu: [CPUTicks(user: 1, system: 1, idle: 1, nice: 0)],
        disk: DiskCounters(readBytes: 100, writeBytes: 100),
        network: NetworkCounters(inBytes: 100, outBytes: 100, interface: "en0")),
      currentDate: now, clusters: [])
    XCTAssertNil(sample.cpuTotal)
    XCTAssertNil(sample.diskReadBytesPerSec)
    XCTAssertNil(sample.netInBytesPerSec)
    XCTAssertEqual(sample.primaryInterface, "en0")
  }

  func testGapLongerThanTheCeilingDiscardsRates() {
    let then = Date()
    let now = then.addingTimeInterval(metricsMaxSampleGap + 1)
    let sample = systemMetricsSample(
      previous: raw(
        cpu: [CPUTicks(user: 0, system: 0, idle: 0, nice: 0)],
        disk: DiskCounters(readBytes: 0, writeBytes: 0),
        network: NetworkCounters(inBytes: 0, outBytes: 0, interface: "en0")),
      previousDate: then,
      current: raw(
        cpu: [CPUTicks(user: 500, system: 0, idle: 500, nice: 0)],
        disk: DiskCounters(readBytes: 9_000_000_000, writeBytes: 9_000_000_000),
        network: NetworkCounters(inBytes: 900_000, outBytes: 900_000, interface: "en0")),
      currentDate: now, clusters: [])
    XCTAssertNil(sample.cpuTotal)
    XCTAssertNil(sample.diskReadBytesPerSec)
    XCTAssertNil(sample.diskWriteBytesPerSec)
    XCTAssertNil(sample.netInBytesPerSec)
    XCTAssertNil(sample.netOutBytesPerSec)
    // Levels survive a gap — only rates are meaningless.
    XCTAssertEqual(sample.gpu, 0.12)
  }

  func testNormalDeltaProducesDiskAndNetworkRates() {
    let then = Date()
    let now = then.addingTimeInterval(2)
    let sample = systemMetricsSample(
      previous: raw(
        disk: DiskCounters(readBytes: 1_000, writeBytes: 2_000),
        network: NetworkCounters(inBytes: 4_000, outBytes: 8_000, interface: "en0")),
      previousDate: then,
      current: raw(
        disk: DiskCounters(readBytes: 3_000, writeBytes: 2_400),
        network: NetworkCounters(inBytes: 4_200, outBytes: 8_600, interface: "en0")),
      currentDate: now, clusters: [])
    XCTAssertEqual(sample.diskReadBytesPerSec ?? -1, 1000, accuracy: 1e-9)
    XCTAssertEqual(sample.diskWriteBytesPerSec ?? -1, 200, accuracy: 1e-9)
    XCTAssertEqual(sample.netInBytesPerSec ?? -1, 100, accuracy: 1e-9)
    XCTAssertEqual(sample.netOutBytesPerSec ?? -1, 300, accuracy: 1e-9)
  }

  func testInterfaceChangeDiscardsNetworkRates() {
    // Wi-Fi to Ethernet: the two counters belong to different NICs and cannot be differenced.
    let then = Date()
    let sample = systemMetricsSample(
      previous: raw(network: NetworkCounters(inBytes: 9_000, outBytes: 9_000, interface: "en0")),
      previousDate: then,
      current: raw(network: NetworkCounters(inBytes: 10, outBytes: 10, interface: "en6")),
      currentDate: then.addingTimeInterval(1), clusters: [])
    XCTAssertNil(sample.netInBytesPerSec)
    XCTAssertNil(sample.netOutBytesPerSec)
    XCTAssertEqual(sample.primaryInterface, "en6")
  }

  func testClusterUtilisationsAreSplitByRange() {
    let then = Date()
    let idle = CPUTicks(user: 0, system: 0, idle: 0, nice: 0)
    let busy = CPUTicks(user: 100, system: 0, idle: 0, nice: 0)
    let quiet = CPUTicks(user: 0, system: 0, idle: 100, nice: 0)
    let sample = systemMetricsSample(
      previous: raw(cpu: [idle, idle, idle, idle]),
      previousDate: then,
      current: raw(cpu: [quiet, quiet, busy, busy]),
      currentDate: then.addingTimeInterval(1),
      clusters: [
        CPUCluster(perfLevelIndex: 0, name: "Performance", range: 2..<4),
        CPUCluster(perfLevelIndex: 1, name: "Efficiency", range: 0..<2),
      ])
    XCTAssertEqual(sample.cpuTotal ?? -1, 0.5, accuracy: 1e-9)
    XCTAssertEqual(sample.cpuPerformance ?? -1, 1.0, accuracy: 1e-9)
    XCTAssertEqual(sample.cpuEfficiency ?? -1, 0.0, accuracy: 1e-9)
  }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd /Users/christiannucifora/Documents/dev/personal/islet && xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`

Expected: compilation fails. The tail contains `error: cannot find 'systemMetricsSample' in scope` and does **not** contain `** TEST SUCCEEDED **`.

- [ ] **Step 3: Create the sample builder**

Create `Islet/Activities/System/SystemSampleBuilder.swift`:

```swift
import Foundation

/// Turns two raw counter snapshots plus the time between them into one publishable sample.
///
/// Levels (memory, GPU, load, thermal, free space) come straight from `current` and are always
/// present. Rates (CPU, disk, network) need a usable previous snapshot: they are nil on the first
/// sample and after any gap longer than `metricsMaxSampleGap`, so a resume from sleep draws a
/// break in the series rather than a spike.
func systemMetricsSample(
  previous: RawCounters?, previousDate: Date?, current: RawCounters, currentDate: Date,
  clusters: [CPUCluster]
) -> SystemMetricsSample {
  var sample = SystemMetricsSample()
  sample.loadAverage = current.loadAverage
  sample.gpu = current.gpu
  sample.thermalState = current.thermalState
  sample.batteryTemperatureC = current.batteryTemperatureC
  sample.memoryPressureLevel = current.memoryPressureLevel
  sample.swapUsedBytes = current.swapUsedBytes
  sample.diskFreeBytes = current.diskFreeBytes
  sample.primaryInterface = current.network?.interface
  if let memory = current.memory {
    sample.memoryUsedBytes = memory.usedBytes
    sample.memoryTotalBytes = memory.totalBytes
    sample.memoryWiredBytes = memory.wiredBytes
    sample.memoryCompressedBytes = memory.compressedBytes
  }

  guard let previous, let previousDate else { return sample }
  let elapsed = currentDate.timeIntervalSince(previousDate)
  guard elapsed > 0, elapsed <= metricsMaxSampleGap else { return sample }

  if !current.cpu.isEmpty, previous.cpu.count == current.cpu.count {
    sample.cpuTotal = cpuUtilisation(
      from: previous.cpu, to: current.cpu, indices: 0..<current.cpu.count)
    for cluster in clusters {
      guard cluster.range.upperBound <= current.cpu.count else { continue }
      let value = cpuUtilisation(from: previous.cpu, to: current.cpu, indices: cluster.range)
      if cluster.isPerformance {
        sample.cpuPerformance = value
      } else {
        sample.cpuEfficiency = value
      }
    }
  }

  if let old = previous.disk, let new = current.disk {
    sample.diskReadBytesPerSec = ratePerSecond(
      from: old.readBytes, to: new.readBytes, elapsed: elapsed, width: .bits64)
    sample.diskWriteBytesPerSec = ratePerSecond(
      from: old.writeBytes, to: new.writeBytes, elapsed: elapsed, width: .bits64)
  }

  // A different NIC means the two counters are unrelated; differencing them invents traffic.
  if let old = previous.network, let new = current.network, old.interface == new.interface {
    sample.netInBytesPerSec = ratePerSecond(
      from: old.inBytes, to: new.inBytes, elapsed: elapsed, width: .bits32)
    sample.netOutBytesPerSec = ratePerSecond(
      from: old.outBytes, to: new.outBytes, elapsed: elapsed, width: .bits32)
  }

  return sample
}
```

- [ ] **Step 4: Regenerate the project so the new source file joins the target**

Run: `cd /Users/christiannucifora/Documents/dev/personal/islet && xcodegen generate`

Expected: `Created project at .../Islet.xcodeproj`.

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd /Users/christiannucifora/Documents/dev/personal/islet && xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`

Expected: `** TEST SUCCEEDED **`, 124 tests.

- [ ] **Step 6: Commit**

```bash
cd /Users/christiannucifora/Documents/dev/personal/islet
git add Islet/Activities/System/SystemSampleBuilder.swift IsletTests/SystemMetricsTests.swift Islet.xcodeproj
git commit -m "System: build one sample from two counter snapshots and the elapsed time"
```

---

### Task 10: SystemPresenceGate

**Files:**
- Create: `Islet/Activities/System/SystemPresenceGate.swift`
- Create: `IsletTests/SystemActivityGateTests.swift`

**Interfaces:**
- Consumes: `ThresholdDetector(thresholds:direction:)`, `ThresholdDetector.crossings(from:to:)` (Phase 1.6).
- Produces:
  - `struct SystemPresenceGate: Equatable` with `enum Reason { case cpu, thermal }`, `static let activateCPU/deactivateCPU/sustainSamples`, `private(set) var isActive: Bool`, `private(set) var reason: Reason?`, `mutating func update(cpuTotal: Double?, thermalState: Int) -> Bool`

- [ ] **Step 1: Write the failing test**

Create `IsletTests/SystemActivityGateTests.swift`:

```swift
import XCTest

@testable import Islet

final class SystemActivityGateTests: XCTestCase {

  /// Feeds `count` identical CPU samples with a nominal thermal state, returning the last result.
  @discardableResult
  private func feed(_ gate: inout SystemPresenceGate, cpu: Double, count: Int) -> Bool {
    var changed = false
    for _ in 0..<count { changed = gate.update(cpuTotal: cpu, thermalState: 0) }
    return changed
  }

  func testFreshGateIsInactive() {
    let gate = SystemPresenceGate()
    XCTAssertFalse(gate.isActive)
    XCTAssertNil(gate.reason)
  }

  func testSustainedHighCPUActivatesOnlyOnTheFifthSample() {
    var gate = SystemPresenceGate()
    for _ in 0..<(SystemPresenceGate.sustainSamples - 1) {
      XCTAssertFalse(gate.update(cpuTotal: 0.9, thermalState: 0))
      XCTAssertFalse(gate.isActive)
    }
    XCTAssertTrue(gate.update(cpuTotal: 0.9, thermalState: 0))
    XCTAssertTrue(gate.isActive)
    XCTAssertEqual(gate.reason, .cpu)
  }

  func testInterruptedStreakRestarts() {
    var gate = SystemPresenceGate()
    feed(&gate, cpu: 0.9, count: 4)
    gate.update(cpuTotal: 0.7, thermalState: 0)  // breaks the streak without deactivating
    feed(&gate, cpu: 0.9, count: 4)
    XCTAssertFalse(gate.isActive)
    XCTAssertTrue(gate.update(cpuTotal: 0.9, thermalState: 0))
    XCTAssertTrue(gate.isActive)
  }

  func testHysteresisBandKeepsAnActiveGateActive() {
    var gate = SystemPresenceGate()
    feed(&gate, cpu: 0.9, count: SystemPresenceGate.sustainSamples)
    XCTAssertFalse(gate.update(cpuTotal: 0.7, thermalState: 0))
    XCTAssertTrue(gate.isActive)
    XCTAssertEqual(gate.reason, .cpu)
  }

  func testFallingBelowReleaseThresholdDeactivates() {
    var gate = SystemPresenceGate()
    feed(&gate, cpu: 0.9, count: SystemPresenceGate.sustainSamples)
    gate.update(cpuTotal: 0.7, thermalState: 0)
    XCTAssertTrue(gate.update(cpuTotal: 0.5, thermalState: 0))
    XCTAssertFalse(gate.isActive)
    XCTAssertNil(gate.reason)
  }

  func testThermalActivatesImmediately() {
    var gate = SystemPresenceGate()
    XCTAssertTrue(gate.update(cpuTotal: 0.02, thermalState: 1))
    XCTAssertTrue(gate.isActive)
    XCTAssertEqual(gate.reason, .thermal)
  }

  func testThermalClearingDeactivatesAThermalActivation() {
    var gate = SystemPresenceGate()
    gate.update(cpuTotal: 0.02, thermalState: 2)
    XCTAssertTrue(gate.update(cpuTotal: 0.02, thermalState: 0))
    XCTAssertFalse(gate.isActive)
    XCTAssertNil(gate.reason)
  }

  func testThermalTakesOverACPUActivationAndReportsTheChange() {
    var gate = SystemPresenceGate()
    feed(&gate, cpu: 0.9, count: SystemPresenceGate.sustainSamples)
    // Still active, but the reason changed — the caller has to redraw the compact glyph.
    XCTAssertTrue(gate.update(cpuTotal: 0.9, thermalState: 1))
    XCTAssertTrue(gate.isActive)
    XCTAssertEqual(gate.reason, .thermal)
  }

  func testCPUMustReearnActivationAfterThermalClears() {
    var gate = SystemPresenceGate()
    feed(&gate, cpu: 0.9, count: SystemPresenceGate.sustainSamples)
    gate.update(cpuTotal: 0.9, thermalState: 1)
    XCTAssertTrue(gate.update(cpuTotal: 0.9, thermalState: 0))  // thermal cleared, drops out
    XCTAssertFalse(gate.isActive)
    feed(&gate, cpu: 0.9, count: SystemPresenceGate.sustainSamples - 2)
    XCTAssertFalse(gate.isActive)
    XCTAssertTrue(gate.update(cpuTotal: 0.9, thermalState: 0))
    XCTAssertTrue(gate.isActive)
    XCTAssertEqual(gate.reason, .cpu)
  }

  func testNilCPUHoldsCurrentState() {
    var gate = SystemPresenceGate()
    feed(&gate, cpu: 0.9, count: SystemPresenceGate.sustainSamples)
    XCTAssertFalse(gate.update(cpuTotal: nil, thermalState: 0))
    XCTAssertTrue(gate.isActive)
  }
}
```

- [ ] **Step 2: Regenerate the project so the new test file joins the target**

Run: `cd /Users/christiannucifora/Documents/dev/personal/islet && xcodegen generate`

Expected: `Created project at .../Islet.xcodeproj`.

- [ ] **Step 3: Run the tests to verify they fail**

Run: `cd /Users/christiannucifora/Documents/dev/personal/islet && xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`

Expected: compilation fails. The tail contains `error: cannot find 'SystemPresenceGate' in scope` and does **not** contain `** TEST SUCCEEDED **`.

- [ ] **Step 4: Create the gate**

Create `Islet/Activities/System/SystemPresenceGate.swift`:

```swift
import Foundation

/// Decides whether the System tab earns a slot in the island.
///
/// A bare Defaults Bool would make this a permanent secondary glyph in `NotchRootView`'s compact
/// row. Combined with a value that changes every second, that drives `onGeometryChange` ->
/// `NotchViewModel.updateCompactWidths` -> `NSPanel.setFrame` once a second, forever. So presence
/// is earned: sustained load, with hysteresis so it cannot flap.
struct SystemPresenceGate: Equatable {
  enum Reason: Equatable, Sendable { case cpu, thermal }

  /// Sustained total CPU fraction that turns the tab on.
  static let activateCPU = 0.80
  /// Falling through this turns it back off. The 20-point band between the two is the hysteresis.
  static let deactivateCPU = 0.60
  /// Consecutive samples above `activateCPU` required. At 1 Hz that is five seconds of real load,
  /// which a single compile or a Spotlight index pass will not fake.
  static let sustainSamples = 5

  private(set) var isActive = false
  private(set) var reason: Reason?
  private var consecutiveHigh = 0
  private var lastCPU: Double?

  /// Activation is a *level* ("sustained above 80%"), so it is a plain comparison. Deactivation
  /// genuinely is an edge, so it goes through the shared Phase 1.6 detector.
  private let release = ThresholdDetector(
    thresholds: [SystemPresenceGate.deactivateCPU], direction: .falling)

  /// Feeds one sample. Returns true when `isActive` OR `reason` changed — the caller redraws the
  /// compact glyph off both, and the two reasons use different SF Symbols.
  mutating func update(cpuTotal: Double?, thermalState: Int) -> Bool {
    let wasActive = isActive
    let wasReason = reason

    if thermalState != 0 {
      isActive = true
      reason = .thermal
      // Do not bank a CPU streak while thermal is holding the tab open; when thermal clears, CPU
      // starts from zero rather than inheriting an unearned five seconds.
      consecutiveHigh = 0
      if let cpuTotal { lastCPU = cpuTotal }
      return isActive != wasActive || reason != wasReason
    }

    // Thermal has cleared. A thermal-driven activation ends here; CPU has to earn its own.
    if reason == .thermal {
      isActive = false
      reason = nil
    }

    guard let cpu = cpuTotal else {
      // No CPU reading — the first sample, or one discarded after a gap. Hold.
      return isActive != wasActive || reason != wasReason
    }

    let crossedDown = !release.crossings(from: lastCPU, to: cpu).isEmpty
    lastCPU = cpu

    if cpu >= Self.activateCPU {
      consecutiveHigh += 1
      if consecutiveHigh >= Self.sustainSamples {
        isActive = true
        reason = .cpu
      }
    } else {
      consecutiveHigh = 0
      if crossedDown || cpu < Self.deactivateCPU {
        isActive = false
        reason = nil
      }
    }

    return isActive != wasActive || reason != wasReason
  }
}
```

- [ ] **Step 5: Regenerate the project so the new source file joins the target**

Run: `cd /Users/christiannucifora/Documents/dev/personal/islet && xcodegen generate`

Expected: `Created project at .../Islet.xcodeproj`.

- [ ] **Step 6: Run tests to verify they pass**

Run: `cd /Users/christiannucifora/Documents/dev/personal/islet && xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`

Expected: `** TEST SUCCEEDED **`, 133 tests.

- [ ] **Step 7: Commit**

```bash
cd /Users/christiannucifora/Documents/dev/personal/islet
git add Islet/Activities/System/SystemPresenceGate.swift IsletTests/SystemActivityGateTests.swift Islet.xcodeproj
git commit -m "System: gate tab presence on sustained load with hysteresis"
```

---

### Task 11: Defaults keys

**Files:**
- Modify: `Islet/Settings/DefaultsKeys.swift:33`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `Defaults.Keys.systemEnabled: Key<Bool>` (default `true`)
  - `Defaults.Keys.systemAlwaysVisible: Key<Bool>` (default `false`)
  - `Defaults.Keys.metricStyles: Key<[String: String]>` (default `[:]`)

**No unit test — verified by build.** `MetricDisplayStyle.resolve` already covers the string→style path (Task 1); these three lines are declarations with no behaviour.

`systemAlwaysVisible` is **not** in the fixed interface contract. It is defined by this plan because the contract's threshold-gated `isActive` makes the System tab unreachable from the switcher until the machine is under load, and there must be a way to look at your own stats on an idle Mac. It defaults to `false`, so the contracted behaviour is what ships out of the box.

- [ ] **Step 1: Add the keys**

In `Islet/Settings/DefaultsKeys.swift`, after line 33 (`static let portsEnabled = ...`) and before the closing brace, add:

```swift
  static let systemEnabled = Key<Bool>("systemEnabled", default: true)
  /// Off: the System tab appears only while `SystemPresenceGate` is hot. On: it is always in the
  /// switcher, which is how you look at an idle machine's stats.
  static let systemAlwaysVisible = Key<Bool>("systemAlwaysVisible", default: false)
  /// Keyed by `SystemMetricKind.rawValue`, valued by `MetricDisplayStyle.rawValue`. Stored as
  /// strings so an unknown value from a future build resolves to the fallback instead of failing
  /// to decode the whole dictionary.
  static let metricStyles = Key<[String: String]>("metricStyles", default: [:])
```

- [ ] **Step 2: Build to verify**

Run: `cd /Users/christiannucifora/Documents/dev/personal/islet && xcodebuild build -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
cd /Users/christiannucifora/Documents/dev/personal/islet
git add Islet/Settings/DefaultsKeys.swift
git commit -m "System: add the system stats defaults keys"
```

---

### Task 12: SystemMetricsMonitor

**Files:**
- Create: `Islet/Activities/System/SystemMetricsMonitor.swift`

**Interfaces:**
- Consumes: `LiveSamplingGate(onChange:)` (Phase 1.4), `RawCounters.read()`, `systemMetricsSample(...)`, `CPUTopology.current()`, `MetricRing`, `SystemMetricsSample`, `SystemMetricKind`.
- Produces:
  - `@MainActor final class SystemMetricsMonitor: ObservableObject` with `static let shared`, `@Published private(set) var sample: SystemMetricsSample`, `@Published private(set) var rings: [SystemMetricKind: MetricRing]`, `private(set) lazy var liveGate: LiveSamplingGate`, `func start()`

**No unit test — verified by build plus the manual check in Step 4.** The class is a timer, an isolation hop and a dictionary write; all of its arithmetic is already covered by Tasks 2–9.

- [ ] **Step 1: Create the monitor**

Create `Islet/Activities/System/SystemMetricsMonitor.swift`:

```swift
import Combine
import Foundation

/// Samples every system source and publishes a snapshot plus a 60-entry history per series.
///
/// Cadence follows the Phase 1.4 refcounted gate: 1 Hz while the System tab is on screen, 5 s
/// otherwise. It never stops, because the ring has to outlive the view — opening the tab to an
/// empty sparkline would defeat the point of having one.
@MainActor
final class SystemMetricsMonitor: ObservableObject {
  static let shared = SystemMetricsMonitor()

  static let ringCapacity = 60

  @Published private(set) var sample = SystemMetricsSample()
  @Published private(set) var rings: [SystemMetricKind: MetricRing] = [:]

  /// Retained by `SystemExpandedView` via `.liveSampling(_:)`.
  private(set) lazy var liveGate = LiveSamplingGate { [weak self] live in
    // The gate is @MainActor and only ever calls this from the main actor.
    MainActor.assumeIsolated { self?.setLive(live) }
  }

  private var timer: AnyCancellable?
  private var previous: RawCounters?
  private var previousDate: Date?
  private var clusters: [CPUCluster] = []
  private var isLive = false
  private var isSampling = false

  func start() {
    clusters = CPUTopology.current()
    restartTimer()
    tick()
  }

  private func setLive(_ live: Bool) {
    guard live != isLive else { return }
    isLive = live
    restartTimer()
    tick()  // don't make the user wait a whole interval for the first fast sample
  }

  private func restartTimer() {
    let interval = isLive ? 1.0 : 5.0
    timer = Timer.publish(every: interval, on: .main, in: .common).autoconnect()
      .sink { [weak self] _ in self?.tick() }
  }

  private func tick() {
    guard !isSampling else { return }
    isSampling = true
    Task { [weak self] in
      await self?.sampleOnce()
      self?.isSampling = false
    }
  }

  private func sampleOnce() async {
    // ~0.10 ms of kernel calls. Off the main thread anyway: it runs during island animations.
    let raw = await Task.detached(priority: .utility) { RawCounters.read() }.value
    let now = Date()
    let next = systemMetricsSample(
      previous: previous, previousDate: previousDate, current: raw, currentDate: now,
      clusters: clusters)
    previous = raw
    previousDate = now
    sample = next
    pushRings(next)
  }

  private func pushRings(_ sample: SystemMetricsSample) {
    push(.cpu, sample.cpuTotal)
    push(.gpu, sample.gpu)
    if let used = sample.memoryUsedBytes, let total = sample.memoryTotalBytes, total > 0 {
      push(.memory, Double(used) / Double(total))
    }
    // Disk and network each have two directions but one series: the sparkline shows total
    // activity, and the numbers beside it already break out the directions.
    if let read = sample.diskReadBytesPerSec, let write = sample.diskWriteBytesPerSec {
      push(.disk, read + write)
    }
    if let inbound = sample.netInBytesPerSec, let outbound = sample.netOutBytesPerSec {
      push(.network, inbound + outbound)
    }
  }

  private func push(_ kind: SystemMetricKind, _ value: Double?) {
    guard let value else { return }
    var ring = rings[kind] ?? MetricRing(capacity: Self.ringCapacity)
    ring.push(value)
    rings[kind] = ring
  }
}
```

- [ ] **Step 2: Regenerate the project so the new source file joins the target**

Run: `cd /Users/christiannucifora/Documents/dev/personal/islet && xcodegen generate`

Expected: `Created project at .../Islet.xcodeproj`.

- [ ] **Step 3: Build to verify**

Run: `cd /Users/christiannucifora/Documents/dev/personal/islet && xcodebuild build -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Run the full suite to confirm nothing regressed**

Run: `cd /Users/christiannucifora/Documents/dev/personal/islet && xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`

Expected: `** TEST SUCCEEDED **`, 133 tests.

- [ ] **Step 5: Commit**

```bash
cd /Users/christiannucifora/Documents/dev/personal/islet
git add Islet/Activities/System/SystemMetricsMonitor.swift Islet.xcodeproj
git commit -m "System: sample metrics off the main thread and publish rings on it"
```

---

### Task 13: SystemActivity

**Files:**
- Create: `Islet/Activities/System/SystemActivity.swift`

**Interfaces:**
- Consumes: `NotchActivity`, `ActivityPriority`, `Metrics.tallExpandedHeight` (Phase 1.2), `SystemMetricsMonitor.shared`, `SystemPresenceGate`, `Defaults[.systemEnabled]`, `Defaults[.systemAlwaysVisible]`, `SystemExpandedView` (Task 14).
- Produces:
  - `@MainActor final class SystemActivity: NotchActivity, ObservableObject` with `let id = "system"`, `var preferredExpandedHeight: CGFloat`, `func start()`

**No unit test — verified by build plus the manual check in Task 15.** The gate logic it drives is fully covered by `SystemActivityGateTests`.

This task creates `SystemActivity.swift`, which references `SystemExpandedView` from Task 14. Build verification for this task is therefore deferred to Task 14 Step 3. Do not try to build between them.

- [ ] **Step 1: Create the activity**

Create `Islet/Activities/System/SystemActivity.swift`:

```swift
import Combine
import Defaults
import SwiftUI

/// The System tab: CPU, GPU, RAM, disk, network and thermal in a 250 pt-tall expanded island.
@MainActor
final class SystemActivity: NotchActivity, ObservableObject {
  let id = "system"
  let priority = ActivityPriority.ambient
  let tabIcon = "cpu"
  private(set) var activationDate: Date?

  /// The six-row readout does not fit the 190 pt base tier.
  var preferredExpandedHeight: CGFloat { Metrics.tallExpandedHeight }

  private let monitor = SystemMetricsMonitor.shared
  private var gate = SystemPresenceGate()
  private var cancellables: Set<AnyCancellable> = []

  func start() {
    monitor.start()
    monitor.$sample
      .receive(on: DispatchQueue.main)
      .sink { [weak self] sample in self?.handle(sample) }
      .store(in: &cancellables)
  }

  /// Republishes ONLY on a gate transition. A per-sample `objectWillChange` would push
  /// `ActivityCenter` — and through it the whole compact row — through a layout pass every second.
  private func handle(_ sample: SystemMetricsSample) {
    guard gate.update(cpuTotal: sample.cpuTotal, thermalState: sample.thermalState ?? 0) else {
      return
    }
    activationDate = gate.isActive ? Date() : nil
    objectWillChange.send()
  }

  var isActive: Bool {
    guard Defaults[.systemEnabled] else { return false }
    return Defaults[.systemAlwaysVisible] || gate.isActive
  }

  // Both compact slots are fixed-width symbols with no digits, by design. A value that changes
  // every second would re-measure through `onGeometryChange` and resize the NSPanel at 1 Hz. The
  // symbol only changes when `SystemPresenceGate.reason` does, which is minutes apart at worst.
  var compactLeading: AnyView {
    AnyView(Image(systemName: "cpu").foregroundStyle(.orange).font(.caption2))
  }

  var compactTrailing: AnyView {
    let thermal = gate.reason == .thermal
    return AnyView(
      Image(systemName: thermal ? "thermometer.high" : "gauge.with.dots.needle.67percent")
        .foregroundStyle(thermal ? Color.red : Color.orange)
        .font(.caption2)
        .accessibilityLabel(thermal ? "Thermal pressure" : "High CPU"))
  }

  var expandedView: AnyView { AnyView(SystemExpandedView(monitor: monitor)) }
}
```

- [ ] **Step 2: Regenerate the project so the new source file joins the target**

Run: `cd /Users/christiannucifora/Documents/dev/personal/islet && xcodegen generate`

Expected: `Created project at .../Islet.xcodeproj`.

Do not build yet — `SystemExpandedView` arrives in Task 14.

---

### Task 14: SystemExpandedView

**Files:**
- Create: `Islet/Activities/System/SystemExpandedView.swift`

**Interfaces:**
- Consumes: `SystemMetricsMonitor`, `SystemMetricsSample`, `SystemMetricKind`, `MetricDisplayStyle`, `MetricRing`, `SparklineView`, `SparklineScale`, `Defaults[.metricStyles]`, `View.liveSampling(_:)` (Phase 1.4).
- Produces:
  - `struct SystemExpandedView: View { @ObservedObject var monitor: SystemMetricsMonitor }`

**No unit test — verified by build plus the manual check in Step 4.** The formatters below are deliberately untested: they route through `Formatter`/`String(format:)` and their output is locale-dependent, so asserting exact strings would test the locale, not the code.

Layout budget: the expanded panel is 480 × 250 (`Metrics.expandedSize.width` × `Metrics.tallExpandedHeight`). `ExpandedContainerView` reserves the notch band at the top (`ExpandedContainerView.swift:40`) and 12 pt at the bottom (`:44`), leaving roughly 200 pt for six 24 pt rows at 4 pt spacing = 164 pt. Pinned `.topLeading`, matching `PortsView` (`PortsActivity.swift:81`).

- [ ] **Step 1: Create the view**

Create `Islet/Activities/System/SystemExpandedView.swift`:

```swift
import Defaults
import SwiftUI

/// The System tab's readout.
///
/// ```
/// CPU   38%  ▁▂▅▃▂▁▄█▅▃   P 44%  E 18%   load 3.51
/// GPU   12%  ▁▁▂▁▁▁▃▂▁▁
/// RAM   14.2 / 36 GB  ▃▃▄▄▄▅▅▅   wired 4.2   swap 12 MB
/// Disk  ↓ 1.2 MB/s  ↑ 340 KB/s   412 GB free
/// Net   ↓ 8.4 Mb/s  ↑ 1.1 Mb/s   en0
/// Therm nominal   31.2 °C
/// ```
///
/// The trailing detail on each row is shown only for `.combined` — that is what makes it the
/// "everything" style. Every other style shows the label, the value and nothing else.
struct SystemExpandedView: View {
  @ObservedObject var monitor: SystemMetricsMonitor
  @Default(.metricStyles) private var metricStyles

  private var sample: SystemMetricsSample { monitor.sample }

  private func style(_ kind: SystemMetricKind) -> MetricDisplayStyle {
    MetricDisplayStyle.effective(
      for: kind, requested: MetricDisplayStyle.resolve(metricStyles[kind.rawValue]))
  }

  private func ring(_ kind: SystemMetricKind) -> [Double] {
    monitor.rings[kind]?.values ?? []
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      cpuRow
      gpuRow
      memoryRow
      diskRow
      networkRow
      thermalRow
    }
    .foregroundStyle(.white)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    // 1 Hz while this view is on screen, 5 s once it leaves.
    .liveSampling(monitor.liveGate)
  }

  // MARK: - Rows

  private var cpuRow: some View {
    row(
      "CPU", kind: .cpu, fraction: sample.cpuTotal,
      text: percent(sample.cpuTotal), scale: .fixed(min: 0, max: 1)
    ) {
      HStack(spacing: 10) {
        if let performance = sample.cpuPerformance {
          detail("P \(percent(performance))")
        }
        if let efficiency = sample.cpuEfficiency {
          detail("E \(percent(efficiency))")
        }
        if let load = sample.loadAverage {
          detail(String(format: "load %.2f", load))
        }
      }
    }
  }

  private var gpuRow: some View {
    row(
      "GPU", kind: .gpu, fraction: sample.gpu,
      text: percent(sample.gpu), scale: .fixed(min: 0, max: 1)
    ) {
      EmptyView()
    }
  }

  private var memoryRow: some View {
    let used = sample.memoryUsedBytes
    let total = sample.memoryTotalBytes
    let fraction: Double? = {
      guard let used, let total, total > 0 else { return nil }
      return Double(used) / Double(total)
    }()
    let text: String = {
      guard let used, let total else { return "—" }
      return "\(bytes(used)) / \(bytes(total))"
    }()
    return row(
      "RAM", kind: .memory, fraction: fraction, text: text, scale: .fixed(min: 0, max: 1)
    ) {
      HStack(spacing: 10) {
        if let wired = sample.memoryWiredBytes { detail("wired \(bytes(wired))") }
        if let swap = sample.swapUsedBytes { detail("swap \(bytes(swap))") }
      }
    }
  }

  private var diskRow: some View {
    let text: String = {
      guard let read = sample.diskReadBytesPerSec, let write = sample.diskWriteBytesPerSec
      else { return "—" }
      return "↓ \(bytesPerSecond(read))  ↑ \(bytesPerSecond(write))"
    }()
    return row("Disk", kind: .disk, fraction: nil, text: text, scale: .auto) {
      if let free = sample.diskFreeBytes { detail("\(bytes(free)) free") }
    }
  }

  private var networkRow: some View {
    let text: String = {
      guard let inbound = sample.netInBytesPerSec, let outbound = sample.netOutBytesPerSec
      else { return "—" }
      return "↓ \(bitsPerSecond(inbound))  ↑ \(bitsPerSecond(outbound))"
    }()
    return row("Net", kind: .network, fraction: nil, text: text, scale: .auto) {
      if let interface = sample.primaryInterface { detail(interface) }
    }
  }

  private var thermalRow: some View {
    row(
      "Therm", kind: .thermal, fraction: nil, text: thermalName(sample.thermalState),
      scale: .fixed(min: 0, max: 1)
    ) {
      if let temperature = sample.batteryTemperatureC {
        detail(String(format: "%.1f °C", temperature))
      }
    }
  }

  // MARK: - Row scaffold

  @ViewBuilder
  private func row<Detail: View>(
    _ label: String, kind: SystemMetricKind, fraction: Double?, text: String,
    scale: SparklineScale, @ViewBuilder detail: () -> Detail
  ) -> some View {
    let style = style(kind)
    HStack(spacing: 8) {
      Text(label)
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.secondary)
        .frame(width: 34, alignment: .leading)
      if style != .sparkline {
        Text(text)
          .font(.caption.weight(.semibold))
          .monospacedDigit()
          .lineLimit(1)
          .frame(width: 132, alignment: .leading)
      }
      if style == .numberAndBar {
        MetricBar(fraction: fraction ?? 0)
      }
      // An empty ring means either a cold start or `.thermal`, which has no series. Drawing an
      // empty 28 × 14 plate in either case is just a smudge, so skip it.
      if style.needsHistory, !ring(kind).isEmpty {
        SparklineView(values: ring(kind), scale: scale)
      }
      if style == .combined {
        detail()
      }
      Spacer(minLength: 0)
    }
    .frame(height: 24)
  }

  private func detail(_ text: String) -> some View {
    Text(text)
      .font(.system(size: 10))
      .monospacedDigit()
      .foregroundStyle(.secondary)
      .lineLimit(1)
  }

  // MARK: - Formatting
  // Untested on purpose: these route through locale-aware formatters, so asserting exact strings
  // would be testing the locale.

  private func percent(_ fraction: Double?) -> String {
    guard let fraction else { return "—" }
    return "\(Int((fraction * 100).rounded()))%"
  }

  /// `.byteCount` takes an `Int64`, not a `UInt64` — the conversion is required, not incidental.
  /// `spellsOutZero: false` keeps an idle disk reading "0 bytes" rather than "Zero kB".
  private func bytes(_ value: UInt64) -> String {
    Int64(value).formatted(
      .byteCount(style: .file, allowedUnits: [.kb, .mb, .gb, .tb], spellsOutZero: false))
  }

  private func bytesPerSecond(_ value: Double) -> String {
    "\(bytes(UInt64(max(value, 0))))/s"
  }

  /// Network is conventionally quoted in bits per second; disk in bytes per second.
  private func bitsPerSecond(_ bytesPerSec: Double) -> String {
    let bits = max(bytesPerSec, 0) * 8
    if bits >= 1_000_000_000 { return String(format: "%.1f Gb/s", bits / 1_000_000_000) }
    if bits >= 1_000_000 { return String(format: "%.1f Mb/s", bits / 1_000_000) }
    if bits >= 1_000 { return String(format: "%.0f Kb/s", bits / 1_000) }
    return String(format: "%.0f b/s", bits)
  }

  private func thermalName(_ raw: Int?) -> String {
    switch raw {
    case 0: "nominal"
    case 1: "fair"
    case 2: "serious"
    case 3: "critical"
    default: "—"
    }
  }
}

/// The bar half of `.numberAndBar`.
private struct MetricBar: View {
  let fraction: Double

  var body: some View {
    GeometryReader { geometry in
      ZStack(alignment: .leading) {
        Capsule().fill(.white.opacity(0.12))
        Capsule().fill(.white.opacity(0.75))
          .frame(width: geometry.size.width * min(max(fraction, 0), 1))
      }
    }
    .frame(width: 40, height: 5)
    .accessibilityHidden(true)
  }
}
```

- [ ] **Step 2: Regenerate the project so the new source file joins the target**

Run: `cd /Users/christiannucifora/Documents/dev/personal/islet && xcodegen generate`

Expected: `Created project at .../Islet.xcodeproj`.

- [ ] **Step 3: Build to verify (this also verifies Task 13)**

Run: `cd /Users/christiannucifora/Documents/dev/personal/islet && xcodebuild build -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Run the full suite to confirm nothing regressed**

Run: `cd /Users/christiannucifora/Documents/dev/personal/islet && xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`

Expected: `** TEST SUCCEEDED **`, 133 tests.

The view is not visible yet — nothing registers `SystemActivity`. Task 15 does that and carries the first manual check.

- [ ] **Step 5: Commit**

```bash
cd /Users/christiannucifora/Documents/dev/personal/islet
git add Islet/Activities/System/SystemActivity.swift Islet/Activities/System/SystemExpandedView.swift Islet.xcodeproj
git commit -m "System: add the system activity and its six-row expanded readout"
```

---

### Task 15: Register the System tab

**Files:**
- Modify: `Islet/Activities/ActivityCatalog.swift:12`
- Modify: `Islet/App/IsletApp.swift:12`
- Modify: `Islet/App/AppDelegate.swift:26`

**Interfaces:**
- Consumes: `SystemActivity`, `ActivityCenter.shared.register(_:)`.
- Produces: `AppState.system: SystemActivity`.

**No unit test — verified by build plus the manual check in Step 5.**

Existing installs have a persisted `Defaults[.activityOrder]` that does not contain `"system"`. `ActivityCenter.activeActivities` (`ActivityCenter.swift:36`) ranks unlisted ids at `Int.max`, so the new tab simply sorts last until the user drags it. That is the intended behaviour; no migration is needed.

- [ ] **Step 1: Add the catalogue entry**

In `Islet/Activities/ActivityCatalog.swift`, change lines 5-13 from:

```swift
  static let orderable: [(id: String, name: String, icon: String)] = [
    ("timer", "Timer", "timer"),
    ("nowPlaying", "Now Playing", "music.note"),
    ("shelf", "File Shelf", "tray.full.fill"),
    ("clipboard", "Clipboard", "doc.on.clipboard"),
    ("ports", "Ports", "cable.connector"),
    ("calendar", "Calendar", "calendar"),
    ("battery", "Battery", "battery.100percent.bolt"),
  ]
```

to:

```swift
  static let orderable: [(id: String, name: String, icon: String)] = [
    ("timer", "Timer", "timer"),
    ("nowPlaying", "Now Playing", "music.note"),
    ("shelf", "File Shelf", "tray.full.fill"),
    ("clipboard", "Clipboard", "doc.on.clipboard"),
    ("ports", "Ports", "cable.connector"),
    ("calendar", "Calendar", "calendar"),
    ("battery", "Battery", "battery.100percent.bolt"),
    ("system", "System", "cpu"),
  ]
```

- [ ] **Step 2: Add the AppState entry**

In `Islet/App/IsletApp.swift`, change line 12 from:

```swift
  static let ports = PortsActivity()
```

to:

```swift
  static let ports = PortsActivity()
  static let system = SystemActivity()
```

- [ ] **Step 3: Register it at launch**

In `Islet/App/AppDelegate.swift`, change lines 25-26 from:

```swift
      AppState.ports.start()
      ActivityCenter.shared.register(AppState.ports)
```

to:

```swift
      AppState.ports.start()
      ActivityCenter.shared.register(AppState.ports)
      AppState.system.start()
      ActivityCenter.shared.register(AppState.system)
```

- [ ] **Step 4: Build and run the full suite**

Run: `cd /Users/christiannucifora/Documents/dev/personal/islet && xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`

Expected: `** TEST SUCCEEDED **`, 133 tests.

- [ ] **Step 5: Manual check**

Run:

```bash
cd /Users/christiannucifora/Documents/dev/personal/islet
pkill -x Islet || true
xcodebuild build -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -5
open ~/Library/Developer/Xcode/DerivedData/Islet-*/Build/Products/Debug/Islet.app
```

Then, with `Defaults[.systemAlwaysVisible]` still at its default `false`, put the machine under load so the gate opens:

```bash
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do yes > /dev/null & done
sleep 8
```

Confirm all of the following, then `killall yes`:

1. Within ~8 s of the load starting, a `cpu` glyph and a gauge glyph appear in the collapsed island.
2. Expanding the island shows a **`cpu` chip** in the switcher row.
3. Selecting it shows six rows — CPU, GPU, RAM, Disk, Net, Therm — with the island grown to the taller 250 pt tier and the content pinned top-left, not floating centred.
4. CPU shows a plausible percentage near 100% under `yes`, and a `P …% E …%` pair if Task 8 confirmed the split.
5. The numbers tick once a second while the tab is open.
6. After `killall yes`, the compact glyphs disappear within a few seconds and the island returns to its previous width.
7. **Critically:** while the island is collapsed and the System tab is inactive, the island does not visibly twitch or resize. Watch it for 30 s.

- [ ] **Step 6: Commit**

```bash
cd /Users/christiannucifora/Documents/dev/personal/islet
git add Islet/Activities/ActivityCatalog.swift Islet/App/IsletApp.swift Islet/App/AppDelegate.swift
git commit -m "System: register the system tab with the activity centre"
```

---

### Task 16: Settings — per-metric display style

**Files:**
- Modify: `Islet/Settings/SettingsView.swift:27` (new `@Default` properties)
- Modify: `Islet/Settings/SettingsView.swift:54` (menu-order list height)
- Modify: `Islet/Settings/SettingsView.swift:132` (new section)

**Interfaces:**
- Consumes: `Defaults[.systemEnabled]`, `Defaults[.systemAlwaysVisible]`, `Defaults[.metricStyles]`, `SystemMetricKind.allCases`, `MetricDisplayStyle.allCases`, `MetricDisplayStyle.resolve(_:)`, `.displayName` on both.
- Produces: nothing consumed elsewhere.

**No unit test — verified by build plus the manual check in Step 5.** `MetricDisplayStyle.resolve` is already covered in Task 1.

- [ ] **Step 1: Add the property wrappers**

In `Islet/Settings/SettingsView.swift`, change line 27 from:

```swift
  @Default(.portsEnabled) private var portsEnabled
```

to:

```swift
  @Default(.portsEnabled) private var portsEnabled
  @Default(.systemEnabled) private var systemEnabled
  @Default(.systemAlwaysVisible) private var systemAlwaysVisible
  @Default(.metricStyles) private var metricStyles
```

- [ ] **Step 2: Add the style binding helper**

In `Islet/Settings/SettingsView.swift`, immediately after the closing brace of `private func enabled(_ id: String) -> Binding<Bool>` (line 39) and before `var body: some View` (line 41), insert:

```swift
  private func styleBinding(_ kind: SystemMetricKind) -> Binding<MetricDisplayStyle> {
    Binding(
      get: { MetricDisplayStyle.resolve(metricStyles[kind.rawValue]) },
      set: { metricStyles[kind.rawValue] = $0.rawValue })
  }

```

- [ ] **Step 3: Grow the menu-order list for the eighth row**

In `Islet/Settings/SettingsView.swift`, change line 54 from:

```swift
        .frame(height: 190)
```

to:

```swift
        .frame(height: 216)
```

- [ ] **Step 4: Add the System stats section**

In `Islet/Settings/SettingsView.swift`, immediately after the closing brace of `Section("Activities")` (line 132) and before `Section("General")` (line 133), insert:

```swift
      Section("System stats") {
        Toggle("System stats tab", isOn: $systemEnabled)
        if systemEnabled {
          Toggle("Always show the tab", isOn: $systemAlwaysVisible)
          Text(
            "Off: the tab appears only when the CPU stays above 80% for five seconds, or the Mac is thermally throttled."
          )
          .font(.caption2).foregroundStyle(.secondary)
          ForEach(SystemMetricKind.allCases, id: \.self) { kind in
            Picker(kind.displayName, selection: styleBinding(kind)) {
              ForEach(MetricDisplayStyle.allCases, id: \.self) { style in
                Text(style.displayName).tag(style)
              }
            }
          }
          Text("Thermal has no history, so the sparkline styles show its state as text.")
            .font(.caption2).foregroundStyle(.secondary)
        }
      }
```

- [ ] **Step 5: Build, run the suite, and check by hand**

Run: `cd /Users/christiannucifora/Documents/dev/personal/islet && xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`

Expected: `** TEST SUCCEEDED **`, 133 tests.

Then:

```bash
cd /Users/christiannucifora/Documents/dev/personal/islet
pkill -x Islet || true
open ~/Library/Developer/Xcode/DerivedData/Islet-*/Build/Products/Debug/Islet.app
```

Open Settings from the menu bar and confirm:

1. "Menu order" lists eight rows including **System**, with no scrolling needed.
2. A "System stats" section exists with the master toggle, "Always show the tab", and six style pickers.
3. Turning "Always show the tab" on makes the `cpu` chip appear in the expanded switcher immediately, with no load applied.
4. Changing CPU's style to **Number** collapses that row to `CPU  38%` — no bar, no sparkline, no P/E/load.
5. Changing it to **Number + bar** shows the number and a filled capsule.
6. Changing it to **Sparkline** hides the number and shows only the 28 × 14 pt trace.
7. Changing it to **Number + sparkline** shows both, still without the P/E/load detail.
8. Changing it to **Everything** adds `P …%  E …%  load …` back.
9. Setting Thermal to **Sparkline** shows `Therm nominal` with no trace (the documented degrade), and **Everything** adds the temperature.
10. Quitting and relaunching Islet keeps every style choice.

- [ ] **Step 6: Commit**

```bash
cd /Users/christiannucifora/Documents/dev/personal/islet
git add Islet/Settings/SettingsView.swift
git commit -m "System: expose the per-metric display style in settings"
```

---

### Task 17: Final verification

**Files:** none.

**Interfaces:** none.

- [ ] **Step 1: Confirm the working tree is clean and the project is in sync**

Run:

```bash
cd /Users/christiannucifora/Documents/dev/personal/islet
xcodegen generate && git status --short
```

Expected: `Created project at .../Islet.xcodeproj`, then either no output or only `Islet.xcodeproj` changes. If the project file changed, commit it:

```bash
git add Islet.xcodeproj && git commit -m "System: regenerate the project"
```

- [ ] **Step 2: Run the full suite one final time**

Run: `cd /Users/christiannucifora/Documents/dev/personal/islet && xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`

Expected: `** TEST SUCCEEDED **`, 133 tests (75 baseline + 58 added), still around 11–13 s.

- [ ] **Step 3: Confirm the sampler does not leak**

Run:

```bash
cd /Users/christiannucifora/Documents/dev/personal/islet
pkill -x Islet || true
open ~/Library/Developer/Xcode/DerivedData/Islet-*/Build/Products/Debug/Islet.app
sleep 5
ps -o rss= -p "$(pgrep -x Islet)"
```

Note the RSS in KB. Expand the island onto the System tab, leave it open for five minutes, then collapse it and re-run the `ps` line. Expected: RSS grows by well under 1 MB. A steady climb of roughly 190 KB per 1000 samples means `vm_deallocate` is missing from `SystemMetricsReader.cpuTicks()` — re-read `Islet/Activities/System/SystemMetricsReader.swift` and restore the `defer` block.

- [ ] **Step 4: Confirm the collapsed island is still still**

With the System tab inactive and no load applied, watch the collapsed island for 60 s. It must not resize, twitch or re-animate. If it does, `SystemActivity.handle(_:)` is sending `objectWillChange` on samples rather than only on gate transitions, or a compact slot has picked up a changing value.

---

## Risks and known limitations

1. **The System tab is unreachable from the switcher on an idle Mac unless "Always show the tab" is on.** This follows directly from the contracted threshold-gated `isActive`, which exists to stop a permanent collapsed glyph resizing the panel every second. The `systemAlwaysVisible` key (Task 11) is the escape hatch and defaults to off.
2. **The P/E split is an empirical result, not a documented API.** Task 8 verifies it on the build machine and Task 6 degrades to total-only when it cannot be established, but a future SoC could reorder the array without warning. If the split ever looks wrong, re-run Task 8's probe first.
3. **`Device Utilization %` is undocumented.** It is read defensively (`as? NSNumber`, clamped to 0…1) and the GPU row simply shows `—` when absent. Verified present on M3 Pro.
4. **`primaryInterfaceName()` returns the IPv4 default-route interface only.** An IPv6-only network falls through to the busiest running `en*`, which on a machine with a Thunderbolt bridge may not be the one carrying traffic. The row still shows which interface it is measuring, so the error is visible rather than silent.
5. **Memory "used" is `active + wired + compressed`.** It matches Activity Monitor's "Memory Used" closely but not exactly — Apple does not document its formula. The row is labelled `14.2 / 36 GB`, not "pressure", so a few hundred MB of disagreement is not misleading.
6. **Disk throughput sums every `IOBlockStorageDriver` node.** On this machine that is the SSD plus two read-only images; on a machine with an external drive it is both drives combined. There is no per-drive breakdown in this phase.
7. **`.liveSampling` depends on Phase 1.4 landing correctly.** If the gate under-releases, the monitor stays at 1 Hz forever. That costs ~0.10 ms per second — real but negligible — so it fails quiet rather than loud. Watch for it during Task 15's manual check.
