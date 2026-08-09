# Compact Event Marquee Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep compact system-event sneaks at a stable width while slowly revealing overflowing title and subtitle text.

**Architecture:** Add a pure `MarqueeMotion` timing model and a focused `CompactMarquee` SwiftUI viewport beside the existing event-to-sneak adapter. `EventTrailingView` supplies its existing styled, single-line message to that viewport. The existing notch geometry remains the source of truth and receives a stable measured slot width.

**Tech Stack:** Swift 6, SwiftUI, AppKit hosting tests, XCTest, Xcode 26/macOS 26.

## Global Constraints

- The trailing event-text viewport is exactly 120 points wide.
- Short messages remain static.
- Overflowing messages pause at the beginning, scroll from right to left at constant speed, pause at the end, then reset and repeat.
- Reduce Motion disables translation and uses a stable, single-line tail-truncated presentation.
- VoiceOver continues announcing the complete `SystemEvent.spokenAnnouncement`.
- Do not change `NotchGeometry`, `NotchViewModel`, event-source wording, or non-event activity layouts unless a failing integration test proves that necessary.

---

### Task 1: Pure marquee timing model

**Files:**
- Modify: `Islet/Events/EventSneak.swift`
- Test: `IsletTests/SneakLogicTests.swift`

**Interfaces:**
- Produces: `MarqueeMotion(viewportWidth:contentWidth:pointsPerSecond:startPause:endPause:resetPause:)`
- Produces: `var travelDistance: CGFloat`, `var cycleDuration: TimeInterval`, and `func offset(at elapsed: TimeInterval) -> CGFloat`
- Consumes: point measurements from `CompactMarquee` in Task 2.

- [ ] **Step 1: Write failing model tests**

Add literal, hand-calculated cases to `SneakLogicTests.swift`:

```swift
func testMarqueeDoesNotTravelWhenContentFitsViewport() {
  let motion = MarqueeMotion(viewportWidth: 120, contentWidth: 90)
  XCTAssertEqual(motion.travelDistance, 0)
  XCTAssertEqual(motion.offset(at: 20), 0)
}

func testMarqueePausesScrollsAndPausesBeforeReset() {
  let motion = MarqueeMotion(
    viewportWidth: 120, contentWidth: 180, pointsPerSecond: 30,
    startPause: 1, endPause: 1, resetPause: 0.5)
  XCTAssertEqual(motion.travelDistance, 60)
  XCTAssertEqual(motion.cycleDuration, 4.5, accuracy: 0.001)
  XCTAssertEqual(motion.offset(at: 0.5), 0, accuracy: 0.001)
  XCTAssertEqual(motion.offset(at: 2), -30, accuracy: 0.001)
  XCTAssertEqual(motion.offset(at: 3.5), -60, accuracy: 0.001)
  XCTAssertEqual(motion.offset(at: 4.25), -60, accuracy: 0.001)
  XCTAssertEqual(motion.offset(at: 4.5), 0, accuracy: 0.001)
}
```

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```bash
xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' -only-testing:IsletTests/SneakLogicTests
```

Expected: compilation fails because `MarqueeMotion` does not exist.

- [ ] **Step 3: Implement the minimal pure model**

Add an internal `MarqueeMotion` to `EventSneak.swift`. Clamp travel distance to zero, derive scroll duration from distance/speed, wrap elapsed time with `truncatingRemainder(dividingBy:)`, and return offsets for the start-pause, scrolling, end-pause, and reset-pause phases. Guard zero distance and non-positive speed before division.

```swift
struct MarqueeMotion {
  var viewportWidth: CGFloat
  var contentWidth: CGFloat
  var pointsPerSecond: CGFloat = 24
  var startPause: TimeInterval = 1
  var endPause: TimeInterval = 0.8
  var resetPause: TimeInterval = 0.35

  var travelDistance: CGFloat { max(0, contentWidth - viewportWidth) }

  var cycleDuration: TimeInterval {
    guard travelDistance > 0, pointsPerSecond > 0 else { return 0 }
    return startPause + TimeInterval(travelDistance / pointsPerSecond) + endPause + resetPause
  }

  func offset(at elapsed: TimeInterval) -> CGFloat {
    guard cycleDuration > 0 else { return 0 }
    let elapsedInCycle = max(0, elapsed).truncatingRemainder(dividingBy: cycleDuration)
    guard elapsedInCycle >= startPause else { return 0 }
    let scrollDuration = TimeInterval(travelDistance / pointsPerSecond)
    let scrollElapsed = elapsedInCycle - startPause
    guard scrollElapsed < scrollDuration else { return -travelDistance }
    return -travelDistance * CGFloat(scrollElapsed / scrollDuration)
  }
}
```

- [ ] **Step 4: Run the focused tests and verify GREEN**

Run the Task 1 command again. Expected: all `SneakLogicTests` pass with no warnings from the new model.

- [ ] **Step 5: Commit the model and tests**

```bash
git add Islet/Events/EventSneak.swift IsletTests/SneakLogicTests.swift
git commit -m "Events: model compact marquee timing"
```

---

### Task 2: Bounded SwiftUI marquee viewport

**Files:**
- Modify: `Islet/Events/EventSneak.swift`
- Modify: `IsletTests/SneakSnapshotTests.swift`

**Interfaces:**
- Consumes: `MarqueeMotion` from Task 1.
- Produces: `CompactMarquee<Content: View>` with `viewportWidth` and `@ViewBuilder content`.
- Preserves: `EventTrailingView(event:)` and `Sneak(event:)` call sites.

- [ ] **Step 1: Write a failing bounded-width hosting test**

Add a helper that hosts `EventTrailingView` at its fitting size, then add:

```swift
func testLongEventTrailingViewHasBoundedWidth() {
  let event = SystemEvent(
    sourceID: "bluetooth", icon: "dot.radiowaves.right",
    title: "Christian's extraordinarily long Bluetooth headphone device name",
    subtitle: "Connected")
  let host = NSHostingView(rootView: EventTrailingView(event: event))
  host.layoutSubtreeIfNeeded()
  XCTAssertEqual(host.fittingSize.width, 120, accuracy: 0.5)
}
```

This catches a regression back to an ideal or maximum width: the current implementation reports up to 175 points and fails.

- [ ] **Step 2: Run the hosting test and verify RED**

Run:

```bash
xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' -only-testing:IsletTests/SneakSnapshotTests/testLongEventTrailingViewHasBoundedWidth
```

Expected: FAIL because `EventTrailingView` measures wider than 120 points.

- [ ] **Step 3: Implement `CompactMarquee` and integrate it**

In `EventSneak.swift`, add a generic view with this structure:

- reads `accessibilityReduceMotion` from the environment;
- holds `contentWidth` and a stable animation epoch in state;
- renders content with `.fixedSize(horizontal: true, vertical: false)` inside an exactly 120-point clipped viewport;
- uses `TimelineView(.animation)` and `MarqueeMotion.offset(at:)` only when overflow exists and Reduce Motion is off;
- presents a nonmoving, constrained copy when Reduce Motion is on;
- applies a narrow leading/trailing `LinearGradient` mask only for overflowing animated content;
- resets the epoch when measured content width changes.

```swift
struct CompactMarquee<Content: View>: View {
  let viewportWidth: CGFloat
  @ViewBuilder let content: () -> Content

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var contentWidth: CGFloat = 0
  @State private var epoch = Date()

  private var motion: MarqueeMotion {
    MarqueeMotion(viewportWidth: viewportWidth, contentWidth: contentWidth)
  }

  var body: some View {
    if reduceMotion {
      content()
        .lineLimit(1)
        .frame(width: viewportWidth, alignment: .leading)
        .clipped()
    } else {
      TimelineView(.animation(paused: motion.travelDistance == 0)) { timeline in
        let offset = motion.offset(at: timeline.date.timeIntervalSince(epoch))
        content()
          .fixedSize(horizontal: true, vertical: false)
          .onGeometryChange(for: CGFloat.self, of: \.size.width) { width in
            guard width != contentWidth else { return }
            contentWidth = width
            epoch = Date()
          }
          .offset(x: offset)
          .mask {
            LinearGradient(
              stops: [
                .init(color: offset < -0.5 ? .clear : .black, location: 0),
                .init(color: .black, location: 0.06),
                .init(color: .black, location: 0.94),
                .init(
                  color: offset > -motion.travelDistance + 0.5 ? .clear : .black,
                  location: 1),
              ],
              startPoint: .leading, endPoint: .trailing)
          }
      }
      .frame(width: viewportWidth, alignment: .leading)
      .clipped()
    }
  }
}
```

Wrap the existing styled `HStack` in `EventTrailingView`:

```swift
CompactMarquee(viewportWidth: 120) {
  HStack(spacing: 5) {
    // Existing title and optional subtitle styles remain unchanged.
  }
}
```

Keep `Sneak(event:)` and `event.spokenAnnouncement` unchanged.

- [ ] **Step 4: Run focused model, hosting, and snapshot tests**

Run:

```bash
xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' \
  -only-testing:IsletTests/SneakLogicTests \
  -only-testing:IsletTests/SneakSnapshotTests
```

Expected: all tests pass and `/tmp/sneak_snapshot.png` is regenerated.

- [ ] **Step 5: Inspect the real rendered snapshot**

Open `/tmp/sneak_snapshot.png` and verify in one bounded pass that the island stays aligned with the hardware notch, the trailing flank is compact, text remains vertically centered, and the mask does not fade fitting content.

- [ ] **Step 6: Commit the viewport integration**

```bash
git add Islet/Events/EventSneak.swift IsletTests/SneakSnapshotTests.swift
git commit -m "Events: bound long sneak text with a marquee"
```

---

### Task 3: Regression and project verification

**Files:**
- Modify only if verification exposes a defect directly caused by Tasks 1–2.

**Interfaces:**
- Consumes the complete marquee behavior from Tasks 1–2.
- Produces a build and test record suitable for the UI audit.

- [ ] **Step 1: Format changed Swift files**

Run the repository's available Swift formatter over only the changed Swift files. If no formatter is configured, preserve the repository's two-space indentation manually and use `git diff --check`.

- [ ] **Step 2: Run the complete test suite**

```bash
xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS'
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 3: Build the application**

```bash
xcodebuild build -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS'
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Inspect the final diff**

Run `git diff --check` and `git diff --stat`. Confirm that no geometry, source wording, or unrelated activity layout changed.
