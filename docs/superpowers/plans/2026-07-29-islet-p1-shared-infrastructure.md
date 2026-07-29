# Phase 1 — Shared Infrastructure Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the six pieces of shared infrastructure — `Motion`, per-tab expanded height, switcher overflow, `LiveSamplingGate`, `IORegistryReader`, `ThresholdDetector` — that Phases 2 through 5 all depend on.

**Architecture:** Four new pure/`@MainActor` types go into `Islet/Core/`; the existing geometry and view-model layer is re-parameterised so the expanded island's height is per-tab rather than a global constant; the battery stack is rewired onto the new bulk IORegistry read, the refcounted sampling gate and the generalised threshold detector. Nothing here adds a feature — every change is a seam that a later phase plugs into, so the visible behaviour of the app after this phase is identical apart from a scrollable switcher bar and a taller island for tabs that ask for one (none do yet).

**Tech Stack:** Swift 6, SwiftUI, AppKit, XcodeGen, XCTest, sindresorhus/Defaults

## Global Constraints

- **Working directory:** every command in this plan runs from the repo root, `/Users/christiannucifora/Documents/dev/personal/islet`.
- **Swift 6 strict concurrency:** app types are `@MainActor`. Pure logic types (`NotchGeometry`, `SneakLogic`, `BatteryEventDetector`, `AdapterParser`, `SourceFilter`, and the new `ThresholdDetector`, `IORegistryReader`, `SmartBatteryReader.metrics(from:)`) stay actor-free so tests call them synchronously. Keep new pure logic that way.
- **XcodeGen:** `Islet.xcodeproj` is generated from `project.yml`. Any step that CREATES a new `.swift` file must be immediately followed by `xcodegen generate` before building, or the file is not in the target and the build fails with "cannot find X in scope". `xcodegen generate` prints a warning about the `Vendor/MediaRemoteAdapter.framework` path — that is expected and harmless.
- **Test command:** `xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`
- **Build command:** `xcodebuild build -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`
- **Baseline:** 75 passing tests in ~1.7s of test time (~11s wall). Success output ends with `** TEST SUCCEEDED **`.
- **Commit after every green test run.** Commit messages are a scope prefix then a lowercase imperative summary, e.g. `Power: read voltage, amperage and capacity from AppleSmartBattery`.
- **Never add a `Co-Authored-By` trailer, and never mention Claude, Anthropic or AI in a commit message.**
- **Phase invariant:** `Metrics` owns sizes only after this phase. Every animation constant lives in `Motion`. Every expanded-height consumer takes the height as a parameter — there is no zero-argument `expandedRect` or `panelFrame` left anywhere.

### Phase 0 is assumed shipped

`docs/superpowers/plans/2026-07-29-islet-p0-notch-drift.md` lands first and edits four of the files
this plan also touches: `NotchGeometry.swift`, `NotchViewModel.swift`, `ScreenManager.swift` and
`NotchRootView.swift`. **Every line number quoted below refers to the tree as it stood before Phase 0.
Apply each edit by matching the quoted text, not by seeking to a line number.**

What Phase 0 already added, which this plan must preserve rather than re-derive:

```swift
// NotchGeometry — Phase 0 additions
let auxLeftWidth: CGFloat
func islandBodyWidth(compactLeading: CGFloat, compactTrailing: CGFloat) -> CGFloat
func islandOffset(inPanel panel: CGRect, compactLeading: CGFloat, compactTrailing: CGFloat) -> CGFloat
func collapsedIslandRect(inPanel panel: CGRect, compactLeading: CGFloat, compactTrailing: CGFloat) -> CGRect

// NotchViewModel — Phase 0 additions
@Published private(set) var actualPanelFrame: CGRect
func setActualPanelFrame(_ frame: CGRect)
func cancelPendingShrink()

// NotchPanel — Phase 0 addition
override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect

// NSScreen+Notch — Phase 0 REPLACED the zero-argument `notchGeometry` property with:
var notchReading: NotchStickiness.Reading { get }
func notchGeometry(reading: NotchStickiness.Reading) -> NotchGeometry
```

Two consequences for this plan:

1. When 1.2 converts `expandedRect` and `panelFrame` into height-parameterised functions, the call
   sites to update include Phase 0's `reassert()` / `reassertIfMoved()` path in `ScreenManager` and
   the `PanelInstance` type Phase 0 introduces — not just the pre-Phase-0 ones listed below.
2. `NotchRootView.islandOffset` reads `vm.actualPanelFrame` after Phase 0, **not** `vm.panelFrame`.
   Do not revert that when editing `bodySize` for the height tier.

---

## File Structure

**Created**

| File | Single responsibility |
|---|---|
| `Islet/Core/Motion.swift` | Every animation constant, the Reduce Motion gate, and the `MotionProfile` catalogue Phase 3 sources name. |
| `Islet/Core/LiveSamplingGate.swift` | Refcounted "is anyone watching?" gate plus the `.liveSampling(_:)` View modifier. |
| `Islet/Core/IORegistryReader.swift` | One-call bulk IORegistry property reads and the two's-complement decode for signed registry ints. |
| `Islet/Core/ThresholdDetector.swift` | Pure threshold-crossing detection for one numeric series, falling or rising. |
| `IsletTests/MotionTests.swift` | Covers `Motion.gated`, the shrink-delay invariant and `MotionProfile`. |
| `IsletTests/PreferredExpandedHeightTests.swift` | Covers the `NotchActivity.preferredExpandedHeight` default and an override. |
| `IsletTests/LiveSamplingGateTests.swift` | Covers retain/release refcounting including the cross-fade order and the below-zero floor. |
| `IsletTests/IORegistryReaderTests.swift` | Covers `signedInt` and the two lookup entry points against a service every Mac has. |
| `IsletTests/SmartBatteryReaderTests.swift` | Covers the pure AppleSmartBattery property-dictionary parse. |
| `IsletTests/ThresholdDetectorTests.swift` | Covers falling, rising, multi-crossing, nil baseline and equality. |

**Modified**

| File | Change |
|---|---|
| `Islet/Core/Metrics.swift` | Loses the four animation constants; gains `tallExpandedHeight`. Sizes only. |
| `Islet/Core/NotchGeometry.swift` | `expandedRect` and `panelFrame` become height-parameterised functions. |
| `Islet/Core/NotchViewModel.swift` | Gains `expandedHeight` / `setExpandedHeight(_:)` / `expandedRect`; every geometry call passes a height; animations route through `Motion`. |
| `Islet/UI/NotchRootView.swift` | `bodySize` case `.expanded` uses `vm.expandedHeight`; animations route through `Motion`; passes `vm` into `ExpandedContainerView`. |
| `Islet/UI/ExpandedContainerView.swift` | Reports the selected tab's preferred height to the view model; switcher chips shrink to 22pt and scroll horizontally. |
| `Islet/Activities/NotchActivity.swift` | Gains `preferredExpandedHeight` with a default. |
| `Islet/Activities/Sneaks/SneakQueue.swift` | Animations route through `Motion`. |
| `Islet/Activities/Battery/BatteryMonitor.swift` | `setLiveMetrics(_:)` replaced by `liveGate`; `refresh()` diffs before publishing. |
| `Islet/Activities/Battery/BatteryMetrics.swift` | `SmartBatteryReader` rewritten on `IORegistryReader` with a pure `metrics(from:)`. |
| `Islet/Activities/Battery/BatteryState.swift` | `BatteryEventDetector` refactored onto `ThresholdDetector`. |
| `Islet/Activities/Battery/BatteryActivity.swift` | `BatteryExpandedView` uses `.liveSampling(monitor.liveGate)`. |
| `IsletTests/NotchGeometryTests.swift` | Existing assertions kept; call sites updated to the function form; three height tests added. |
| `IsletTests/NotchViewModelTests.swift` | Existing assertions kept; call sites updated; five expanded-height tests added. |

---

## Task 1: Motion.swift

**Files:**
- Create: `Islet/Core/Motion.swift`
- Create: `IsletTests/MotionTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `enum Motion` with `static let closingDuration: TimeInterval`, `static let opening: Animation`, `static let closing: Animation`, `static let compact: Animation`, `static let panelShrinkDelay: Duration`, `@MainActor static var reduceMotion: Bool`, `@MainActor static func gated(_ animation: Animation) -> Animation?`, `static func gated(_ animation: Animation, reduceMotion: Bool) -> Animation?`
  - `enum MotionProfile: String, CaseIterable, Codable, Sendable`

> **Note on the second `gated` overload:** the phase contract names only `gated(_:)`. The two-argument overload is added here so the decision can be unit-tested without changing the tester's System Settings. `gated(_:)` is a one-line wrapper over it.

- [ ] **Step 1: Write the failing test**

Create `IsletTests/MotionTests.swift`:

```swift
import SwiftUI
import XCTest

@testable import Islet

final class MotionTests: XCTestCase {
  func testGatedPassesTheAnimationThroughWhenMotionIsAllowed() {
    XCTAssertEqual(Motion.gated(Motion.opening, reduceMotion: false), Motion.opening)
    XCTAssertEqual(Motion.gated(Motion.closing, reduceMotion: false), Motion.closing)
    XCTAssertEqual(Motion.gated(Motion.compact, reduceMotion: false), Motion.compact)
  }

  func testGatedCollapsesToNilUnderReduceMotion() {
    // nil is the "apply the change with no animation" argument for both withAnimation(_:_:)
    // and .animation(_:value:), so every call site gates by wrapping its animation.
    XCTAssertNil(Motion.gated(Motion.opening, reduceMotion: true))
    XCTAssertNil(Motion.gated(Motion.closing, reduceMotion: true))
    XCTAssertNil(Motion.gated(Motion.compact, reduceMotion: true))
  }

  func testPanelShrinkDelayOutlastsTheClosingAnimation() {
    // The panel must stay oversized until the close has finished drawing, or the island is
    // clipped mid-collapse.
    XCTAssertGreaterThan(
      Motion.panelShrinkDelay,
      Duration.milliseconds(Int(Motion.closingDuration * 1000)))
  }

  func testMotionProfileNamesEverySourceAndRoundTrips() {
    XCTAssertEqual(MotionProfile.allCases.count, 15)
    for profile in MotionProfile.allCases {
      XCTAssertEqual(MotionProfile(rawValue: profile.rawValue), profile)
    }
    XCTAssertEqual(MotionProfile.volumeMount.rawValue, "volumeMount")
    XCTAssertEqual(MotionProfile.chargeComplete.rawValue, "chargeComplete")
  }
}
```

- [ ] **Step 2: Regenerate the project so the new test file is in the target**

Run: `xcodegen generate`
Expected: `Loaded project`, a warning mentioning `Vendor/MediaRemoteAdapter.framework`, then `Created project at Islet.xcodeproj`.

- [ ] **Step 3: Run the test to verify it fails**

Run: `xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`
Expected: compilation failure containing `cannot find 'Motion' in scope` and `cannot find 'MotionProfile' in scope`, ending in `** TEST BUILD FAILED **`.

- [ ] **Step 4: Create Motion.swift**

Create `Islet/Core/Motion.swift`:

```swift
import AppKit
import SwiftUI

/// Every animation Islet plays, in one place. Split out of `Metrics` — which now owns sizes only —
/// so per-source event choreography and the Reduce Motion gate have somewhere to live.
enum Motion {
  static let closingDuration: TimeInterval = 0.4
  static let opening: Animation = .bouncy(duration: 0.4)
  static let closing: Animation = .smooth(duration: closingDuration)
  static let compact: Animation = .snappy(duration: 0.4)
  /// The panel has to stay oversized until the closing animation has finished drawing — but not a
  /// frame longer, since every extra millisecond is menu bar nobody can click.
  static let panelShrinkDelay: Duration = .milliseconds(Int(closingDuration * 1000) + 32)

  /// System Settings → Accessibility → Display → Reduce Motion.
  @MainActor
  static var reduceMotion: Bool {
    NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
  }

  /// Collapses `animation` to `nil` when Reduce Motion is on. `withAnimation(nil) { ... }` and
  /// `.animation(nil, value:)` both mean "apply the change with no animation", so a call site gates
  /// itself by wrapping its animation in this.
  @MainActor
  static func gated(_ animation: Animation) -> Animation? {
    gated(animation, reduceMotion: reduceMotion)
  }

  /// Testable core of `gated(_:)`, so the decision can be covered without changing the tester's
  /// accessibility settings.
  static func gated(_ animation: Animation, reduceMotion: Bool) -> Animation? {
    reduceMotion ? nil : animation
  }
}

/// Per-source event choreography. A Phase 3 `SystemEvent` names one of these and the sneak renderer
/// turns it into the actual symbol effect or phase animator.
enum MotionProfile: String, CaseIterable, Codable, Sendable {
  case wifi, bluetooth, usb, airdrop, volumeMount, display, chargeComplete,
    lowPower, screenshot, lock, sleepWake, peripheralLow, focus, vpn, generic
}
```

- [ ] **Step 5: Regenerate the project so the new source file is in the target**

Run: `xcodegen generate`
Expected: `Created project at Islet.xcodeproj`.

- [ ] **Step 6: Run tests to verify they pass**

Run: `xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`
Expected: `** TEST SUCCEEDED **`, `Executed 79 tests, with 0 failures`.

- [ ] **Step 7: Commit**

```bash
git add Islet/Core/Motion.swift IsletTests/MotionTests.swift Islet.xcodeproj
git commit -m "Motion: add the animation catalogue, the reduce-motion gate and motion profiles"
```

---

## Task 2: Move the animation constants off Metrics and update every call site

**Files:**
- Modify: `Islet/Core/Metrics.swift:20-26`
- Modify: `Islet/UI/NotchRootView.swift:129-130`
- Modify: `Islet/Core/NotchViewModel.swift:100`, `Islet/Core/NotchViewModel.swift:116`
- Modify: `Islet/Activities/Sneaks/SneakQueue.swift:36`, `Islet/Activities/Sneaks/SneakQueue.swift:39`
- Modify: `IsletTests/NotchViewModelTests.swift:72`, `IsletTests/NotchViewModelTests.swift:87`

**Interfaces:**
- Consumes: `Motion.opening`, `Motion.closing`, `Motion.compact`, `Motion.panelShrinkDelay`, `Motion.gated(_:)` (Task 1).
- Produces: `Metrics` with no animation members.

There is no new unit test here — this is a pure move, covered by the 79 tests already passing. `Motion.gated(_:)` is applied at the same time, so this is also the commit where Reduce Motion starts being honoured (nothing in the codebase checked it before).

- [ ] **Step 1: Delete the animation constants from Metrics**

Replace the whole of `Islet/Core/Metrics.swift` with:

```swift
import SwiftUI

enum Metrics {
  static let expandedSize = CGSize(width: 480, height: 190)
  static let shadowPadding: CGFloat = 20
  static let earMargin: CGFloat = 64
  static let closedOversize: CGFloat = 2  // draw wider/taller than hardware
  static let hitSlop: CGFloat = 4  // hit target extends this far beyond notch
  static let peekGrowth: CGFloat = 4
  static let fallbackNotchWidth: CGFloat = 200
  /// Breathing room between the drawn island and the panel edge that clips it, so fractional
  /// compact widths can't shave the outward corner flare.
  static let islandMargin: CGFloat = 4
  /// Extra height the collapsed panel carries below the notch: peek growth plus the drop target.
  static let collapsedDepth: CGFloat = 12

  static let closedRadii = (top: CGFloat(6), bottom: CGFloat(14))
  static let expandedRadii = (top: CGFloat(19), bottom: CGFloat(24))
}
```

- [ ] **Step 2: Point NotchViewModel at Motion**

In `Islet/Core/NotchViewModel.swift`, replace line 100:

```swift
    shrinkTask = Self.debounce(for: Metrics.panelShrinkDelay) { [weak self] in
```

with:

```swift
    shrinkTask = Self.debounce(for: Motion.panelShrinkDelay) { [weak self] in
```

and replace line 116:

```swift
    withAnimation(opening ? Metrics.opening : Metrics.closing) {
```

with:

```swift
    withAnimation(Motion.gated(opening ? Motion.opening : Motion.closing)) {
```

- [ ] **Step 3: Point NotchRootView at Motion**

In `Islet/UI/NotchRootView.swift`, replace lines 129-130:

```swift
    .animation(vm.state.isExpanded ? Metrics.opening : Metrics.closing, value: vm.state)
    .animation(Metrics.compact, value: compactVisible)
```

with:

```swift
    .animation(
      Motion.gated(vm.state.isExpanded ? Motion.opening : Motion.closing), value: vm.state
    )
    .animation(Motion.gated(Motion.compact), value: compactVisible)
```

- [ ] **Step 4: Point SneakQueue at Motion**

In `Islet/Activities/Sneaks/SneakQueue.swift`, replace line 36:

```swift
      withAnimation(Metrics.compact) { current = next }
```

with:

```swift
      withAnimation(Motion.gated(Motion.compact)) { current = next }
```

and replace line 39:

```swift
      withAnimation(Metrics.compact) { current = nil }
```

with:

```swift
      withAnimation(Motion.gated(Motion.compact)) { current = nil }
```

- [ ] **Step 5: Point the existing view-model tests at Motion**

In `IsletTests/NotchViewModelTests.swift`, replace line 72:

```swift
    try await Task.sleep(for: Metrics.panelShrinkDelay + .milliseconds(200))
```

with:

```swift
    try await Task.sleep(for: Motion.panelShrinkDelay + .milliseconds(200))
```

and replace line 87 (identical text, inside `testRepeatedTransitionsDoNotDeferTheShrink`):

```swift
    try await Task.sleep(for: Metrics.panelShrinkDelay + .milliseconds(200))
```

with:

```swift
    try await Task.sleep(for: Motion.panelShrinkDelay + .milliseconds(200))
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`
Expected: `** TEST SUCCEEDED **`, `Executed 79 tests, with 0 failures`.

- [ ] **Step 7: Commit**

```bash
git add Islet/Core/Metrics.swift Islet/Core/NotchViewModel.swift Islet/UI/NotchRootView.swift Islet/Activities/Sneaks/SneakQueue.swift IsletTests/NotchViewModelTests.swift
git commit -m "Motion: move every animation off Metrics and gate them on reduce motion"
```

---

## Task 3: Height-parameterised NotchGeometry

**Files:**
- Modify: `Islet/Core/Metrics.swift:4`
- Modify: `Islet/Core/NotchGeometry.swift:43-54`
- Modify: `Islet/Core/NotchViewModel.swift:84` (compile fix only; the real work is Task 4)
- Test: `IsletTests/NotchGeometryTests.swift:28-33`, `IsletTests/NotchGeometryTests.swift:40-48`
- Test: `IsletTests/NotchViewModelTests.swift:49`, `:56`, `:65` (compile fix only)

**Interfaces:**
- Consumes: `Metrics.expandedSize`, `Metrics.earMargin`, `Metrics.shadowPadding`.
- Produces:
  - `Metrics.tallExpandedHeight: CGFloat` (250)
  - `NotchGeometry.expandedRect(height: CGFloat) -> CGRect`
  - `NotchGeometry.panelFrame(height: CGFloat) -> CGRect`

The zero-argument `expandedRect` and `panelFrame` properties are **removed**. Existing geometry assertions are preserved verbatim; only the call syntax changes.

- [ ] **Step 1: Write the failing tests**

In `IsletTests/NotchGeometryTests.swift`, replace `testPanelFrameFixedAndTopCentered` (lines 28-33):

```swift
  func testPanelFrameFixedAndTopCentered() {
    XCTAssertEqual(mbp.panelFrame.width, Metrics.expandedSize.width + Metrics.earMargin * 2)
    XCTAssertEqual(mbp.panelFrame.height, Metrics.expandedSize.height + Metrics.shadowPadding)
    XCTAssertEqual(mbp.panelFrame.maxY, 1117)
    XCTAssertEqual(mbp.panelFrame.midX, 864, accuracy: 0.5)
  }
```

with:

```swift
  func testPanelFrameFixedAndTopCentered() {
    let base = mbp.panelFrame(height: Metrics.expandedSize.height)
    XCTAssertEqual(base.width, Metrics.expandedSize.width + Metrics.earMargin * 2)
    XCTAssertEqual(base.height, Metrics.expandedSize.height + Metrics.shadowPadding)
    XCTAssertEqual(base.maxY, 1117)
    XCTAssertEqual(base.midX, 864, accuracy: 0.5)
  }

  func testExpandedRectFollowsTheRequestedHeight() {
    let base = mbp.expandedRect(height: Metrics.expandedSize.height)
    let tall = mbp.expandedRect(height: Metrics.tallExpandedHeight)
    XCTAssertEqual(base.height, 190)
    XCTAssertEqual(tall.height, 250)
    // Both hang off the top edge and stay centred on the screen; only the bottom edge moves.
    XCTAssertEqual(base.maxY, 1117)
    XCTAssertEqual(tall.maxY, 1117)
    XCTAssertEqual(tall.midX, 864, accuracy: 0.5)
    XCTAssertEqual(tall.width, base.width)
    XCTAssertLessThan(tall.minY, base.minY)
  }

  func testPanelFrameFollowsTheRequestedHeight() {
    let tall = mbp.panelFrame(height: Metrics.tallExpandedHeight)
    XCTAssertEqual(tall.height, Metrics.tallExpandedHeight + Metrics.shadowPadding)
    // Width is fixed: only the height tier varies per tab.
    XCTAssertEqual(tall.width, Metrics.expandedSize.width + Metrics.earMargin * 2)
    XCTAssertEqual(tall.maxY, 1117)
    XCTAssertEqual(tall.midX, 864, accuracy: 0.5)
  }

  func testTallPanelFrameContainsTheBaseOneAndItsIsland() {
    let base = mbp.panelFrame(height: Metrics.expandedSize.height)
    let tall = mbp.panelFrame(height: Metrics.tallExpandedHeight)
    // Switching tiers never has to move the panel sideways, and the union of the two frames is
    // just the tall one — which is what lets the view model grow now and shrink later without
    // ever clipping the island.
    XCTAssertTrue(tall.contains(base))
    XCTAssertEqual(base.union(tall), tall)
    XCTAssertTrue(tall.contains(mbp.expandedRect(height: Metrics.tallExpandedHeight)))
  }
```

Then in the same file replace lines 43-44 inside `testCollapsedPanelFrameHugsTheIsland`:

```swift
    XCTAssertLessThan(bare.width, mbp.panelFrame.width)
    XCTAssertLessThan(bare.height, mbp.panelFrame.height)
```

with:

```swift
    let expanded = mbp.panelFrame(height: Metrics.expandedSize.height)
    XCTAssertLessThan(bare.width, expanded.width)
    XCTAssertLessThan(bare.height, expanded.height)
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`
Expected: compilation failure containing `cannot call value of non-function type 'CGRect'` (for `mbp.panelFrame(height:)`) and `type 'Metrics' has no member 'tallExpandedHeight'`, ending in `** TEST BUILD FAILED **`.

- [ ] **Step 3: Add the tall tier to Metrics**

In `Islet/Core/Metrics.swift`, replace line 4:

```swift
  static let expandedSize = CGSize(width: 480, height: 190)
```

with:

```swift
  /// The base height tier. Width is fixed for every tier; only the height varies per tab.
  static let expandedSize = CGSize(width: 480, height: 190)
  /// The tall tier, for information-dense tabs (power, system stats).
  static let tallExpandedHeight: CGFloat = 250
```

- [ ] **Step 4: Make the geometry functions height-parameterised**

In `Islet/Core/NotchGeometry.swift`, replace lines 43-54:

```swift
  var expandedRect: CGRect {
    CGRect(
      x: screenFrame.midX - Metrics.expandedSize.width / 2,
      y: screenFrame.maxY - Metrics.expandedSize.height,
      width: Metrics.expandedSize.width, height: Metrics.expandedSize.height)
  }

  var panelFrame: CGRect {
    let w = Metrics.expandedSize.width + Metrics.earMargin * 2
    let h = Metrics.expandedSize.height + Metrics.shadowPadding
    return CGRect(x: screenFrame.midX - w / 2, y: screenFrame.maxY - h, width: w, height: h)
  }
```

with:

```swift
  /// The expanded island on screen. Height is a per-tab tier — `Metrics.expandedSize.height` for
  /// the base one, `Metrics.tallExpandedHeight` for the dense ones — so it is a parameter rather
  /// than a constant. The island always hangs off the top edge, so only the bottom edge moves.
  func expandedRect(height: CGFloat) -> CGRect {
    CGRect(
      x: screenFrame.midX - Metrics.expandedSize.width / 2,
      y: screenFrame.maxY - height,
      width: Metrics.expandedSize.width, height: height)
  }

  /// The panel hosting the expanded island: wide enough for the ear margins, tall enough for the
  /// drop shadow below the island's bottom edge.
  func panelFrame(height: CGFloat) -> CGRect {
    let w = Metrics.expandedSize.width + Metrics.earMargin * 2
    let h = height + Metrics.shadowPadding
    return CGRect(x: screenFrame.midX - w / 2, y: screenFrame.maxY - h, width: w, height: h)
  }
```

- [ ] **Step 5: Fix the view model and view-model tests so the project compiles**

In `Islet/Core/NotchViewModel.swift`, replace lines 42-44:

```swift
  private var hoverRegion: CGRect {
    state.isExpanded ? geometry.expandedRect.union(geometry.hitRect) : geometry.hitRect
  }
```

with:

```swift
  private var hoverRegion: CGRect {
    state.isExpanded
      ? geometry.expandedRect(height: Metrics.expandedSize.height).union(geometry.hitRect)
      : geometry.hitRect
  }
```

replace line 66:

```swift
    } else if state.isExpanded, geometry.expandedRect.contains(location) {
```

with:

```swift
    } else if state.isExpanded,
      geometry.expandedRect(height: Metrics.expandedSize.height).contains(location)
    {
```

and replace lines 82-87:

```swift
  private func targetPanelFrame(for state: NotchState) -> CGRect {
    state.isExpanded
      ? geometry.panelFrame
      : geometry.collapsedPanelFrame(
        compactLeading: compactLeadingWidth, compactTrailing: compactTrailingWidth)
  }
```

with:

```swift
  private func targetPanelFrame(for state: NotchState) -> CGRect {
    state.isExpanded
      ? geometry.panelFrame(height: Metrics.expandedSize.height)
      : geometry.collapsedPanelFrame(
        compactLeading: compactLeadingWidth, compactTrailing: compactTrailingWidth)
  }
```

In `IsletTests/NotchViewModelTests.swift`, replace line 49:

```swift
    XCTAssertLessThan(vm.panelFrame.width, vm.geometry.panelFrame.width)
```

with:

```swift
    XCTAssertLessThan(
      vm.panelFrame.width, vm.geometry.panelFrame(height: Metrics.expandedSize.height).width)
```

replace line 56:

```swift
    XCTAssertEqual(vm.panelFrame, vm.geometry.panelFrame)  // grown synchronously, not deferred
  }
```

with:

```swift
    // grown synchronously, not deferred
    XCTAssertEqual(vm.panelFrame, vm.geometry.panelFrame(height: Metrics.expandedSize.height))
  }
```

and replace line 65:

```swift
    XCTAssertEqual(vm.panelFrame, vm.geometry.panelFrame)
```

with:

```swift
    XCTAssertEqual(vm.panelFrame, vm.geometry.panelFrame(height: Metrics.expandedSize.height))
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`
Expected: `** TEST SUCCEEDED **`, `Executed 82 tests, with 0 failures`.

- [ ] **Step 7: Commit**

```bash
git add Islet/Core/Metrics.swift Islet/Core/NotchGeometry.swift Islet/Core/NotchViewModel.swift IsletTests/NotchGeometryTests.swift IsletTests/NotchViewModelTests.swift
git commit -m "Notch: parameterise the expanded rect and panel frame by height"
```

---

## Task 4: NotchViewModel.expandedHeight

**Files:**
- Modify: `Islet/Core/NotchViewModel.swift:8-12`, `:42-44`, `:66`, `:82-87`
- Test: `IsletTests/NotchViewModelTests.swift`

**Interfaces:**
- Consumes: `NotchGeometry.expandedRect(height:)`, `NotchGeometry.panelFrame(height:)` (Task 3); `Motion.gated(_:)`, `Motion.opening` (Task 1); `Metrics.tallExpandedHeight` (Task 3).
- Produces:
  - `NotchViewModel.expandedHeight: CGFloat` (`@Published private(set)`)
  - `NotchViewModel.setExpandedHeight(_ height: CGFloat)`
  - `NotchViewModel.expandedRect: CGRect`

- [ ] **Step 1: Write the failing tests**

Append these five tests to `IsletTests/NotchViewModelTests.swift`, immediately before the closing `}` of the class:

```swift
  // MARK: - Per-tab height tiers

  func testExpandedHeightStartsAtTheBaseTier() {
    let vm = makeVM()
    XCTAssertEqual(vm.expandedHeight, Metrics.expandedSize.height)
    XCTAssertEqual(vm.expandedRect, vm.geometry.expandedRect(height: Metrics.expandedSize.height))
  }

  func testSetExpandedHeightGrowsThePanelImmediately() {
    let vm = makeVM(mode: .clickToPin)
    vm.handleMouseDown(CGPoint(x: 864, y: 1110))
    vm.setExpandedHeight(Metrics.tallExpandedHeight)
    XCTAssertEqual(vm.expandedHeight, Metrics.tallExpandedHeight)
    // Grown synchronously: a taller tab must never be drawn into a panel still sized for the
    // shorter one it replaced.
    XCTAssertEqual(vm.panelFrame, vm.geometry.panelFrame(height: Metrics.tallExpandedHeight))
    XCTAssertEqual(vm.expandedRect.height, Metrics.tallExpandedHeight)
  }

  func testSetExpandedHeightShrinksBackOnlyAfterTheDelay() async throws {
    let vm = makeVM(mode: .clickToPin)
    vm.handleMouseDown(CGPoint(x: 864, y: 1110))
    vm.setExpandedHeight(Metrics.tallExpandedHeight)
    vm.setExpandedHeight(Metrics.expandedSize.height)
    // Still tall: shrinking here would clip the outgoing tab mid-cross-fade.
    XCTAssertEqual(vm.panelFrame, vm.geometry.panelFrame(height: Metrics.tallExpandedHeight))
    try await Task.sleep(for: Motion.panelShrinkDelay + .milliseconds(200))
    XCTAssertEqual(vm.panelFrame, vm.geometry.panelFrame(height: Metrics.expandedSize.height))
  }

  func testTallExpandedRectSwallowsAClickTheBaseTierWouldTreatAsOutside() {
    let vm = makeVM(mode: .clickToPin)
    vm.handleMouseDown(CGPoint(x: 864, y: 1110))
    vm.setExpandedHeight(Metrics.tallExpandedHeight)
    // y = 900 is 217pt below the screen top: inside a 250pt island, below a 190pt one.
    vm.handleMouseDown(CGPoint(x: 864, y: 900))
    XCTAssertEqual(vm.state, .expanded(pinned: true))
  }

  func testBaseExpandedRectTreatsThatSamePointAsOutside() {
    let vm = makeVM(mode: .clickToPin)
    vm.handleMouseDown(CGPoint(x: 864, y: 1110))
    vm.handleMouseDown(CGPoint(x: 864, y: 900))
    XCTAssertEqual(vm.state, .closed)
  }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`
Expected: compilation failure containing `value of type 'NotchViewModel' has no member 'expandedHeight'` and `value of type 'NotchViewModel' has no member 'setExpandedHeight'`, ending in `** TEST BUILD FAILED **`.

- [ ] **Step 3: Add expandedHeight, setExpandedHeight and expandedRect to the view model**

In `Islet/Core/NotchViewModel.swift`, replace lines 8-12:

```swift
  @Published private(set) var state: NotchState = .closed
  /// Screen-coordinate frame the panel should occupy right now. Tracked so the collapsed island
  /// doesn't reserve — and swallow the clicks of — the whole expanded footprint.
  @Published private(set) var panelFrame: CGRect
  var preventAutoClose = false
```

with:

```swift
  @Published private(set) var state: NotchState = .closed
  /// Screen-coordinate frame the panel should occupy right now. Tracked so the collapsed island
  /// doesn't reserve — and swallow the clicks of — the whole expanded footprint.
  @Published private(set) var panelFrame: CGRect
  /// Height tier the currently selected tab asked for. Reported by `ExpandedContainerView`; drives
  /// the drawn island, the hover region, the click-inside test and the panel frame.
  @Published private(set) var expandedHeight: CGFloat = Metrics.expandedSize.height
  var preventAutoClose = false
```

replace lines 42-44 (the version left by Task 3):

```swift
  private var hoverRegion: CGRect {
    state.isExpanded
      ? geometry.expandedRect(height: Metrics.expandedSize.height).union(geometry.hitRect)
      : geometry.hitRect
  }
```

with:

```swift
  /// The expanded island's rect at the current height tier.
  var expandedRect: CGRect { geometry.expandedRect(height: expandedHeight) }

  /// The region that counts as "hovering" for the current state.
  private var hoverRegion: CGRect {
    state.isExpanded ? expandedRect.union(geometry.hitRect) : geometry.hitRect
  }
```

(the `/// The region that counts as "hovering" for the current state.` doc comment on line 41 is now duplicated — delete the original line 41 comment so the file has one of each)

replace the `handleMouseDown` branch left by Task 3:

```swift
    } else if state.isExpanded,
      geometry.expandedRect(height: Metrics.expandedSize.height).contains(location)
    {
```

with:

```swift
    } else if state.isExpanded, expandedRect.contains(location) {
```

and replace `targetPanelFrame` as left by Task 3:

```swift
  private func targetPanelFrame(for state: NotchState) -> CGRect {
    state.isExpanded
      ? geometry.panelFrame(height: Metrics.expandedSize.height)
      : geometry.collapsedPanelFrame(
        compactLeading: compactLeadingWidth, compactTrailing: compactTrailingWidth)
  }
```

with:

```swift
  private func targetPanelFrame(for state: NotchState) -> CGRect {
    state.isExpanded
      ? geometry.panelFrame(height: expandedHeight)
      : geometry.collapsedPanelFrame(
        compactLeading: compactLeadingWidth, compactTrailing: compactTrailingWidth)
  }

  /// The selected tab's height tier, reported by `ExpandedContainerView`. Reuses the same
  /// grow-now/shrink-later panel path as expanding does, so switching to a taller tab widens the
  /// window before the content draws into it and switching back only shrinks once the cross-fade
  /// has finished.
  func setExpandedHeight(_ height: CGFloat) {
    guard height != expandedHeight else { return }
    withAnimation(Motion.gated(Motion.opening)) { expandedHeight = height }
    updatePanelFrame(for: state)
  }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`
Expected: `** TEST SUCCEEDED **`, `Executed 87 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Islet/Core/NotchViewModel.swift IsletTests/NotchViewModelTests.swift
git commit -m "Notch: track the selected tab's height tier in the view model"
```

---

## Task 5: NotchActivity.preferredExpandedHeight

**Files:**
- Modify: `Islet/Activities/NotchActivity.swift:11-26`
- Create: `IsletTests/PreferredExpandedHeightTests.swift`

**Interfaces:**
- Consumes: `Metrics.expandedSize`, `Metrics.tallExpandedHeight` (Task 3).
- Produces: `NotchActivity.preferredExpandedHeight: CGFloat` with a default of `Metrics.expandedSize.height`.

- [ ] **Step 1: Write the failing test**

Create `IsletTests/PreferredExpandedHeightTests.swift`:

```swift
import SwiftUI
import XCTest

@testable import Islet

@MainActor
final class PreferredExpandedHeightTests: XCTestCase {
  /// Takes the protocol default, the way every activity shipping today does.
  final class BaseTierActivity: NotchActivity, ObservableObject {
    let id = "baseTier"
    let priority = ActivityPriority.ambient
    var isActive = true
    var activationDate: Date?
    var compactLeading: AnyView { AnyView(EmptyView()) }
    var compactTrailing: AnyView { AnyView(EmptyView()) }
    var expandedView: AnyView { AnyView(EmptyView()) }
  }

  /// Opts into the taller tier, the way the Phase 2 power tab and the Phase 4 system tab will.
  final class TallTierActivity: NotchActivity, ObservableObject {
    let id = "tallTier"
    let priority = ActivityPriority.ambient
    var isActive = true
    var activationDate: Date?
    var compactLeading: AnyView { AnyView(EmptyView()) }
    var compactTrailing: AnyView { AnyView(EmptyView()) }
    var expandedView: AnyView { AnyView(EmptyView()) }
    let preferredExpandedHeight = Metrics.tallExpandedHeight
  }

  func testDefaultPreferredExpandedHeightIsTheBaseTier() {
    XCTAssertEqual(BaseTierActivity().preferredExpandedHeight, Metrics.expandedSize.height)
    XCTAssertEqual(BaseTierActivity().preferredExpandedHeight, 190)
  }

  func testAnActivityCanRequestTheTallTier() {
    XCTAssertEqual(TallTierActivity().preferredExpandedHeight, Metrics.tallExpandedHeight)
    XCTAssertEqual(TallTierActivity().preferredExpandedHeight, 250)
  }
}
```

- [ ] **Step 2: Regenerate the project so the new test file is in the target**

Run: `xcodegen generate`
Expected: `Created project at Islet.xcodeproj`.

- [ ] **Step 3: Run the test to verify it fails**

Run: `xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`
Expected: compilation failure containing `value of type 'BaseTierActivity' has no member 'preferredExpandedHeight'`, ending in `** TEST BUILD FAILED **`.

- [ ] **Step 4: Add the protocol requirement and its default**

In `Islet/Activities/NotchActivity.swift`, replace lines 11-26:

```swift
@MainActor
protocol NotchActivity: AnyObject {
  var id: String { get }
  var priority: ActivityPriority { get }
  var isActive: Bool { get }
  var activationDate: Date? { get }
  var compactLeading: AnyView { get }
  var compactTrailing: AnyView { get }
  var expandedView: AnyView { get }
  /// SF Symbol used for this activity's chip in the expanded switcher.
  var tabIcon: String { get }
}

extension NotchActivity {
  var tabIcon: String { "app.dashed" }
}
```

with:

```swift
@MainActor
protocol NotchActivity: AnyObject {
  var id: String { get }
  var priority: ActivityPriority { get }
  var isActive: Bool { get }
  var activationDate: Date? { get }
  var compactLeading: AnyView { get }
  var compactTrailing: AnyView { get }
  var expandedView: AnyView { get }
  /// SF Symbol used for this activity's chip in the expanded switcher.
  var tabIcon: String { get }
  /// Height tier this activity's expanded view wants. The island resizes to it while this tab is
  /// selected, so a dense layout gets the room it needs without taxing every other tab.
  var preferredExpandedHeight: CGFloat { get }
}

extension NotchActivity {
  var tabIcon: String { "app.dashed" }
  var preferredExpandedHeight: CGFloat { Metrics.expandedSize.height }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`
Expected: `** TEST SUCCEEDED **`, `Executed 89 tests, with 0 failures`.

- [ ] **Step 6: Commit**

```bash
git add Islet/Activities/NotchActivity.swift IsletTests/PreferredExpandedHeightTests.swift Islet.xcodeproj
git commit -m "Activities: let an activity ask for a taller expanded island"
```

---

## Task 6: Thread the selected tab's height through the view layer

**Files:**
- Modify: `Islet/UI/ExpandedContainerView.swift:5-10`, `:35-52`
- Modify: `Islet/UI/NotchRootView.swift:77-78`, `:152`

**Interfaces:**
- Consumes: `NotchViewModel.setExpandedHeight(_:)`, `NotchViewModel.expandedHeight` (Task 4); `NotchActivity.preferredExpandedHeight` (Task 5).
- Produces: `ExpandedContainerView(notchSize: CGSize, vm: NotchViewModel)`.

**No unit test — verified by build + manual check.** SwiftUI view wiring has no seam a unit test can hold: the assertion that matters (the panel resizes, the island is drawn at the reported height) needs a real window server.

- [ ] **Step 1: Give ExpandedContainerView the view model and a selected-height accessor**

In `Islet/UI/ExpandedContainerView.swift`, replace lines 5-10:

```swift
struct ExpandedContainerView: View {
  /// The physical notch's size, so the switcher can flank it in the top band.
  let notchSize: CGSize
  @ObservedObject private var center = ActivityCenter.shared
  @ObservedObject private var shelf = ShelfModel.shared
  /// nil selection means the dashboard ("Home"); otherwise an activity id.
  @State private var selection: String? = nil
```

with:

```swift
struct ExpandedContainerView: View {
  /// The physical notch's size, so the switcher can flank it in the top band.
  let notchSize: CGSize
  /// Height tiers are reported up to the view model, which owns the panel frame.
  let vm: NotchViewModel
  @ObservedObject private var center = ActivityCenter.shared
  @ObservedObject private var shelf = ShelfModel.shared
  /// nil selection means the dashboard ("Home"); otherwise an activity id.
  @State private var selection: String? = nil
```

- [ ] **Step 2: Report the selected tab's height on every selection change**

In `Islet/UI/ExpandedContainerView.swift`, replace lines 35-52 (the `body` property):

```swift
  var body: some View {
    ZStack(alignment: .top) {
      // Main content sits directly below the physical notch — reclaiming the space the switcher
      // row used to take.
      VStack(spacing: 0) {
        Spacer().frame(height: notchSize.height)
        content
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .padding(.horizontal, 14)
          .padding(.bottom, 12)
      }
      // Switcher tabs (left ear) and settings gear (right ear) live in the notch band, flanking
      // the hardware notch.
      switcherBar
        .frame(height: notchSize.height)
        .padding(.horizontal, 12)
    }
  }
```

with:

```swift
  /// The height tier the selected tab wants. The dashboard always takes the base tier.
  private var selectedHeight: CGFloat {
    guard effectiveSelection != Self.homeTab,
      let activity = center.activeActivities.first(where: { $0.id == effectiveSelection })
    else { return Metrics.expandedSize.height }
    return activity.preferredExpandedHeight
  }

  var body: some View {
    ZStack(alignment: .top) {
      // Main content sits directly below the physical notch — reclaiming the space the switcher
      // row used to take.
      VStack(spacing: 0) {
        Spacer().frame(height: notchSize.height)
        content
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .padding(.horizontal, 14)
          .padding(.bottom, 12)
      }
      // Switcher tabs (left ear) and settings gear (right ear) live in the notch band, flanking
      // the hardware notch.
      switcherBar
        .frame(height: notchSize.height)
        .padding(.horizontal, 12)
    }
    .onChange(of: effectiveSelection, initial: true) { _, _ in
      vm.setExpandedHeight(selectedHeight)
    }
  }
```

- [ ] **Step 3: Draw the island at the reported height and pass the view model down**

In `Islet/UI/NotchRootView.swift`, replace lines 77-78:

```swift
    case .expanded:
      return Metrics.expandedSize
```

with:

```swift
    case .expanded:
      return CGSize(width: Metrics.expandedSize.width, height: vm.expandedHeight)
```

and replace line 152:

```swift
      ExpandedContainerView(notchSize: vm.geometry.notchSize)
```

with:

```swift
      ExpandedContainerView(notchSize: vm.geometry.notchSize, vm: vm)
```

- [ ] **Step 4: Build and run the full test suite**

Run: `xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`
Expected: `** TEST SUCCEEDED **`, `Executed 89 tests, with 0 failures`.

- [ ] **Step 5: Manual check — the island still expands to exactly 190pt**

```bash
killall Islet 2>/dev/null; open "$(xcodebuild -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' -showBuildSettings 2>/dev/null | awk -F' = ' '/^ *BUILT_PRODUCTS_DIR/ {print $2; exit}')/Islet.app"
```

Confirm, by hovering and clicking the notch: the island still expands, every tab (Home, and whichever activities are active) renders at the same height it did before this change, switching tabs does not resize the island, and the panel does not clip the island's bottom edge or its shadow. No activity requests the tall tier yet, so any resize at all is a bug in this task.

- [ ] **Step 6: Commit**

```bash
git add Islet/UI/ExpandedContainerView.swift Islet/UI/NotchRootView.swift
git commit -m "Notch: resize the expanded island to the selected tab's height tier"
```

---

## Task 7: Switcher-bar overflow

**Files:**
- Modify: `Islet/UI/ExpandedContainerView.swift:54-88` (the `switcherBar` property) and the `.onChange` added in Task 6

**Interfaces:**
- Consumes: `Metrics.expandedSize`, `ActivityCatalog.name(for:)`, `Haptics.perform(_:)`, `SettingsOpener.open()`.
- Produces: no new types.

**No unit test — verified by build + manual check.** The break being fixed is a layout overflow: eight 26pt chips plus their 6pt gaps total ~250pt of chips in a left ear of ~126pt, and a ninth is coming in Phase 4.

- [ ] **Step 1: Add the scroll position state**

In `Islet/UI/ExpandedContainerView.swift`, replace:

```swift
  /// nil selection means the dashboard ("Home"); otherwise an activity id.
  @State private var selection: String? = nil
```

with:

```swift
  /// nil selection means the dashboard ("Home"); otherwise an activity id.
  @State private var selection: String? = nil
  /// Drives the tab strip's scroll offset so the selected chip is always on screen.
  @State private var scrolledTab: String? = nil
```

- [ ] **Step 2: Keep the selected chip visible when the selection changes**

In `Islet/UI/ExpandedContainerView.swift`, replace the `.onChange` added in Task 6:

```swift
    .onChange(of: effectiveSelection, initial: true) { _, _ in
      vm.setExpandedHeight(selectedHeight)
    }
```

with:

```swift
    .onChange(of: effectiveSelection, initial: true) { _, id in
      vm.setExpandedHeight(selectedHeight)
      scrolledTab = id
    }
```

- [ ] **Step 3: Shrink the chips and make the strip scroll**

In `Islet/UI/ExpandedContainerView.swift`, replace the whole `switcherBar` property (lines 54-88 in the original file):

```swift
  private var switcherBar: some View {
    HStack(spacing: 6) {
      ForEach(tabs, id: \.id) { tab in
        let selected = tab.id == effectiveSelection
        Button {
          Haptics.perform(.alignment)
          selection = tab.id
        } label: {
          Image(systemName: tab.icon)
            .font(.caption)
            .frame(width: 26, height: 20)
            .background(
              RoundedRectangle(cornerRadius: 6)
                .fill(.white.opacity(selected ? 0.22 : 0.06))
            )
            .foregroundStyle(selected ? .white : .secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.id == Self.homeTab ? "Home" : ActivityCatalog.name(for: tab.id))
      }
      // Gap for the physical notch, keeping tabs in the left ear and the gear in the right ear.
      Spacer(minLength: notchSize.width)
      Button {
        Haptics.perform()
        SettingsOpener.open()
      } label: {
        Image(systemName: "gearshape.fill")
          .font(.caption)
          .frame(width: 26, height: 20)
          .foregroundStyle(.secondary)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Settings")
    }
  }
```

with:

```swift
  private static let chipWidth: CGFloat = 22
  private static let chipHeight: CGFloat = 20
  private static let rowSpacing: CGFloat = 6
  private static let rowPadding: CGFloat = 12

  /// Width the tab strip gets in the left ear: the expanded row, minus its own horizontal padding,
  /// the notch gap, the two spacings flanking that gap, and the settings gear. On a 14" MBP that
  /// is 480 − 24 − 296 − 12 − 22 = 126pt, which fits five chips. Eight already overflowed it at
  /// the old 26pt, and Phase 4 adds a ninth — so the strip scrolls rather than squeezing.
  private var tabStripWidth: CGFloat {
    let usable = Metrics.expandedSize.width - Self.rowPadding * 2
    return max(
      Self.chipWidth, usable - notchSize.width - Self.rowSpacing * 2 - Self.chipWidth)
  }

  private var switcherBar: some View {
    HStack(spacing: Self.rowSpacing) {
      ScrollView(.horizontal) {
        HStack(spacing: Self.rowSpacing) {
          ForEach(tabs, id: \.id) { tab in
            let selected = tab.id == effectiveSelection
            Button {
              Haptics.perform(.alignment)
              selection = tab.id
            } label: {
              Image(systemName: tab.icon)
                .font(.caption)
                .frame(width: Self.chipWidth, height: Self.chipHeight)
                .background(
                  RoundedRectangle(cornerRadius: 6)
                    .fill(.white.opacity(selected ? 0.22 : 0.06))
                )
                .foregroundStyle(selected ? .white : .secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
              tab.id == Self.homeTab ? "Home" : ActivityCatalog.name(for: tab.id))
          }
        }
        .scrollTargetLayout()
      }
      .scrollIndicators(.hidden)
      .scrollPosition(id: $scrolledTab, anchor: .center)
      .frame(width: tabStripWidth)
      // Gap for the physical notch, keeping tabs in the left ear and the gear in the right ear.
      Spacer(minLength: notchSize.width)
      Button {
        Haptics.perform()
        SettingsOpener.open()
      } label: {
        Image(systemName: "gearshape.fill")
          .font(.caption)
          .frame(width: Self.chipWidth, height: Self.chipHeight)
          .foregroundStyle(.secondary)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Settings")
    }
  }
```

- [ ] **Step 4: Build and run the full test suite**

Run: `xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`
Expected: `** TEST SUCCEEDED **`, `Executed 89 tests, with 0 failures`.

- [ ] **Step 5: Manual check — the strip scrolls and the gear stays put**

```bash
killall Islet 2>/dev/null; open "$(xcodebuild -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' -showBuildSettings 2>/dev/null | awk -F' = ' '/^ *BUILT_PRODUCTS_DIR/ {print $2; exit}')/Islet.app"
```

Open Settings from the gear and enable every activity (Timer, Now Playing, File Shelf, Clipboard, Ports, Calendar, Battery) so as many chips as possible are active. Then expand the island and confirm: the chips are visibly narrower than before, no chip is drawn on top of the hardware notch, the gear is still in the right ear and still opens Settings, two-finger scrolling over the chip strip moves it horizontally with no visible scroll bar, and clicking a chip both selects that tab and leaves that chip on screen.

- [ ] **Step 6: Commit**

```bash
git add Islet/UI/ExpandedContainerView.swift
git commit -m "Notch: scroll the switcher bar instead of overflowing the left ear"
```

---

## Task 8: LiveSamplingGate

**Files:**
- Create: `Islet/Core/LiveSamplingGate.swift`
- Create: `IsletTests/LiveSamplingGateTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `@MainActor final class LiveSamplingGate` with `init(onChange: @escaping (Bool) -> Void)`, `var isLive: Bool { get }`, `func retain()`, `func release()`
  - `View.liveSampling(_ gate: LiveSamplingGate) -> some View`

- [ ] **Step 1: Write the failing test**

Create `IsletTests/LiveSamplingGateTests.swift`:

```swift
import XCTest

@testable import Islet

@MainActor
final class LiveSamplingGateTests: XCTestCase {
  /// Records every transition the gate announces, in order.
  final class Recorder {
    var transitions: [Bool] = []
  }

  func testFirstRetainGoesLive() {
    let r = Recorder()
    let gate = LiveSamplingGate { live in r.transitions.append(live) }
    XCTAssertFalse(gate.isLive)
    gate.retain()
    XCTAssertTrue(gate.isLive)
    XCTAssertEqual(r.transitions, [true])
  }

  func testSecondRetainDoesNotAnnounceAgain() {
    let r = Recorder()
    let gate = LiveSamplingGate { live in r.transitions.append(live) }
    gate.retain()
    gate.retain()
    XCTAssertTrue(gate.isLive)
    XCTAssertEqual(r.transitions, [true])
  }

  func testPartialReleaseStaysLive() {
    let r = Recorder()
    let gate = LiveSamplingGate { live in r.transitions.append(live) }
    gate.retain()
    gate.retain()
    gate.release()
    XCTAssertTrue(gate.isLive)
    XCTAssertEqual(r.transitions, [true])
  }

  func testReleaseToZeroGoesIdle() {
    let r = Recorder()
    let gate = LiveSamplingGate { live in r.transitions.append(live) }
    gate.retain()
    gate.release()
    XCTAssertFalse(gate.isLive)
    XCTAssertEqual(r.transitions, [true, false])
  }

  func testReleaseBelowZeroIsANoOp() {
    let r = Recorder()
    let gate = LiveSamplingGate { live in r.transitions.append(live) }
    gate.release()
    gate.release()
    XCTAssertFalse(gate.isLive)
    XCTAssertEqual(r.transitions, [])
    // The count must not have gone negative: an unbalanced onDisappear would otherwise poison
    // every later retain().
    gate.retain()
    XCTAssertTrue(gate.isLive)
    XCTAssertEqual(r.transitions, [true])
  }

  func testCrossFadeKeepsSamplingLive() {
    let r = Recorder()
    let gate = LiveSamplingGate { live in r.transitions.append(live) }
    // SwiftUI's cross-fade order: the incoming view's onAppear lands BEFORE the outgoing view's
    // onDisappear. A plain Bool would switch sampling off with a subscriber still on screen.
    gate.retain()  // battery tab appears
    gate.retain()  // power tab appears (incoming)
    gate.release()  // battery tab disappears (outgoing)
    XCTAssertTrue(gate.isLive)
    XCTAssertEqual(r.transitions, [true])
    gate.release()  // power tab finally goes away too
    XCTAssertFalse(gate.isLive)
    XCTAssertEqual(r.transitions, [true, false])
  }
}
```

- [ ] **Step 2: Regenerate the project so the new test file is in the target**

Run: `xcodegen generate`
Expected: `Created project at Islet.xcodeproj`.

- [ ] **Step 3: Run the test to verify it fails**

Run: `xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`
Expected: compilation failure containing `cannot find 'LiveSamplingGate' in scope`, ending in `** TEST BUILD FAILED **`.

- [ ] **Step 4: Create LiveSamplingGate.swift**

Create `Islet/Core/LiveSamplingGate.swift`:

```swift
import SwiftUI

/// Refcounted "is anyone watching?" gate.
///
/// A monitor that samples fast while its view is visible and slowly otherwise cannot use a Bool:
/// during a tab cross-fade SwiftUI runs the incoming view's `onAppear` before the outgoing view's
/// `onDisappear`, so the outgoing view switches sampling off with a subscriber still on screen and
/// the readout silently freezes. Counting observers fixes that.
@MainActor
final class LiveSamplingGate {
  private var count = 0
  private let onChange: (Bool) -> Void

  init(onChange: @escaping (Bool) -> Void) {
    self.onChange = onChange
  }

  var isLive: Bool { count > 0 }

  /// One more observer. 0 -> 1 announces `true`.
  func retain() {
    count += 1
    if count == 1 { onChange(true) }
  }

  /// One fewer observer. 1 -> 0 announces `false`. The count never goes below zero: SwiftUI does
  /// not promise a matching `onDisappear` for every `onAppear`, and a negative count would poison
  /// every later `retain()`.
  func release() {
    guard count > 0 else { return }
    count -= 1
    if count == 0 { onChange(false) }
  }
}

extension View {
  /// Retains `gate` for as long as this view is on screen.
  func liveSampling(_ gate: LiveSamplingGate) -> some View {
    onAppear { gate.retain() }
      .onDisappear { gate.release() }
  }
}
```

- [ ] **Step 5: Regenerate the project so the new source file is in the target**

Run: `xcodegen generate`
Expected: `Created project at Islet.xcodeproj`.

- [ ] **Step 6: Run tests to verify they pass**

Run: `xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`
Expected: `** TEST SUCCEEDED **`, `Executed 95 tests, with 0 failures`.

- [ ] **Step 7: Commit**

```bash
git add Islet/Core/LiveSamplingGate.swift IsletTests/LiveSamplingGateTests.swift Islet.xcodeproj
git commit -m "Core: add a refcounted live-sampling gate for visibility-driven monitors"
```

---

## Task 9: Migrate BatteryMonitor onto the gate

**Files:**
- Modify: `Islet/Activities/Battery/BatteryMonitor.swift:14-16`, `:37-44`
- Modify: `Islet/Activities/Battery/BatteryActivity.swift:166-168`

**Interfaces:**
- Consumes: `LiveSamplingGate`, `View.liveSampling(_:)` (Task 8).
- Produces: `BatteryMonitor.liveGate: LiveSamplingGate`. `BatteryMonitor.setLiveMetrics(_:)` is **removed**.

> **Documented deviation from the contract:** the contract writes `let liveGate: LiveSamplingGate`. It is implemented as `private(set) lazy var` because the gate's `onChange` closure captures `self`, which a stored `let` initialised in the property declaration cannot do. Every call site (`monitor.liveGate`) is identical either way.

**No unit test — verified by build + manual check.** `BatteryMonitor` drives real IOKit hardware timers; the refcounting logic it now depends on is covered by Task 8.

- [ ] **Step 1: Replace setLiveMetrics with the gate**

In `Islet/Activities/Battery/BatteryMonitor.swift`, replace lines 14-16:

```swift
  private var runLoopSource: CFRunLoopSource?
  private var metricsTimer: AnyCancellable?
  private var fastMetrics = false
```

with:

```swift
  private var runLoopSource: CFRunLoopSource?
  private var metricsTimer: AnyCancellable?
  private var fastMetrics = false

  /// Temperature/power/charger change continuously, so refresh fast (1 s) while a battery view is
  /// on screen and slowly (5 s) otherwise. The slow tick also re-reads `state` as a fallback poll.
  ///
  /// Refcounted rather than a Bool: during a tab cross-fade the incoming view's `onAppear` lands
  /// before the outgoing view's `onDisappear`, so a Bool would leave sampling switched off with a
  /// subscriber still visible. `lazy var` rather than `let` because the callback captures `self`.
  private(set) lazy var liveGate = LiveSamplingGate { [weak self] live in
    self?.setFastMetrics(live)
  }
```

and replace lines 37-44:

```swift
  /// Temperature/power/charger change continuously, so refresh fast (1 s) while the battery view is
  /// on screen and slowly (5 s) otherwise. The slow tick also re-reads `state` as a fallback poll.
  func setLiveMetrics(_ live: Bool) {
    guard live != fastMetrics else { return }
    fastMetrics = live
    restartMetricsTimer()
    refresh()  // update immediately on the transition
  }
```

with:

```swift
  private func setFastMetrics(_ live: Bool) {
    guard live != fastMetrics else { return }
    fastMetrics = live
    restartMetricsTimer()
    refresh()  // update immediately on the transition
  }
```

- [ ] **Step 2: Point BatteryExpandedView at the gate**

In `Islet/Activities/Battery/BatteryActivity.swift`, replace lines 166-168:

```swift
    // Refresh power/temperature quickly while this view is visible; slow back down when it's not.
    .onAppear { monitor.setLiveMetrics(true) }
    .onDisappear { monitor.setLiveMetrics(false) }
```

with:

```swift
    // Refresh power/temperature quickly while this view is visible; slow back down when it's not.
    .liveSampling(monitor.liveGate)
```

- [ ] **Step 3: Build and run the full test suite**

Run: `xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`
Expected: `** TEST SUCCEEDED **`, `Executed 95 tests, with 0 failures`.

- [ ] **Step 4: Manual check — the battery tab still samples at 1 Hz while open**

```bash
killall Islet 2>/dev/null; open "$(xcodebuild -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' -showBuildSettings 2>/dev/null | awk -F' = ' '/^ *BUILT_PRODUCTS_DIR/ {print $2; exit}')/Islet.app"
```

Plug in the charger so the Battery tab appears, expand the island and select it. Confirm the Temp and Power tiles update roughly once a second (Power especially — it moves visibly while charging). Switch to another tab and back several times in a row and confirm the values keep updating every time, never freezing. Freezing after a tab switch is exactly the bug this task removes.

- [ ] **Step 5: Commit**

```bash
git add Islet/Activities/Battery/BatteryMonitor.swift Islet/Activities/Battery/BatteryActivity.swift
git commit -m "Power: refcount the battery monitor's live sampling instead of flipping a bool"
```

---

## Task 10: IORegistryReader

**Files:**
- Create: `Islet/Core/IORegistryReader.swift`
- Create: `IsletTests/IORegistryReaderTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `IORegistryReader.properties(matching serviceName: String) -> [String: Any]?`
  - `IORegistryReader.allProperties(matching serviceName: String) -> [[String: Any]]`
  - `IORegistryReader.signedInt(_ raw: Int?) -> Int?`

- [ ] **Step 1: Write the failing test**

Create `IsletTests/IORegistryReaderTests.swift`:

```swift
import XCTest

@testable import Islet

final class IORegistryReaderTests: XCTestCase {
  func testSignedIntPassesThroughNonNegativeValues() {
    XCTAssertEqual(IORegistryReader.signedInt(0), 0)
    XCTAssertEqual(IORegistryReader.signedInt(1500), 1500)
    XCTAssertEqual(IORegistryReader.signedInt(Int(Int32.max)), Int(Int32.max))
  }

  func testSignedIntDecodesTheTwosComplementNegatives() {
    // AppleSmartBattery reports a discharging current as an unsigned register value.
    XCTAssertEqual(IORegistryReader.signedInt(Int(UInt32.max)), -1)
    XCTAssertEqual(IORegistryReader.signedInt(4_294_966_796), -500)
    XCTAssertEqual(IORegistryReader.signedInt(4_294_964_796), -2500)
  }

  func testSignedIntIsNilForNil() {
    XCTAssertNil(IORegistryReader.signedInt(nil))
  }

  func testUnknownServiceHasNoProperties() {
    XCTAssertNil(IORegistryReader.properties(matching: "IsletNoSuchServiceExists"))
    XCTAssertTrue(IORegistryReader.allProperties(matching: "IsletNoSuchServiceExists").isEmpty)
  }

  func testPlatformExpertPropertiesComeBackInOneRead() {
    // IOPlatformExpertDevice is present on every Mac and carries IOPlatformUUID, so this asserts
    // the bulk read really returns the whole dictionary and not just a handle.
    let props = IORegistryReader.properties(matching: "IOPlatformExpertDevice")
    XCTAssertNotNil(props)
    XCTAssertFalse(props?.isEmpty ?? true)
    XCTAssertNotNil(props?["IOPlatformUUID"] as? String)
  }

  func testAllPropertiesEnumeratesEveryMatchingNode() {
    let nodes = IORegistryReader.allProperties(matching: "IOPlatformExpertDevice")
    XCTAssertGreaterThanOrEqual(nodes.count, 1)
    XCTAssertNotNil(nodes.first?["IOPlatformUUID"] as? String)
  }
}
```

- [ ] **Step 2: Regenerate the project so the new test file is in the target**

Run: `xcodegen generate`
Expected: `Created project at Islet.xcodeproj`.

- [ ] **Step 3: Run the test to verify it fails**

Run: `xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`
Expected: compilation failure containing `cannot find 'IORegistryReader' in scope`, ending in `** TEST BUILD FAILED **`.

- [ ] **Step 4: Create IORegistryReader.swift**

Create `Islet/Core/IORegistryReader.swift`:

```swift
import Foundation
import IOKit

/// Bulk IORegistry reads.
///
/// `IORegistryEntryCreateCFProperty` is one kernel round trip per key; a monitor reading a dozen
/// keys at 1 Hz pays for all twelve every tick. `IORegistryEntryCreateCFProperties` returns the
/// whole property dictionary in one call, which is what every caller here actually wanted.
enum IORegistryReader {
  /// The full property dictionary of the first service matching `serviceName`, or nil when no such
  /// service exists (a desktop Mac has no AppleSmartBattery, for instance).
  static func properties(matching serviceName: String) -> [String: Any]? {
    let service = IOServiceGetMatchingService(
      kIOMainPortDefault, IOServiceMatching(serviceName))
    guard service != 0 else { return nil }
    defer { IOObjectRelease(service) }
    return properties(of: service)
  }

  /// The same, for every matching service node. `IOBlockStorageDriver` returns several, so the
  /// caller has to decide whether to filter or sum them.
  static func allProperties(matching serviceName: String) -> [[String: Any]] {
    var iterator: io_iterator_t = 0
    guard
      IOServiceGetMatchingServices(
        kIOMainPortDefault, IOServiceMatching(serviceName), &iterator) == KERN_SUCCESS
    else { return [] }
    defer { IOObjectRelease(iterator) }

    var out: [[String: Any]] = []
    var service = IOIteratorNext(iterator)
    while service != 0 {
      if let props = properties(of: service) { out.append(props) }
      IOObjectRelease(service)
      service = IOIteratorNext(iterator)
    }
    return out
  }

  private static func properties(of service: io_service_t) -> [String: Any]? {
    var unmanaged: Unmanaged<CFMutableDictionary>?
    guard
      IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0)
        == KERN_SUCCESS,
      let dict = unmanaged?.takeRetainedValue() as? [String: Any]
    else { return nil }
    return dict
  }

  /// AppleSmartBattery reports amperage as an unsigned 64-bit register: values above `Int32.max`
  /// are the two's-complement encoding of a negative current (discharging).
  static func signedInt(_ raw: Int?) -> Int? {
    guard let raw else { return nil }
    if raw > Int(Int32.max) { return raw - Int(UInt32.max) - 1 }
    return raw
  }
}
```

- [ ] **Step 5: Regenerate the project so the new source file is in the target**

Run: `xcodegen generate`
Expected: `Created project at Islet.xcodeproj`.

- [ ] **Step 6: Run tests to verify they pass**

Run: `xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`
Expected: `** TEST SUCCEEDED **`, `Executed 101 tests, with 0 failures`.

- [ ] **Step 7: Commit**

```bash
git add Islet/Core/IORegistryReader.swift IsletTests/IORegistryReaderTests.swift Islet.xcodeproj
git commit -m "Core: read IORegistry properties in one bulk call"
```

---

## Task 11: Rewrite SmartBatteryReader on IORegistryReader and diff before publishing

**Files:**
- Modify: `Islet/Activities/Battery/BatteryMetrics.swift:1-2`, `:21-70`
- Modify: `Islet/Activities/Battery/BatteryMonitor.swift` (the `refresh()` method)
- Create: `IsletTests/SmartBatteryReaderTests.swift`

**Interfaces:**
- Consumes: `IORegistryReader.properties(matching:)`, `IORegistryReader.signedInt(_:)` (Task 10).
- Produces: `SmartBatteryReader.metrics(from props: [String: Any]) -> BatteryMetrics?` — the pure parse, so the health formula, unit conversions and sentinels are testable without hardware. `SmartBatteryReader.read()` keeps its signature. `SmartBatteryReader.signedAmperage(_:)` is **removed** (replaced by `IORegistryReader.signedInt`).

- [ ] **Step 1: Write the failing test**

Create `IsletTests/SmartBatteryReaderTests.swift`:

```swift
import XCTest

@testable import Islet

final class SmartBatteryReaderTests: XCTestCase {
  func testEmptyDictionaryYieldsNoMetrics() {
    // hasAny is false, so the caller renders nothing rather than a grid of blanks.
    XCTAssertNil(SmartBatteryReader.metrics(from: [:]))
  }

  func testHealthComesFromRawMaxOverDesignCapacity() {
    let m = SmartBatteryReader.metrics(from: [
      "AppleRawMaxCapacity": 5364, "DesignCapacity": 6249,
    ])
    XCTAssertEqual(m?.healthPercent, 86)
  }

  func testHealthFallsBackToMaxCapacity() {
    let m = SmartBatteryReader.metrics(from: ["MaxCapacity": 5500, "DesignCapacity": 6249])
    XCTAssertEqual(m?.healthPercent, 88)
  }

  func testZeroDesignCapacityYieldsNoHealth() {
    let m = SmartBatteryReader.metrics(from: [
      "AppleRawMaxCapacity": 5364, "DesignCapacity": 0, "CycleCount": 142,
    ])
    XCTAssertNil(m?.healthPercent)
    XCTAssertEqual(m?.cycleCount, 142)
  }

  func testTemperatureIsReportedInCentiDegrees() {
    let m = SmartBatteryReader.metrics(from: ["Temperature": 3120])
    XCTAssertEqual(try XCTUnwrap(m?.temperatureC), 31.2, accuracy: 0.001)
  }

  func testDischargingPowerIsNegative() {
    // 11.25 V at -0.5 A, with the amperage in its unsigned two's-complement form.
    let m = SmartBatteryReader.metrics(from: ["Voltage": 11250, "Amperage": 4_294_966_796])
    XCTAssertEqual(try XCTUnwrap(m?.powerWatts), -5.625, accuracy: 0.0001)
  }

  func testChargingPowerIsPositive() {
    let m = SmartBatteryReader.metrics(from: ["Voltage": 12000, "Amperage": 2000])
    XCTAssertEqual(try XCTUnwrap(m?.powerWatts), 24.0, accuracy: 0.0001)
  }

  func testStillCalculatingSentinelIsIgnored() {
    let m = SmartBatteryReader.metrics(from: [
      "AvgTimeToFull": 65535, "AvgTimeToEmpty": 252, "CycleCount": 142,
    ])
    XCTAssertNil(m?.timeToFullMinutes)
    XCTAssertEqual(m?.timeToEmptyMinutes, 252)
  }

  func testAdapterWattsComeFromTheNestedDetailsDictionary() {
    let m = SmartBatteryReader.metrics(from: [
      "AdapterDetails": ["Watts": 96, "Description": "pd charger"] as [String: Any]
    ])
    XCTAssertEqual(m?.adapterWatts, 96)
    // A disconnected adapter reports 0 W; that is absence, not a reading.
    let none = SmartBatteryReader.metrics(from: [
      "AdapterDetails": ["Watts": 0] as [String: Any]
    ])
    XCTAssertNil(none)
  }
}
```

- [ ] **Step 2: Regenerate the project so the new test file is in the target**

Run: `xcodegen generate`
Expected: `Created project at Islet.xcodeproj`.

- [ ] **Step 3: Run the test to verify it fails**

Run: `xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`
Expected: compilation failure containing `type 'SmartBatteryReader' has no member 'metrics'`, ending in `** TEST BUILD FAILED **`.

- [ ] **Step 4: Rewrite SmartBatteryReader**

In `Islet/Activities/Battery/BatteryMetrics.swift`, replace lines 1-2:

```swift
import Foundation
import IOKit
```

with:

```swift
import Foundation
```

and replace lines 21-70 (the whole `SmartBatteryReader` enum):

```swift
enum SmartBatteryReader {
  static func read() -> BatteryMetrics? {
    let service = IOServiceGetMatchingService(
      kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
    guard service != 0 else { return nil }
    defer { IOObjectRelease(service) }

    func intVal(_ key: String) -> Int? {
      guard
        let prop = IORegistryEntryCreateCFProperty(
          service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
      else { return nil }
      return (prop as? NSNumber)?.intValue
    }

    var m = BatteryMetrics()

    if let maxCap = intVal("AppleRawMaxCapacity") ?? intVal("MaxCapacity"),
      let design = intVal("DesignCapacity"), design > 0
    {
      m.healthPercent = Int((Double(maxCap) / Double(design) * 100).rounded())
    }
    m.cycleCount = intVal("CycleCount")
    if let rawTemp = intVal("Temperature") {
      m.temperatureC = Double(rawTemp) / 100.0  // reported in centi-degrees
    }
    if let mV = intVal("Voltage"), let mA = signedAmperage(intVal("Amperage")) {
      m.powerWatts = Double(mV) / 1000.0 * Double(mA) / 1000.0
    }
    // 65535 is the "still calculating" sentinel.
    if let ttf = intVal("AvgTimeToFull"), ttf > 0, ttf < 65535 { m.timeToFullMinutes = ttf }
    if let tte = intVal("AvgTimeToEmpty"), tte > 0, tte < 65535 { m.timeToEmptyMinutes = tte }
    if let adapter = IORegistryEntryCreateCFProperty(
      service, "AdapterDetails" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
      as? [String: Any],
      let watts = adapter["Watts"] as? Int, watts > 0
    {
      m.adapterWatts = watts
    }

    return m.hasAny ? m : nil
  }

  /// AppleSmartBattery reports amperage as a 64-bit value; large values are negative (discharge).
  private static func signedAmperage(_ raw: Int?) -> Int? {
    guard let raw else { return nil }
    if raw > Int(Int32.max) { return raw - Int(UInt32.max) - 1 }
    return raw
  }
}
```

with:

```swift
enum SmartBatteryReader {
  /// One bulk IORegistry read of AppleSmartBattery, then a pure parse. Returns nil on a machine
  /// with no battery.
  static func read() -> BatteryMetrics? {
    guard let props = IORegistryReader.properties(matching: "AppleSmartBattery") else {
      return nil
    }
    return metrics(from: props)
  }

  /// Pure parse of one AppleSmartBattery property dictionary. Split out of `read()` so the health
  /// formula, the unit conversions and the sentinels can be tested against literal dictionaries
  /// instead of whatever the machine's battery happens to be doing.
  static func metrics(from props: [String: Any]) -> BatteryMetrics? {
    func intVal(_ key: String) -> Int? { (props[key] as? NSNumber)?.intValue }

    var m = BatteryMetrics()

    if let maxCap = intVal("AppleRawMaxCapacity") ?? intVal("MaxCapacity"),
      let design = intVal("DesignCapacity"), design > 0
    {
      m.healthPercent = Int((Double(maxCap) / Double(design) * 100).rounded())
    }
    m.cycleCount = intVal("CycleCount")
    if let rawTemp = intVal("Temperature") {
      m.temperatureC = Double(rawTemp) / 100.0  // reported in centi-degrees
    }
    if let mV = intVal("Voltage"), let mA = IORegistryReader.signedInt(intVal("Amperage")) {
      m.powerWatts = Double(mV) / 1000.0 * Double(mA) / 1000.0
    }
    // 65535 is the "still calculating" sentinel.
    if let ttf = intVal("AvgTimeToFull"), ttf > 0, ttf < 65535 { m.timeToFullMinutes = ttf }
    if let tte = intVal("AvgTimeToEmpty"), tte > 0, tte < 65535 { m.timeToEmptyMinutes = tte }
    if let adapter = props["AdapterDetails"] as? [String: Any],
      let watts = (adapter["Watts"] as? NSNumber)?.intValue, watts > 0
    {
      m.adapterWatts = watts
    }

    return m.hasAny ? m : nil
  }
}
```

- [ ] **Step 5: Diff before publishing in BatteryMonitor.refresh**

In `Islet/Activities/Battery/BatteryMonitor.swift`, replace the `refresh()` method:

```swift
  func refresh() {
    state = Self.readState()
    metrics = SmartBatteryReader.read()
    peripherals = PeripheralBatteryReader.read()
  }
```

with:

```swift
  /// Every value here is `Equatable`, and at 1 Hz almost all of them are unchanged from the last
  /// tick. Assigning regardless republishes three `@Published`s a second and redraws the whole
  /// expanded island for nothing, so diff first.
  func refresh() {
    let newState = Self.readState()
    if newState != state { state = newState }
    let newMetrics = SmartBatteryReader.read()
    if newMetrics != metrics { metrics = newMetrics }
    let newPeripherals = PeripheralBatteryReader.read()
    if newPeripherals != peripherals { peripherals = newPeripherals }
  }
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`
Expected: `** TEST SUCCEEDED **`, `Executed 109 tests, with 0 failures`.

- [ ] **Step 7: Manual check — the battery tab still shows real numbers**

```bash
killall Islet 2>/dev/null; open "$(xcodebuild -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' -showBuildSettings 2>/dev/null | awk -F' = ' '/^ *BUILT_PRODUCTS_DIR/ {print $2; exit}')/Islet.app"
```

Plug in the charger, expand the island and select the Battery tab. Confirm Health, Cycles, Temp, Power and Charger all show plausible values matching System Settings → Battery, and that Power still flips sign when you unplug. The reader was rewritten under these tiles; blank or zeroed tiles mean a key regressed.

- [ ] **Step 8: Commit**

```bash
git add Islet/Activities/Battery/BatteryMetrics.swift Islet/Activities/Battery/BatteryMonitor.swift IsletTests/SmartBatteryReaderTests.swift Islet.xcodeproj
git commit -m "Power: read the smart battery in one pass and publish only on change"
```

---

## Task 12: ThresholdDetector

**Files:**
- Create: `Islet/Core/ThresholdDetector.swift`
- Create: `IsletTests/ThresholdDetectorTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `struct ThresholdDetector: Equatable` with `enum Direction { case falling, rising }`, `let thresholds: [Double]`, `let direction: Direction`, `init(thresholds: [Double], direction: Direction)`, `func crossings(from old: Double?, to new: Double) -> [Double]`

- [ ] **Step 1: Write the failing test**

Create `IsletTests/ThresholdDetectorTests.swift`:

```swift
import XCTest

@testable import Islet

final class ThresholdDetectorTests: XCTestCase {
  let lowBattery = ThresholdDetector(thresholds: [20, 10], direction: .falling)
  let hotCPU = ThresholdDetector(thresholds: [80, 90], direction: .rising)

  func testFallingCrossingFiresOnce() {
    XCTAssertEqual(lowBattery.crossings(from: 21, to: 20), [20])
  }

  func testFallingDoesNotRefireBelowTheThreshold() {
    XCTAssertEqual(lowBattery.crossings(from: 20, to: 19), [])
    XCTAssertEqual(lowBattery.crossings(from: 15, to: 12), [])
  }

  func testFallingReportsEveryThresholdSkippedInOneStep() {
    // Declaration order, not numeric order: callers render them in the order they listed them.
    XCTAssertEqual(lowBattery.crossings(from: 21, to: 9), [20, 10])
  }

  func testNilBaselineIsNotACrossing() {
    // The first sample establishes a baseline; announcing it would fire an event at every launch.
    XCTAssertEqual(lowBattery.crossings(from: nil, to: 5), [])
    XCTAssertEqual(hotCPU.crossings(from: nil, to: 99), [])
  }

  func testEqualValuesDoNotCross() {
    XCTAssertEqual(lowBattery.crossings(from: 20, to: 20), [])
    XCTAssertEqual(lowBattery.crossings(from: 50, to: 50), [])
    XCTAssertEqual(hotCPU.crossings(from: 80, to: 80), [])
  }

  func testRisingCrossingFiresOnce() {
    XCTAssertEqual(hotCPU.crossings(from: 79, to: 85), [80])
  }

  func testRisingFiresOnLandingExactlyOnTheThreshold() {
    XCTAssertEqual(hotCPU.crossings(from: 79, to: 80), [80])
  }

  func testRisingDoesNotRefireAboveTheThreshold() {
    XCTAssertEqual(hotCPU.crossings(from: 80, to: 85), [])
    XCTAssertEqual(hotCPU.crossings(from: 85, to: 89), [])
  }

  func testRisingReportsEveryThresholdSkippedInOneStep() {
    XCTAssertEqual(hotCPU.crossings(from: 79, to: 95), [80, 90])
  }

  func testDetectorsCompareByThresholdsAndDirection() {
    XCTAssertEqual(lowBattery, ThresholdDetector(thresholds: [20, 10], direction: .falling))
    XCTAssertNotEqual(lowBattery, ThresholdDetector(thresholds: [20, 10], direction: .rising))
    XCTAssertNotEqual(lowBattery, ThresholdDetector(thresholds: [10, 20], direction: .falling))
  }
}
```

- [ ] **Step 2: Regenerate the project so the new test file is in the target**

Run: `xcodegen generate`
Expected: `Created project at Islet.xcodeproj`.

- [ ] **Step 3: Run the test to verify it fails**

Run: `xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`
Expected: compilation failure containing `cannot find 'ThresholdDetector' in scope`, ending in `** TEST BUILD FAILED **`.

- [ ] **Step 4: Create ThresholdDetector.swift**

Create `Islet/Core/ThresholdDetector.swift`:

```swift
import Foundation

/// Fires once per crossing of a fixed set of thresholds on one numeric series.
///
/// Extracted from the battery low-charge check so peripheral low battery, charge complete, low
/// disk space and CPU/thermal thresholds can share it. Pure and value-typed: hold one per series.
struct ThresholdDetector: Equatable {
  enum Direction: Equatable {
    /// Fires when the value drops onto or through a threshold (battery percent, free disk).
    case falling
    /// Fires when the value rises onto or through a threshold (CPU load, temperature).
    case rising
  }

  let thresholds: [Double]
  let direction: Direction

  init(thresholds: [Double], direction: Direction) {
    self.thresholds = thresholds
    self.direction = direction
  }

  /// Thresholds crossed going from `old` to `new`, in the order they were declared. Empty when
  /// `old` is nil — the first sample is a baseline, not a crossing, or every launch would announce
  /// whatever state the machine happened to already be in.
  func crossings(from old: Double?, to new: Double) -> [Double] {
    guard let old else { return [] }
    switch direction {
    case .falling: return thresholds.filter { old > $0 && new <= $0 }
    case .rising: return thresholds.filter { old < $0 && new >= $0 }
    }
  }
}
```

- [ ] **Step 5: Regenerate the project so the new source file is in the target**

Run: `xcodegen generate`
Expected: `Created project at Islet.xcodeproj`.

- [ ] **Step 6: Run tests to verify they pass**

Run: `xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`
Expected: `** TEST SUCCEEDED **`, `Executed 118 tests, with 0 failures`.

- [ ] **Step 7: Commit**

```bash
git add Islet/Core/ThresholdDetector.swift IsletTests/ThresholdDetectorTests.swift Islet.xcodeproj
git commit -m "Core: add a generalised threshold-crossing detector"
```

---

## Task 13: Refactor BatteryEventDetector onto ThresholdDetector

**Files:**
- Modify: `Islet/Activities/Battery/BatteryState.swift:17-35`
- Test: `IsletTests/BatteryEventDetectorTests.swift` — **unchanged**, and must stay that way.

**Interfaces:**
- Consumes: `ThresholdDetector(thresholds:direction:)`, `ThresholdDetector.crossings(from:to:)` (Task 12).
- Produces: no signature change. `BatteryEventDetector.thresholds` and `BatteryEventDetector.events(from:to:)` keep their exact shapes.

This is a behaviour-preserving refactor. The eight existing tests in `IsletTests/BatteryEventDetectorTests.swift` are the specification — do not edit that file. Note in particular that `testSkippingStraightThroughBothThresholds` pins the *order* `[20, 10]`, which is declaration order rather than numeric order, and `ThresholdDetector` preserves it because it filters the threshold array in place.

- [ ] **Step 1: Rewrite BatteryEventDetector on top of the detector**

In `Islet/Activities/Battery/BatteryState.swift`, replace lines 15-35:

```swift
/// Pure change detection between consecutive battery snapshots.
/// Low-battery events fire once per downward crossing of a threshold, and only on battery power.
enum BatteryEventDetector {
  static let thresholds = [20, 10]

  static func events(from old: BatteryState?, to new: BatteryState) -> [BatteryEvent] {
    guard let old else { return [] }  // first snapshot is baseline only
    var out: [BatteryEvent] = []
    if !old.onAC, new.onAC {
      out.append(.acConnected(percent: new.percent))
    } else if old.onAC, !new.onAC {
      out.append(.acDisconnected(percent: new.percent))
    }
    if !new.onAC {
      for t in Self.thresholds where old.percent > t && new.percent <= t {
        out.append(.lowBattery(threshold: t, percent: new.percent))
      }
    }
    return out
  }
}
```

with:

```swift
/// Pure change detection between consecutive battery snapshots.
/// Low-battery events fire once per downward crossing of a threshold, and only on battery power.
enum BatteryEventDetector {
  static let thresholds = [20, 10]

  /// Declaration order is load-bearing: dropping straight past both thresholds in one tick has to
  /// report 20 before 10.
  private static var lowBatteryDetector: ThresholdDetector {
    ThresholdDetector(thresholds: thresholds.map(Double.init), direction: .falling)
  }

  static func events(from old: BatteryState?, to new: BatteryState) -> [BatteryEvent] {
    guard let old else { return [] }  // first snapshot is baseline only
    var out: [BatteryEvent] = []
    if !old.onAC, new.onAC {
      out.append(.acConnected(percent: new.percent))
    } else if old.onAC, !new.onAC {
      out.append(.acDisconnected(percent: new.percent))
    }
    if !new.onAC {
      let crossed = lowBatteryDetector.crossings(
        from: Double(old.percent), to: Double(new.percent))
      for t in crossed {
        out.append(.lowBattery(threshold: Int(t), percent: new.percent))
      }
    }
    return out
  }
}
```

- [ ] **Step 2: Confirm the battery event tests were not touched**

Run: `git diff --stat IsletTests/BatteryEventDetectorTests.swift`
Expected: no output at all. Any output means the specification was edited to fit the implementation — revert the test file and fix the implementation instead.

- [ ] **Step 3: Run tests to verify they pass**

Run: `xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`
Expected: `** TEST SUCCEEDED **`, `Executed 118 tests, with 0 failures`.

- [ ] **Step 4: Commit**

```bash
git add Islet/Activities/Battery/BatteryState.swift
git commit -m "Power: detect low-battery crossings with the shared threshold detector"
```

---

## Task 14: Phase close-out

**Files:** none modified.

- [ ] **Step 1: Confirm no zero-argument geometry accessor survived**

Run: `grep -rn "geometry\.panelFrame$\|geometry\.expandedRect$\|Metrics\.opening\|Metrics\.closing\|Metrics\.compact\|Metrics\.panelShrinkDelay\|Metrics\.closingDuration\|setLiveMetrics" --include="*.swift" .`
Expected: no output. Any hit is a call site that was missed.

- [ ] **Step 2: Confirm the working tree is clean and the project file is committed**

Run: `git status --porcelain`
Expected: no output.

- [ ] **Step 3: Run the full suite one last time from a clean build**

Run: `xcodebuild clean test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`
Expected: `** TEST SUCCEEDED **`, `Executed 118 tests, with 0 failures`.

- [ ] **Step 4: Sanity-run the app once more**

```bash
killall Islet 2>/dev/null; open "$(xcodebuild -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' -showBuildSettings 2>/dev/null | awk -F' = ' '/^ *BUILT_PRODUCTS_DIR/ {print $2; exit}')/Islet.app"
```

Confirm: hovering the notch peeks, clicking expands, the switcher chips are narrow and scrollable, the gear opens Settings, tabs switch without the island resizing (no tab requests the tall tier yet), and the Battery tab's live values keep ticking across repeated tab switches.

---

## What Phase 2 through Phase 5 can now rely on

| Contract item | Where it landed |
|---|---|
| `Motion.opening/.closing/.compact/.closingDuration/.panelShrinkDelay` | `Islet/Core/Motion.swift` (Task 1) |
| `Motion.reduceMotion`, `Motion.gated(_:)` | `Islet/Core/Motion.swift` (Task 1) |
| `MotionProfile` | `Islet/Core/Motion.swift` (Task 1) |
| `Metrics.tallExpandedHeight` | `Islet/Core/Metrics.swift` (Task 3) |
| `NotchGeometry.expandedRect(height:)`, `.panelFrame(height:)` | `Islet/Core/NotchGeometry.swift` (Task 3) |
| `NotchViewModel.expandedHeight`, `.setExpandedHeight(_:)`, `.expandedRect` | `Islet/Core/NotchViewModel.swift` (Task 4) |
| `NotchActivity.preferredExpandedHeight` (default 190) | `Islet/Activities/NotchActivity.swift` (Task 5) |
| Scrollable switcher, 22pt chips | `Islet/UI/ExpandedContainerView.swift` (Task 7) |
| `LiveSamplingGate`, `View.liveSampling(_:)` | `Islet/Core/LiveSamplingGate.swift` (Task 8) |
| `BatteryMonitor.liveGate` | `Islet/Activities/Battery/BatteryMonitor.swift` (Task 9) |
| `IORegistryReader.properties/allProperties/signedInt` | `Islet/Core/IORegistryReader.swift` (Task 10) |
| `SmartBatteryReader.metrics(from:)` — the pure parse Phase 2 extends | `Islet/Activities/Battery/BatteryMetrics.swift` (Task 11) |
| `ThresholdDetector` | `Islet/Core/ThresholdDetector.swift` (Task 12) |

A Phase 2 or Phase 4 tab opts into the tall tier with one line in its activity:

```swift
  let preferredExpandedHeight = Metrics.tallExpandedHeight
```
