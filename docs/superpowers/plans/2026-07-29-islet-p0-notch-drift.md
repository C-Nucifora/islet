# Phase 0 — Position Drift Bug Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop the collapsed island drifting right and sliding under the hardware notch, and lock the fix in with pure-function regression tests.

**Architecture:** The island is drawn centred inside the panel window and nudged sideways by `NotchRootView.islandOffset`, which today computes that nudge from `vm.panelFrame` — the frame the app *requested* — while the island is actually drawn in the frame AppKit *gave* it. Phase 0 makes the real window frame authoritative (`constrainFrameRect` passthrough, a read-back into `NotchViewModel.actualPanelFrame`, and `reassert()` on every event that can move a window behind our back), corrects `notchRect.minX` to follow the left aux area instead of the screen centre, and lifts the alignment arithmetic out of the View into `NotchGeometry` so it is testable.

**Tech Stack:** Swift 6, SwiftUI, AppKit, XcodeGen, XCTest, sindresorhus/Defaults

## Global Constraints

- **Swift 6 strict concurrency:** most app types are `@MainActor`; pure logic types (`NotchGeometry`, `NotchStickiness`, `SneakLogic`, `BatteryEventDetector`, `AdapterParser`, `SourceFilter`) stay actor-free so tests call them synchronously. Do not add `@MainActor` to `NotchGeometry` or `NotchStickiness`.
- **XcodeGen:** `Islet.xcodeproj` is generated from `project.yml` and is gitignored. Any step that CREATES a new `.swift` file must be followed immediately by `xcodegen generate` before building, or the file is not in the target and the build fails with "cannot find X in scope". `xcodegen generate` prints a warning about `Vendor/MediaRemoteAdapter.framework`; that is expected and harmless.
- **Test command:** `xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`. Baseline is **75 passing tests, ~11s**, ending in `** TEST SUCCEEDED **`. This plan ends at **86**.
- **Build command:** `xcodebuild build -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`, ending in `** BUILD SUCCEEDED **`.
- **Commit rule:** commit after every green test run. Messages are a scope prefix then a lowercase imperative summary, e.g. `Notch: re-assert the panel frame on Space change`.
- **No AI attribution in commits:** never add a `Co-Authored-By` trailer, and never mention Claude, Anthropic or AI in a commit message.
- **Phase-specific invariant — do NOT reshape `expandedRect` / `panelFrame`.** Phase 1.2 later converts `NotchGeometry.expandedRect` and `NotchGeometry.panelFrame` from zero-argument computed properties into height-parameterised **functions** (`func expandedRect(height:) -> CGRect`, `func panelFrame(height:) -> CGRect`) and adds `NotchViewModel.expandedHeight`. Phase 0 ships first and must leave them as the zero-argument computed properties they are today (`NotchGeometry.swift:43-48`, `:50-54`). Write every new call against the current property form.
- **Phase-specific invariant — existing tests are untouchable.** All 75 tests in `IsletTests/` must keep passing without being edited. New tests are added; existing ones are not modified.
- **Line numbers are as of the start of Phase 0.** Earlier tasks shift later ones. Every replacement step also quotes the exact text being replaced — anchor on the quoted text, not the number.

---

## File Structure

**Created**

| File | Single responsibility |
|---|---|
| `Islet/Core/NotchStickiness.swift` | Pure, per-display memory of the last hardware-notch measurement, so a transient empty aux-area read cannot downgrade a built-in display to the 200pt fallback. |

**Modified**

| File | What changes |
|---|---|
| `Islet/Core/NotchGeometry.swift` | Stores `auxLeftWidth`; `notchRect.minX` derives from it; gains `islandBodyWidth`, `islandOffset(inPanel:…)` and `collapsedIslandRect(inPanel:…)` — the alignment maths lifted out of the View. |
| `Islet/Core/NotchPanel.swift` | Overrides `constrainFrameRect(_:to:)` to return the requested rect untouched. |
| `Islet/Core/NotchViewModel.swift` | Adds `actualPanelFrame` + `setActualPanelFrame`; clears `shrinkTask` on the cancelled path; adds `cancelPendingShrink()`. |
| `Islet/Core/NSScreen+Notch.swift` | Splits the raw notch reading (`notchReading`) from geometry construction (`notchGeometry(reading:)`) so stickiness can sit between them. |
| `Islet/Core/ScreenManager.swift` | `Instance` struct becomes a `PanelInstance` class that owns every `setFrame`, reads the window frame straight back, and can `reassert()`; four new re-assert triggers; the Space observer is registered unconditionally; stickiness is applied at rebuild. |
| `Islet/UI/NotchRootView.swift` | Offsets against `vm.actualPanelFrame` via `NotchGeometry.islandOffset`; consolidates slot widths through `effectiveCompact`; rejects slot measurements from a stale (outgoing) `.id` subtree. |
| `IsletTests/NotchGeometryTests.swift` | +8 tests: island-position invariance under panel drift, panel containment, `auxLeftWidth` origin, non-zero screen origin, fallback centring, and three `NotchStickiness` cases. |
| `IsletTests/NotchViewModelTests.swift` | +3 tests: `actualPanelFrame` seeding, `actualPanelFrame` tracking the window rather than the request, and a cancelled shrink not blocking later shrinks. |

---

### Task 1: Lift the island alignment maths into NotchGeometry

The bug is a View computing screen positions from the wrong rectangle. Nothing about that arithmetic is testable while it lives in a `private var` on a SwiftUI `View`, so it moves first.

**Files:**
- Modify: `Islet/Core/NotchGeometry.swift:63-71` (append after `collapsedPanelFrame`)
- Test: `IsletTests/NotchGeometryTests.swift`

**Interfaces:**
- Consumes: `NotchGeometry.notchRect`, `NotchGeometry.notchSize`, `NotchGeometry.collapsedPanelFrame(compactLeading:compactTrailing:)`, `NotchGeometry.panelFrame`, `Metrics.closedOversize`, `Metrics.closedRadii`, `Metrics.islandMargin` — all existing.
- Produces (used by Task 8, and by Task 6's test):
  ```swift
  func islandBodyWidth(compactLeading: CGFloat, compactTrailing: CGFloat) -> CGFloat
  func islandOffset(inPanel panel: CGRect, compactLeading: CGFloat, compactTrailing: CGFloat) -> CGFloat
  func collapsedIslandRect(inPanel panel: CGRect, compactLeading: CGFloat, compactTrailing: CGFloat) -> CGRect
  ```
  `islandBodyWidth` is **not** in the phase interface contract; it is defined here because `collapsedIslandRect` and `NotchRootView.bodySize` would otherwise each carry their own copy of the same formula, which is exactly how the two drift apart.

- [ ] **Step 1: Write the failing tests**

Append these two tests to `IsletTests/NotchGeometryTests.swift`, immediately before the closing `}` of `final class NotchGeometryTests` (i.e. after `testFallbackWhenNoNotch` at `:69-75`):

```swift
  // MARK: - Island alignment
  //
  // The island is drawn centred in the panel window and nudged sideways by `islandOffset`. If that
  // nudge is computed against a frame the window does not actually have, the divergence lands 1:1
  // on the drawn island — it slides right and disappears under the hardware notch, and no hover
  // ever clears it. These pin the offset down as a function of the REAL panel frame.

  func testIslandScreenPositionIsInvariantUnderAnArbitraryPanelFrame() {
    let leading: CGFloat = 18
    let trailing: CGFloat = 76
    let sized = mbp.collapsedPanelFrame(compactLeading: leading, compactTrailing: trailing)
    // Where the island body must land, expressed only in hardware terms.
    let expectedMinX = mbp.notchRect.minX - Metrics.closedOversize - leading
    let expectedMaxX = mbp.notchRect.maxX + Metrics.closedOversize + trailing

    let panels: [CGRect] = [
      sized,  // the frame we asked for
      sized.offsetBy(dx: 37, dy: 0),  // AppKit nudged us right
      sized.offsetBy(dx: -12.5, dy: 0),  // ... or left, fractionally
      mbp.panelFrame,  // ... or we are still held at expanded size mid-collapse
    ]
    for panel in panels {
      let body = mbp.collapsedIslandRect(
        inPanel: panel, compactLeading: leading, compactTrailing: trailing)
      XCTAssertEqual(body.minX, expectedMinX, accuracy: 0.01, "panel \(panel)")
      XCTAssertEqual(body.maxX, expectedMaxX, accuracy: 0.01, "panel \(panel)")
      XCTAssertEqual(body.maxY, panel.maxY, accuracy: 0.01, "panel \(panel)")
    }
  }

  func testASizedPanelFullyContainsItsIslandOnBothFlanks() {
    let leading: CGFloat = 18
    let trailing: CGFloat = 76
    let panel = mbp.collapsedPanelFrame(compactLeading: leading, compactTrailing: trailing)
    let body = mbp.collapsedIslandRect(
      inPanel: panel, compactLeading: leading, compactTrailing: trailing)
    XCTAssertTrue(panel.contains(body), "panel \(panel) clips island \(body)")
    // Asymmetric slots must not eat the margin on the narrow side: both flanks keep the corner
    // flare plus the island margin, which is the whole point of sizing each flank independently.
    let slack = Metrics.closedRadii.top + Metrics.islandMargin
    XCTAssertEqual(body.minX - panel.minX, slack, accuracy: 0.01)
    XCTAssertEqual(panel.maxX - body.maxX, slack, accuracy: 0.01)
  }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`

Expected: the build fails before any test executes. The tail contains

```
IsletTests/NotchGeometryTests.swift:__:__: error: value of type 'NotchGeometry' has no member 'collapsedIslandRect'
```

and the run ends with `** TEST FAILED **` (some Xcode versions print `** TEST BUILD FAILED **` — the `error:` line is the signal, not the banner).

- [ ] **Step 3: Add the three functions to NotchGeometry**

In `Islet/Core/NotchGeometry.swift`, insert this block after `collapsedPanelFrame` ends at `:71` and before the struct's closing `}` at `:72`:

```swift

  // MARK: - Island alignment

  /// Width of the drawn island body — the black shape, EXCLUDING the outward corner flare — for a
  /// pair of measured compact slot widths. One definition, shared by the view that draws it and by
  /// `collapsedIslandRect` below that says where it lands.
  func islandBodyWidth(compactLeading: CGFloat, compactTrailing: CGFloat) -> CGFloat {
    notchSize.width + Metrics.closedOversize * 2 + compactLeading + compactTrailing
  }

  /// Horizontal offset that lines the island's notch cut-out up with the hardware notch.
  ///
  /// `panel` must be the frame the window ACTUALLY occupies, not the frame the app asked for. The
  /// island is drawn centred in the real window, so any divergence between requested and real maps
  /// 1:1 onto a horizontal shift of the drawn island — the drift this function exists to make
  /// testable. Positioning off the notch's offset within the panel rather than the panel's centre
  /// also keeps the island aligned while the panel is still held at expanded size mid-collapse.
  func islandOffset(inPanel panel: CGRect, compactLeading: CGFloat, compactTrailing: CGFloat)
    -> CGFloat
  {
    notchRect.midX - panel.midX + (compactTrailing - compactLeading) / 2
  }

  /// Where the collapsed island body lands on screen, given the panel it is drawn in. Height is the
  /// `.closed` body; `.peek` grows by 4pt instead of 2pt but never moves in x, so every alignment
  /// assertion here holds for both.
  func collapsedIslandRect(inPanel panel: CGRect, compactLeading: CGFloat, compactTrailing: CGFloat)
    -> CGRect
  {
    let width = islandBodyWidth(compactLeading: compactLeading, compactTrailing: compactTrailing)
    let height = notchSize.height + Metrics.closedOversize
    let centreX =
      panel.midX
      + islandOffset(
        inPanel: panel, compactLeading: compactLeading, compactTrailing: compactTrailing)
    return CGRect(
      x: centreX - width / 2, y: panel.maxY - height, width: width, height: height)
  }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`

Expected: `** TEST SUCCEEDED **`, `Executed 77 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Islet/Core/NotchGeometry.swift IsletTests/NotchGeometryTests.swift
git commit -m "Notch: lift the island alignment maths into NotchGeometry"
```

---

### Task 2: Derive notchRect.minX from auxLeftWidth, not the screen centre

`notchRect` currently sits at `screenFrame.midX - notchSize.width / 2` (`NotchGeometry.swift:29`). The aux areas are not equal on real hardware, and that form shifts the island by `(auxRight − auxLeft) / 2`.

**Files:**
- Modify: `Islet/Core/NotchGeometry.swift:4-8` (stored properties), `:10-25` (init), `:27-32` (`notchRect`)
- Test: `IsletTests/NotchGeometryTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces: `NotchGeometry.auxLeftWidth: CGFloat` (a new stored `let`; `NotchGeometry`'s synthesised `Equatable` conformance now includes it).

- [ ] **Step 1: Write the failing tests**

Append these three tests to `IsletTests/NotchGeometryTests.swift`, before the closing `}` of the class. One of the three (`testNotchRectFollowsAuxLeftWidthNotTheScreenCentre`) fails today; the other two are new coverage that passes immediately and exists to stop the change breaking the centred cases.

```swift
  // MARK: - Notch origin
  //
  // Every fixture above sits at screen origin (0,0) with symmetric 716/716 aux areas, so nothing
  // catches an x term that forgot `screenFrame.minX` or one that assumed a centred notch.

  func testNotchRectFollowsAuxLeftWidthNotTheScreenCentre() {
    // Real hardware: the aux areas differ by a few points. Deriving the origin from the screen
    // centre puts the notch at 712 and drags the whole island 4pt right of the hardware.
    let offCentre = NotchGeometry(
      screenFrame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
      safeAreaTop: 32, auxLeftWidth: 716, auxRightWidth: 708, menuBarHeight: 37)
    XCTAssertEqual(offCentre.notchSize.width, 304)
    XCTAssertEqual(offCentre.notchRect.minX, 716, accuracy: 0.01)
    XCTAssertEqual(offCentre.notchRect.maxX, 1728 - 708, accuracy: 0.01)
    XCTAssertNotEqual(offCentre.notchRect.midX, offCentre.screenFrame.midX)
  }

  func testPanelsCentreOnTheNotchForAScreenAtANonZeroOrigin() {
    // A second display placed to the right of the built-in one. notch = 1512 - 610 - 610 = 292,
    // starting at 1728 + 610 = 2338, so its centre is 2484.
    let secondary = NotchGeometry(
      screenFrame: CGRect(x: 1728, y: 0, width: 1512, height: 982),
      safeAreaTop: 32, auxLeftWidth: 610, auxRightWidth: 610, menuBarHeight: 37)
    XCTAssertEqual(secondary.notchSize.width, 292)
    XCTAssertEqual(secondary.notchRect.minX, 2338, accuracy: 0.01)
    XCTAssertEqual(secondary.notchRect.midX, 2484, accuracy: 0.01)
    XCTAssertEqual(secondary.panelFrame.midX, 2484, accuracy: 0.01)
    XCTAssertEqual(secondary.expandedRect.midX, 2484, accuracy: 0.01)
    XCTAssertEqual(secondary.collapsedPanelFrame().midX, 2484, accuracy: 0.01)
    XCTAssertEqual(secondary.panelFrame.maxY, 982)
    let body = secondary.collapsedIslandRect(
      inPanel: secondary.collapsedPanelFrame(), compactLeading: 0, compactTrailing: 0)
    XCTAssertEqual(body.midX, 2484, accuracy: 0.01)
  }

  func testFallbackNotchStaysScreenCentred() {
    // No hardware notch: there is no aux area to anchor to, so the 200pt rectangle keeps centring
    // on the screen — including on a screen that does not start at x = 0.
    let ext = NotchGeometry(
      screenFrame: CGRect(x: 2560, y: 0, width: 2560, height: 1440),
      safeAreaTop: 0, auxLeftWidth: 0, auxRightWidth: 0, menuBarHeight: 24)
    XCTAssertFalse(ext.hasHardwareNotch)
    XCTAssertEqual(ext.notchRect.midX, ext.screenFrame.midX, accuracy: 0.01)
    XCTAssertEqual(ext.notchRect.minX, 3840 - Metrics.fallbackNotchWidth / 2, accuracy: 0.01)
  }
```

- [ ] **Step 2: Run the tests to verify one fails**

Run: `xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`

Expected: `** TEST FAILED **`, `Executed 80 tests, with 1 failure`, with

```
IsletTests/NotchGeometryTests.swift:__: error: -[IsletTests.NotchGeometryTests testNotchRectFollowsAuxLeftWidthNotTheScreenCentre] : XCTAssertEqual failed: ("712.0") is not equal to ("716.0") +/- ("0.01")
```

- [ ] **Step 3: Store auxLeftWidth and anchor notchRect to it**

In `Islet/Core/NotchGeometry.swift`, replace lines 4-32 (from `struct NotchGeometry: Equatable {` through the end of `notchRect`) with:

```swift
struct NotchGeometry: Equatable {
  let screenFrame: CGRect
  let notchSize: CGSize
  let hasHardwareNotch: Bool
  let menuBarHeight: CGFloat
  /// Width of the menu bar area to the LEFT of the hardware notch, as AppKit reports it. Stored
  /// because the notch is not centred: `auxLeftWidth` and `auxRightWidth` differ by a few points on
  /// real hardware, and deriving the notch origin from the screen centre shifts the drawn island by
  /// half that difference — rightward whenever the right aux area is the wider one.
  let auxLeftWidth: CGFloat

  init(
    screenFrame: CGRect, safeAreaTop: CGFloat, auxLeftWidth: CGFloat,
    auxRightWidth: CGFloat, menuBarHeight: CGFloat
  ) {
    self.screenFrame = screenFrame
    self.menuBarHeight = menuBarHeight
    self.auxLeftWidth = auxLeftWidth
    if safeAreaTop > 0, auxLeftWidth > 0, auxRightWidth > 0 {
      hasHardwareNotch = true
      notchSize = CGSize(
        width: screenFrame.width - auxLeftWidth - auxRightWidth,
        height: safeAreaTop)
    } else {
      hasHardwareNotch = false
      notchSize = CGSize(width: Metrics.fallbackNotchWidth, height: max(menuBarHeight, 24))
    }
  }

  /// With real hardware the notch starts where AppKit says it starts — the screen's left edge plus
  /// the left aux area. Without one there is nothing to anchor to, so the fallback rectangle
  /// centres on the screen.
  var notchRect: CGRect {
    let x =
      hasHardwareNotch
      ? screenFrame.minX + auxLeftWidth
      : screenFrame.midX - notchSize.width / 2
    return CGRect(
      x: x, y: screenFrame.maxY - notchSize.height,
      width: notchSize.width, height: notchSize.height)
  }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`

Expected: `** TEST SUCCEEDED **`, `Executed 80 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Islet/Core/NotchGeometry.swift IsletTests/NotchGeometryTests.swift
git commit -m "Notch: anchor the notch rect to the left aux area instead of the screen centre"
```

---

### Task 3: NotchStickiness — a built-in display never loses its notch

`NotchGeometry.init` treats an empty aux read as "no notch" and substitutes a 200pt rectangle in the middle of the screen (`NotchGeometry.swift:16`, `:23`). On a built-in display that is visibly wrong and, since geometry is only rebuilt on display changes, it sticks. This is a defensive floor, not a claim about undocumented AppKit behaviour — Task 7 logs every substitution.

**Files:**
- Create: `Islet/Core/NotchStickiness.swift`
- Test: `IsletTests/NotchGeometryTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces (used by Task 7):
  ```swift
  struct NotchStickiness: Equatable {
    struct Reading: Equatable {
      var safeAreaTop: CGFloat
      var auxLeftWidth: CGFloat
      var auxRightWidth: CGFloat
      var hasNotch: Bool { get }
    }
    init()
    mutating func resolve(displayUUID: String, isBuiltin: Bool, reading: Reading) -> Reading
  }
  ```

- [ ] **Step 1: Write the failing tests**

Append to `IsletTests/NotchGeometryTests.swift`, before the closing `}` of the class:

```swift
  // MARK: - Notch stickiness

  private var notchedReading: NotchStickiness.Reading {
    NotchStickiness.Reading(safeAreaTop: 32, auxLeftWidth: 716, auxRightWidth: 708)
  }
  private var emptyReading: NotchStickiness.Reading {
    NotchStickiness.Reading(safeAreaTop: 0, auxLeftWidth: 0, auxRightWidth: 0)
  }

  func testAKnownNotchedBuiltinDisplayKeepsItsNotchWhenAuxAreasReadEmpty() {
    var sticky = NotchStickiness()
    XCTAssertTrue(notchedReading.hasNotch)
    XCTAssertFalse(emptyReading.hasNotch)
    XCTAssertEqual(
      sticky.resolve(displayUUID: "builtin", isBuiltin: true, reading: notchedReading),
      notchedReading)
    // A transient empty read must not downgrade it to the 200pt fallback.
    XCTAssertEqual(
      sticky.resolve(displayUUID: "builtin", isBuiltin: true, reading: emptyReading),
      notchedReading)
    // ... and the geometry built from what we hand back still has a hardware notch.
    let remembered = sticky.resolve(
      displayUUID: "builtin", isBuiltin: true, reading: emptyReading)
    let geometry = NotchGeometry(
      screenFrame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
      safeAreaTop: remembered.safeAreaTop, auxLeftWidth: remembered.auxLeftWidth,
      auxRightWidth: remembered.auxRightWidth, menuBarHeight: 37)
    XCTAssertTrue(geometry.hasHardwareNotch)
    XCTAssertEqual(geometry.notchRect.minX, 716, accuracy: 0.01)
  }

  func testAnExternalDisplayIsNeverStickied() {
    var sticky = NotchStickiness()
    _ = sticky.resolve(displayUUID: "external", isBuiltin: false, reading: notchedReading)
    // An external display that stops reporting a notch really has stopped having one.
    XCTAssertEqual(
      sticky.resolve(displayUUID: "external", isBuiltin: false, reading: emptyReading),
      emptyReading)
  }

  func testStickinessIsKeyedPerDisplay() {
    var sticky = NotchStickiness()
    _ = sticky.resolve(displayUUID: "A", isBuiltin: true, reading: notchedReading)
    XCTAssertEqual(
      sticky.resolve(displayUUID: "B", isBuiltin: true, reading: emptyReading), emptyReading)
  }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`

Expected: the build fails with

```
IsletTests/NotchGeometryTests.swift:__:__: error: cannot find 'NotchStickiness' in scope
```

- [ ] **Step 3: Create Islet/Core/NotchStickiness.swift**

```swift
import Foundation

/// Last-known hardware-notch measurements, per display.
///
/// `NSScreen.safeAreaInsets` and `auxiliaryTopLeftArea` / `auxiliaryTopRightArea` can read empty
/// transiently — during display reconfiguration, on wake, and around a Space switch.
/// `NotchGeometry.init` reads an empty triple as "no hardware notch" and falls back to a 200pt
/// rectangle centred on the screen, which on a built-in display is visibly wrong and survives until
/// the next rebuild.
///
/// This is written as a defensive floor rather than as a claim about undocumented AppKit behaviour:
/// a built-in display that has ever reported a notch keeps it, everything else is passed straight
/// through, and the caller logs every substitution so the transition is observable before anyone
/// relies on it.
///
/// Deliberately actor-free: pure logic, so tests call it synchronously.
struct NotchStickiness: Equatable {
  /// The three numbers `NotchGeometry` needs to decide whether a screen has a hardware notch.
  struct Reading: Equatable {
    var safeAreaTop: CGFloat
    var auxLeftWidth: CGFloat
    var auxRightWidth: CGFloat

    /// Matches `NotchGeometry.init`'s test exactly. When this is false the 200pt fallback applies.
    var hasNotch: Bool { safeAreaTop > 0 && auxLeftWidth > 0 && auxRightWidth > 0 }
  }

  private var lastNotched: [String: Reading] = [:]

  init() {}

  /// Records a notched reading, and substitutes the last recorded one when a BUILT-IN display reads
  /// empty. Returns `reading` untouched in every other case, so external displays and displays that
  /// never had a notch behave exactly as before.
  mutating func resolve(displayUUID: String, isBuiltin: Bool, reading: Reading) -> Reading {
    if reading.hasNotch {
      lastNotched[displayUUID] = reading
      return reading
    }
    guard isBuiltin, let remembered = lastNotched[displayUUID] else { return reading }
    return remembered
  }
}
```

- [ ] **Step 4: Regenerate the Xcode project**

A new `.swift` file is not in the target until XcodeGen re-globs `Islet/`.

Run: `xcodegen generate`

Expected: `Loaded project ... Created project at .../Islet.xcodeproj`, preceded by a warning about `Vendor/MediaRemoteAdapter.framework` — expected and harmless.

- [ ] **Step 5: Run tests to verify they pass**

Run: `xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`

Expected: `** TEST SUCCEEDED **`, `Executed 83 tests, with 0 failures`.

- [ ] **Step 6: Commit**

```bash
git add Islet/Core/NotchStickiness.swift IsletTests/NotchGeometryTests.swift
git commit -m "Notch: remember the last hardware notch reading per display"
```

---

### Task 4: Stop AppKit adjusting the panel frame

`NotchPanel` (24 lines, `NotchPanel.swift:1-24`) does not override `constrainFrameRect(_:to:)`, so AppKit is free to adjust any rect handed to `setFrame` — and the adjustment is never fed back.

**Files:**
- Modify: `Islet/Core/NotchPanel.swift:22-23`

**Interfaces:**
- Consumes: nothing.
- Produces: `NotchPanel.constrainFrameRect(_:to:)` override (an AppKit override, not called directly by Islet code).

- [ ] **Step 1: Add the override**

No unit test — `NSPanel` cannot be exercised meaningfully from `IsletTests` without a window server session, and the behaviour under test is AppKit's. Verified by build plus the manual check in Step 3.

In `Islet/Core/NotchPanel.swift`, replace lines 22-23:

```swift
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
```

with:

```swift
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }

  /// AppKit is otherwise free to adjust the rect handed to `setFrame` — to keep a title bar on
  /// screen, to respect the menu bar, to fit a "usable" area. The island is positioned to the pixel
  /// against the hardware notch and deliberately overlaps the menu bar, so every such adjustment is
  /// wrong, and because the adjusted rect was never read back it was also permanent.
  override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
    frameRect
  }
```

- [ ] **Step 2: Build**

Run: `xcodebuild build -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Manual check**

```bash
open "$(xcodebuild -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR/ {print $2; exit}')/Islet.app"
```

Confirm: the island still appears over the hardware notch, hovering it still peeks, and clicking it still expands. Nothing should look different yet — this step only removes AppKit's licence to move the window. Quit the app (menu bar icon → Quit, or `pkill -x Islet`) before continuing.

- [ ] **Step 4: Run the full test suite**

Run: `xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`

Expected: `** TEST SUCCEEDED **`, `Executed 83 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Islet/Core/NotchPanel.swift
git commit -m "Notch: return the requested frame unchanged from constrainFrameRect"
```

---

### Task 5: NotchViewModel.actualPanelFrame

`panelFrame` (`NotchViewModel.swift:11`) is what Islet *asks* for. The island is drawn in what it *gets*. Those are two different numbers and the view needs the second one.

**Files:**
- Modify: `Islet/Core/NotchViewModel.swift:9-11` (property), `:27-39` (init)
- Test: `IsletTests/NotchViewModelTests.swift`

**Interfaces:**
- Consumes: `NotchGeometry.collapsedPanelFrame()`, `NotchGeometry.collapsedIslandRect(inPanel:compactLeading:compactTrailing:)` (Task 1).
- Produces (used by Tasks 7 and 8):
  ```swift
  @Published private(set) var actualPanelFrame: CGRect
  func setActualPanelFrame(_ frame: CGRect)
  ```

- [ ] **Step 1: Write the failing tests**

Append to `IsletTests/NotchViewModelTests.swift`, before the closing `}` of `final class NotchViewModelTests` (i.e. after `testHoverRegionWhileExpandedIsExpandedRect` at `:98-104`):

```swift
  // MARK: - Actual panel frame
  //
  // `panelFrame` is what we ask AppKit for; `actualPanelFrame` is what the window ended up with.
  // The island is drawn centred in the real window, so the drawing offset must use the second one.

  func testActualPanelFrameStartsEqualToTheRequestedFrame() {
    let vm = makeVM()
    XCTAssertEqual(vm.actualPanelFrame, vm.panelFrame)
    XCTAssertEqual(vm.actualPanelFrame, vm.geometry.collapsedPanelFrame())
  }

  func testActualPanelFrameTracksTheWindowNotTheRequest() {
    let vm = makeVM()
    let drifted = vm.panelFrame.offsetBy(dx: 37, dy: 0)
    vm.setActualPanelFrame(drifted)
    XCTAssertEqual(vm.actualPanelFrame, drifted)
    XCTAssertNotEqual(vm.panelFrame, drifted)  // the request is left alone

    // The whole point: with the real frame in hand the island still lands on the notch.
    let body = vm.geometry.collapsedIslandRect(
      inPanel: vm.actualPanelFrame, compactLeading: 0, compactTrailing: 0)
    XCTAssertEqual(
      body.minX, vm.geometry.notchRect.minX - Metrics.closedOversize, accuracy: 0.01)
  }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`

Expected: the build fails with

```
IsletTests/NotchViewModelTests.swift:__:__: error: value of type 'NotchViewModel' has no member 'actualPanelFrame'
```

- [ ] **Step 3: Add the property, the seed and the setter**

In `Islet/Core/NotchViewModel.swift`, replace lines 9-11:

```swift
  /// Screen-coordinate frame the panel should occupy right now. Tracked so the collapsed island
  /// doesn't reserve — and swallow the clicks of — the whole expanded footprint.
  @Published private(set) var panelFrame: CGRect
```

with:

```swift
  /// Screen-coordinate frame the panel should occupy right now. Tracked so the collapsed island
  /// doesn't reserve — and swallow the clicks of — the whole expanded footprint. This is a
  /// REQUEST: AppKit is handed it, and what the window ends up with is `actualPanelFrame`.
  @Published private(set) var panelFrame: CGRect
  /// The frame the window really occupies, read back from AppKit after every `setFrame` by
  /// `ScreenManager`. Anything that positions drawn content on screen must use this: the island is
  /// drawn centred in the real window, so any divergence from `panelFrame` maps 1:1 onto a
  /// horizontal shift of the island.
  @Published private(set) var actualPanelFrame: CGRect
```

Then replace line 30:

```swift
    self.panelFrame = geometry.collapsedPanelFrame()
```

with:

```swift
    let initialFrame = geometry.collapsedPanelFrame()
    self.panelFrame = initialFrame
    self.actualPanelFrame = initialFrame
```

Then add this method immediately after `updateCompactWidths` ends at `:80` (before `targetPanelFrame` at `:82`):

```swift
  /// Records where AppKit actually put the window. Only drawing offsets read it — `panelFrame`
  /// remains the single source of truth for what Islet asks for, so a rejected request is visible
  /// as a divergence rather than being quietly adopted as the new intent.
  func setActualPanelFrame(_ frame: CGRect) {
    guard frame != actualPanelFrame else { return }
    actualPanelFrame = frame
  }

```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`

Expected: `** TEST SUCCEEDED **`, `Executed 85 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Islet/Core/NotchViewModel.swift IsletTests/NotchViewModelTests.swift
git commit -m "Notch: track the frame the panel window actually has"
```

---

### Task 6: A cancelled shrink must not strand shrinkTask

`updatePanelFrame` gates on `shrinkTask == nil` (`NotchViewModel.swift:99`) and clears the handle inside the debounce body (`:102`). `debounce` returns early on cancellation (`:140`) so the body never runs — a cancelled shrink leaves `shrinkTask` non-nil forever and the panel can never shrink again, permanently reserving expanded-sized menu bar that nobody can click.

**Files:**
- Modify: `Islet/Core/NotchViewModel.swift:99-106` (the shrink scheduling), `:131-143` (`debounce`)
- Test: `IsletTests/NotchViewModelTests.swift`

**Interfaces:**
- Consumes: `Metrics.panelShrinkDelay`, `NotchGeometry.collapsedPanelFrame(compactLeading:compactTrailing:)`.
- Produces: `NotchViewModel.cancelPendingShrink()`, and a `cleanup:` parameter on the private `debounce` helper.

- [ ] **Step 1: Write the failing test**

Append to `IsletTests/NotchViewModelTests.swift`, before the closing `}` of the class:

```swift
  /// Nothing in the app cancels the shrink today, but the handle that gates it must survive
  /// cancellation: a stranded non-nil `shrinkTask` fails the `shrinkTask == nil` guard forever, so
  /// the panel stays expanded-sized and the menu bar under it stays dead to clicks.
  func testACancelledShrinkDoesNotBlockLaterShrinks() async throws {
    let vm = makeVM(mode: .clickToPin)
    vm.handleMouseDown(CGPoint(x: 864, y: 1110))  // expand: panel grows immediately
    vm.handleMouseDown(CGPoint(x: 100, y: 500))  // close: a shrink is scheduled
    vm.cancelPendingShrink()
    try await Task.sleep(for: Metrics.panelShrinkDelay + .milliseconds(200))
    XCTAssertEqual(vm.panelFrame, vm.geometry.panelFrame)  // cancelled, so nothing shrank

    // A later slot measurement must still be able to schedule a fresh shrink.
    vm.updateCompactWidths(leading: 10, trailing: 10)
    try await Task.sleep(for: Metrics.panelShrinkDelay + .milliseconds(300))
    XCTAssertEqual(
      vm.panelFrame,
      vm.geometry.collapsedPanelFrame(compactLeading: 10, compactTrailing: 10))
  }
```

- [ ] **Step 2: Run the test to verify it fails to compile**

Run: `xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`

Expected: the build fails with

```
IsletTests/NotchViewModelTests.swift:__:__: error: value of type 'NotchViewModel' has no member 'cancelPendingShrink'
```

- [ ] **Step 3: Add cancelPendingShrink() only — do not fix the bug yet**

In `Islet/Core/NotchViewModel.swift`, add this method immediately after `updatePanelFrame` ends at `:106` and before `func apply(_ event:)` at `:108`:

```swift
  /// Cancels a pending shrink without scheduling a replacement. Exposed for tests: nothing in the
  /// app cancels it today, and the point of the test is that the gating handle survives a cancel.
  func cancelPendingShrink() { shrinkTask?.cancel() }

```

- [ ] **Step 4: Run the test to verify it fails for the right reason**

Run: `xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`

Expected: `** TEST FAILED **`, `Executed 86 tests, with 1 failure`, with the second assertion failing because the panel never shrank:

```
IsletTests/NotchViewModelTests.swift:__: error: -[IsletTests.NotchViewModelTests testACancelledShrinkDoesNotBlockLaterShrinks] : XCTAssertEqual failed: ("(560.0, 907.0, 608.0, 210.0)") is not equal to ("(694.0, 1073.0, 340.0, 44.0)")
```

- [ ] **Step 5: Release the handle on the cancelled path**

In `Islet/Core/NotchViewModel.swift`, replace lines 99-105 (the shrink scheduling inside `updatePanelFrame`):

```swift
    guard target != panelFrame, shrinkTask == nil else { return }
    shrinkTask = Self.debounce(for: Metrics.panelShrinkDelay) { [weak self] in
      guard let self else { return }
      self.shrinkTask = nil
      let settled = self.targetPanelFrame(for: self.state)
      if settled != self.panelFrame { self.panelFrame = settled }
    }
```

with:

```swift
    guard target != panelFrame, shrinkTask == nil else { return }
    shrinkTask = Self.debounce(
      for: Metrics.panelShrinkDelay,
      cleanup: { [weak self] in self?.shrinkTask = nil }
    ) { [weak self] in
      guard let self else { return }
      let settled = self.targetPanelFrame(for: self.state)
      if settled != self.panelFrame { self.panelFrame = settled }
    }
```

Then replace lines 131-143 (`debounce`) with:

```swift
  /// Runs `body` after `delay`, cancelling any timer passed as `cancelling`. Omitting it schedules
  /// without disturbing what's already in flight.
  ///
  /// `cleanup` runs on EVERY path, cancellation included. A handle that gates future scheduling —
  /// `shrinkTask`, whose non-nil-ness blocks the next shrink — has to be released even when the
  /// timer never fires, or the first cancel blocks that path for the rest of the process. Nilling
  /// the handle here is safe against clobbering a newer one: no replacement can be scheduled while
  /// the old handle is still non-nil.
  private static func debounce(
    cancelling existing: Task<Void, Never>? = nil, for delay: Duration,
    cleanup: (@MainActor () -> Void)? = nil,
    _ body: @escaping @MainActor () -> Void
  ) -> Task<Void, Never> {
    existing?.cancel()
    return Task { @MainActor in
      try? await Task.sleep(for: delay)
      cleanup?()
      guard !Task.isCancelled else { return }
      body()
    }
  }
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`

Expected: `** TEST SUCCEEDED **`, `Executed 86 tests, with 0 failures`.

- [ ] **Step 7: Commit**

```bash
git add Islet/Core/NotchViewModel.swift IsletTests/NotchViewModelTests.swift
git commit -m "Notch: release the shrink handle when the timer is cancelled"
```

---

### Task 7: Make the window frame authoritative in ScreenManager

Four separate holes close here, and they touch the same two files, so they land together:

1. `panel.setFrame(frame, display: false)` (`ScreenManager.swift:87`) is fire-and-forget — nothing reads `panel.frame` back.
2. The only reposition path sits behind `.removeDuplicates()` (`:84`), so republishing an unchanged frame emits nothing and a drifted window is never corrected.
3. No `activeSpaceDidChange` / `didActivateApplication` / `didMove` observer re-asserts the frame. The Space observer that exists (`:99-105`) is registered only when `hideInFullscreen` is on — and that defaults to `false` (`DefaultsKeys.swift:28`).
4. The notch geometry is built from a raw, unstickied screen reading (`:70`).

**Files:**
- Modify: `Islet/Core/NSScreen+Notch.swift:25-32`
- Modify: `Islet/Core/ScreenManager.swift` (whole file)

**Interfaces:**
- Consumes: `NotchStickiness` + `NotchStickiness.Reading` (Task 3), `NotchViewModel.setActualPanelFrame(_:)` (Task 5), `NotchViewModel.panelFrame`, `NSScreen.isBuiltin`, `NSScreen.displayUUID`, `Log.app`, `Log.shell`.
- Produces: `NSScreen.notchReading: NotchStickiness.Reading`, `NSScreen.notchGeometry(reading:) -> NotchGeometry`. **Removes** `NSScreen.notchGeometry` (the zero-argument computed property); its only call site was `ScreenManager.swift:70`.

- [ ] **Step 1: Split the raw reading from geometry construction**

Replace lines 25-32 of `Islet/Core/NSScreen+Notch.swift`:

```swift
  var notchGeometry: NotchGeometry {
    NotchGeometry(
      screenFrame: frame,
      safeAreaTop: safeAreaInsets.top,
      auxLeftWidth: auxiliaryTopLeftArea?.width ?? 0,
      auxRightWidth: auxiliaryTopRightArea?.width ?? 0,
      menuBarHeight: frame.maxY - visibleFrame.maxY)
  }
```

with:

```swift
  /// The notch numbers AppKit reports right now. Split out from geometry construction so callers
  /// can run the reading through `NotchStickiness` first — these can come back empty transiently,
  /// and an empty reading silently means "no notch, use the 200pt fallback".
  var notchReading: NotchStickiness.Reading {
    NotchStickiness.Reading(
      safeAreaTop: safeAreaInsets.top,
      auxLeftWidth: auxiliaryTopLeftArea?.width ?? 0,
      auxRightWidth: auxiliaryTopRightArea?.width ?? 0)
  }

  /// Geometry for this screen from an explicit reading, so the caller decides whether that reading
  /// is the live one or a remembered one.
  func notchGeometry(reading: NotchStickiness.Reading) -> NotchGeometry {
    NotchGeometry(
      screenFrame: frame,
      safeAreaTop: reading.safeAreaTop,
      auxLeftWidth: reading.auxLeftWidth,
      auxRightWidth: reading.auxRightWidth,
      menuBarHeight: frame.maxY - visibleFrame.maxY)
  }
```

- [ ] **Step 2: Rewrite ScreenManager.swift**

Replace the entire contents of `Islet/Core/ScreenManager.swift` with:

```swift
import AppKit
import Combine
import Defaults
import SwiftUI

/// One notch panel plus the frame plumbing that keeps its window where the model says it should be.
///
/// A class rather than a struct because re-asserting a frame needs per-panel mutable state: the
/// re-entrancy guard has to outlive any single call, or a `didMove` fired by our own `setFrame`
/// would call straight back into it.
@MainActor
private final class PanelInstance {
  let screenUUID: String
  let panel: NotchPanel
  let viewModel: NotchViewModel
  var cancellables: Set<AnyCancellable> = []
  private var isApplying = false

  init(screenUUID: String, panel: NotchPanel, viewModel: NotchViewModel) {
    self.screenUUID = screenUUID
    self.panel = panel
    self.viewModel = viewModel
  }

  /// The single place a notch panel's frame is ever set.
  ///
  /// The window's real frame is read straight back and pushed into the model. `NotchPanel` now
  /// returns `constrainFrameRect` unchanged so the two should always agree, but "should" is not
  /// "does": the island is drawn centred in the REAL window, so any divergence lands 1:1 on the
  /// drawn island, and a divergence nobody measures is a drift nobody can explain.
  ///
  /// `display: false` — the view reports its slot widths from inside a SwiftUI update, so this can
  /// run mid-layout, and forcing a synchronous display pass there re-enters layout.
  func apply(_ frame: CGRect) {
    guard !isApplying else { return }
    isApplying = true
    panel.setFrame(frame, display: false)
    let actual = panel.frame
    if actual != frame {
      Log.app.error(
        "Panel frame diverged on \(self.screenUUID, privacy: .public): requested \(NSStringFromRect(frame), privacy: .public) actual \(NSStringFromRect(actual), privacy: .public)"
      )
    }
    viewModel.setActualPanelFrame(actual)
    isApplying = false
  }

  /// Feeds the window's real frame into the model without touching the window.
  func syncActualFrame() { viewModel.setActualPanelFrame(panel.frame) }

  /// Unconditional re-push of the model's frame, deliberately bypassing the `removeDuplicates` on
  /// `$panelFrame`: republishing an unchanged value emits nothing, so a window the system moved
  /// behind our back would otherwise never be corrected. `targetPanelFrame` also returns the same
  /// value for `.closed` and `.peek`, so hovering the notch republishes nothing either — a drift
  /// used to survive every hover and clear only on a real expand.
  func reassert() { apply(viewModel.panelFrame) }

  /// The panel is `isMovable = false` and Islet never drags it, so a move we did not cause is the
  /// system relocating the window — put it back. Gated on an actual mismatch, which makes this a
  /// fixed point: a `setFrame` that lands exactly where asked posts no move, so it cannot loop.
  func reassertIfMoved() {
    guard !isApplying else { return }
    guard panel.frame != viewModel.panelFrame else {
      syncActualFrame()
      return
    }
    Log.app.notice("Panel on \(self.screenUUID, privacy: .public) moved; re-asserting its frame")
    reassert()
  }
}

/// One notch panel per active screen, keyed by display UUID. Rebuilds on display changes;
/// hides panels on screens showing a fullscreen app when that option is enabled.
@MainActor
final class ScreenManager {
  static let shared = ScreenManager()

  private var instances: [String: PanelInstance] = [:]
  private var cancellables: Set<AnyCancellable> = []
  private var fullscreenTimer: AnyCancellable?
  /// Last-known notch measurements per display, so a transient empty aux-area read can't downgrade
  /// a built-in screen to the 200pt fallback for the rest of the session.
  private var stickiness = NotchStickiness()

  /// The view model on the screen under the mouse (for menu-bar-driven actions), else any.
  var viewModel: NotchViewModel? {
    if let uuid = NSScreen.screenWithMouse?.displayUUID, let inst = instances[uuid] {
      return inst.viewModel
    }
    return instances.values.first?.viewModel
  }

  func start() {
    rebuild()
    NotificationCenter.default
      .publisher(for: NSApplication.didChangeScreenParametersNotification)
      .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
      .sink { [weak self] _ in self?.rebuild() }
      .store(in: &cancellables)
    // Undebounced companion to the rebuild above. A display reconfiguration can displace the window
    // straight away, and half a second of a visibly misplaced island is half a second too many;
    // harmless when the debounced rebuild later replaces the panel outright.
    NotificationCenter.default
      .publisher(for: NSApplication.didChangeScreenParametersNotification)
      .sink { [weak self] _ in self?.reassertAll() }
      .store(in: &cancellables)
    // Registered UNCONDITIONALLY, not behind `hideInFullscreen` (which defaults to false): a Space
    // switch is the most common way the panel ends up somewhere we did not put it.
    // `applyFullscreenVisibility` no-ops on its own when the option is off.
    NSWorkspace.shared.notificationCenter
      .publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
      .sink { [weak self] _ in
        self?.reassertAll()
        self?.applyFullscreenVisibility()
      }
      .store(in: &cancellables)
    NSWorkspace.shared.notificationCenter
      .publisher(for: NSWorkspace.didActivateApplicationNotification)
      .sink { [weak self] _ in self?.reassertAll() }
      .store(in: &cancellables)
    Defaults.publisher(.hideFromScreenRecording)
      .sink { [weak self] change in
        Task { @MainActor in
          self?.instances.values.forEach {
            $0.panel.sharingType = change.newValue ? .none : .readOnly
          }
        }
      }
      .store(in: &cancellables)
    Defaults.publisher(.showOnAllDisplays)
      .dropFirst()
      .sink { [weak self] _ in Task { @MainActor in self?.rebuild() } }
      .store(in: &cancellables)
    Defaults.publisher(.hideInFullscreen)
      .sink { [weak self] _ in Task { @MainActor in self?.updateFullscreenObserving() } }
      .store(in: &cancellables)
    updateFullscreenObserving()
  }

  private func targetScreens() -> [NSScreen] {
    if Defaults[.showOnAllDisplays] { return NSScreen.screens }
    if let screen = NSScreen.builtin ?? NSScreen.main { return [screen] }
    return []
  }

  func rebuild() {
    instances.values.forEach { $0.panel.close() }
    instances.removeAll()

    for screen in targetScreens() {
      guard let uuid = screen.displayUUID else { continue }
      let raw = screen.notchReading
      let reading = stickiness.resolve(
        displayUUID: uuid, isBuiltin: screen.isBuiltin, reading: raw)
      if reading != raw {
        let kept =
          "safeAreaTop \(reading.safeAreaTop) aux \(reading.auxLeftWidth)/\(reading.auxRightWidth)"
        Log.app.notice(
          "Display \(uuid, privacy: .public) reported no notch; keeping \(kept, privacy: .public)")
      }
      let geometry = screen.notchGeometry(reading: reading)
      let vm = NotchViewModel(geometry: geometry)
      let panel = NotchPanel(frame: vm.panelFrame)
      panel.contentView = NSHostingView(rootView: NotchRootView(vm: vm))
      panel.alphaValue = 0
      panel.orderFrontRegardless()
      panel.setFrame(vm.panelFrame, display: true)
      panel.alphaValue = 1  // alpha-flash hides ghost frames
      panel.sharingType = Defaults[.hideFromScreenRecording] ? .none : .readOnly

      let inst = PanelInstance(screenUUID: uuid, panel: panel, viewModel: vm)
      inst.syncActualFrame()  // seed from the window we just placed, before anything is drawn
      // The panel only claims the space the island actually occupies, so the rest of the menu bar
      // stays clickable; it grows on expand and back down on collapse.
      vm.$panelFrame
        .removeDuplicates()
        .sink { [weak inst] frame in inst?.apply(frame) }
        .store(in: &inst.cancellables)
      NotificationCenter.default
        .publisher(for: NSWindow.didMoveNotification, object: panel)
        .sink { [weak inst] _ in inst?.reassertIfMoved() }
        .store(in: &inst.cancellables)
      instances[uuid] = inst
    }
    Log.shell.info("Built \(self.instances.count) notch panel(s)")
    applyFullscreenVisibility()
  }

  /// Re-pushes every panel's frame. See `PanelInstance.reassert()` for why this cannot go through
  /// the `$panelFrame` publisher.
  private func reassertAll() {
    for inst in instances.values { inst.reassert() }
  }

  // MARK: - Fullscreen awareness

  private func updateFullscreenObserving() {
    if Defaults[.hideInFullscreen] {
      // Fullscreen enter/exit moves the active Space, and that observer is now registered
      // unconditionally in `start()`. All that is left here is a slow safety poll, instead of
      // scanning every window once a second.
      fullscreenTimer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()
        .sink { [weak self] _ in self?.applyFullscreenVisibility() }
      applyFullscreenVisibility()
    } else {
      fullscreenTimer = nil
      // Restore any panel we hid.
      instances.values.forEach { if !$0.panel.isVisible { $0.panel.orderFrontRegardless() } }
    }
  }

  private func applyFullscreenVisibility() {
    guard Defaults[.hideInFullscreen] else { return }
    for inst in instances.values {
      guard let screen = NSScreen.screens.first(where: { $0.displayUUID == inst.screenUUID })
      else { continue }
      let hidden = FullscreenDetector.hasFullscreenWindow(on: screen)
      // orderOut (not alpha 0) so the hidden panel's SwiftUI tree stops rendering entirely.
      if hidden, inst.panel.isVisible {
        inst.panel.orderOut(nil)
      } else if !hidden, !inst.panel.isVisible {
        inst.panel.orderFrontRegardless()
      }
    }
  }
}
```

- [ ] **Step 3: Build**

No unit test — `ScreenManager` drives real `NSPanel`s and `NSWorkspace` notifications, neither of which `IsletTests` can exercise. Verified by build plus the manual check in Step 5.

Run: `xcodebuild build -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Run the full test suite**

Run: `xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`

Expected: `** TEST SUCCEEDED **`, `Executed 86 tests, with 0 failures`.

- [ ] **Step 5: Manual check**

In one terminal, start a log stream:

```bash
log stream --predicate 'subsystem == "dev.cnucifora.Islet"' --level info
```

In another, launch the app:

```bash
open "$(xcodebuild -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR/ {print $2; exit}')/Islet.app"
```

Confirm: `Built 1 notch panel(s)` appears; switching Spaces (Ctrl+← / Ctrl+→) and Cmd+Tabbing between apps produce **no** repeated `Panel frame diverged` or `moved; re-asserting` spam — a handful of `re-asserting` lines around a real Space change is fine, a continuous stream is a loop and means the re-entrancy guard is not holding. Quit the app before continuing.

- [ ] **Step 6: Commit**

```bash
git add Islet/Core/ScreenManager.swift Islet/Core/NSScreen+Notch.swift
git commit -m "Notch: read the panel frame back and re-assert it on space, activation and move"
```

---

### Task 8: Draw the island against the real panel frame

This is the fix the whole phase exists for. `NotchRootView.islandOffset` (`:58-62`) uses `vm.panelFrame`; the island is drawn in `vm.actualPanelFrame`.

**Files:**
- Modify: `Islet/UI/NotchRootView.swift:54-80` (`islandOffset`, `bodySize`), `:142-146` (`syncPanelWidths`)

**Interfaces:**
- Consumes: `NotchViewModel.actualPanelFrame` (Task 5), `NotchGeometry.islandOffset(inPanel:compactLeading:compactTrailing:)` and `NotchGeometry.islandBodyWidth(compactLeading:compactTrailing:)` (Task 1).
- Produces: nothing consumed elsewhere.

- [ ] **Step 1: Replace islandOffset and bodySize**

No unit test — this is a SwiftUI `View`; the arithmetic it now delegates to is already covered by `testIslandScreenPositionIsInvariantUnderAnArbitraryPanelFrame` (Task 1) and `testActualPanelFrameTracksTheWindowNotTheRequest` (Task 5). Verified by build plus the manual check in Step 3.

In `Islet/UI/NotchRootView.swift`, replace lines 54-80 — from the `/// Horizontal offset ...` doc comment at `:54` through the closing `}` of `bodySize` at `:80`:

```swift
  /// Horizontal offset that lines the island's notch cut-out up with the hardware notch. The
  /// collapsed panel hugs the island flank by flank, so it is *not* centred on the notch —
  /// everything positions off the notch's offset within the panel rather than the panel's centre,
  /// which also keeps the island aligned while the panel is still held at expanded size.
  private var islandOffset: CGFloat {
    let notchInPanel = vm.geometry.notchRect.midX - vm.panelFrame.midX
    guard compactVisible else { return notchInPanel }
    return notchInPanel + (compactTrailingWidth - compactLeadingWidth) / 2
  }

  /// Size of the black shape body, EXCLUDING the top-flare ears.
  private var bodySize: CGSize {
    let notch = vm.geometry.notchSize
    let compactExtra = compactVisible ? compactLeadingWidth + compactTrailingWidth : 0
    switch vm.state {
    case .closed:
      return CGSize(
        width: notch.width + Metrics.closedOversize * 2 + compactExtra,
        height: notch.height + Metrics.closedOversize)
    case .peek:
      return CGSize(
        width: notch.width + Metrics.closedOversize * 2 + compactExtra,
        height: notch.height + Metrics.peekGrowth)
    case .expanded:
      return Metrics.expandedSize
    }
  }
```

with:

```swift
  /// Slot widths as layout should use them: zero whenever no compact content is drawn, so neither
  /// the offset nor the body size can carry a stale measurement from a slot that isn't on screen.
  private var effectiveCompact: (leading: CGFloat, trailing: CGFloat) {
    compactVisible ? (compactLeadingWidth, compactTrailingWidth) : (0, 0)
  }

  /// Horizontal offset that lines the island's notch cut-out up with the hardware notch.
  ///
  /// `vm.actualPanelFrame` — the frame the window really has — NOT `vm.panelFrame`, the frame we
  /// asked for. The island is drawn centred in the real window, so aligning it against the request
  /// maps any divergence 1:1 onto a horizontal shift that no hover ever clears: `targetPanelFrame`
  /// returns the same value for `.closed` and `.peek`, so hovering republishes nothing.
  private var islandOffset: CGFloat {
    vm.geometry.islandOffset(
      inPanel: vm.actualPanelFrame,
      compactLeading: effectiveCompact.leading,
      compactTrailing: effectiveCompact.trailing)
  }

  /// Size of the black shape body, EXCLUDING the top-flare ears.
  private var bodySize: CGSize {
    let notch = vm.geometry.notchSize
    let width = vm.geometry.islandBodyWidth(
      compactLeading: effectiveCompact.leading, compactTrailing: effectiveCompact.trailing)
    switch vm.state {
    case .closed:
      return CGSize(width: width, height: notch.height + Metrics.closedOversize)
    case .peek:
      return CGSize(width: width, height: notch.height + Metrics.peekGrowth)
    case .expanded:
      return Metrics.expandedSize
    }
  }
```

- [ ] **Step 2: Route syncPanelWidths through the same accessor**

In `Islet/UI/NotchRootView.swift`, replace lines 142-146:

```swift
  private func syncPanelWidths() {
    vm.updateCompactWidths(
      leading: compactVisible ? compactLeadingWidth : 0,
      trailing: compactVisible ? compactTrailingWidth : 0)
  }
```

with:

```swift
  private func syncPanelWidths() {
    vm.updateCompactWidths(
      leading: effectiveCompact.leading, trailing: effectiveCompact.trailing)
  }
```

- [ ] **Step 3: Build and manually verify the drift is gone**

Run: `xcodebuild build -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`

Expected: `** BUILD SUCCEEDED **`.

Then:

```bash
open "$(xcodebuild -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR/ {print $2; exit}')/Islet.app"
```

Confirm, on the built-in display:

1. The collapsed island sits exactly over the hardware notch — no black sliver on either flank, and the notch is not visible through it.
2. Hover the notch (peek), move away, repeat ten times. The island does not creep sideways.
3. Switch Space and come back. No shift.
4. Cmd+Tab through several apps. No shift.
5. Start playing audio so a sneak fires and the island widens; when it collapses back, it re-centres on the notch.
6. **The old diagnostic must now be a no-op:** click the notch to expand and click away to collapse. Previously this was the only thing that snapped a drifted island back into alignment; there should now be nothing to snap.

Quit the app before continuing.

- [ ] **Step 4: Run the full test suite**

Run: `xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`

Expected: `** TEST SUCCEEDED **`, `Executed 86 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Islet/UI/NotchRootView.swift
git commit -m "Notch: offset the island against the frame the window actually has"
```

---

### Task 9: Reject slot measurements from the outgoing subtree

The two `onGeometryChange` closures at `NotchRootView.swift:161-172` sit under `.id(...)` at `:172`. When the identity changes, SwiftUI builds a new subtree while the old one is still alive and animating out under `.transition(.opacity)` — and both write the same two `@State` variables. If the outgoing subtree reports last, its stale width is what sizes the panel.

**Files:**
- Modify: `Islet/UI/NotchRootView.swift:148-177` (`content`)

**Interfaces:**
- Consumes: `HUDController.shared.hud`, `SneakQueue.shared.current` (both already observed on the view).
- Produces: nothing consumed elsewhere.

- [ ] **Step 1: Replace the content builder**

No unit test — this is SwiftUI subtree-identity behaviour, not extractable logic; the reduce-through-a-single-`onPreferenceChange` alternative was considered and rejected because during a cross-fade both subtrees contribute preferences too, so it needs the same identity discriminator with more machinery. Verified by build plus the manual check in Step 2.

In `Islet/UI/NotchRootView.swift`, replace lines 148-177 (the whole `content` property, from `@ViewBuilder private var content: some View {` to its closing `}`):

```swift
  /// Identity of the compact slot subtree. The HUD and each sneak get their own, so SwiftUI
  /// cross-fades between them instead of mutating one subtree in place.
  private var slotIdentity: String {
    if hud.hud != nil { return "hud" }
    if let sneak = sneaks.current { return "sneak-\(sneak.id.uuidString)" }
    return "activity"
  }

  /// Accepts a slot measurement only from the subtree that is currently on screen.
  ///
  /// Both `onGeometryChange` closures live under `.id(slotIdentity)`. During a cross-fade the
  /// outgoing subtree is still alive and still reporting, and if it reports LAST its stale width
  /// wins — stranding a measurement for content that is no longer drawn and sizing the panel to it.
  /// Each closure captures the identity it was built with; `slotIdentity` here reads the live
  /// observed objects, so an outgoing subtree's write no longer matches and is dropped.
  private func applySlotWidth(_ width: CGFloat, leading: Bool, from identity: String) {
    guard identity == slotIdentity else { return }
    if leading {
      compactLeadingWidth = width
    } else {
      compactTrailingWidth = width
    }
  }

  @ViewBuilder private var content: some View {
    if vm.state.isExpanded {
      // The switcher (tabs + gear) sits in the notch band, flanking the hardware notch, and the
      // content fills the rest — so nothing is wasted below the notch.
      ExpandedContainerView(notchSize: vm.geometry.notchSize)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .top)))
    } else if let slots = compactContent {
      let identity = slotIdentity
      HStack(spacing: 0) {
        // The measured width already includes the padding — don't add it a second time, or the
        // shape (and the panel sized from it) gains 12pt of dead space per flank.
        slots.leading
          .padding(.leading, 6)
          .onGeometryChange(for: CGFloat.self, of: \.size.width) {
            applySlotWidth($0, leading: true, from: identity)
          }
        Spacer().frame(width: vm.geometry.notchSize.width)
        slots.trailing
          .padding(.trailing, 6)
          .onGeometryChange(for: CGFloat.self, of: \.size.width) {
            applySlotWidth($0, leading: false, from: identity)
          }
      }
      .frame(height: vm.geometry.notchSize.height)
      .id(identity)
      .transition(.opacity)
    } else {
      Color.clear
    }
  }
```

- [ ] **Step 2: Build and manually verify**

Run: `xcodebuild build -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`

Expected: `** BUILD SUCCEEDED **`.

Then:

```bash
open "$(xcodebuild -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR/ {print $2; exit}')/Islet.app"
```

Confirm: change tracks rapidly in a music player so several track-change sneaks fire back to back (each one is a fresh identity). The island widens for each sneak and returns to exactly the hardware-notch width afterwards — it must not settle at a width belonging to a sneak that has already gone. Then trigger a HUD (volume keys) while a sneak is on screen: the HUD replaces it and the island sizes to the HUD, not to a blend of the two. Quit the app before continuing.

- [ ] **Step 3: Run the full test suite**

Run: `xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`

Expected: `** TEST SUCCEEDED **`, `Executed 86 tests, with 0 failures`.

- [ ] **Step 4: Commit**

```bash
git add Islet/UI/NotchRootView.swift
git commit -m "Notch: ignore slot measurements from the outgoing compact subtree"
```

---

### Task 10: Final verification

**Files:**
- Modify: none

**Interfaces:**
- Consumes: everything above.
- Produces: nothing.

- [ ] **Step 1: Confirm the tree is clean and every fix is present**

```bash
git status --short
git log --oneline -9
grep -n "constrainFrameRect" Islet/Core/NotchPanel.swift
grep -n "actualPanelFrame" Islet/Core/NotchViewModel.swift Islet/UI/NotchRootView.swift
grep -n "reassert\|didMoveNotification\|didActivateApplicationNotification\|activeSpaceDidChangeNotification" Islet/Core/ScreenManager.swift
grep -n "auxLeftWidth" Islet/Core/NotchGeometry.swift
```

Expected: `git status --short` prints nothing; the log shows the nine Phase 0 commits with no `Co-Authored-By` trailer and no mention of Claude, Anthropic or AI; every grep returns at least one hit.

- [ ] **Step 2: Confirm the Phase 1 boundary was respected**

```bash
grep -n "var expandedRect\|var panelFrame\|func expandedRect\|func panelFrame" Islet/Core/NotchGeometry.swift
```

Expected: exactly two hits, both `var` — `var expandedRect: CGRect {` and `var panelFrame: CGRect {`. If either reads `func`, Phase 1.2's work has leaked into Phase 0; revert it.

- [ ] **Step 3: Run the full suite one final time**

Run: `xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`

Expected: `** TEST SUCCEEDED **`, `Executed 86 tests, with 0 failures`, in roughly 11 seconds.

- [ ] **Step 4: Soak the running app**

```bash
open "$(xcodebuild -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR/ {print $2; exit}')/Islet.app"
log stream --predicate 'subsystem == "dev.cnucifora.Islet"' --level info
```

Leave it running for five minutes while using the machine normally — switch Spaces, Cmd+Tab, enter and leave a fullscreen app, play and skip music, connect and disconnect an external display if one is available. Confirm the island never leaves the hardware notch, and the log contains no repeating `Panel frame diverged` and no runaway `moved; re-asserting` loop. Quit the app when done.
