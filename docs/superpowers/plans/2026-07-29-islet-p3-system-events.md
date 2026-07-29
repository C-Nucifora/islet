# Phase 3 — SystemEventBus and Event Animations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give every system event Islet can observe its own animated sneak, behind one registrable event bus with a per-source toggle, across all three observability tiers.

**Architecture:** A `SystemEvent` value type carries everything a presentation needs (icon, title, subtitle, accent, motion profile, urgency) so nothing downstream has to know which source produced it. `SystemEventSource` implementations own their observation and are started and stopped by `SystemEventBus`, which mirrors `ActivityCenter` — so per-source enable/disable, the Settings section and the Debug menu all generate from one catalogue, and a disabled source costs zero observation. The bus renders each event into the existing `Sneak` type and hands it to the untouched `SneakQueue`. Every piece of decidable logic — set diffing, burst coalescing, the event→sneak mapping, tier filtering — is a pure free function or struct so `IsletTests` covers it synchronously.

**Tech Stack:** Swift 6, SwiftUI, AppKit, CoreWLAN, IOBluetooth, CoreAudio, IOKit, FSEvents, XcodeGen, XCTest, sindresorhus/Defaults

## Global Constraints

- **Working directory:** every command runs from the repo root, `/Users/christiannucifora/Documents/dev/personal/islet`.
- **Swift 6 strict concurrency.** `SystemEventBus` and every `SystemEventSource` are `@MainActor`. Everything else in this phase — `SystemEvent`, `SetDiff`, `BurstCoalescer`, `EventSummary`, `SourceCatalog` — is deliberately actor-free and `Sendable` so tests call it synchronously.
- **XcodeGen is mandatory.** `Islet.xcodeproj` is generated from `project.yml`, which globs `- path: Islet` and `- path: IsletTests`. Any step that CREATES a new `.swift` file must be immediately followed by `xcodegen generate` before building, or the build fails with "cannot find X in scope". `xcodegen generate` prints a warning about `Vendor/MediaRemoteAdapter.framework`; that is expected and harmless.
- **Test command:** `xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`
- **Build command:** `xcodebuild build -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`
- **Baseline: 86 passing tests** after Phase 0. Phase 1 adds more; re-read the actual count with the test command before Task 1 and treat that as your baseline rather than trusting a number written here. This plan adds 38, in this distribution: Task 1 → 6, Task 2 → 8, Task 3 → 9, Task 4 → 4, Task 5 → 2, Task 7 → 5, Task 8 → 2, Task 12 → 2.
- **Commit after every green test run.** Scope prefix, then a lowercase imperative summary — e.g. `Events: coalesce a docking burst into one summary sneak`.
- **Never put `Co-Authored-By`, or any mention of Claude / Anthropic / AI, in a commit message.**
- **Line numbers refer to the file as it stands at the start of that task.** Apply each edit by matching the quoted text, not by seeking to a line number.

### Phase-specific invariant — all overshoot must be inward

`Metrics.islandMargin` is 4pt and `Metrics.collapsedDepth` is 12pt, and the drawn island is clipped
twice: by the `NotchShape` mask in `NotchRootView` and again by the panel window itself. **Every
animation scales from 0.6 → 1.0 and never past 1.0, and never translates outward beyond the slot it
was measured in.** A bounce that overshoots to 1.15 is clipped to a hard edge, and widening the
margins to accommodate it gives back the menu-bar clickability that commits `372c645` and `61cf4d5`
were fighting for.

### Phase-specific invariant — every animation is gated on Reduce Motion

Nothing in the codebase checks it today. Every `withAnimation` and every `.animation(...)` added by
this phase goes through `Motion.gated(_:)`, which returns `nil` when
`NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` is true. A gated `nil` animation makes the
state change instant rather than removing it — the event still appears, it just does not move.

### Phase 0 and Phase 1 are assumed shipped

This plan consumes, and does not define:

```swift
// Phase 1.1 — Islet/Core/Motion.swift
enum Motion {
  static let opening: Animation
  static let closing: Animation
  static let compact: Animation
  static var reduceMotion: Bool { get }
  static func gated(_ animation: Animation) -> Animation?
}
enum MotionProfile: String, CaseIterable, Codable, Sendable {
  case wifi, bluetooth, usb, airdrop, volumeMount, display, chargeComplete,
       lowPower, screenshot, lock, sleepWake, peripheralLow, focus, vpn, generic
}

// Phase 1.6 — Islet/Core/ThresholdDetector.swift
struct ThresholdDetector: Equatable {
  enum Direction { case falling, rising }
  init(thresholds: [Double], direction: Direction)
  func crossings(from old: Double?, to new: Double) -> [Double]
}
```

`Metrics` owns sizes only after Phase 1 — `Metrics.opening` / `.closing` / `.compact` no longer
exist. Use `Motion.*`.

---

## File Structure

**Created**

| File | Single responsibility |
|---|---|
| `Islet/Events/SystemEvent.swift` | The event value type, its tier and urgency enums, and the accent palette. Pure. |
| `Islet/Events/SystemEventSource.swift` | The source protocol and `SourceCatalog`, the single list of every source's id, name and tier. |
| `Islet/Events/SystemEventBus.swift` | Registration, enable/disable, start/stop, and the emit path into `SneakQueue`. |
| `Islet/Events/SetDiff.swift` | One tested set-difference function, used by the USB, display, Bluetooth and VPN sources. Pure. |
| `Islet/Events/BurstCoalescer.swift` | Collapses a flurry of events (docking) into one summary. Pure. |
| `Islet/Events/EventSneak.swift` | `Sneak.init(event:)` — the event → presentation mapping, plus the leading/trailing slot views. |
| `Islet/Events/EventMotion.swift` | One `ViewModifier` per `MotionProfile`: the bespoke choreography. |
| `Islet/Events/Sources/PortEventSource.swift` | USB attach/detach. Tier 1. |
| `Islet/Events/Sources/VolumeEventSource.swift` | Disk mount/unmount. Tier 1. |
| `Islet/Events/Sources/DisplayEventSource.swift` | External display connect/disconnect. Tier 1. |
| `Islet/Events/Sources/PowerEventSource.swift` | Charge complete, Low Power Mode, sleep/wake. Tier 1. |
| `Islet/Events/Sources/PeripheralEventSource.swift` | Magic Mouse/Keyboard/Trackpad low battery. Tier 1. |
| `Islet/Events/Sources/WiFiEventSource.swift` | Wi-Fi join/leave/SSID change via CoreWLAN. Tier 2. |
| `Islet/Events/Sources/BluetoothEventSource.swift` | Bluetooth device connect/disconnect via IOBluetooth. Tier 2. |
| `Islet/Events/Sources/SessionEventSource.swift` | Screen lock/unlock and caps lock. Tier 2. |
| `Islet/Events/Sources/ScreenshotEventSource.swift` | Screenshot taken, via a Spotlight query. Tier 2. |
| `Islet/Events/Sources/AirDropEventSource.swift` | Outbound (real) and inbound (heuristic) AirDrop. Tier 3. |
| `Islet/Events/Sources/FocusEventSource.swift` | Focus / Do Not Disturb, via a file watch. Tier 3. |
| `Islet/Events/Sources/VPNEventSource.swift` | VPN up/down, via a utun interface diff. Tier 3. |
| `IsletTests/SystemEventTests.swift` | Bus enable/disable, tier filtering, event→sneak mapping. |
| `IsletTests/SetDiffTests.swift` | Set diffing, including the identified-element overload. |
| `IsletTests/BurstCoalescerTests.swift` | Burst detection, summary construction, window expiry. |

**Modified**

| File | What changes |
|---|---|
| `Islet/Settings/DefaultsKeys.swift` | `disabledEventSources`. |
| `Islet/Settings/SettingsView.swift` | A generated "System events" section, grouped by tier, with the heuristic tier labelled. |
| `Islet/App/IsletApp.swift` | The Debug menu's sneak buttons are generated from `SourceCatalog` instead of hand-written. |
| `Islet/App/AppDelegate.swift` | Registers every source and calls `SystemEventBus.shared.startEnabled()`. |
| `Islet/Activities/Battery/BatteryActivity.swift` | `sneak(for:)` is replaced by an event; adds the charge-complete case. |
| `Islet/Activities/Battery/BatteryState.swift` | `BatteryEvent.chargeComplete`. |
| `Islet/Activities/AudioDevice/AudioDeviceMonitor.swift` | Emits through the bus instead of building a `Sneak` directly. |
| `Islet/Activities/NowPlaying/NowPlayingActivity.swift` | `trackChangeSneak` emits through the bus, gaining app attribution. |
| `Islet/Activities/Timer/TimerActivity.swift` | Completion emits through the bus. |
| `Islet/Activities/Ports/Ports.swift` | `PortMonitor` exposes the previous device list so the source can diff it. |
| `project.yml` | `NSLocationWhenInUseUsageDescription` for the Wi-Fi SSID name. |

---

## Honest limits of the Tier 3 sources

Write these into the Settings UI, not just this document. Each is labelled "heuristic" there.

| Source | What it cannot do |
|---|---|
| **AirDrop inbound** | Fires **after** the transfer finishes, never during. No progress. No sender name — `sharingd` is the quarantine agent, and the originating device is not recorded anywhere readable. It is a file-appeared notification wearing an AirDrop badge. Requires the Downloads folder TCC grant, which macOS prompts for on first use; the source must degrade to disabled-with-a-reason when denied rather than retrying. |
| **AirDrop outbound** | Real and reliable via `NSSharingServiceDelegate`, but only for shares **Islet itself** initiates. Islet does not initiate AirDrop except from the file shelf, so in practice this fires only for shelf sends. It cannot see a Finder or Safari AirDrop. |
| **Focus** | Reads `~/Library/DoNotDisturb/DB/Assertions.json`, an undocumented private format that has changed between macOS releases. Parse defensively and emit nothing when the shape is unrecognised. It reports *that* a Focus is on, and its identifier — not always a friendly name. |
| **VPN** | A `utun*` interface appearing is not proof of a VPN. iCloud Private Relay, Handoff, AirPlay and Continuity all create utun interfaces. Expect false positives; the event says "Network tunnel up", not "VPN connected". |

---

### Task 1: The SystemEvent value type

**Files:**
- Create: `Islet/Events/SystemEvent.swift`
- Test: `IsletTests/SystemEventTests.swift`

**Interfaces:**
- Consumes: `MotionProfile` (Phase 1.1), `Color(isletHex:)` (`Islet/Support/ColorHex.swift:21`).
- Produces:
  ```swift
  enum SystemEventTier: Int, CaseIterable, Codable, Sendable { case core = 1, extended = 2, heuristic = 3 }
  enum SystemEventUrgency: Int, Comparable, Sendable { case ambient = 0, normal = 1, alert = 2 }
  struct SystemEvent: Identifiable, Equatable, Sendable { ... }
  enum EventAccent { static let neutral/positive/warning/danger/info: String }
  ```

- [ ] **Step 1: Write the failing tests**

Create `IsletTests/SystemEventTests.swift`:

```swift
import SwiftUI
import XCTest

@testable import Islet

final class SystemEventTests: XCTestCase {
  // MARK: - Identity and equality

  /// Two events describing the same thing must compare equal so the coalescer and the queue can
  /// deduplicate them. `id` is per-instance and deliberately excluded from `==`.
  func testEqualityIgnoresIdentity() {
    let a = SystemEvent(sourceID: "usb", icon: "cable.connector", title: "Keyboard connected")
    let b = SystemEvent(sourceID: "usb", icon: "cable.connector", title: "Keyboard connected")
    XCTAssertNotEqual(a.id, b.id)
    XCTAssertEqual(a, b)
  }

  func testEqualityDistinguishesContent() {
    let a = SystemEvent(sourceID: "usb", icon: "cable.connector", title: "Keyboard connected")
    let b = SystemEvent(sourceID: "usb", icon: "cable.connector", title: "Mouse connected")
    XCTAssertNotEqual(a, b)
  }

  // MARK: - Defaults

  func testDefaultsMatchTheExistingSneakDefaults() {
    let e = SystemEvent(sourceID: "x", icon: "circle", title: "T")
    XCTAssertEqual(e.duration, 2)  // Sneak.duration's default
    XCTAssertEqual(e.motion, .generic)
    XCTAssertEqual(e.urgency, .normal)
    XCTAssertNil(e.subtitle)
    XCTAssertEqual(e.accentHex, EventAccent.neutral)
  }

  /// The announcement is what VoiceOver speaks. Falling back to title + subtitle means a source that
  /// forgets to set one is still accessible rather than silent.
  func testAnnouncementFallsBackToTitleAndSubtitle() {
    let bare = SystemEvent(sourceID: "x", icon: "circle", title: "Wi-Fi connected")
    XCTAssertEqual(bare.spokenAnnouncement, "Wi-Fi connected")

    let withSub = SystemEvent(
      sourceID: "x", icon: "circle", title: "Wi-Fi connected", subtitle: "Home")
    XCTAssertEqual(withSub.spokenAnnouncement, "Wi-Fi connected, Home")

    let explicit = SystemEvent(
      sourceID: "x", icon: "circle", title: "Wi-Fi connected", subtitle: "Home",
      announcement: "Joined the Home network")
    XCTAssertEqual(explicit.spokenAnnouncement, "Joined the Home network")
  }

  // MARK: - Urgency ordering

  func testUrgencyOrders() {
    XCTAssertLessThan(SystemEventUrgency.ambient, SystemEventUrgency.normal)
    XCTAssertLessThan(SystemEventUrgency.normal, SystemEventUrgency.alert)
  }

  // MARK: - Accent palette

  /// Every accent must survive the round trip through ColorHex, or the sneak renders with no tint.
  func testEveryAccentParsesAsAColor() {
    for hex in [
      EventAccent.neutral, EventAccent.positive, EventAccent.warning,
      EventAccent.danger, EventAccent.info,
    ] {
      XCTAssertNotNil(Color(isletHex: hex), "accent \(hex) did not parse")
    }
  }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`

Expected: the build fails before any test runs, with

```
IsletTests/SystemEventTests.swift:__:__: error: cannot find 'SystemEvent' in scope
```

- [ ] **Step 3: Create Islet/Events/SystemEvent.swift**

```swift
import Foundation

/// How reliably a source can observe what it claims to observe.
///
/// This is surfaced to the user in Settings, because it is the difference between "Islet will tell
/// you when a USB device is plugged in" and "Islet will probably notice a file that probably arrived
/// by AirDrop, shortly after it finished arriving".
enum SystemEventTier: Int, CaseIterable, Codable, Sendable {
  /// Public, callback-driven, no permission, no ambiguity.
  case core = 1
  /// Public and reliable; may cost one permission prompt.
  case extended = 2
  /// Inferred. Can be late, can be wrong, cannot always name what it saw.
  case heuristic = 3

  var label: String {
    switch self {
    case .core: "Devices and power"
    case .extended: "Network and session"
    case .heuristic: "Inferred (may be late or wrong)"
    }
  }
}

/// Ordering hint for the queue. Nothing consumes it yet — `SneakQueue` is strictly FIFO — but a
/// low-battery warning queueing behind a track change is a real defect, and the ordering fix wants
/// this field to already be populated at every call site when it lands.
enum SystemEventUrgency: Int, Comparable, Sendable {
  case ambient = 0
  case normal = 1
  case alert = 2

  static func < (l: Self, r: Self) -> Bool { l.rawValue < r.rawValue }
}

/// The accent palette, as `#RRGGBB` strings so `SystemEvent` stays `Equatable` and `Sendable`
/// without dragging SwiftUI's `Color` (which is neither, usefully) into the model.
enum EventAccent {
  static let neutral = "#EBEBF5"
  static let positive = "#32D74B"
  static let warning = "#FFD60A"
  static let danger = "#FF453A"
  static let info = "#0A84FF"
}

/// One thing that happened, described completely enough that nothing downstream needs to know which
/// source produced it.
///
/// `Equatable` deliberately ignores `id`: the coalescer and the queue need to ask "is this the same
/// event as that one?", and a per-instance UUID would make the answer always no.
struct SystemEvent: Identifiable, Equatable, Sendable {
  let id: UUID
  /// Coalescing key. Matches the emitting source's `id`, so a second event from the same source
  /// replaces a queued one rather than stacking behind it — the semantics `SneakLogic.enqueue`
  /// already implements (`Islet/Activities/Sneaks/Sneak.swift:18-24`).
  let sourceID: String
  let icon: String
  let title: String
  var subtitle: String?
  var accentHex: String
  var motion: MotionProfile
  var urgency: SystemEventUrgency
  var duration: TimeInterval
  /// Explicit VoiceOver text. Leave nil and `spokenAnnouncement` composes one.
  var announcement: String?

  init(
    id: UUID = UUID(),
    sourceID: String,
    icon: String,
    title: String,
    subtitle: String? = nil,
    accentHex: String = EventAccent.neutral,
    motion: MotionProfile = .generic,
    urgency: SystemEventUrgency = .normal,
    duration: TimeInterval = 2,
    announcement: String? = nil
  ) {
    self.id = id
    self.sourceID = sourceID
    self.icon = icon
    self.title = title
    self.subtitle = subtitle
    self.accentHex = accentHex
    self.motion = motion
    self.urgency = urgency
    self.duration = duration
    self.announcement = announcement
  }

  /// What VoiceOver says. A source that sets no announcement is still announced.
  var spokenAnnouncement: String {
    if let announcement { return announcement }
    guard let subtitle, !subtitle.isEmpty else { return title }
    return "\(title), \(subtitle)"
  }

  static func == (l: Self, r: Self) -> Bool {
    l.sourceID == r.sourceID && l.icon == r.icon && l.title == r.title
      && l.subtitle == r.subtitle && l.accentHex == r.accentHex && l.motion == r.motion
      && l.urgency == r.urgency && l.duration == r.duration && l.announcement == r.announcement
  }
}
```

- [ ] **Step 4: Regenerate the Xcode project**

Run: `xcodegen generate`

Expected: `Created project at .../Islet.xcodeproj`, preceded by the harmless `Vendor/MediaRemoteAdapter.framework` warning.

- [ ] **Step 5: Run tests to verify they pass**

Run: `xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`

Expected: `** TEST SUCCEEDED **`, six more tests than your baseline.

- [ ] **Step 6: Commit**

```bash
git add Islet/Events/SystemEvent.swift IsletTests/SystemEventTests.swift
git commit -m "Events: add the SystemEvent value type"
```

---

### Task 2: SetDiff — one tested difference function for four sources

USB, displays, Bluetooth devices and utun interfaces are all "what appeared, what disappeared". Writing that four times is how three of them end up subtly wrong.

**Files:**
- Create: `Islet/Events/SetDiff.swift`
- Test: `IsletTests/SetDiffTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  ```swift
  enum SetDiff {
    static func changes<T: Hashable>(from old: [T], to new: [T]) -> (added: [T], removed: [T])
    static func changes<T: Identifiable>(from old: [T], to new: [T]) -> (added: [T], removed: [T])
      where T.ID: Hashable
  }
  ```

- [ ] **Step 1: Write the failing tests**

Create `IsletTests/SetDiffTests.swift`:

```swift
import XCTest

@testable import Islet

final class SetDiffTests: XCTestCase {
  func testAddedAndRemoved() {
    let d = SetDiff.changes(from: ["a", "b", "c"], to: ["b", "c", "d"])
    XCTAssertEqual(d.added, ["d"])
    XCTAssertEqual(d.removed, ["a"])
  }

  func testNoChangeYieldsNothing() {
    let d = SetDiff.changes(from: ["a", "b"], to: ["b", "a"])
    XCTAssertTrue(d.added.isEmpty)
    XCTAssertTrue(d.removed.isEmpty)
  }

  /// The very first read has nothing to compare against. Reporting every device as newly attached
  /// on launch would fire a sneak per USB device every time Islet starts.
  func testFirstReadFromEmptyReportsEverythingAsAdded() {
    let d = SetDiff.changes(from: [], to: ["a", "b"])
    XCTAssertEqual(d.added.sorted(), ["a", "b"])
    XCTAssertTrue(d.removed.isEmpty)
  }

  func testEverythingRemoved() {
    let d = SetDiff.changes(from: ["a", "b"], to: [])
    XCTAssertTrue(d.added.isEmpty)
    XCTAssertEqual(d.removed.sorted(), ["a", "b"])
  }

  /// Order of the result follows the order of the input it came from, so a caller can render
  /// "Keyboard, Mouse" in the order the system reported them rather than in hash order.
  func testResultsPreserveInputOrder() {
    let d = SetDiff.changes(from: ["z"], to: ["c", "a", "b"])
    XCTAssertEqual(d.added, ["c", "a", "b"])
  }

  func testDuplicatesInInputDoNotDuplicateInOutput() {
    let d = SetDiff.changes(from: [], to: ["a", "a", "b"])
    XCTAssertEqual(d.added, ["a", "b"])
  }

  // MARK: - Identified overload

  private struct Device: Identifiable, Equatable {
    let id: String
    let name: String
  }

  /// USB devices are compared by locationID, not by value: a device that renegotiates its speed is
  /// the same device, and must not fire a detach followed by an attach.
  func testIdentifiedOverloadComparesByIDNotByValue() {
    let old = [Device(id: "0x1", name: "Keyboard")]
    let new = [Device(id: "0x1", name: "Keyboard (2.0)"), Device(id: "0x2", name: "Mouse")]
    let d = SetDiff.changes(from: old, to: new)
    XCTAssertEqual(d.added, [Device(id: "0x2", name: "Mouse")])
    XCTAssertTrue(d.removed.isEmpty)
  }

  func testIdentifiedOverloadReportsRemovals() {
    let old = [Device(id: "0x1", name: "Keyboard"), Device(id: "0x2", name: "Mouse")]
    let new = [Device(id: "0x2", name: "Mouse")]
    let d = SetDiff.changes(from: old, to: new)
    XCTAssertTrue(d.added.isEmpty)
    XCTAssertEqual(d.removed, [Device(id: "0x1", name: "Keyboard")])
  }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`

Expected: `error: cannot find 'SetDiff' in scope`.

- [ ] **Step 3: Create Islet/Events/SetDiff.swift**

```swift
import Foundation

/// What appeared and what disappeared between two snapshots.
///
/// USB devices, displays, Bluetooth peripherals and network interfaces are all the same question,
/// and four hand-rolled versions of it is three opportunities to get the first-read case wrong.
///
/// Deliberately actor-free: pure logic, so tests call it synchronously.
enum SetDiff {
  /// Results preserve the order of the array they came from, so callers can render device names in
  /// the order the system reported them rather than in hash order.
  static func changes<T: Hashable>(from old: [T], to new: [T]) -> (added: [T], removed: [T]) {
    let oldSet = Set(old)
    let newSet = Set(new)
    var seenAdded: Set<T> = []
    var seenRemoved: Set<T> = []
    let added = new.filter { !oldSet.contains($0) && seenAdded.insert($0).inserted }
    let removed = old.filter { !newSet.contains($0) && seenRemoved.insert($0).inserted }
    return (added, removed)
  }

  /// Compares by identity rather than by value: a device whose *description* changed — a USB device
  /// renegotiating its speed, a display renaming itself — is the same device, and must not produce a
  /// removal followed by an addition.
  static func changes<T: Identifiable>(from old: [T], to new: [T]) -> (added: [T], removed: [T])
  where T.ID: Hashable {
    let oldIDs = Set(old.map(\.id))
    let newIDs = Set(new.map(\.id))
    var seenAdded: Set<T.ID> = []
    var seenRemoved: Set<T.ID> = []
    let added = new.filter { !oldIDs.contains($0.id) && seenAdded.insert($0.id).inserted }
    let removed = old.filter { !newIDs.contains($0.id) && seenRemoved.insert($0.id).inserted }
    return (added, removed)
  }
}
```

- [ ] **Step 4: Regenerate the Xcode project**

Run: `xcodegen generate`

- [ ] **Step 5: Run tests to verify they pass**

Run: `xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`

Expected: `** TEST SUCCEEDED **`, eight more tests.

- [ ] **Step 6: Commit**

```bash
git add Islet/Events/SetDiff.swift IsletTests/SetDiffTests.swift
git commit -m "Events: add a tested set-difference helper for device snapshots"
```

---

### Task 3: BurstCoalescer

Docking a MacBook fires display connect, several USB attaches, a power event, an audio-device change and a volume mount inside about two seconds. At the queue's 2s duration plus a 250ms gap that is roughly eleven seconds of island churn for one physical action.

**Files:**
- Create: `Islet/Events/BurstCoalescer.swift`
- Test: `IsletTests/BurstCoalescerTests.swift`

**Interfaces:**
- Consumes: `SystemEvent` (Task 1), `EventAccent` (Task 1).
- Produces:
  ```swift
  struct BurstCoalescer {
    enum Decision: Equatable { case pass(SystemEvent); case hold; case summarise(SystemEvent) }
    init(window: TimeInterval = 2.5, threshold: Int = 3, maxHeld: Int = 12)
    mutating func accept(_ event: SystemEvent, at now: TimeInterval) -> Decision
    mutating func flush(at now: TimeInterval) -> SystemEvent?
    var isHolding: Bool { get }
  }
  ```

Time is passed in explicitly rather than read from `Date()`, so the whole thing is a pure function of its inputs and tests need no sleeps.

- [ ] **Step 1: Write the failing tests**

Create `IsletTests/BurstCoalescerTests.swift`:

```swift
import XCTest

@testable import Islet

final class BurstCoalescerTests: XCTestCase {
  private func event(_ source: String, _ title: String) -> SystemEvent {
    SystemEvent(sourceID: source, icon: "circle", title: title)
  }

  /// Isolated events are the common case and must pass straight through untouched.
  func testEventsBelowTheThresholdPassThrough() {
    var c = BurstCoalescer(window: 2.5, threshold: 3)
    XCTAssertEqual(c.accept(event("usb", "Keyboard"), at: 0), .pass(event("usb", "Keyboard")))
    XCTAssertEqual(c.accept(event("usb", "Mouse"), at: 0.4), .pass(event("usb", "Mouse")))
    XCTAssertFalse(c.isHolding)
  }

  /// The third event inside the window turns the burst on: it and everything after it are held.
  func testTheThirdEventInsideTheWindowStartsHolding() {
    var c = BurstCoalescer(window: 2.5, threshold: 3)
    _ = c.accept(event("usb", "Keyboard"), at: 0)
    _ = c.accept(event("display", "Studio Display"), at: 0.3)
    XCTAssertEqual(c.accept(event("volume", "Backup"), at: 0.6), .hold)
    XCTAssertEqual(c.accept(event("usb", "Hub"), at: 0.9), .hold)
    XCTAssertTrue(c.isHolding)
  }

  /// Flushing after the window closes yields one summary naming what arrived.
  func testFlushSummarisesTheHeldBurst() {
    var c = BurstCoalescer(window: 2.5, threshold: 3)
    _ = c.accept(event("usb", "Keyboard"), at: 0)
    _ = c.accept(event("display", "Studio Display"), at: 0.3)
    _ = c.accept(event("volume", "Backup"), at: 0.6)
    _ = c.accept(event("usb", "Hub"), at: 0.9)

    let summary = c.flush(at: 3.5)
    XCTAssertNotNil(summary)
    XCTAssertEqual(summary?.sourceID, "burst")
    XCTAssertEqual(summary?.title, "4 system events")
    XCTAssertEqual(summary?.subtitle, "Keyboard, Studio Display, Backup +1")
    XCTAssertEqual(summary?.duration, 3)
    XCTAssertFalse(c.isHolding)
  }

  /// Exactly three held events name all three rather than "+0".
  func testSummaryWithNoOverflowOmitsTheCounter() {
    var c = BurstCoalescer(window: 2.5, threshold: 2)
    _ = c.accept(event("usb", "Keyboard"), at: 0)
    _ = c.accept(event("usb", "Mouse"), at: 0.2)
    _ = c.accept(event("usb", "Hub"), at: 0.4)
    XCTAssertEqual(c.flush(at: 3)?.subtitle, "Mouse, Hub")
  }

  /// Flushing before the window closes yields nothing: the burst may still be growing.
  func testFlushBeforeTheWindowClosesYieldsNothing() {
    var c = BurstCoalescer(window: 2.5, threshold: 3)
    _ = c.accept(event("usb", "Keyboard"), at: 0)
    _ = c.accept(event("display", "Studio"), at: 0.3)
    _ = c.accept(event("volume", "Backup"), at: 0.6)
    XCTAssertNil(c.flush(at: 1.0))
    XCTAssertTrue(c.isHolding)
  }

  /// Nothing held means nothing to flush — the timer firing on a quiet system is a no-op.
  func testFlushWithNothingHeldYieldsNothing() {
    var c = BurstCoalescer(window: 2.5, threshold: 3)
    XCTAssertNil(c.flush(at: 10))
  }

  /// Events spread out beyond the window are not a burst, however many there are.
  func testEventsOutsideTheWindowNeverAccumulate() {
    var c = BurstCoalescer(window: 2.5, threshold: 3)
    for i in 0..<10 {
      let e = event("usb", "Device \(i)")
      XCTAssertEqual(c.accept(e, at: Double(i) * 5), .pass(e), "event \(i) should pass")
    }
    XCTAssertFalse(c.isHolding)
  }

  /// An alert must never be swallowed by a burst. Low battery during docking is exactly when you
  /// need to see it.
  func testAlertsAlwaysPassEvenMidBurst() {
    var c = BurstCoalescer(window: 2.5, threshold: 3)
    _ = c.accept(event("usb", "Keyboard"), at: 0)
    _ = c.accept(event("display", "Studio"), at: 0.3)
    _ = c.accept(event("volume", "Backup"), at: 0.6)
    XCTAssertTrue(c.isHolding)

    var alert = event("battery", "Low battery")
    alert.urgency = .alert
    XCTAssertEqual(c.accept(alert, at: 0.7), .pass(alert))
    XCTAssertTrue(c.isHolding)  // the burst is still held; the alert jumped it
  }

  /// A pathological storm must not grow the held array without bound.
  func testHeldEventsAreCappedButStillCounted() {
    var c = BurstCoalescer(window: 100, threshold: 3, maxHeld: 5)
    for i in 0..<50 { _ = c.accept(event("usb", "Device \(i)"), at: Double(i) * 0.01) }
    let summary = c.flush(at: 200)
    XCTAssertEqual(summary?.title, "50 system events")  // the count is exact ...
    XCTAssertEqual(summary?.subtitle?.contains("+47"), true)  // ... even though only 5 were kept
  }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`

Expected: `error: cannot find 'BurstCoalescer' in scope`.

- [ ] **Step 3: Create Islet/Events/BurstCoalescer.swift**

```swift
import Foundation

/// Collapses a flurry of events into one summary.
///
/// Docking a MacBook fires a display connect, several USB attaches, a power change, an audio-device
/// change and a volume mount inside about two seconds. Presented individually at the queue's 2s
/// duration plus a 250ms gap, one physical action becomes eleven seconds of island churn.
///
/// Time is a parameter rather than read from `Date()`, which keeps this a pure function of its
/// inputs — tests need no sleeps and no clock injection protocol.
///
/// Deliberately actor-free: pure logic, so tests call it synchronously.
struct BurstCoalescer {
  enum Decision: Equatable {
    /// Present this event now.
    case pass(SystemEvent)
    /// Held as part of a burst. Present nothing; `flush` will produce a summary.
    case hold
  }

  /// Events closer together than this are candidates for the same burst.
  let window: TimeInterval
  /// How many events inside `window` before coalescing starts. The first `threshold - 1` are
  /// presented normally, so an ordinary pair of events is never delayed.
  let threshold: Int
  /// Upper bound on retained events. The *count* stays exact; only the named ones are capped.
  let maxHeld: Int

  private var recentTimes: [TimeInterval] = []
  private var held: [SystemEvent] = []
  private var heldCount = 0
  private var burstStartedAt: TimeInterval?

  init(window: TimeInterval = 2.5, threshold: Int = 3, maxHeld: Int = 12) {
    self.window = window
    self.threshold = threshold
    self.maxHeld = maxHeld
  }

  var isHolding: Bool { heldCount > 0 }

  mutating func accept(_ event: SystemEvent, at now: TimeInterval) -> Decision {
    // An alert is never swallowed by a burst — low battery during docking is exactly when it
    // matters. It also does not count towards the burst, so it cannot trigger one on its own.
    guard event.urgency != .alert else { return .pass(event) }

    recentTimes.removeAll { now - $0 > window }
    recentTimes.append(now)

    guard recentTimes.count >= threshold else { return .pass(event) }

    if burstStartedAt == nil { burstStartedAt = now }
    heldCount += 1
    if held.count < maxHeld { held.append(event) }
    return .hold
  }

  /// Produces the summary once the burst has gone quiet for a full window. Returns nil while the
  /// burst may still be growing, and nil when nothing is held.
  mutating func flush(at now: TimeInterval) -> SystemEvent? {
    guard heldCount > 0 else { return nil }
    guard let last = recentTimes.last, now - last >= window else { return nil }

    let count = heldCount
    let names = held.map(\.title)
    let shown = Array(names.prefix(3))
    let overflow = count - shown.count
    let subtitle = overflow > 0 ? "\(shown.joined(separator: ", ")) +\(overflow)"
      : shown.joined(separator: ", ")

    held.removeAll()
    heldCount = 0
    burstStartedAt = nil
    recentTimes.removeAll()

    return SystemEvent(
      sourceID: "burst",
      icon: "square.stack.3d.up.fill",
      title: "\(count) system events",
      subtitle: subtitle,
      accentHex: EventAccent.info,
      motion: .generic,
      urgency: .normal,
      duration: 3)
  }
}
```

- [ ] **Step 4: Regenerate the Xcode project**

Run: `xcodegen generate`

- [ ] **Step 5: Run tests to verify they pass**

Run: `xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`

Expected: `** TEST SUCCEEDED **`, nine more tests.

- [ ] **Step 6: Commit**

```bash
git add Islet/Events/BurstCoalescer.swift IsletTests/BurstCoalescerTests.swift
git commit -m "Events: coalesce a docking burst into one summary sneak"
```

---

### Task 4: The source protocol and catalogue

**Files:**
- Create: `Islet/Events/SystemEventSource.swift`
- Modify: `Islet/Settings/DefaultsKeys.swift` (append inside `extension Defaults.Keys`)
- Test: `IsletTests/SystemEventTests.swift` (append)

**Interfaces:**
- Consumes: `SystemEventTier` (Task 1).
- Produces:
  ```swift
  @MainActor protocol SystemEventSource: AnyObject {
    var id: String { get }
    var displayName: String { get }
    var tier: SystemEventTier { get }
    func start()
    func stop()
  }
  enum SourceCatalog {
    static let all: [(id: String, name: String, tier: SystemEventTier, icon: String)]
    static func name(for id: String) -> String
    static func tier(for id: String) -> SystemEventTier
    static func ids(in tier: SystemEventTier) -> [String]
  }
  ```
  New Defaults key: `disabledEventSources`.

- [ ] **Step 1: Write the failing tests**

Append to `IsletTests/SystemEventTests.swift`, before the closing `}` of the class:

```swift
  // MARK: - Source catalogue

  /// The catalogue is the single list Settings, the Debug menu and the bus all read. A duplicate id
  /// would silently give two sources the same toggle.
  func testCatalogueIDsAreUnique() {
    let ids = SourceCatalog.all.map(\.id)
    XCTAssertEqual(Set(ids).count, ids.count, "duplicate source id in SourceCatalog")
  }

  func testCatalogueIsGroupedByTierWithNothingOrphaned() {
    let grouped = SystemEventTier.allCases.flatMap { SourceCatalog.ids(in: $0) }
    XCTAssertEqual(Set(grouped), Set(SourceCatalog.all.map(\.id)))
  }

  func testCatalogueLookupsFallBackToTheRawID() {
    XCTAssertEqual(SourceCatalog.name(for: "usb"), "USB devices")
    XCTAssertEqual(SourceCatalog.name(for: "nope"), "nope")
    XCTAssertEqual(SourceCatalog.tier(for: "nope"), .core)
  }

  /// Every Tier 3 source must be reachable through the tier query, because that is what puts the
  /// "may be late or wrong" caption above them in Settings.
  func testHeuristicTierContainsTheInferredSources() {
    let heuristic = Set(SourceCatalog.ids(in: .heuristic))
    XCTAssertTrue(heuristic.contains("airdropIn"))
    XCTAssertTrue(heuristic.contains("focus"))
    XCTAssertTrue(heuristic.contains("vpn"))
  }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`

Expected: `error: cannot find 'SourceCatalog' in scope`.

- [ ] **Step 3: Create Islet/Events/SystemEventSource.swift**

```swift
import Foundation

/// One observer of one kind of system event.
///
/// Sources are started and stopped by `SystemEventBus` as the user toggles them, so a disabled
/// source holds no notification registration, no run-loop source and no timer — it costs nothing.
@MainActor
protocol SystemEventSource: AnyObject {
  /// Stable identifier. Doubles as the coalescing key on every event this source emits, and as the
  /// Defaults key suffix for its toggle.
  var id: String { get }
  var displayName: String { get }
  var tier: SystemEventTier { get }
  /// Begin observing. Must be idempotent — the bus may call it again after a Defaults round trip.
  func start()
  /// Stop observing and release every registration. Must leave the source restartable.
  func stop()
}

/// The single list of every event source: its id, its user-facing name, its tier and its icon.
///
/// Settings renders from this, the Debug menu generates a "fire this event" button from it, and the
/// bus validates registrations against it. Adding a source means adding one row here and one file.
enum SourceCatalog {
  static let all: [(id: String, name: String, tier: SystemEventTier, icon: String)] = [
    // Tier 1 — public, callback-driven, no permission.
    ("usb", "USB devices", .core, "cable.connector"),
    ("volume", "Disks and volumes", .core, "externaldrive.fill"),
    ("display", "External displays", .core, "display"),
    ("power", "Charging and Low Power Mode", .core, "bolt.fill"),
    ("sleep", "Sleep and wake", .core, "moon.fill"),
    ("peripheral", "Peripheral batteries", .core, "magicmouse.fill"),
    ("audiodevice", "Audio output device", .core, "airpodspro"),
    ("battery", "Battery", .core, "battery.100percent.bolt"),
    ("timer", "Timer", .core, "timer"),
    ("nowPlaying", "Track changes", .core, "music.note"),
    // Tier 2 — public and reliable; Wi-Fi names cost one Location prompt.
    ("wifi", "Wi-Fi", .extended, "wifi"),
    ("bluetooth", "Bluetooth devices", .extended, "dot.radiowaves.right"),
    ("session", "Screen lock and Caps Lock", .extended, "lock.fill"),
    ("screenshot", "Screenshots", .extended, "camera.viewfinder"),
    // Tier 3 — inferred. Can be late, can be wrong.
    ("airdropOut", "AirDrop sent", .heuristic, "square.and.arrow.up"),
    ("airdropIn", "AirDrop received", .heuristic, "square.and.arrow.down"),
    ("focus", "Focus mode", .heuristic, "moon.circle.fill"),
    ("vpn", "Network tunnel", .heuristic, "lock.shield.fill"),
  ]

  static func name(for id: String) -> String {
    all.first { $0.id == id }?.name ?? id
  }

  static func tier(for id: String) -> SystemEventTier {
    all.first { $0.id == id }?.tier ?? .core
  }

  static func icon(for id: String) -> String {
    all.first { $0.id == id }?.icon ?? "circle"
  }

  static func ids(in tier: SystemEventTier) -> [String] {
    all.filter { $0.tier == tier }.map(\.id)
  }
}
```

- [ ] **Step 4: Add the Defaults key**

In `Islet/Settings/DefaultsKeys.swift`, replace:

```swift
  static let portsEnabled = Key<Bool>("portsEnabled", default: true)
}
```

with:

```swift
  static let portsEnabled = Key<Bool>("portsEnabled", default: true)
  /// Event sources the user has switched off. Absent means on — every source ships enabled, and a
  /// disabled source is fully stopped rather than merely silenced.
  static let disabledEventSources = Key<[String]>("disabledEventSources", default: [])
}
```

- [ ] **Step 5: Regenerate the Xcode project**

Run: `xcodegen generate`

- [ ] **Step 6: Run tests to verify they pass**

Run: `xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`

Expected: `** TEST SUCCEEDED **`, four more tests.

- [ ] **Step 7: Commit**

```bash
git add Islet/Events/SystemEventSource.swift Islet/Settings/DefaultsKeys.swift IsletTests/SystemEventTests.swift
git commit -m "Events: add the source protocol and the source catalogue"
```

---

### Task 5: Sneak.init(event:) — the presentation mapping

**Files:**
- Create: `Islet/Events/EventSneak.swift`
- Test: `IsletTests/SystemEventTests.swift` (append)

**Interfaces:**
- Consumes: `SystemEvent` (Task 1), `Sneak` (`Islet/Activities/Sneaks/Sneak.swift:4-12`), `Color(isletHex:)`, `MotionProfile`, `EventMotion` (Task 6 — declared here, implemented there; until then `.eventMotion(_:)` is a no-op modifier defined in Task 6's file).
- Produces: `extension Sneak { init(event: SystemEvent) }`, `struct EventLeadingView`, `struct EventTrailingView`.

**Task 6 must land before this builds.** Do Task 6 first if you are executing out of order.

- [ ] **Step 1: Write the failing tests**

Append to `IsletTests/SystemEventTests.swift`, before the closing `}` of the class:

```swift
  // MARK: - Event to sneak

  /// The bus renders events into the existing Sneak type; the queue is untouched. Coalescing key,
  /// duration and announcement must all survive the trip.
  @MainActor
  func testSneakCarriesTheEventsCoalescingKeyDurationAndAnnouncement() {
    let e = SystemEvent(
      sourceID: "wifi", icon: "wifi", title: "Wi-Fi connected", subtitle: "Home",
      accentHex: EventAccent.positive, motion: .wifi, duration: 2.5)
    let sneak = Sneak(event: e)
    XCTAssertEqual(sneak.source, "wifi")
    XCTAssertEqual(sneak.duration, 2.5)
    XCTAssertEqual(sneak.announcement, "Wi-Fi connected, Home")
  }

  @MainActor
  func testSneakUsesTheExplicitAnnouncementWhenGiven() {
    let e = SystemEvent(
      sourceID: "vpn", icon: "lock.shield.fill", title: "Tunnel up",
      announcement: "A network tunnel came up")
    XCTAssertEqual(Sneak(event: e).announcement, "A network tunnel came up")
  }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`

Expected: `error: incorrect argument label in call (have 'event:', expected 'source:')` or `extra argument 'event' in call`.

- [ ] **Step 3: Create Islet/Events/EventSneak.swift**

```swift
import SwiftUI

/// The leading slot: the event's icon, tinted, wearing its source's bespoke choreography.
///
/// Sized to match the existing compact glyphs exactly (`.font(.caption)` — see
/// `BatteryActivity.compactLeading`), because the panel width is derived from what this measures.
struct EventLeadingView: View {
  let event: SystemEvent

  var body: some View {
    Image(systemName: event.icon)
      .font(.caption)
      .foregroundStyle(Color(isletHex: event.accentHex) ?? .white)
      .eventMotion(event.motion)
  }
}

/// The trailing slot: title, plus subtitle when there is one and it fits.
///
/// `lineLimit(1)` and a max width are load-bearing. The compact slots are measured and the panel is
/// sized from the measurement, so an unbounded string drags the island out to the width of a track
/// title — the creep that `NotchRootView`'s comment at the `.frame(width: compactVisible ? nil : ...)`
/// call already warns about.
struct EventTrailingView: View {
  let event: SystemEvent

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(event.title)
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.white)
        .lineLimit(1)
      if let subtitle = event.subtitle, !subtitle.isEmpty {
        Text(subtitle)
          .font(.system(size: 9))
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
    .frame(maxWidth: 150, alignment: .leading)
    .fixedSize(horizontal: true, vertical: false)
  }
}

extension Sneak {
  /// Renders an event into the transient-presentation type the queue already understands.
  ///
  /// `source` becomes the event's `sourceID`, which is what gives the queue its existing coalescing
  /// behaviour for free: a second Wi-Fi event replaces a queued one instead of stacking behind it
  /// (`SneakLogic.enqueue`).
  @MainActor
  init(event: SystemEvent) {
    self.init(
      source: event.sourceID,
      duration: event.duration,
      leading: AnyView(EventLeadingView(event: event)),
      trailing: AnyView(EventTrailingView(event: event)),
      announcement: event.spokenAnnouncement)
  }
}
```

- [ ] **Step 4: Regenerate the Xcode project**

Run: `xcodegen generate`

- [ ] **Step 5: Run tests to verify they pass**

Run: `xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`

Expected: `** TEST SUCCEEDED **`, two more tests.

- [ ] **Step 6: Commit**

```bash
git add Islet/Events/EventSneak.swift IsletTests/SystemEventTests.swift
git commit -m "Events: render a system event into the existing sneak type"
```

---

### Task 6: Bespoke motion per source

**Files:**
- Create: `Islet/Events/EventMotion.swift`

**Interfaces:**
- Consumes: `MotionProfile`, `Motion.gated(_:)` (Phase 1.1).
- Produces: `extension View { func eventMotion(_ profile: MotionProfile) -> some View }`.

No unit test — this is SwiftUI animation, not extractable logic. Verified by build plus the manual check in Step 3. What *is* testable — that every profile is handled — is enforced by the `switch` being exhaustive over `MotionProfile`, which the compiler checks.

**The inward-overshoot invariant is enforced here.** Every `scaleEffect` in this file starts below 1.0 and ends at exactly 1.0. Grep for `scaleEffect(1.` after editing: there must be no value above `1.0`.

- [ ] **Step 1: Create Islet/Events/EventMotion.swift**

```swift
import SwiftUI

/// Per-source choreography for an event's icon.
///
/// Each profile is a distinct piece of motion, so a Wi-Fi drop and a completed timer do not feel
/// identical — but all of them obey two rules:
///
/// 1. **Overshoot is inward only.** Scale runs 0.6 → 1.0 and never past it. `Metrics.islandMargin`
///    is 4pt, `Metrics.collapsedDepth` is 12pt, and the island is clipped by both the `NotchShape`
///    mask and the panel window. A bounce to 1.15 is clipped to a hard edge, and widening the
///    margins to fit it gives back the menu-bar clickability commits 372c645 and 61cf4d5 bought.
/// 2. **Everything routes through `Motion.gated`**, so Reduce Motion makes the change instant
///    rather than removing the event.
private struct EventMotionModifier: ViewModifier {
  let profile: MotionProfile
  @State private var appeared = false

  func body(content: Content) -> some View {
    switch profile {
    // Signal arcs filling outward from the dot.
    case .wifi:
      content
        .symbolEffect(.variableColor.iterative, options: .repeat(2), value: appeared)
        .scaleEffect(appeared ? 1.0 : 0.7)
        .onAppear { animate() }

    // A pulse, the way a pairing indicator pulses.
    case .bluetooth:
      content
        .symbolEffect(.pulse, options: .repeat(2), value: appeared)
        .scaleEffect(appeared ? 1.0 : 0.8)
        .onAppear { animate() }

    // Slides in from the leading edge, like a plug going in. Travel is inside the measured slot.
    case .usb:
      content
        .offset(x: appeared ? 0 : -10)
        .opacity(appeared ? 1 : 0)
        .onAppear { animate() }

    // A radar sweep outward.
    case .airdrop:
      content
        .symbolEffect(.variableColor.cumulative, options: .repeat(3), value: appeared)
        .scaleEffect(appeared ? 1.0 : 0.75)
        .onAppear { animate() }

    // A drive rising into place.
    case .volumeMount:
      content
        .offset(y: appeared ? 0 : 6)
        .opacity(appeared ? 1 : 0)
        .onAppear { animate() }

    // A screen unfolding.
    case .display:
      content
        .scaleEffect(x: appeared ? 1.0 : 0.6, y: appeared ? 1.0 : 0.85, anchor: .center)
        .opacity(appeared ? 1 : 0)
        .onAppear { animate() }

    // The checkmark draws itself on.
    case .chargeComplete:
      content
        .symbolEffect(.bounce, options: .nonRepeating, value: appeared)
        .scaleEffect(appeared ? 1.0 : 0.6)
        .onAppear { animate() }

    // A slow amber breath — deliberately calmer than the rest; it is a state, not an arrival.
    case .lowPower:
      content
        .symbolEffect(.pulse, options: .repeat(3), value: appeared)
        .opacity(appeared ? 1 : 0.3)
        .onAppear { animate() }

    // Flash, then settle small — the shutter.
    case .screenshot:
      content
        .scaleEffect(appeared ? 1.0 : 0.9)
        .brightness(appeared ? 0 : 0.8)
        .onAppear { animate() }

    // Snaps shut.
    case .lock:
      content
        .symbolEffect(.bounce.down, options: .nonRepeating, value: appeared)
        .scaleEffect(appeared ? 1.0 : 0.85)
        .onAppear { animate() }

    // Fades down, like the screen going to sleep.
    case .sleepWake:
      content
        .opacity(appeared ? 1 : 0)
        .scaleEffect(appeared ? 1.0 : 0.92)
        .onAppear { animate() }

    // A shake: this one wants attention.
    case .peripheralLow:
      content
        .symbolEffect(.wiggle, options: .repeat(2), value: appeared)
        .onAppear { animate() }

    // A crescent settling in.
    case .focus:
      content
        .rotationEffect(.degrees(appeared ? 0 : -25))
        .scaleEffect(appeared ? 1.0 : 0.8)
        .onAppear { animate() }

    // The shield seals.
    case .vpn:
      content
        .symbolEffect(.bounce.up, options: .nonRepeating, value: appeared)
        .scaleEffect(appeared ? 1.0 : 0.75)
        .onAppear { animate() }

    // Everything else: a plain settle. Still gated, still inward.
    case .generic:
      content
        .scaleEffect(appeared ? 1.0 : 0.8)
        .opacity(appeared ? 1 : 0)
        .onAppear { animate() }
    }
  }

  /// One entry point so no profile can forget the Reduce Motion gate. `withAnimation(nil)` applies
  /// the state change instantly, which is exactly the wanted behaviour: the event still appears.
  private func animate() {
    withAnimation(Motion.gated(.bouncy(duration: 0.45))) { appeared = true }
  }
}

extension View {
  /// Applies the bespoke choreography for a source's event class.
  func eventMotion(_ profile: MotionProfile) -> some View {
    modifier(EventMotionModifier(profile: profile))
  }
}
```

- [ ] **Step 2: Regenerate and build**

Run: `xcodegen generate && xcodebuild build -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`

Expected: `** BUILD SUCCEEDED **`.

If any `symbolEffect` named above does not exist on this SDK, the compiler names it. Replace only
that one with `.bounce` and leave a comment saying which effect was unavailable — do not remove the
`scaleEffect`/`opacity` fallback around it, which is what carries the motion when a symbol effect is
unavailable.

- [ ] **Step 3: Verify the inward-overshoot invariant**

```bash
grep -n "scaleEffect" Islet/Events/EventMotion.swift | grep -v "1\.0" | grep -v "0\."
```

Expected: no output. Any hit is a scale factor that is neither a documented inward start nor the 1.0
resting state, and must be brought inside those bounds.

- [ ] **Step 4: Run the full test suite**

Run: `xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`

Expected: `** TEST SUCCEEDED **`, count unchanged from Task 5.

- [ ] **Step 5: Commit**

```bash
git add Islet/Events/EventMotion.swift
git commit -m "Events: give each source its own icon choreography"
```

---

### Task 7: SystemEventBus

**Files:**
- Create: `Islet/Events/SystemEventBus.swift`
- Test: `IsletTests/SystemEventTests.swift` (append)

**Interfaces:**
- Consumes: `SystemEvent`, `SystemEventSource`, `SourceCatalog`, `BurstCoalescer`, `Sneak.init(event:)`, `SneakQueue.shared`, `Defaults[.disabledEventSources]`.
- Produces:
  ```swift
  @MainActor final class SystemEventBus: ObservableObject {
    static let shared: SystemEventBus
    var sources: [any SystemEventSource] { get }
    func register(_ source: any SystemEventSource)
    func startEnabled()
    func emit(_ event: SystemEvent)
    func isEnabled(_ sourceID: String) -> Bool
    func setEnabled(_ enabled: Bool, for sourceID: String)
  }
  ```

- [ ] **Step 1: Write the failing tests**

Append to `IsletTests/SystemEventTests.swift`, before the closing `}` of the class:

```swift
  // MARK: - Bus

  /// A stub source that records whether the bus started and stopped it.
  @MainActor
  private final class StubSource: SystemEventSource {
    let id: String
    let displayName = "Stub"
    let tier: SystemEventTier
    private(set) var startCount = 0
    private(set) var stopCount = 0
    init(id: String, tier: SystemEventTier = .core) {
      self.id = id
      self.tier = tier
    }
    func start() { startCount += 1 }
    func stop() { stopCount += 1 }
  }

  @MainActor
  private func makeBus() -> SystemEventBus {
    Defaults[.disabledEventSources] = []
    return SystemEventBus(queue: nil)
  }

  @MainActor
  func testSourcesShipEnabled() {
    let bus = makeBus()
    XCTAssertTrue(bus.isEnabled("usb"))
    XCTAssertTrue(bus.isEnabled("airdropIn"))
  }

  /// Disabling must actually STOP the source, not merely silence it — a stopped source holds no
  /// notification registration, no run-loop source and no timer.
  @MainActor
  func testDisablingStopsTheSourceAndEnablingRestartsIt() {
    let bus = makeBus()
    let stub = StubSource(id: "usb")
    bus.register(stub)
    bus.startEnabled()
    XCTAssertEqual(stub.startCount, 1)

    bus.setEnabled(false, for: "usb")
    XCTAssertEqual(stub.stopCount, 1)
    XCTAssertFalse(bus.isEnabled("usb"))

    bus.setEnabled(true, for: "usb")
    XCTAssertEqual(stub.startCount, 2)
    XCTAssertTrue(bus.isEnabled("usb"))
  }

  @MainActor
  func testStartEnabledSkipsDisabledSources() {
    Defaults[.disabledEventSources] = ["usb"]
    let bus = SystemEventBus(queue: nil)
    let off = StubSource(id: "usb")
    let on = StubSource(id: "wifi", tier: .extended)
    bus.register(off)
    bus.register(on)
    bus.startEnabled()
    XCTAssertEqual(off.startCount, 0)
    XCTAssertEqual(on.startCount, 1)
    Defaults[.disabledEventSources] = []
  }

  /// An event from a disabled source must not reach the queue even if the source emits anyway —
  /// belt and braces, because a source with an in-flight callback can emit after stop().
  @MainActor
  func testEmitFromADisabledSourceIsDropped() {
    let bus = makeBus()
    var delivered: [Sneak] = []
    bus.onSneak = { delivered.append($0) }

    bus.emit(SystemEvent(sourceID: "usb", icon: "cable.connector", title: "Keyboard"))
    XCTAssertEqual(delivered.count, 1)

    bus.setEnabled(false, for: "usb")
    bus.emit(SystemEvent(sourceID: "usb", icon: "cable.connector", title: "Mouse"))
    XCTAssertEqual(delivered.count, 1, "a disabled source's event reached the queue")
    Defaults[.disabledEventSources] = []
  }

  /// Registering twice must not double-start or double-deliver.
  @MainActor
  func testRegisteringTheSameSourceTwiceIsIdempotent() {
    let bus = makeBus()
    let stub = StubSource(id: "usb")
    bus.register(stub)
    bus.register(stub)
    XCTAssertEqual(bus.sources.count, 1)
    bus.startEnabled()
    XCTAssertEqual(stub.startCount, 1)
  }
```

Add `import Defaults` to the top of `IsletTests/SystemEventTests.swift`.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`

Expected: `error: cannot find 'SystemEventBus' in scope`.

- [ ] **Step 3: Create Islet/Events/SystemEventBus.swift**

```swift
import Combine
import Defaults
import Foundation

/// Registration, enable/disable and delivery for every system-event source.
///
/// Mirrors `ActivityCenter` (`Islet/Activities/ActivityCenter.swift`) on purpose: same registration
/// shape, same Defaults-driven enable/disable, so the Settings section and the Debug menu both
/// generate from `SourceCatalog` rather than being hand-maintained alongside it.
///
/// Delivery goes through the existing `SneakQueue` untouched. The bus's own contribution is the
/// burst coalescer: one physical action (docking) can fire six sources at once, and the queue is
/// strictly FIFO with a 2s dwell.
@MainActor
final class SystemEventBus: ObservableObject {
  static let shared = SystemEventBus(queue: SneakQueue.shared)

  private let queue: SneakQueue?
  /// Test seam. Left nil in production, where `queue` does the delivering.
  var onSneak: ((Sneak) -> Void)?

  private(set) var sources: [any SystemEventSource] = []
  private var coalescer = BurstCoalescer()
  private var flushTask: Task<Void, Never>?
  private let startedAt = Date()

  init(queue: SneakQueue?) {
    self.queue = queue
  }

  // MARK: - Registration

  /// Idempotent: registering the same id twice keeps the first registration, so a double call in
  /// `AppDelegate` cannot double-start an observer.
  func register(_ source: any SystemEventSource) {
    guard !sources.contains(where: { $0.id == source.id }) else { return }
    if !SourceCatalog.all.contains(where: { $0.id == source.id }) {
      Log.app.error(
        "Event source \(source.id, privacy: .public) is not in SourceCatalog; it will have no Settings toggle"
      )
    }
    sources.append(source)
    objectWillChange.send()
  }

  /// Starts every source the user has left enabled. Called once at launch.
  func startEnabled() {
    for source in sources where isEnabled(source.id) {
      source.start()
    }
  }

  // MARK: - Enable / disable

  func isEnabled(_ sourceID: String) -> Bool {
    !Defaults[.disabledEventSources].contains(sourceID)
  }

  /// Toggling actually starts or stops the source. A disabled source holds no registration, no
  /// run-loop source and no timer — "off" means off, not muted.
  func setEnabled(_ enabled: Bool, for sourceID: String) {
    var disabled = Defaults[.disabledEventSources]
    if enabled {
      disabled.removeAll { $0 == sourceID }
    } else if !disabled.contains(sourceID) {
      disabled.append(sourceID)
    }
    Defaults[.disabledEventSources] = disabled

    if let source = sources.first(where: { $0.id == sourceID }) {
      if enabled { source.start() } else { source.stop() }
    }
    objectWillChange.send()
  }

  // MARK: - Emission

  /// The one path from a source to the island.
  ///
  /// The enabled check is repeated here even though a disabled source is stopped: a source with an
  /// in-flight callback can emit once after `stop()` returns, and that event should not appear.
  func emit(_ event: SystemEvent) {
    guard isEnabled(event.sourceID) else { return }
    let now = Date().timeIntervalSince(startedAt)
    switch coalescer.accept(event, at: now) {
    case .pass(let passed):
      deliver(passed)
    case .hold:
      scheduleFlush()
    }
  }

  private func deliver(_ event: SystemEvent) {
    let sneak = Sneak(event: event)
    if let onSneak {
      onSneak(sneak)
    } else {
      queue?.submit(sneak)
    }
  }

  /// A single pending flush, re-armed rather than stacked: the coalescer returns nil until the burst
  /// has been quiet for a full window, so an early wake-up simply reschedules.
  private func scheduleFlush() {
    guard flushTask == nil else { return }
    flushTask = Task { [weak self] in
      while true {
        try? await Task.sleep(for: .milliseconds(400))
        guard let self, !Task.isCancelled else { return }
        let now = Date().timeIntervalSince(self.startedAt)
        if let summary = self.coalescer.flush(at: now) {
          self.deliver(summary)
          self.flushTask = nil
          return
        }
        if !self.coalescer.isHolding {
          self.flushTask = nil
          return
        }
      }
    }
  }
}
```

- [ ] **Step 4: Regenerate the Xcode project**

Run: `xcodegen generate`

- [ ] **Step 5: Run tests to verify they pass**

Run: `xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`

Expected: `** TEST SUCCEEDED **`, five more tests.

- [ ] **Step 6: Commit**

```bash
git add Islet/Events/SystemEventBus.swift IsletTests/SystemEventTests.swift
git commit -m "Events: add the bus that owns source registration and delivery"
```

---

### Task 8: Migrate the four existing producers

Four sources already emit sneaks, with hand-typed coalescing keys and inconsistent gating: battery and audio device check a Defaults key, timer and track change check nothing at all. They move onto the bus so all four gain a Settings toggle and a Debug-menu entry for free.

**Files:**
- Modify: `Islet/Activities/Battery/BatteryActivity.swift:42-67` (`sneak(for:)`), `:36-39` (the emit loop)
- Modify: `Islet/Activities/AudioDevice/AudioDeviceMonitor.swift:30-44`
- Modify: `Islet/Activities/NowPlaying/NowPlayingActivity.swift` (`trackChangeSneak`)
- Modify: `Islet/Activities/Timer/TimerActivity.swift:107-113`

**Interfaces:**
- Consumes: `SystemEventBus.shared.emit(_:)`, `SystemEvent`, `EventAccent`, `MotionProfile`.
- Produces: `BatteryActivity.event(for:) -> SystemEvent` replacing `sneak(for:)`.

- [ ] **Step 1: Replace BatteryActivity.sneak(for:) with event(for:)**

No unit test for the emit wiring itself — `SneakQueue` and the monitors need a run loop. The mapping
below is covered by Task 5's tests through `Sneak(event:)`. Verified by build plus the Debug menu.

In `Islet/Activities/Battery/BatteryActivity.swift`, replace the whole of `static func sneak(for event: BatteryEvent) -> Sneak` (from `static func sneak(for event: BatteryEvent) -> Sneak {` through its closing `}`) with:

```swift
  static func event(for event: BatteryEvent) -> SystemEvent {
    switch event {
    case .acConnected(let percent):
      SystemEvent(
        sourceID: "battery", icon: "bolt.fill", title: "Charging",
        subtitle: "\(percent)%", accentHex: EventAccent.positive, motion: .generic,
        announcement: "Charger connected, \(percent) percent")
    case .acDisconnected(let percent):
      SystemEvent(
        sourceID: "battery", icon: "battery.100percent", title: "On battery",
        subtitle: "\(percent)%", accentHex: EventAccent.neutral, motion: .generic,
        announcement: "Charger disconnected, \(percent) percent")
    case .lowBattery(_, let percent):
      SystemEvent(
        sourceID: "battery", icon: "battery.25percent", title: "Low battery",
        subtitle: "\(percent)%", accentHex: EventAccent.danger, motion: .peripheralLow,
        urgency: .alert, duration: 3,
        announcement: "Low battery, \(percent) percent")
    case .chargeComplete(let percent):
      SystemEvent(
        sourceID: "battery", icon: "checkmark.circle.fill", title: "Charged",
        subtitle: "\(percent)%", accentHex: EventAccent.positive, motion: .chargeComplete,
        announcement: "Battery fully charged")
    }
  }
```

Then replace, in `handle(_:)`:

```swift
    guard Defaults[.batteryEnabled] else { return }
    for event in events {
      SneakQueue.shared.submit(Self.sneak(for: event))
    }
```

with:

```swift
    guard Defaults[.batteryEnabled] else { return }
    for event in events {
      SystemEventBus.shared.emit(Self.event(for: event))
    }
```

- [ ] **Step 2: Add the charge-complete battery event**

In `Islet/Activities/Battery/BatteryState.swift`, replace:

```swift
enum BatteryEvent: Equatable {
  case acConnected(percent: Int)
  case acDisconnected(percent: Int)
  case lowBattery(threshold: Int, percent: Int)
}
```

with:

```swift
enum BatteryEvent: Equatable {
  case acConnected(percent: Int)
  case acDisconnected(percent: Int)
  case lowBattery(threshold: Int, percent: Int)
  /// Reached 100% while on AC. Fires once per charge, on the upward crossing only, so a battery
  /// hovering at 100 and dropping to 99 and back does not re-announce.
  case chargeComplete(percent: Int)
}
```

Then in the same file, replace the body of `BatteryEventDetector.events(from:to:)` — from `guard let old else { return [] }` through the closing `return out` — with:

```swift
    guard let old else { return [] }  // first snapshot is baseline only
    var out: [BatteryEvent] = []
    if !old.onAC, new.onAC {
      out.append(.acConnected(percent: new.percent))
    } else if old.onAC, !new.onAC {
      out.append(.acDisconnected(percent: new.percent))
    }
    // Upward crossing of 100 while plugged in. Guarding on the crossing rather than on the level
    // means a battery sitting at 100 does not re-announce on every one of the monitor's 1 Hz ticks.
    if new.onAC, new.percent >= 100, old.percent < 100 {
      out.append(.chargeComplete(percent: new.percent))
    }
    if !new.onAC {
      for t in Self.thresholds where old.percent > t && new.percent <= t {
        out.append(.lowBattery(threshold: t, percent: new.percent))
      }
    }
    return out
```

- [ ] **Step 3: Add a charge-complete test**

Append to `IsletTests/BatteryEventDetectorTests.swift`, before the closing `}` of the class:

```swift
  func testChargeCompleteFiresOnceOnTheUpwardCrossing() {
    let at99 = BatteryState(percent: 99, isCharging: true, onAC: true)
    let at100 = BatteryState(percent: 100, isCharging: false, onAC: true)
    XCTAssertEqual(
      BatteryEventDetector.events(from: at99, to: at100), [.chargeComplete(percent: 100)])
    // Still at 100 on the next tick: nothing more to say.
    XCTAssertTrue(BatteryEventDetector.events(from: at100, to: at100).isEmpty)
  }

  func testChargeCompleteDoesNotFireOnBattery() {
    let a = BatteryState(percent: 99, isCharging: false, onAC: false)
    let b = BatteryState(percent: 100, isCharging: false, onAC: false)
    XCTAssertTrue(BatteryEventDetector.events(from: a, to: b).isEmpty)
  }
```

- [ ] **Step 4: Migrate the audio-device monitor**

In `Islet/Activities/AudioDevice/AudioDeviceMonitor.swift`, replace:

```swift
    let name = Self.deviceName(device) ?? "Audio device"
    let icon = Self.iconName(for: name)
    SneakQueue.shared.submit(
      Sneak(
        source: "audiodevice",
        leading: AnyViewBox.icon(icon),
        trailing: AnyViewBox.name(name),
        announcement: "\(name) connected"))
```

with:

```swift
    let name = Self.deviceName(device) ?? "Audio device"
    SystemEventBus.shared.emit(
      SystemEvent(
        sourceID: "audiodevice",
        icon: Self.iconName(for: name),
        title: name,
        subtitle: "Output",
        accentHex: EventAccent.info,
        motion: .bluetooth,
        announcement: "\(name) connected"))
```

- [ ] **Step 5: Migrate the timer**

In `Islet/Activities/Timer/TimerActivity.swift`, replace:

```swift
      Sneak(
        source: "timer", duration: 4,
        leading: AnyView(Image(systemName: "timer").foregroundStyle(.orange).font(.caption)),
        trailing: AnyView(
          Text("\(label ?? "Timer") done")
            .font(.caption2.weight(.semibold)).foregroundStyle(.white).lineLimit(1)),
        announcement: "\(label ?? "Timer") done"))
```

with:

```swift
      SystemEvent(
        sourceID: "timer", icon: "timer", title: "\(label ?? "Timer") done",
        accentHex: EventAccent.warning, motion: .chargeComplete, urgency: .alert, duration: 4,
        announcement: "\(label ?? "Timer") done"))
```

and change the enclosing `SneakQueue.shared.submit(` on the line above it to `SystemEventBus.shared.emit(`.

- [ ] **Step 6: Migrate the track-change sneak**

In `Islet/Activities/NowPlaying/NowPlayingActivity.swift`, replace the call site:

```swift
            SneakQueue.shared.submit(Self.trackChangeSneak(for: state))
```

with:

```swift
            SystemEventBus.shared.emit(Self.trackChangeEvent(for: state))
```

Then replace the whole of `static func trackChangeSneak(for state: PlaybackState) -> Sneak` (from its `static func` line through its closing `}`) with:

```swift
  /// Track changes go through the bus so they gain a Settings toggle, an entry in the generated
  /// Debug menu, and app attribution in the subtitle — none of which the hand-built sneak had.
  ///
  /// Artwork is deliberately dropped in favour of the source app's name. The sneak's leading slot is
  /// an SF Symbol for every other event, and a 16pt bitmap in that slot measures differently, which
  /// changes the island's width for track changes only.
  static func trackChangeEvent(for state: PlaybackState) -> SystemEvent {
    let app = ExpandedPlayerView.appName(for: state.sourceBundleIdentifier)
    let subtitle = [state.artist, app].filter { !$0.isEmpty }.joined(separator: " · ")
    return SystemEvent(
      sourceID: "nowPlaying",
      icon: "music.note",
      title: state.title,
      subtitle: subtitle.isEmpty ? nil : subtitle,
      accentHex: EventAccent.positive,
      motion: .generic,
      urgency: .ambient,
      announcement: "\(state.title), \(state.artist)")
  }
```

- [ ] **Step 7: Add the app-name resolver**

In `Islet/Activities/NowPlaying/NowPlayingViews.swift`, immediately after the existing `static func appIcon(for bundleID: String) -> NSImage?` and before `private func format(_ t: TimeInterval) -> String`, add:

```swift
  /// The source app's display name, for attribution in a track-change event. Empty when the bundle
  /// ID does not resolve — a browser-hosted player whose parent app is not installed, say.
  static func appName(for bundleID: String) -> String {
    guard !bundleID.isEmpty,
      let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    else { return "" }
    return FileManager.default.displayName(atPath: url.path)
  }
```

- [ ] **Step 8: Fix the Debug menu's now-broken references**

`IsletApp.swift:41-53` calls `BatteryActivity.sneak(for:)` and `NowPlayingActivity.trackChangeSneak(for:)`, both of which no longer exist. Task 12 replaces this whole menu with a generated one; for now, replace the three buttons

```swift
        Button("Sneak: charger") {
          SneakQueue.shared.submit(BatteryActivity.sneak(for: .acConnected(percent: 64)))
        }
        Button("Sneak: low battery") {
          SneakQueue.shared.submit(
            BatteryActivity.sneak(for: .lowBattery(threshold: 20, percent: 18)))
        }
        Button("Sneak: track change") {
          var fake = PlaybackState()
          fake.title = "Paranoid Android"
          fake.artist = "Radiohead"
          SneakQueue.shared.submit(NowPlayingActivity.trackChangeSneak(for: fake))
        }
```

with

```swift
        Button("Sneak: charger") {
          SystemEventBus.shared.emit(BatteryActivity.event(for: .acConnected(percent: 64)))
        }
        Button("Sneak: low battery") {
          SystemEventBus.shared.emit(
            BatteryActivity.event(for: .lowBattery(threshold: 20, percent: 18)))
        }
        Button("Sneak: track change") {
          var fake = PlaybackState()
          fake.title = "Paranoid Android"
          fake.artist = "Radiohead"
          SystemEventBus.shared.emit(NowPlayingActivity.trackChangeEvent(for: fake))
        }
```

- [ ] **Step 9: Run tests to verify they pass**

Run: `xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`

Expected: `** TEST SUCCEEDED **`, two more tests than Task 7.

- [ ] **Step 10: Manual check**

```bash
open "$(xcodebuild -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR/ {print $2; exit}')/Islet.app"
```

From the menu bar icon → Debug, fire "Sneak: charger", "Sneak: low battery" and "Sneak: track change". Each must appear in the island with its icon animating, its title and subtitle legible, and the island returning to hardware-notch width afterwards. Quit the app before continuing.

- [ ] **Step 11: Commit**

```bash
git add Islet/Activities Islet/App/IsletApp.swift IsletTests/BatteryEventDetectorTests.swift
git commit -m "Events: move the four existing sneak producers onto the bus"
```

---

### Task 9: Tier 1 sources — USB, volumes, displays

**Files:**
- Create: `Islet/Events/Sources/PortEventSource.swift`
- Create: `Islet/Events/Sources/VolumeEventSource.swift`
- Create: `Islet/Events/Sources/DisplayEventSource.swift`
- Modify: `Islet/Activities/Ports/Ports.swift:118` (`refresh`)

**Interfaces:**
- Consumes: `SetDiff.changes(from:to:)` (Task 2), `SystemEventBus.shared.emit(_:)`, `PortMonitor.shared`, `PortDevice`.
- Produces: `PortEventSource`, `VolumeEventSource`, `DisplayEventSource`.

USB attach/detach is already fully observed in `Ports.swift:80-112` and completely silent — the cheapest event in the repo. `PortMonitor.refresh` replaces its device list wholesale, so the source needs the previous value to diff against.

- [ ] **Step 1: Publish the previous device list from PortMonitor**

In `Islet/Activities/Ports/Ports.swift`, replace:

```swift
  func refresh() { devices = PortsReader.read() }
```

with:

```swift
  /// The list as it was before the most recent refresh, so an observer can diff the two. Kept here
  /// rather than in the observer because the IOKit callback can fire twice before an observer runs,
  /// and a diff against a stale snapshot reports a device twice.
  private(set) var previousDevices: [PortDevice] = []

  func refresh() {
    let next = PortsReader.read()
    guard next != devices else { return }  // IOKit re-arms fire spuriously; don't republish
    previousDevices = devices
    devices = next
  }
```

- [ ] **Step 2: Create Islet/Events/Sources/PortEventSource.swift**

No unit test for the observation — IOKit notifications need a run loop. The diff it depends on is
covered by `SetDiffTests.testIdentifiedOverloadComparesByIDNotByValue`.

```swift
import Combine
import Foundation

/// USB attach and detach.
///
/// `PortMonitor` has watched IOKit matching notifications since the Ports tab shipped and has never
/// said anything about them. This is the whole source: subscribe to the list it already publishes,
/// diff, emit.
@MainActor
final class PortEventSource: SystemEventSource {
  let id = "usb"
  let displayName = "USB devices"
  let tier = SystemEventTier.core

  private var cancellable: AnyCancellable?

  func start() {
    guard cancellable == nil else { return }
    PortMonitor.shared.start()
    cancellable = PortMonitor.shared.$devices
      // The first value is the list as it stands at launch. Announcing it would fire one event per
      // already-connected device every time Islet starts.
      .dropFirst()
      .sink { [weak self] devices in
        self?.report(devices)
      }
  }

  func stop() {
    cancellable = nil
  }

  private func report(_ devices: [PortDevice]) {
    let diff = SetDiff.changes(from: PortMonitor.shared.previousDevices, to: devices)
    for device in diff.added {
      SystemEventBus.shared.emit(
        SystemEvent(
          sourceID: id, icon: "cable.connector", title: device.name,
          subtitle: [device.vendor, device.speed].compactMap { $0 }.joined(separator: " · "),
          accentHex: EventAccent.info, motion: .usb,
          announcement: "\(device.name) connected"))
    }
    for device in diff.removed {
      SystemEventBus.shared.emit(
        SystemEvent(
          sourceID: id, icon: "cable.connector.slash", title: device.name,
          subtitle: "Disconnected", accentHex: EventAccent.neutral, motion: .usb,
          urgency: .ambient,
          announcement: "\(device.name) disconnected"))
    }
  }
}
```

- [ ] **Step 3: Create Islet/Events/Sources/VolumeEventSource.swift**

```swift
import AppKit
import Combine

/// Disks and volumes mounting and unmounting.
///
/// `NSWorkspace` posts both, with the volume URL in the userInfo — no polling, no permission.
@MainActor
final class VolumeEventSource: SystemEventSource {
  let id = "volume"
  let displayName = "Disks and volumes"
  let tier = SystemEventTier.core

  private var cancellables: Set<AnyCancellable> = []

  func start() {
    guard cancellables.isEmpty else { return }
    NSWorkspace.shared.notificationCenter
      .publisher(for: NSWorkspace.didMountNotification)
      .sink { [weak self] note in self?.report(note, mounted: true) }
      .store(in: &cancellables)
    NSWorkspace.shared.notificationCenter
      .publisher(for: NSWorkspace.didUnmountNotification)
      .sink { [weak self] note in self?.report(note, mounted: false) }
      .store(in: &cancellables)
  }

  func stop() { cancellables.removeAll() }

  private func report(_ note: Notification, mounted: Bool) {
    let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
    let name = url.map { FileManager.default.displayName(atPath: $0.path) } ?? "Volume"
    SystemEventBus.shared.emit(
      SystemEvent(
        sourceID: id,
        icon: mounted ? "externaldrive.fill.badge.plus" : "externaldrive.fill.badge.minus",
        title: name,
        subtitle: mounted ? "Mounted" : "Ejected",
        accentHex: mounted ? EventAccent.info : EventAccent.neutral,
        motion: .volumeMount,
        urgency: mounted ? .normal : .ambient,
        announcement: "\(name) \(mounted ? "mounted" : "ejected")"))
  }
}
```

- [ ] **Step 4: Create Islet/Events/Sources/DisplayEventSource.swift**

```swift
import AppKit
import Combine

/// External displays connecting and disconnecting.
///
/// `didChangeScreenParametersNotification` fires for resolution changes and menu-bar changes too, so
/// the notification alone means nothing — the screen set has to be diffed. Keyed by display UUID,
/// which survives reconfiguration where `NSScreen` identity does not (see `NSScreen.displayUUID`).
@MainActor
final class DisplayEventSource: SystemEventSource {
  let id = "display"
  let displayName = "External displays"
  let tier = SystemEventTier.core

  private var cancellable: AnyCancellable?
  private var known: [String] = []

  func start() {
    guard cancellable == nil else { return }
    known = Self.currentUUIDs()  // baseline; the displays already attached are not news
    cancellable = NotificationCenter.default
      .publisher(for: NSApplication.didChangeScreenParametersNotification)
      .debounce(for: .milliseconds(600), scheduler: DispatchQueue.main)
      .sink { [weak self] _ in self?.report() }
  }

  func stop() {
    cancellable = nil
    known = []
  }

  private static func currentUUIDs() -> [String] {
    NSScreen.screens.compactMap(\.displayUUID)
  }

  private static func name(forUUID uuid: String) -> String {
    guard let screen = NSScreen.screens.first(where: { $0.displayUUID == uuid })
    else { return "Display" }
    return screen.localizedName
  }

  private func report() {
    let now = Self.currentUUIDs()
    let diff = SetDiff.changes(from: known, to: now)
    known = now
    for uuid in diff.added {
      let name = Self.name(forUUID: uuid)
      SystemEventBus.shared.emit(
        SystemEvent(
          sourceID: id, icon: "display", title: name, subtitle: "Connected",
          accentHex: EventAccent.info, motion: .display,
          announcement: "\(name) connected"))
    }
    for _ in diff.removed {
      // The screen is already gone, so its name is no longer resolvable — say so plainly rather
      // than caching names purely to produce a nicer string for the disconnect case.
      SystemEventBus.shared.emit(
        SystemEvent(
          sourceID: id, icon: "display.trianglebadge.exclamationmark", title: "Display disconnected",
          accentHex: EventAccent.neutral, motion: .display, urgency: .ambient,
          announcement: "Display disconnected"))
    }
  }
}
```

- [ ] **Step 5: Regenerate, build and test**

Run: `xcodegen generate && xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`

Expected: `** TEST SUCCEEDED **`, count unchanged from Task 8.

- [ ] **Step 6: Commit**

```bash
git add Islet/Events/Sources Islet/Activities/Ports/Ports.swift
git commit -m "Events: announce USB, volume and display connections"
```

---

### Task 10: Tier 1 sources — power, sleep and peripherals

**Files:**
- Create: `Islet/Events/Sources/PowerEventSource.swift`
- Create: `Islet/Events/Sources/PeripheralEventSource.swift`

**Interfaces:**
- Consumes: `ThresholdDetector` (Phase 1.6), `PeripheralBatteryReader.read()`, `SetDiff`.
- Produces: `PowerEventSource`, `PeripheralEventSource`.

Charge complete already emits through `BatteryActivity` (Task 8). This task adds Low Power Mode,
sleep/wake, and the peripheral batteries that `PeripheralBatteryReader` has been reading every tick
and never announcing.

- [ ] **Step 1: Create Islet/Events/Sources/PowerEventSource.swift**

```swift
import AppKit
import Combine
import Foundation

/// Low Power Mode, and sleep/wake.
///
/// Both are public and notification-driven. `ProcessInfo.isLowPowerModeEnabled` plus
/// `.NSProcessInfoPowerStateDidChange` is the documented pair — never shell out to `pmset`.
@MainActor
final class PowerEventSource: SystemEventSource {
  let id = "power"
  let displayName = "Charging and Low Power Mode"
  let tier = SystemEventTier.core

  private var cancellables: Set<AnyCancellable> = []
  private var lastLowPower: Bool?

  func start() {
    guard cancellables.isEmpty else { return }
    lastLowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    NotificationCenter.default
      .publisher(for: .NSProcessInfoPowerStateDidChange)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in self?.reportLowPower() }
      .store(in: &cancellables)
  }

  func stop() {
    cancellables.removeAll()
    lastLowPower = nil
  }

  private func reportLowPower() {
    let on = ProcessInfo.processInfo.isLowPowerModeEnabled
    guard on != lastLowPower else { return }
    lastLowPower = on
    SystemEventBus.shared.emit(
      SystemEvent(
        sourceID: id,
        icon: on ? "battery.25percent" : "battery.100percent",
        title: on ? "Low Power Mode on" : "Low Power Mode off",
        accentHex: on ? EventAccent.warning : EventAccent.neutral,
        motion: .lowPower,
        urgency: .ambient,
        announcement: on ? "Low Power Mode on" : "Low Power Mode off"))
  }
}

/// Sleep and wake. Separate source so it gets its own toggle — it is the one people switch off
/// first, because a wake sneak competes with the login window.
@MainActor
final class SleepEventSource: SystemEventSource {
  let id = "sleep"
  let displayName = "Sleep and wake"
  let tier = SystemEventTier.core

  private var cancellables: Set<AnyCancellable> = []

  func start() {
    guard cancellables.isEmpty else { return }
    NSWorkspace.shared.notificationCenter
      .publisher(for: NSWorkspace.didWakeNotification)
      .sink { [weak self] _ in self?.report(waking: true) }
      .store(in: &cancellables)
    NSWorkspace.shared.notificationCenter
      .publisher(for: NSWorkspace.willSleepNotification)
      .sink { [weak self] _ in self?.report(waking: false) }
      .store(in: &cancellables)
  }

  func stop() { cancellables.removeAll() }

  private func report(waking: Bool) {
    SystemEventBus.shared.emit(
      SystemEvent(
        sourceID: id,
        icon: waking ? "sun.max.fill" : "moon.fill",
        title: waking ? "Awake" : "Going to sleep",
        accentHex: waking ? EventAccent.warning : EventAccent.neutral,
        motion: .sleepWake,
        urgency: .ambient,
        announcement: waking ? "Awake" : "Going to sleep"))
  }
}
```

- [ ] **Step 2: Create Islet/Events/Sources/PeripheralEventSource.swift**

```swift
import Combine
import Foundation

/// Magic Mouse / Keyboard / Trackpad batteries crossing a low threshold.
///
/// `PeripheralBatteryReader` has been read on every `BatteryMonitor` tick since Bluetooth peripheral
/// batteries shipped, and the result has only ever been rendered in the expanded view — a level you
/// have to go looking for. This announces the crossing.
///
/// Crossings only, via `ThresholdDetector`: a mouse sitting at 9% must not announce once a second.
@MainActor
final class PeripheralEventSource: SystemEventSource {
  let id = "peripheral"
  let displayName = "Peripheral batteries"
  let tier = SystemEventTier.core

  private let detector = ThresholdDetector(thresholds: [20, 10], direction: .falling)
  private var lastLevels: [String: Double] = [:]
  private var timer: AnyCancellable?

  func start() {
    guard timer == nil else { return }
    // Seed without announcing: a peripheral already below the threshold at launch is not news.
    for p in PeripheralBatteryReader.read() { lastLevels[p.id] = Double(p.percent) }
    // These change over hours. A five-minute poll is generous and costs one IORegistry walk.
    timer = Timer.publish(every: 300, on: .main, in: .common).autoconnect()
      .sink { [weak self] _ in self?.check() }
  }

  func stop() {
    timer = nil
    lastLevels = [:]
  }

  private func check() {
    for p in PeripheralBatteryReader.read() {
      let level = Double(p.percent)
      let crossings = detector.crossings(from: lastLevels[p.id], to: level)
      lastLevels[p.id] = level
      guard let lowest = crossings.min() else { continue }
      SystemEventBus.shared.emit(
        SystemEvent(
          sourceID: id, icon: p.icon, title: "\(p.name) battery low",
          subtitle: "\(p.percent)%",
          accentHex: lowest <= 10 ? EventAccent.danger : EventAccent.warning,
          motion: .peripheralLow,
          urgency: .alert, duration: 3,
          announcement: "\(p.name) battery at \(p.percent) percent"))
    }
  }
}
```

- [ ] **Step 3: Regenerate, build and test**

Run: `xcodegen generate && xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`

Expected: `** TEST SUCCEEDED **`, count unchanged.

- [ ] **Step 4: Commit**

```bash
git add Islet/Events/Sources
git commit -m "Events: announce Low Power Mode, sleep/wake and low peripheral batteries"
```

---

### Task 11: Tier 2 sources — Wi-Fi, Bluetooth, session, screenshots

**Files:**
- Create: `Islet/Events/Sources/WiFiEventSource.swift`
- Create: `Islet/Events/Sources/BluetoothEventSource.swift`
- Create: `Islet/Events/Sources/SessionEventSource.swift`
- Create: `Islet/Events/Sources/ScreenshotEventSource.swift`
- Modify: `project.yml` (the `info.properties` block)

**Interfaces:**
- Consumes: `SetDiff`, `SystemEventBus.shared.emit(_:)`.
- Produces: `WiFiEventSource`, `BluetoothEventSource`, `SessionEventSource`, `ScreenshotEventSource`.

- [ ] **Step 1: Add the Location usage string**

Reading a Wi-Fi network's **name** requires Location authorisation on macOS 14+. Connect and
disconnect without the name are free. In `project.yml`, inside the `Islet` target's
`info.properties` block, add after the `NSRemindersFullAccessUsageDescription` line:

```yaml
        NSLocationWhenInUseUsageDescription: "Islet shows the name of the Wi-Fi network you join. macOS requires location access to read network names; deny this and Islet will simply say 'Wi-Fi connected'."
```

- [ ] **Step 2: Create Islet/Events/Sources/WiFiEventSource.swift**

```swift
import CoreLocation
import CoreWLAN
import Foundation

/// Wi-Fi join, leave and network change.
///
/// `CWEventDelegate` callbacks arrive on a CoreWLAN-owned thread, so every one of them hops to the
/// main actor before touching the bus.
///
/// **The name costs a permission.** On macOS 14+ `CWInterface.ssid` returns nil without Location
/// authorisation. Connect and disconnect are free; only the *name* is gated. Islet asks once, and
/// degrades to a nameless "Wi-Fi connected" when refused — the event still fires.
@MainActor
final class WiFiEventSource: NSObject, SystemEventSource, CWEventDelegate {
  let id = "wifi"
  let displayName = "Wi-Fi"
  let tier = SystemEventTier.extended

  private let client = CWWiFiClient.shared()
  private let location = CLLocationManager()
  private var running = false
  private var lastSSID: String?

  func start() {
    guard !running else { return }
    running = true
    client.delegate = self
    // Ask once. Never blocks: a refusal simply means `ssid` keeps returning nil.
    if location.authorizationStatus == .notDetermined {
      location.requestWhenInUseAuthorization()
    }
    lastSSID = client.interface()?.ssid()
    try? client.startMonitoringEvent(.ssidDidChange)
    try? client.startMonitoringEvent(.linkDidChange)
    try? client.startMonitoringEvent(.powerDidChange)
  }

  func stop() {
    guard running else { return }
    running = false
    try? client.stopMonitoringAllEvents()
    client.delegate = nil
    lastSSID = nil
  }

  // MARK: - CWEventDelegate (called off the main thread)

  nonisolated func ssidDidChangeForWiFiInterface(withName interfaceName: String) {
    Task { @MainActor [weak self] in self?.linkChanged() }
  }

  nonisolated func linkDidChangeForWiFiInterface(withName interfaceName: String) {
    Task { @MainActor [weak self] in self?.linkChanged() }
  }

  nonisolated func powerStateDidChangeForWiFiInterface(withName interfaceName: String) {
    Task { @MainActor [weak self] in self?.powerChanged() }
  }

  // MARK: - Reporting

  private func linkChanged() {
    let ssid = client.interface()?.ssid()
    guard ssid != lastSSID else { return }
    let previous = lastSSID
    lastSSID = ssid

    if let ssid {
      SystemEventBus.shared.emit(
        SystemEvent(
          sourceID: id, icon: "wifi", title: "Wi-Fi connected", subtitle: ssid,
          accentHex: EventAccent.positive, motion: .wifi,
          announcement: "Connected to \(ssid)"))
    } else if previous != nil || client.interface()?.powerOn() == true {
      // Name unavailable — either genuinely disconnected, or connected with Location refused.
      // `powerOn` tells the two apart.
      let connected = client.interface()?.powerOn() == true && client.interface()?.bssid() != nil
      SystemEventBus.shared.emit(
        SystemEvent(
          sourceID: id,
          icon: connected ? "wifi" : "wifi.slash",
          title: connected ? "Wi-Fi connected" : "Wi-Fi disconnected",
          accentHex: connected ? EventAccent.positive : EventAccent.neutral,
          motion: .wifi,
          urgency: .ambient,
          announcement: connected ? "Wi-Fi connected" : "Wi-Fi disconnected"))
    }
  }

  private func powerChanged() {
    let on = client.interface()?.powerOn() ?? false
    if !on { lastSSID = nil }
    SystemEventBus.shared.emit(
      SystemEvent(
        sourceID: id,
        icon: on ? "wifi" : "wifi.slash",
        title: on ? "Wi-Fi on" : "Wi-Fi off",
        accentHex: on ? EventAccent.info : EventAccent.neutral,
        motion: .wifi,
        urgency: .ambient,
        announcement: on ? "Wi-Fi on" : "Wi-Fi off"))
  }
}
```

- [ ] **Step 3: Create Islet/Events/Sources/BluetoothEventSource.swift**

```swift
import Combine
import Foundation
import IOBluetooth

/// Bluetooth devices connecting and disconnecting.
///
/// `IOBluetoothDevice.register(forConnectNotifications:selector:)` needs an Objective-C selector
/// target, so this class is `NSObject` with `@objc` handlers. No permission prompt — unlike
/// CoreBluetooth, which is for BLE peripherals and does prompt.
///
/// Disconnect has no global notification: it is registered per device, at the moment that device
/// connects. Devices already paired and connected when the source starts are therefore not watched
/// for disconnect until they next connect — an accepted limitation, noted here so it is not
/// rediscovered as a bug.
@MainActor
final class BluetoothEventSource: NSObject, SystemEventSource {
  let id = "bluetooth"
  let displayName = "Bluetooth devices"
  let tier = SystemEventTier.extended

  private var connectNotification: IOBluetoothUserNotification?
  private var disconnectNotifications: [IOBluetoothUserNotification] = []

  func start() {
    guard connectNotification == nil else { return }
    connectNotification = IOBluetoothDevice.register(
      forConnectNotifications: self, selector: #selector(deviceConnected(_:device:)))
  }

  func stop() {
    connectNotification?.unregister()
    connectNotification = nil
    disconnectNotifications.forEach { $0.unregister() }
    disconnectNotifications.removeAll()
  }

  @objc private func deviceConnected(
    _ notification: IOBluetoothUserNotification, device: IOBluetoothDevice
  ) {
    let name = device.name ?? device.addressString ?? "Bluetooth device"
    SystemEventBus.shared.emit(
      SystemEvent(
        sourceID: id, icon: "dot.radiowaves.right", title: name, subtitle: "Connected",
        accentHex: EventAccent.info, motion: .bluetooth,
        announcement: "\(name) connected"))
    // Disconnect is per-device and can only be registered once the device is in hand.
    if let n = device.register(
      forDisconnectNotification: self, selector: #selector(deviceDisconnected(_:device:)))
    {
      disconnectNotifications.append(n)
    }
  }

  @objc private func deviceDisconnected(
    _ notification: IOBluetoothUserNotification, device: IOBluetoothDevice
  ) {
    let name = device.name ?? device.addressString ?? "Bluetooth device"
    notification.unregister()
    disconnectNotifications.removeAll { $0 === notification }
    SystemEventBus.shared.emit(
      SystemEvent(
        sourceID: id, icon: "dot.radiowaves.right", title: name, subtitle: "Disconnected",
        accentHex: EventAccent.neutral, motion: .bluetooth, urgency: .ambient,
        announcement: "\(name) disconnected"))
  }
}
```

- [ ] **Step 4: Create Islet/Events/Sources/SessionEventSource.swift**

```swift
import AppKit
import Combine

/// Screen lock, screen unlock and Caps Lock.
///
/// Lock and unlock arrive on `DistributedNotificationCenter` under undocumented-but-stable names
/// that every screen-lock utility on macOS has used for a decade. Caps Lock comes off a global
/// `.flagsChanged` monitor — the same mechanism `EventMonitors` already uses, and unlike the HUD's
/// event tap it needs no Accessibility grant, because it only observes.
@MainActor
final class SessionEventSource: SystemEventSource {
  let id = "session"
  let displayName = "Screen lock and Caps Lock"
  let tier = SystemEventTier.extended

  private var cancellables: Set<AnyCancellable> = []
  private var flagsMonitor: Any?
  private var lastCapsLock = false

  func start() {
    guard cancellables.isEmpty, flagsMonitor == nil else { return }
    let dnc = DistributedNotificationCenter.default()
    dnc.publisher(for: Notification.Name("com.apple.screenIsLocked"))
      .sink { [weak self] _ in self?.reportLock(locked: true) }
      .store(in: &cancellables)
    dnc.publisher(for: Notification.Name("com.apple.screenIsUnlocked"))
      .sink { [weak self] _ in self?.reportLock(locked: false) }
      .store(in: &cancellables)

    lastCapsLock = NSEvent.modifierFlags.contains(.capsLock)
    flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
      MainActor.assumeIsolated { self?.reportCapsLock(event.modifierFlags.contains(.capsLock)) }
    }
  }

  func stop() {
    cancellables.removeAll()
    if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
    flagsMonitor = nil
  }

  private func reportLock(locked: Bool) {
    SystemEventBus.shared.emit(
      SystemEvent(
        sourceID: id,
        icon: locked ? "lock.fill" : "lock.open.fill",
        title: locked ? "Locked" : "Unlocked",
        accentHex: locked ? EventAccent.neutral : EventAccent.positive,
        motion: .lock,
        urgency: .ambient,
        announcement: locked ? "Screen locked" : "Screen unlocked"))
  }

  private func reportCapsLock(_ on: Bool) {
    guard on != lastCapsLock else { return }
    lastCapsLock = on
    SystemEventBus.shared.emit(
      SystemEvent(
        sourceID: id,
        icon: on ? "capslock.fill" : "capslock",
        title: on ? "Caps Lock on" : "Caps Lock off",
        accentHex: on ? EventAccent.warning : EventAccent.neutral,
        motion: .lock,
        urgency: .ambient,
        duration: 1.2,
        announcement: on ? "Caps Lock on" : "Caps Lock off"))
  }
}
```

- [ ] **Step 5: Create Islet/Events/Sources/ScreenshotEventSource.swift**

```swift
import Foundation

/// Screenshots.
///
/// A Spotlight query on `kMDItemIsScreenCapture` — a real, indexed attribute — rather than watching
/// the screenshot folder, which the user can relocate and which would also catch every unrelated
/// file that lands there.
///
/// `NSMetadataQuery` delivers its first batch as "everything that already matches", which for this
/// predicate is every screenshot ever taken. That gather phase is discarded; only live updates after
/// it emit.
@MainActor
final class ScreenshotEventSource: SystemEventSource {
  let id = "screenshot"
  let displayName = "Screenshots"
  let tier = SystemEventTier.extended

  private var query: NSMetadataQuery?
  private var observers: [NSObjectProtocol] = []
  private var gathered = false

  func start() {
    guard query == nil else { return }
    let q = NSMetadataQuery()
    q.predicate = NSPredicate(format: "kMDItemIsScreenCapture == 1")
    q.searchScopes = [NSMetadataQueryUserHomeScope]
    q.sortDescriptors = [NSSortDescriptor(key: kMDItemContentCreationDate as String, ascending: false)]

    let center = NotificationCenter.default
    observers.append(
      center.addObserver(
        forName: .NSMetadataQueryDidFinishGathering, object: q, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.gathered = true }
      })
    observers.append(
      center.addObserver(
        forName: .NSMetadataQueryDidUpdate, object: q, queue: .main
      ) { [weak self] note in
        MainActor.assumeIsolated { self?.handleUpdate(note) }
      })

    query = q
    q.start()
  }

  func stop() {
    query?.stop()
    query = nil
    observers.forEach { NotificationCenter.default.removeObserver($0) }
    observers.removeAll()
    gathered = false
  }

  private func handleUpdate(_ note: Notification) {
    // Everything before the gather completes is history, not news.
    guard gathered else { return }
    let added = note.userInfo?[kMDQueryUpdateAddedItems as String] as? [NSMetadataItem] ?? []
    guard let item = added.first else { return }
    let name = item.value(forAttribute: kMDItemDisplayName as String) as? String ?? "Screenshot"
    SystemEventBus.shared.emit(
      SystemEvent(
        sourceID: id, icon: "camera.viewfinder",
        title: added.count > 1 ? "\(added.count) screenshots" : "Screenshot",
        subtitle: added.count > 1 ? nil : name,
        accentHex: EventAccent.info, motion: .screenshot,
        urgency: .ambient, duration: 1.5,
        announcement: "Screenshot taken"))
  }
}
```

- [ ] **Step 6: Regenerate, build and test**

Run: `xcodegen generate && xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`

Expected: `** TEST SUCCEEDED **`, count unchanged.

If `IOBluetoothDevice.register(forConnectNotifications:selector:)` will not type-check under Swift 6
strict concurrency, wrap the `@objc` handlers' bodies in `MainActor.assumeIsolated { }` and mark the
handlers `nonisolated` — IOBluetooth delivers on the main run loop but is not annotated for it.

- [ ] **Step 7: Commit**

```bash
git add Islet/Events/Sources project.yml
git commit -m "Events: announce Wi-Fi, Bluetooth, screen lock and screenshots"
```

---

### Task 12: Tier 3 sources — AirDrop, Focus, VPN

Everything here is inferred. The plan's "Honest limits" table above is the contract; the Settings
section built in Task 13 repeats it to the user.

**Files:**
- Create: `Islet/Events/Sources/AirDropEventSource.swift`
- Create: `Islet/Events/Sources/FocusEventSource.swift`
- Create: `Islet/Events/Sources/VPNEventSource.swift`
- Test: `IsletTests/SetDiffTests.swift` (append the utun classifier tests)

**Interfaces:**
- Consumes: `SetDiff.changes(from:to:)`, `ShelfModel` (for the outbound AirDrop hook).
- Produces: `AirDropOutEventSource`, `AirDropInEventSource`, `FocusEventSource`, `VPNEventSource`, `TunnelInterfaces.current()`.

- [ ] **Step 1: Write the failing tests for the utun classifier**

Append to `IsletTests/SetDiffTests.swift`, before the closing `}` of the class:

```swift
  // MARK: - Tunnel interfaces

  /// utun is the only tunnel family worth watching, and it must not match unrelated interfaces.
  func testTunnelClassifierMatchesOnlyUtun() {
    XCTAssertTrue(TunnelInterfaces.isTunnel("utun0"))
    XCTAssertTrue(TunnelInterfaces.isTunnel("utun12"))
    XCTAssertTrue(TunnelInterfaces.isTunnel("ipsec0"))
    XCTAssertFalse(TunnelInterfaces.isTunnel("en0"))
    XCTAssertFalse(TunnelInterfaces.isTunnel("lo0"))
    XCTAssertFalse(TunnelInterfaces.isTunnel("awdl0"))
    XCTAssertFalse(TunnelInterfaces.isTunnel("bridge0"))
    XCTAssertFalse(TunnelInterfaces.isTunnel("utunnel"))  // prefix must be followed by digits
  }

  /// The whole VPN source is this diff. If it reports a change when nothing changed, the island
  /// announces a tunnel every time the network reconfigures.
  func testTunnelDiffIsStableWhenNothingChanges() {
    let d = SetDiff.changes(from: ["utun0", "utun1"], to: ["utun1", "utun0"])
    XCTAssertTrue(d.added.isEmpty)
    XCTAssertTrue(d.removed.isEmpty)
  }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`

Expected: `error: cannot find 'TunnelInterfaces' in scope`.

- [ ] **Step 3: Create Islet/Events/Sources/VPNEventSource.swift**

```swift
import Combine
import Foundation

/// Which tunnel interfaces exist right now.
///
/// Split from the source so the classifier is a pure, tested function — it is the only part that can
/// be wrong in a way tests can catch.
enum TunnelInterfaces {
  /// `utun` and `ipsec` are the tunnel families. The digit check matters: `utunnel` is not a tunnel,
  /// and a bare prefix match would classify it as one.
  static func isTunnel(_ name: String) -> Bool {
    for prefix in ["utun", "ipsec"] where name.hasPrefix(prefix) {
      let rest = name.dropFirst(prefix.count)
      return !rest.isEmpty && rest.allSatisfy(\.isNumber)
    }
    return false
  }

  /// Live interface names from `getifaddrs`. Public API, no permission.
  static func current() -> [String] {
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0, let head else { return [] }
    defer { freeifaddrs(head) }

    var names: Set<String> = []
    var cursor: UnsafeMutablePointer<ifaddrs>? = head
    while let entry = cursor {
      let name = String(cString: entry.pointee.ifa_name)
      if isTunnel(name) { names.insert(name) }
      cursor = entry.pointee.ifa_next
    }
    return names.sorted()
  }
}

/// Network tunnels coming up and going down.
///
/// **Heuristic, and the event text says so.** A `utun` interface is not proof of a VPN: iCloud
/// Private Relay, Handoff, AirPlay and Continuity all create them. The event reads "Network tunnel
/// up", never "VPN connected", because Islet genuinely cannot tell the difference.
///
/// There is no notification for interface changes that does not involve SystemConfiguration
/// dynamic-store plumbing, so this polls. `getifaddrs` measured at 0.024 ms; at 5s that is free.
@MainActor
final class VPNEventSource: SystemEventSource {
  let id = "vpn"
  let displayName = "Network tunnel"
  let tier = SystemEventTier.heuristic

  private var timer: AnyCancellable?
  private var known: [String] = []

  func start() {
    guard timer == nil else { return }
    known = TunnelInterfaces.current()  // baseline: a tunnel already up is not news
    timer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()
      .sink { [weak self] _ in self?.check() }
  }

  func stop() {
    timer = nil
    known = []
  }

  private func check() {
    let now = TunnelInterfaces.current()
    let diff = SetDiff.changes(from: known, to: now)
    known = now
    guard !diff.added.isEmpty || !diff.removed.isEmpty else { return }
    let up = !diff.added.isEmpty
    SystemEventBus.shared.emit(
      SystemEvent(
        sourceID: id,
        icon: up ? "lock.shield.fill" : "lock.shield",
        title: up ? "Network tunnel up" : "Network tunnel down",
        subtitle: (up ? diff.added : diff.removed).first,
        accentHex: up ? EventAccent.info : EventAccent.neutral,
        motion: .vpn,
        urgency: .ambient,
        announcement: up ? "Network tunnel up" : "Network tunnel down"))
  }
}
```

- [ ] **Step 4: Create Islet/Events/Sources/FocusEventSource.swift**

```swift
import Combine
import Foundation

/// Focus / Do Not Disturb.
///
/// **Heuristic.** There is no public API to read the current Focus. The App Intents route
/// (`SetFocusFilterIntent`) would need a whole new extension target in `project.yml`, so this reads
/// `~/Library/DoNotDisturb/DB/Assertions.json` — the file the system writes when a Focus is
/// asserted. That format is undocumented and has changed between macOS releases, so every read is
/// defensive: an unrecognised shape emits nothing rather than guessing.
@MainActor
final class FocusEventSource: SystemEventSource {
  let id = "focus"
  let displayName = "Focus mode"
  let tier = SystemEventTier.heuristic

  private var source: DispatchSourceFileSystemObject?
  private var descriptor: CInt = -1
  private var lastActive: String?

  private var assertionsURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/DoNotDisturb/DB/Assertions.json")
  }

  func start() {
    guard source == nil else { return }
    lastActive = Self.activeFocus(at: assertionsURL)
    watch()
  }

  func stop() {
    source?.cancel()
    source = nil
    if descriptor >= 0 { close(descriptor) }
    descriptor = -1
    lastActive = nil
  }

  private func watch() {
    let fd = open(assertionsURL.path, O_EVTONLY)
    guard fd >= 0 else {
      // The file only exists once a Focus has been used at least once. Nothing to watch yet —
      // fail quiet rather than retrying on a timer.
      Log.app.notice("Focus assertions file not present; Focus events unavailable")
      return
    }
    descriptor = fd
    let s = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: .main)
    s.setEventHandler { [weak self] in
      MainActor.assumeIsolated {
        guard let self else { return }
        // A rewrite replaces the file, which invalidates the descriptor — re-arm on the new inode.
        self.check()
        self.rearmIfReplaced(s)
      }
    }
    s.setCancelHandler { [weak self] in
      MainActor.assumeIsolated {
        guard let self, self.descriptor >= 0 else { return }
        close(self.descriptor)
        self.descriptor = -1
      }
    }
    source = s
    s.resume()
  }

  private func rearmIfReplaced(_ s: DispatchSourceFileSystemObject) {
    guard s.data.contains(.delete) || s.data.contains(.rename) else { return }
    source?.cancel()
    source = nil
    watch()
  }

  private func check() {
    let active = Self.activeFocus(at: assertionsURL)
    guard active != lastActive else { return }
    let previous = lastActive
    lastActive = active

    if let active {
      SystemEventBus.shared.emit(
        SystemEvent(
          sourceID: id, icon: "moon.circle.fill", title: "Focus on", subtitle: active,
          accentHex: EventAccent.info, motion: .focus, urgency: .ambient,
          announcement: "Focus on, \(active)"))
    } else if previous != nil {
      SystemEventBus.shared.emit(
        SystemEvent(
          sourceID: id, icon: "moon.circle", title: "Focus off",
          accentHex: EventAccent.neutral, motion: .focus, urgency: .ambient,
          announcement: "Focus off"))
    }
  }

  /// Returns the active Focus identifier, or nil when none is asserted or the file's shape is not
  /// what this version of macOS wrote last time anyone looked.
  static func activeFocus(at url: URL) -> String? {
    guard let data = try? Data(contentsOf: url),
      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let store = root["data"] as? [[String: Any]],
      let first = store.first,
      let records = first["storeAssertionRecords"] as? [[String: Any]],
      let record = records.first,
      let details = record["assertionDetails"] as? [String: Any],
      let identifier = details["assertionDetailsModeIdentifier"] as? String
    else { return nil }
    // The identifier is a reverse-DNS mode id; the trailing component is the closest thing to a
    // friendly name that is available without private frameworks.
    return identifier.split(separator: ".").last.map(String.init) ?? identifier
  }
}
```

- [ ] **Step 5: Create Islet/Events/Sources/AirDropEventSource.swift**

```swift
import AppKit
import Combine
import Foundation

/// AirDrop sends that Islet itself initiated.
///
/// **Real, but narrow.** `NSSharingService` reports its own completion reliably — but only for
/// shares Islet starts. Islet starts exactly one: the file shelf's AirDrop button. A Finder or
/// Safari AirDrop is invisible to this, and no public API changes that.
@MainActor
final class AirDropOutEventSource: SystemEventSource {
  let id = "airdropOut"
  let displayName = "AirDrop sent"
  let tier = SystemEventTier.heuristic

  private var running = false

  func start() { running = true }
  func stop() { running = false }

  /// Called by the shelf's AirDrop action once the share service reports completion.
  func report(fileCount: Int) {
    guard running else { return }
    SystemEventBus.shared.emit(
      SystemEvent(
        sourceID: id, icon: "square.and.arrow.up",
        title: fileCount == 1 ? "Sent by AirDrop" : "\(fileCount) files sent",
        accentHex: EventAccent.info, motion: .airdrop,
        announcement: "AirDrop send complete"))
  }
}

/// Files that appear to have arrived by AirDrop.
///
/// **The weakest source in Islet, and the UI says so.** There is no AirDrop receive API. This
/// watches `~/Downloads` and, when a file appears, checks whether `sharingd` is recorded as its
/// quarantine agent. That means:
///
/// - it fires **after** the transfer completes, never during, so there is no progress;
/// - it cannot name the sender, because the originating device is not recorded anywhere readable;
/// - it needs the Downloads folder TCC grant, and macOS prompts on first read.
///
/// When the grant is refused the source disables itself rather than retrying — a denied TCC read
/// returns the same error forever, and a retry loop would just burn CPU.
@MainActor
final class AirDropInEventSource: SystemEventSource {
  let id = "airdropIn"
  let displayName = "AirDrop received"
  let tier = SystemEventTier.heuristic

  private var source: DispatchSourceFileSystemObject?
  private var descriptor: CInt = -1
  private var known: Set<String> = []

  private var downloads: URL? {
    FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
  }

  func start() {
    guard source == nil, let downloads else { return }
    guard let initial = Self.contents(of: downloads) else {
      Log.app.notice("Downloads folder unreadable; AirDrop receive events unavailable")
      return
    }
    known = initial

    let fd = open(downloads.path, O_EVTONLY)
    guard fd >= 0 else { return }
    descriptor = fd
    let s = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: fd, eventMask: .write, queue: .main)
    s.setEventHandler { [weak self] in
      MainActor.assumeIsolated { self?.check() }
    }
    s.setCancelHandler { [weak self] in
      MainActor.assumeIsolated {
        guard let self, self.descriptor >= 0 else { return }
        close(self.descriptor)
        self.descriptor = -1
      }
    }
    source = s
    s.resume()
  }

  func stop() {
    source?.cancel()
    source = nil
    known = []
  }

  private func check() {
    guard let downloads, let now = Self.contents(of: downloads) else { return }
    let appeared = now.subtracting(known)
    known = now
    for name in appeared {
      let url = downloads.appendingPathComponent(name)
      guard Self.arrivedViaAirDrop(url) else { continue }
      SystemEventBus.shared.emit(
        SystemEvent(
          sourceID: id, icon: "square.and.arrow.down", title: "AirDrop received",
          subtitle: name, accentHex: EventAccent.info, motion: .airdrop,
          duration: 3,
          announcement: "Received \(name) by AirDrop"))
    }
  }

  private static func contents(of url: URL) -> Set<String>? {
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) else {
      return nil
    }
    return Set(names.filter { !$0.hasPrefix(".") })
  }

  /// `sharingd` is the daemon that writes AirDrop arrivals, and it records itself as the quarantine
  /// agent. Anything else in Downloads — a browser download, a file you moved there — has a
  /// different agent or none at all.
  private static func arrivedViaAirDrop(_ url: URL) -> Bool {
    guard
      let values = try? url.resourceValues(forKeys: [.quarantinePropertiesKey]),
      let quarantine = values.quarantineProperties,
      let agent = quarantine[kLSQuarantineAgentNameKey as String] as? String
    else { return false }
    return agent.localizedCaseInsensitiveContains("sharingd")
  }
}
```

- [ ] **Step 6: Regenerate, build and test**

Run: `xcodegen generate && xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`

Expected: `** TEST SUCCEEDED **`, two more tests.

`URLResourceValues.quarantineProperties` may need `url.resourceValues(forKeys:)` to be called on a
file URL that still exists; a file moved away between the directory read and the check returns nil,
which correctly yields `false`.

- [ ] **Step 7: Commit**

```bash
git add Islet/Events/Sources IsletTests/SetDiffTests.swift
git commit -m "Events: add the inferred AirDrop, Focus and tunnel sources"
```

---

### Task 13: Generated Settings section and Debug menu

The point of the catalogue is that neither of these is hand-maintained. Adding a source means adding one row to `SourceCatalog` and one file — Settings and Debug pick it up.

**Files:**
- Modify: `Islet/Settings/SettingsView.swift`
- Modify: `Islet/App/IsletApp.swift:34-60` (the Debug menu)

**Interfaces:**
- Consumes: `SourceCatalog`, `SystemEventBus.shared`, `SystemEventTier`.
- Produces: nothing consumed elsewhere.

- [ ] **Step 1: Add the generated Settings section**

No unit test — this is a SwiftUI `Form`. The enable/disable logic behind it is covered by Task 7's
bus tests. Verified by build plus the manual check in Step 3.

In `Islet/Settings/SettingsView.swift`, add to the `@Default` block at the top of the struct, after
`@Default(.portsEnabled) private var portsEnabled`:

```swift
  @Default(.disabledEventSources) private var disabledEventSources
```

Then add this section to the `Form`, immediately before the closing `}` of the `Form` body:

```swift
      Section("System events") {
        Text(
          "Islet shows a brief animation in the island when something happens. Turn a source off and Islet stops watching it entirely."
        )
        .font(.caption).foregroundStyle(.secondary)

        ForEach(SystemEventTier.allCases, id: \.rawValue) { tier in
          let ids = SourceCatalog.ids(in: tier)
          if !ids.isEmpty {
            Text(tier.label)
              .font(.caption.weight(.semibold))
              .foregroundStyle(tier == .heuristic ? .orange : .secondary)
            if tier == .heuristic {
              Text(
                "These are inferred rather than reported. AirDrop arrivals are noticed after the transfer finishes and cannot name the sender; a network tunnel may be iCloud Private Relay rather than a VPN."
              )
              .font(.caption2).foregroundStyle(.secondary)
            }
            ForEach(ids, id: \.self) { id in
              Toggle(isOn: eventSourceEnabled(id)) {
                Label(SourceCatalog.name(for: id), systemImage: SourceCatalog.icon(for: id))
              }
            }
          }
        }
      }
```

Then add this helper immediately after the existing `private func enabled(_ id: String) -> Binding<Bool>` method:

```swift
  /// Writes through the bus rather than straight to Defaults, so toggling a source actually starts
  /// or stops its observation instead of only silencing it.
  private func eventSourceEnabled(_ id: String) -> Binding<Bool> {
    Binding(
      get: { !disabledEventSources.contains(id) },
      set: { on in SystemEventBus.shared.setEnabled(on, for: id) })
  }
```

- [ ] **Step 2: Generate the Debug menu**

In `Islet/App/IsletApp.swift`, replace the whole `Menu("Debug") { ... }` block — from `Menu("Debug") {` through its closing `}` — with:

```swift
      Menu("Debug") {
        Button("Toggle demo activity") {
          AppState.demoActivity.isActive.toggle()
        }
        Button("Expand") {
          ScreenManager.shared.viewModel?.apply(.clickedNotch)
        }
        Divider()
        // Generated from the catalogue so every source is exercisable without the hardware —
        // you cannot unplug a display or receive an AirDrop on demand while testing motion.
        Menu("Fire event") {
          ForEach(SourceCatalog.all, id: \.id) { entry in
            Button(entry.name) {
              SystemEventBus.shared.emit(
                SystemEvent(
                  sourceID: entry.id,
                  icon: entry.icon,
                  title: entry.name,
                  subtitle: "Debug",
                  accentHex: EventAccent.info,
                  motion: SourceCatalog.debugMotion(for: entry.id)))
            }
          }
        }
        Button("Fire a docking burst") {
          for (i, name) in ["Studio Display", "Keyboard", "Hub", "Backup", "Mouse"].enumerated() {
            SystemEventBus.shared.emit(
              SystemEvent(
                sourceID: ["display", "usb", "usb", "volume", "usb"][i],
                icon: "cable.connector", title: name, accentHex: EventAccent.info, motion: .usb))
          }
        }
        Divider()
        Button("HUD: volume") {
          HUDController.shared.debugPresent(.init(kind: .volume, level: 0.6, isMuted: false))
        }
        Button("HUD: brightness") {
          HUDController.shared.debugPresent(.init(kind: .brightness, level: 0.35, isMuted: false))
        }
      }
```

- [ ] **Step 3: Add the debug motion lookup**

In `Islet/Events/SystemEventSource.swift`, add inside `enum SourceCatalog`, after `ids(in:)`:

```swift
  /// The motion a source's events normally use, so the Debug menu exercises the real choreography
  /// rather than showing every source with the generic settle.
  static func debugMotion(for id: String) -> MotionProfile {
    switch id {
    case "usb": .usb
    case "volume": .volumeMount
    case "display": .display
    case "power": .lowPower
    case "sleep": .sleepWake
    case "peripheral": .peripheralLow
    case "audiodevice", "bluetooth": .bluetooth
    case "battery": .chargeComplete
    case "wifi": .wifi
    case "session": .lock
    case "screenshot": .screenshot
    case "airdropOut", "airdropIn": .airdrop
    case "focus": .focus
    case "vpn": .vpn
    default: .generic
    }
  }
```

- [ ] **Step 4: Build and test**

Run: `xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`

Expected: `** TEST SUCCEEDED **`, count unchanged.

- [ ] **Step 5: Manual check**

```bash
open "$(xcodebuild -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR/ {print $2; exit}')/Islet.app"
```

1. Menu bar → Debug → **Fire event**, and walk every entry. Each must show its own distinct motion. **Watch for clipping:** no icon may be cut off at the island's left or right edge, or at its bottom. Anything clipped is an overshoot past 1.0 in `EventMotion.swift` and must be brought inward.
2. Menu bar → Debug → **Fire a docking burst.** Five events must collapse into ONE sneak reading "5 system events" with a subtitle naming three of them, not five separate sneaks over eleven seconds.
3. Settings → **System events**: three tier groups, with the heuristic caption above the last. Turn "USB devices" off, plug a device in, confirm nothing appears. Turn it back on, unplug, confirm it does.
4. System Settings → Accessibility → Display → **Reduce motion** on. Fire several events: each must appear instantly with no movement, and must still appear.

Quit the app before continuing.

- [ ] **Step 6: Commit**

```bash
git add Islet/Settings/SettingsView.swift Islet/App/IsletApp.swift Islet/Events/SystemEventSource.swift
git commit -m "Events: generate the Settings section and Debug menu from the source catalogue"
```

---

### Task 14: Register every source and verify the phase

**Files:**
- Modify: `Islet/App/IsletApp.swift` (the `AppState` enum)
- Modify: `Islet/App/AppDelegate.swift:8-45`

**Interfaces:**
- Consumes: every source from Tasks 9-12, `SystemEventBus.shared`.
- Produces: nothing.

- [ ] **Step 1: Add the sources to AppState**

In `Islet/App/IsletApp.swift`, replace:

```swift
@MainActor
enum AppState {
  static let demoActivity = DemoActivity()
  static let nowPlaying = NowPlayingActivity()
  static let battery = BatteryActivity()
  static let calendar = CalendarActivity()
  static let timer = TimerActivity()
  static let shelf = ShelfActivity()
  static let clipboard = ClipboardActivity()
  static let ports = PortsActivity()
}
```

with:

```swift
@MainActor
enum AppState {
  static let demoActivity = DemoActivity()
  static let nowPlaying = NowPlayingActivity()
  static let battery = BatteryActivity()
  static let calendar = CalendarActivity()
  static let timer = TimerActivity()
  static let shelf = ShelfActivity()
  static let clipboard = ClipboardActivity()
  static let ports = PortsActivity()

  /// Every system-event source, in catalogue order. Sources that only re-shape an existing
  /// producer's output — battery, timer, track change, audio device — are not listed: those emit
  /// from the activity that already owns the observation, and appear in Settings through
  /// `SourceCatalog` regardless.
  static let eventSources: [any SystemEventSource] = [
    PortEventSource(),
    VolumeEventSource(),
    DisplayEventSource(),
    PowerEventSource(),
    SleepEventSource(),
    PeripheralEventSource(),
    WiFiEventSource(),
    BluetoothEventSource(),
    SessionEventSource(),
    ScreenshotEventSource(),
    AirDropOutEventSource(),
    AirDropInEventSource(),
    FocusEventSource(),
    VPNEventSource(),
  ]
}
```

- [ ] **Step 2: Register and start them**

In `Islet/App/AppDelegate.swift`, replace:

```swift
      RemindersProvider.shared.start()
      AudioDeviceMonitor.shared.start()
```

with:

```swift
      RemindersProvider.shared.start()
      AudioDeviceMonitor.shared.start()
      AppState.eventSources.forEach { SystemEventBus.shared.register($0) }
      SystemEventBus.shared.startEnabled()
```

- [ ] **Step 3: Build and run the full suite**

Run: `xcodegen generate && xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`

Expected: `** TEST SUCCEEDED **`, 38 more tests than the Phase 3 baseline.

- [ ] **Step 4: Verify the phase invariants**

```bash
# Every scale factor is inward: starts below 1.0, rests at exactly 1.0.
grep -n "scaleEffect" Islet/Events/EventMotion.swift | grep -vE "1\.0|0\.[0-9]"

# Every animation is gated.
grep -n "withAnimation" Islet/Events/*.swift | grep -v "Motion.gated"

# No source bypasses the bus to reach the queue directly.
grep -rn "SneakQueue.shared.submit" Islet/ | grep -v "SystemEventBus.swift"

# Every catalogue entry that should have a source object has one.
grep -c "EventSource()" Islet/App/IsletApp.swift
```

Expected: the first three commands print **nothing**. The fourth prints `14`.

The third is the important one: after this phase, `SystemEventBus` is the only thing that calls
`SneakQueue.shared.submit`. A source that submits directly bypasses the enable check, the burst
coalescer and the motion mapping.

- [ ] **Step 5: Soak the running app**

```bash
open "$(xcodebuild -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR/ {print $2; exit}')/Islet.app"
log stream --predicate 'subsystem == "dev.cnucifora.Islet"' --level info
```

Over ten minutes of ordinary use: plug and unplug a USB device, join and leave a Wi-Fi network,
connect Bluetooth headphones, lock and unlock the screen, take a screenshot, mount and eject a disk.
Each must produce exactly one sneak with its own motion. Confirm the log contains no repeating
`Event source ... is not in SourceCatalog` and that the island always returns to hardware-notch width.

If the Location prompt appears on first Wi-Fi change, accept it once and confirm the SSID name then
appears in the subtitle; deny it on a second run and confirm the event still fires without a name.

- [ ] **Step 6: Commit**

```bash
git add Islet/App
git commit -m "Events: register and start every system event source at launch"
```
