# Phase 5 — Multi-source Media Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Islet's single `playback: PlaybackState?` with a keyed `sources: [SourceID: PlaybackState]` model, detect additional players through CoreAudio process objects, and render them as a tappable chip strip under the existing hero player.

**Architecture:** A new `SourceID` (bundle identifier + pid + resolved display identity) keys every media source. `MediaSourceTable` — a pure, actor-free struct — owns the insert/update/remove/idle-expiry state machine and the ordering, so all of it is unit-testable. The MediaRemote adapter feeds it (at most one entry, see the limitation below); a push-driven `AudioProcessMonitor` reading `kAudioHardwarePropertyProcessObjectList` supplies the rest as metadata-free chips.

**Tech Stack:** Swift 6, SwiftUI, AppKit, XcodeGen, XCTest, sindresorhus/Defaults

---

## READ THIS FIRST — the ceiling of this phase

**`sources` holds at most ONE adapter-derived entry.** The vendored MediaRemote adapter physically
collapses concurrent players: `Vendor/mediaremote-adapter-src/src/adapter/stream.m:189` keeps a single
`__block NSMutableDictionary *liveData`, and calls `resetAll()` the moment a notification arrives from
a different process (`:396-408` and `:437-449`):

```objc
if (liveData[kMRABundleIdentifier] != nil && process.bundleIdentifier != nil &&
    ![liveData[kMRABundleIdentifier] isEqual:process.bundleIdentifier]) {
    // This is a different process, reset all data.
    resetAll();
}
```

`nm -gU Vendor/MediaRemoteAdapter.framework/Versions/A/MediaRemoteAdapter` exports only the singular
symbol set — no `*Clients`, no `*ForClient`, no `SendCommandTo*`.

So this phase ships a model that *can* hold N sources, but only one of them will ever have a title, an
artist, artwork, a scrubber or transport controls. Every other source comes from CoreAudio and carries
nothing but "this app is producing audio right now". Lifting that ceiling requires forking the adapter;
that work is fully scoped in the design spec
`docs/superpowers/specs/2026-07-29-power-stats-events-media-design.md`, section
**"Upgrade path — fork the MediaRemote adapter for true per-source media"**. Do not attempt it here.
The model built in this plan is the strict prerequisite for it, and is deliberately shaped so the fork
drops in behind it without a model change.

Two further honest limitations, both to be stated in the code comments this plan writes:

- **CoreAudio flags any audio, not just music.** A video call, a game, a notification chime and a
  YouTube tab all read as "playing output". A denylist covers the known system offenders; a Zoom call
  will still show a chip.
- **Tapping a chip cannot truly promote a player.** `MRMediaRemoteSetNowPlayingPlayerIfPossible`
  resolves in-process (verified — it returns a non-nil function pointer), but it takes an `MRPlayerPath`
  object that only the entitled *reads* macOS 15.4 locked down can produce. Task 10 resolves the symbol
  so the fork can use it, logs whether it resolved, and falls back to activating the owning app — which
  is what a user tapping the chip means anyway.

---

## Global Constraints

- **Swift 6 strict concurrency.** App types are `@MainActor`. Every new pure logic type in this plan
  (`SourceID`, `AudioSourceResolver`, `SourceFilter`, `MediaSourceTable`, `SourceStrip`,
  `AudioProcessReducer`, `MediaWatcher.expand`) is deliberately actor-free so tests call it synchronously.
- **XcodeGen is mandatory.** `Islet.xcodeproj` is generated from `project.yml`, which globs by directory.
  Any step that creates a new `.swift` file, or a new file in `IsletTests/Fixtures/`, MUST be followed by
  `xcodegen generate` before building, or the build fails with "cannot find X in scope" (or the fixture is
  missing at runtime). `xcodegen generate` prints a warning about the
  `Vendor/MediaRemoteAdapter.framework` path; that is expected and harmless.
- **Test command:** `xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`
- **Build command:** `xcodebuild build -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`
- **Baseline:** 75 passing tests, ~3s of test time. Success output ends with `** TEST SUCCEEDED **`.
- **Commit after every green run.** Repo commit style is a scope prefix then a lowercase imperative
  summary, e.g. `Media: carry the source key through the adapter parser`.
- **Never add a `Co-Authored-By` trailer, and never mention Claude, Anthropic or AI in a commit message.**
- **Tests use XCTest**, not swift-testing: `import XCTest`, `final class FooTests: XCTestCase`. Tests that
  touch `@MainActor` types get `@MainActor` on the class (see `IsletTests/ActivityCenterTests.swift:7`).
- **Phase-specific invariant:** `NowPlayingActivity.playback` must keep working as a `PlaybackState?` shim
  for the whole phase. `CompactArtworkView` (`NowPlayingViews.swift:8`), `CompactBarsView` (`:24`, `:34`)
  and `ExpandedPlayerView` (`:50`) all read it, and none of them are being rewritten.
- **Soft dependency on Phase 1.3 (switcher overflow):** Phase 5 adds no new switcher chip, so it does not
  worsen the existing overflow. It needs nothing from 1.3 at the API level and can land in either order.
- **Optional dependency on Phase 3 (SystemEventBus):** the track-change sneak stays on `SneakQueue` in
  this phase and simply gains app attribution locally (Task 12). Routing it through the bus is written
  out in "Deferred follow-ups" at the end of this document and is not required for Phase 5 to ship.

---

## File Structure

**Created**

| File | Single responsibility |
|---|---|
| `Islet/Activities/NowPlaying/SourceID.swift` | The `SourceID` key and `AudioSourceResolver`, which collapses helper processes onto the app that owns them. |
| `Islet/Activities/NowPlaying/MediaSourceTable.swift` | Pure state machine for the set of known sources (insert/update/remove/idle-expiry/ordering) plus `SourceStrip` chip-strip reduction. |
| `Islet/Activities/NowPlaying/AudioProcessMonitor.swift` | Pure `AudioProcessReducer` plus the push-driven CoreAudio process-object monitor that feeds it. |
| `IsletTests/Fixtures/adapter-stream-two-sources.jsonl` | Adapter stream fixture containing two distinct players and two distinct pids for one bundle identifier. |
| `IsletTests/SourceIDTests.swift` | Covers `SourceID` construction and display-identity resolution. |
| `IsletTests/MediaSourceTableTests.swift` | Covers the sources state machine, per-source idle expiry and ordering. |
| `IsletTests/SourceStripTests.swift` | Covers merge, secondary selection and the cap-at-3-then-+N reduction. |
| `IsletTests/AudioProcessReducerTests.swift` | Covers the CoreAudio denylist, helper→parent collapsing and de-duplication. |
| `IsletTests/NowPlayingActivityTests.swift` | The `@MainActor` tests: the `playback` shim and the track-change sneak. |

**Modified**

| File | Change |
|---|---|
| `Islet/Activities/NowPlaying/PlaybackState.swift` | Gains `processIdentifier`, half of the source key. |
| `Islet/Activities/NowPlaying/SourceFilter.swift` | `shouldAccept -> Bool` becomes `rank -> Int?`, plus the shared denylist. |
| `Islet/Activities/NowPlaying/AdapterParser.swift` | `AdapterUpdate` carries the source key and gains `.sourceGone`; parses `processIdentifier`. |
| `Islet/Activities/NowPlaying/MediaWatcher.swift` | `lastState` becomes per-source; adds the pure `expand` sequencer. |
| `Islet/Activities/NowPlaying/NowPlayingActivity.swift` | Moves onto `MediaSourceTable`, keeps the `playback` shim, wires the audio monitor. |
| `Islet/Activities/NowPlaying/NowPlayingViews.swift` | Hero factored out; adds the source chip strip. |
| `Islet/Activities/NowPlaying/MediaRemoteCommands.swift` | Adds `promote(_:)` and the `MRMediaRemoteSetNowPlayingPlayerIfPossible` probe. |
| `Islet/Settings/SettingsView.swift` | Media section copy: the priority list is display order, not a filter. |
| `IsletTests/SourceFilterTests.swift` | Rewritten for `rank`. |
| `IsletTests/AdapterParserTests.swift` | Updated pattern matches plus two-source coverage. |
| `IsletTests/MediaWatcherTests.swift` | Adds `expand` coverage. |

---

## Task 1: `SourceID` and helper→parent display identity

**Files:**
- Create: `Islet/Activities/NowPlaying/SourceID.swift`
- Modify: `Islet/Activities/NowPlaying/PlaybackState.swift:3-12`
- Test: `IsletTests/SourceIDTests.swift`

**Interfaces:**
- Consumes: `PlaybackState` (`Islet/Activities/NowPlaying/PlaybackState.swift:3`)
- Produces:
  - `struct SourceID: Hashable, Sendable { let bundleIdentifier: String; let pid: Int32; let displayBundleIdentifier: String }`
  - `SourceID.init(bundleIdentifier: String, pid: Int32, displayBundleIdentifier: String)`
  - `SourceID.init(bundleIdentifier: String, pid: Int32, parentBundleIdentifier: String)`
  - `SourceID.init(state: PlaybackState)`
  - `enum AudioSourceResolver`
  - `static let AudioSourceResolver.helperParents: [String: String]`
  - `static func AudioSourceResolver.displayBundleID(bundleID: String, pid: Int32, runningAppBundleID: (Int32) -> String?) -> String`
  - `static func AudioSourceResolver.runningAppBundleID(_ pid: Int32) -> String?`
  - `PlaybackState.processIdentifier: Int32`

- [ ] **Step 1: Write the failing test**

Create `IsletTests/SourceIDTests.swift`:

```swift
import XCTest

@testable import Islet

final class SourceIDTests: XCTestCase {
  func testDisplayIdentityPrefersTheParentApp() {
    let id = SourceID(
      bundleIdentifier: "com.apple.WebKit.GPU", pid: 6712,
      parentBundleIdentifier: "com.apple.Safari")
    XCTAssertEqual(id.displayBundleIdentifier, "com.apple.Safari")
    XCTAssertEqual(id.bundleIdentifier, "com.apple.WebKit.GPU")
    XCTAssertEqual(id.pid, 6712)
  }

  func testDisplayIdentityFallsBackToTheBundleIdentifier() {
    let id = SourceID(
      bundleIdentifier: "com.spotify.client", pid: 9931, parentBundleIdentifier: "")
    XCTAssertEqual(id.displayBundleIdentifier, "com.spotify.client")
  }

  func testInitFromPlaybackStateUsesTheParentField() {
    var state = PlaybackState()
    state.bundleIdentifier = "com.apple.WebKit.GPU"
    state.parentBundleIdentifier = "com.apple.Safari"
    state.processIdentifier = 1172
    let id = SourceID(state: state)
    XCTAssertEqual(id.displayBundleIdentifier, "com.apple.Safari")
    XCTAssertEqual(id.pid, 1172)
  }

  func testSameBundleDifferentPidAreDistinctKeys() {
    // Three com.apple.WebKit.GPU processes coexist on a real machine; the pid is what tells
    // them apart.
    let a = SourceID(
      bundleIdentifier: "com.apple.WebKit.GPU", pid: 1172,
      parentBundleIdentifier: "com.apple.Safari")
    let b = SourceID(
      bundleIdentifier: "com.apple.WebKit.GPU", pid: 1469,
      parentBundleIdentifier: "com.apple.Safari")
    XCTAssertNotEqual(a, b)
    XCTAssertEqual(Set([a, b]).count, 2)
  }

  func testWebKitHelperCollapsesOntoSafari() {
    let display = AudioSourceResolver.displayBundleID(
      bundleID: "com.apple.WebKit.GPU", pid: 1172, runningAppBundleID: { _ in nil })
    XCTAssertEqual(display, "com.apple.Safari")
  }

  func testChromiumHelperSuffixCollapsesOntoTheParent() {
    let display = AudioSourceResolver.displayBundleID(
      bundleID: "com.google.Chrome.helper", pid: 11407, runningAppBundleID: { _ in nil })
    XCTAssertEqual(display, "com.google.Chrome")
  }

  func testNestedHelperSuffixCollapsesOntoTheParent() {
    let display = AudioSourceResolver.displayBundleID(
      bundleID: "com.anthropic.claudefordesktop.helper.Renderer", pid: 50412,
      runningAppBundleID: { _ in nil })
    XCTAssertEqual(display, "com.anthropic.claudefordesktop")
  }

  func testFallsBackToTheRunningApplicationLookup() {
    let display = AudioSourceResolver.displayBundleID(
      bundleID: "some.unknown.xpc", pid: 42,
      runningAppBundleID: { $0 == 42 ? "com.example.Host" : nil })
    XCTAssertEqual(display, "com.example.Host")
  }

  func testFallsBackToTheBundleIdentifierWhenNothingResolves() {
    let display = AudioSourceResolver.displayBundleID(
      bundleID: "com.spotify.client", pid: 9931, runningAppBundleID: { _ in nil })
    XCTAssertEqual(display, "com.spotify.client")
  }
}
```

- [ ] **Step 2: Regenerate the project so the new test file is in the target**

Run: `xcodegen generate`
Expected: `Loaded project ... Created project at ...`, plus a warning mentioning
`Vendor/MediaRemoteAdapter.framework` (expected, harmless).

- [ ] **Step 3: Run the test to verify it fails**

Run: `xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`
Expected: `** TEST FAILED **`, with compile errors `cannot find 'SourceID' in scope` and
`cannot find 'AudioSourceResolver' in scope`.

- [ ] **Step 4: Add `processIdentifier` to `PlaybackState`**

In `Islet/Activities/NowPlaying/PlaybackState.swift`, replace line 7:

```swift
  var bundleIdentifier = ""
```

with:

```swift
  var bundleIdentifier = ""
  /// The pid the adapter reported. Part of the source key: bundle identifier alone is not unique,
  /// because several com.apple.WebKit.GPU processes coexist, one per media-hosting web view.
  var processIdentifier: Int32 = 0
```

- [ ] **Step 5: Create `SourceID.swift`**

Create `Islet/Activities/NowPlaying/SourceID.swift`:

```swift
import AppKit
import Foundation

/// Identity of one media source.
///
/// The bundle identifier alone is not unique — three distinct `com.apple.WebKit.GPU` processes
/// coexist on a normal machine, one per media-hosting web view — so the pid is part of the key.
/// The display identity is what the user sees: the parent app, never the helper.
struct SourceID: Hashable, Sendable {
  /// The process actually holding the session.
  let bundleIdentifier: String
  let pid: Int32
  /// Display identity: parentApplicationBundleIdentifier when present, else bundleIdentifier.
  let displayBundleIdentifier: String

  /// Designated. Use when the display identity has already been resolved.
  init(bundleIdentifier: String, pid: Int32, displayBundleIdentifier: String) {
    self.bundleIdentifier = bundleIdentifier
    self.pid = pid
    self.displayBundleIdentifier = displayBundleIdentifier
  }

  /// Resolves display identity from the adapter's parent-app field: the parent when non-empty,
  /// otherwise the bundle identifier itself. Mirrors `PlaybackState.sourceBundleIdentifier`.
  init(bundleIdentifier: String, pid: Int32, parentBundleIdentifier: String) {
    self.init(
      bundleIdentifier: bundleIdentifier,
      pid: pid,
      displayBundleIdentifier: parentBundleIdentifier.isEmpty
        ? bundleIdentifier : parentBundleIdentifier)
  }

  init(state: PlaybackState) {
    self.init(
      bundleIdentifier: state.bundleIdentifier,
      pid: state.processIdentifier,
      parentBundleIdentifier: state.parentBundleIdentifier)
  }
}

/// Collapses helper processes onto the app that owns them.
///
/// CoreAudio reports raw process objects with no parent-app field, so Safari appears as one to
/// three `com.apple.WebKit.GPU` rows and Chromium apps as N `<parent>.helper` rows. Verified by
/// probe on this machine: pids 1172, 1469 and 17670 all reported `com.apple.WebKit.GPU`.
enum AudioSourceResolver {
  /// Helpers whose bundle identifier gives no hint of the parent app.
  static let helperParents: [String: String] = [
    "com.apple.WebKit.GPU": "com.apple.Safari",
    "com.apple.WebKit.WebContent": "com.apple.Safari",
  ]

  /// The app a process should be displayed as.
  ///
  /// `runningAppBundleID` maps a pid to the bundle identifier of the owning `NSRunningApplication`.
  /// Tests pass a stub; production passes `AudioSourceResolver.runningAppBundleID`.
  static func displayBundleID(
    bundleID: String, pid: Int32, runningAppBundleID: (Int32) -> String?
  ) -> String {
    if let mapped = helperParents[bundleID] { return mapped }
    // Chromium-family helpers are "<parent>.helper", "<parent>.helper.Renderer", and so on.
    if let range = bundleID.range(of: ".helper", options: [.caseInsensitive]) {
      let parent = String(bundleID[bundleID.startIndex..<range.lowerBound])
      if !parent.isEmpty { return parent }
    }
    if let app = runningAppBundleID(pid), !app.isEmpty { return app }
    return bundleID
  }

  /// Production pid → owning-application lookup. Returns nil for daemons and XPC services, which
  /// are not applications.
  static func runningAppBundleID(_ pid: Int32) -> String? {
    NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
  }
}
```

- [ ] **Step 6: Regenerate the project so the new source file is in the target**

Run: `xcodegen generate`
Expected: `Created project at ...`.

- [ ] **Step 7: Run tests to verify they pass**

Run: `xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`
Expected: `** TEST SUCCEEDED **`, 84 tests.

- [ ] **Step 8: Commit**

```bash
git add Islet/Activities/NowPlaying/SourceID.swift Islet/Activities/NowPlaying/PlaybackState.swift IsletTests/SourceIDTests.swift Islet.xcodeproj
git commit -m "Media: identify playback sources by bundle identifier and pid"
```

---

## Task 2: `SourceFilter.rank` replaces `shouldAccept`

**Files:**
- Modify: `Islet/Activities/NowPlaying/SourceFilter.swift:5-22`
- Test: `IsletTests/SourceFilterTests.swift` (rewritten in full)

**Interfaces:**
- Consumes: `enum MediaSourceMode: String, CaseIterable, Codable { case auto, prioritized }` (`SourceFilter.swift:3`, unchanged)
- Produces:
  - `static let SourceFilter.denylist: Set<String>`
  - `static func SourceFilter.isDenied(_ bundleID: String) -> Bool`
  - `static func SourceFilter.rank(bundleID: String, mode: MediaSourceMode, priorityList: [String]) -> Int?`
- Removes: `static func SourceFilter.shouldAccept(bundleID:currentBundleID:mode:priorityList:) -> Bool`

**Semantic change, stated plainly:** `.prioritized` no longer *drops* unlisted players. The old
behaviour (`SourceFilter.swift:15`, `guard let rank = priorityList.firstIndex(of: bundleID) else { return false }`)
made a second player invisible instead of secondary, which is exactly what this phase exists to fix.
`mediaPriorityList` is now display order. `nil` still means "hidden", but only for denylisted or
empty bundle identifiers. `IsletTests/SourceFilterTests.swift:13-43` locks in the old replacement
semantics and is therefore deleted, not adapted.

- [ ] **Step 1: Write the failing test — rewrite `IsletTests/SourceFilterTests.swift` in full**

Replace the entire contents of `IsletTests/SourceFilterTests.swift` with:

```swift
import XCTest

@testable import Islet

final class SourceFilterTests: XCTestCase {
  func testDenylistedBundlesAreHidden() {
    for bundleID in [
      "systemsoundserverd", "com.apple.PowerChime", "com.apple.controlcenter",
      "dev.cnucifora.Islet",
    ] {
      XCTAssertNil(
        SourceFilter.rank(bundleID: bundleID, mode: .auto, priorityList: []),
        "\(bundleID) should be hidden")
      XCTAssertTrue(SourceFilter.isDenied(bundleID))
    }
  }

  func testEmptyBundleIdentifierIsHidden() {
    XCTAssertNil(SourceFilter.rank(bundleID: "", mode: .auto, priorityList: []))
  }

  func testAutoRanksEveryVisibleSourceEqually() {
    // .auto ignores the list entirely, so ordering falls through to the table's tiebreakers.
    let spotify = SourceFilter.rank(
      bundleID: "com.spotify.client", mode: .auto,
      priorityList: ["com.apple.Music", "com.spotify.client"])
    let music = SourceFilter.rank(
      bundleID: "com.apple.Music", mode: .auto,
      priorityList: ["com.apple.Music", "com.spotify.client"])
    XCTAssertNotNil(spotify)
    XCTAssertEqual(spotify, music)
  }

  func testPrioritizedOrdersByListPosition() {
    let list = ["com.spotify.client", "com.apple.Music"]
    XCTAssertEqual(
      SourceFilter.rank(bundleID: "com.spotify.client", mode: .prioritized, priorityList: list), 0)
    XCTAssertEqual(
      SourceFilter.rank(bundleID: "com.apple.Music", mode: .prioritized, priorityList: list), 1)
  }

  func testPrioritizedKeepsUnlistedSourcesAfterListedOnes() {
    let list = ["com.spotify.client", "com.apple.Music"]
    let unlisted = SourceFilter.rank(
      bundleID: "com.apple.Safari", mode: .prioritized, priorityList: list)
    XCTAssertEqual(unlisted, 2)
    XCTAssertGreaterThan(
      try XCTUnwrap(unlisted),
      try XCTUnwrap(
        SourceFilter.rank(bundleID: "com.apple.Music", mode: .prioritized, priorityList: list)))
  }

  func testPrioritizedNoLongerDropsUnlistedSources() {
    // The retired behaviour: an unlisted bundle used to be dropped outright, which made a second
    // player invisible rather than secondary.
    XCTAssertNotNil(
      SourceFilter.rank(
        bundleID: "com.apple.Safari", mode: .prioritized,
        priorityList: ["com.spotify.client"]))
  }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`
Expected: `** TEST FAILED **`, with compile errors `type 'SourceFilter' has no member 'rank'` and
`type 'SourceFilter' has no member 'isDenied'`.

- [ ] **Step 3: Rewrite `SourceFilter`**

Replace the entire contents of `Islet/Activities/NowPlaying/SourceFilter.swift` with:

```swift
import Foundation

enum MediaSourceMode: String, CaseIterable, Codable { case auto, prioritized }

enum SourceFilter {
  /// Bundle identifiers that are never shown as a media source. All four were observed in the
  /// CoreAudio process list on this machine, along with Islet itself; none of them is a player a
  /// user would want to switch to.
  static let denylist: Set<String> = [
    "systemsoundserverd",
    "com.apple.PowerChime",
    "com.apple.controlcenter",
    "dev.cnucifora.Islet",
    // Also observed and equally useless as a "player":
    "com.apple.audio.Core-Audio-Driver-Service",
    "com.apple.mediaremoted",
  ]

  static func isDenied(_ bundleID: String) -> Bool { denylist.contains(bundleID) }

  /// Display rank for a source: lower sorts first, nil means "never show".
  ///
  /// `mediaPriorityList` is display order, not a filter — `.prioritized` puts listed apps first in
  /// list order and leaves everything else behind them. The old `shouldAccept` dropped unlisted
  /// bundles outright, which made a second player invisible rather than secondary.
  static func rank(bundleID: String, mode: MediaSourceMode, priorityList: [String]) -> Int? {
    guard !bundleID.isEmpty, !isDenied(bundleID) else { return nil }
    switch mode {
    case .auto:
      // Flat: every visible source ranks the same, so the caller's tiebreakers decide.
      return priorityList.count
    case .prioritized:
      return priorityList.firstIndex(of: bundleID) ?? priorityList.count
    }
  }
}
```

- [ ] **Step 4: Fix the one remaining call site**

`NowPlayingActivity.swift:36-42` still calls `SourceFilter.shouldAccept`. Delete that guard for now —
ranking moves into the table in Task 9. In `Islet/Activities/NowPlaying/NowPlayingActivity.swift`,
replace lines 35-42:

```swift
        case .nowPlaying(let state):
          guard
            SourceFilter.shouldAccept(
              bundleID: state.bundleIdentifier,
              currentBundleID: self.playback?.bundleIdentifier,
              mode: Defaults[.mediaSourceMode],
              priorityList: Defaults[.mediaPriorityList])
          else { continue }
```

with:

```swift
        case .nowPlaying(let state):
          // Filtering moved out of ingestion: every source is stored, and SourceFilter.rank
          // decides display order and visibility when the table is read.
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`
Expected: `** TEST SUCCEEDED **`, 85 tests.

- [ ] **Step 6: Commit**

```bash
git add Islet/Activities/NowPlaying/SourceFilter.swift Islet/Activities/NowPlaying/NowPlayingActivity.swift IsletTests/SourceFilterTests.swift
git commit -m "Media: rank sources for display instead of filtering them out"
```

---

## Task 3: `AdapterUpdate` carries the source key

**Files:**
- Modify: `Islet/Activities/NowPlaying/AdapterParser.swift:7-11`, `:30-35`, `:42`
- Create: `IsletTests/Fixtures/adapter-stream-two-sources.jsonl`
- Test: `IsletTests/AdapterParserTests.swift`

**Interfaces:**
- Consumes: `SourceID.init(state: PlaybackState)`, `PlaybackState.processIdentifier`
- Produces: `enum AdapterUpdate: Equatable { case ignored; case nowPlaying(SourceID, PlaybackState); case sourceGone(SourceID); case idle }`

- [ ] **Step 1: Create the two-source fixture**

Create `IsletTests/Fixtures/adapter-stream-two-sources.jsonl` with exactly these five lines:

```
{"type":"data","diff":false,"payload":{"processIdentifier":6712,"bundleIdentifier":"com.apple.WebKit.GPU","parentApplicationBundleIdentifier":"com.apple.Safari","title":"Paranoid Android","artist":"Radiohead","album":"OK Computer","playing":true,"duration":386.466,"elapsedTime":12.5}}
{"type":"data","diff":true,"payload":{"elapsedTime":18.25}}
{"type":"data","diff":false,"payload":{"processIdentifier":9931,"bundleIdentifier":"com.spotify.client","title":"Weird Fishes","artist":"Radiohead","album":"In Rainbows","playing":true,"duration":321.2,"elapsedTime":4}}
{"type":"data","diff":true,"payload":{"elapsedTime":9.5}}
{"type":"data","diff":false,"payload":{"processIdentifier":7742,"bundleIdentifier":"com.apple.WebKit.GPU","parentApplicationBundleIdentifier":"com.apple.Safari","title":"Videotape","artist":"Radiohead","playing":true,"duration":278,"elapsedTime":1}}
```

Line 4 is deliberately the same bundle identifier as line 0 with a different pid — that is the case
that proves the pid belongs in the key.

- [ ] **Step 2: Regenerate the project so the fixture is copied into the test bundle**

Run: `xcodegen generate`
Expected: `Created project at ...`.

- [ ] **Step 3: Write the failing test**

In `IsletTests/AdapterParserTests.swift`, update the four existing `case .nowPlaying` pattern matches
and append the new tests. Replace the entire file with:

```swift
import XCTest

@testable import Islet

final class AdapterParserTests: XCTestCase {
  func fixtureLines() throws -> [String] {
    let url = try XCTUnwrap(
      Bundle(for: Self.self).url(forResource: "adapter-stream", withExtension: "jsonl"))
    return try String(contentsOf: url, encoding: .utf8)
      .split(separator: "\n").map(String.init)
  }

  func twoSourceLines() throws -> [String] {
    let url = try XCTUnwrap(
      Bundle(for: Self.self).url(
        forResource: "adapter-stream-two-sources", withExtension: "jsonl"))
    return try String(contentsOf: url, encoding: .utf8)
      .split(separator: "\n").map(String.init)
  }

  func testEmptyFullPayloadMeansIdle() throws {
    let lines = try fixtureLines()
    XCTAssertEqual(AdapterParser.parse(line: lines[0], current: nil), .idle)
  }

  func testFullPayloadParses() throws {
    let lines = try fixtureLines()
    guard case .nowPlaying(_, let state) = AdapterParser.parse(line: lines[1], current: nil)
    else { return XCTFail("expected nowPlaying") }
    XCTAssertEqual(state.title, "Paranoid Android")
    XCTAssertEqual(state.artist, "Radiohead")
    XCTAssertEqual(state.bundleIdentifier, "com.apple.WebKit.GPU")
    XCTAssertTrue(state.isPlaying)
    XCTAssertEqual(state.duration, 386.466, accuracy: 0.001)
    XCTAssertNotNil(state.artwork)
    // Depth-pack fields
    XCTAssertEqual(state.parentBundleIdentifier, "com.apple.Safari")
    XCTAssertEqual(state.sourceBundleIdentifier, "com.apple.Safari")  // parent preferred
    XCTAssertTrue(state.isShuffleOn)
    XCTAssertEqual(state.repeatMode, 2)
    XCTAssertTrue(state.supportsSkip15)
    XCTAssertFalse(state.isAdvertisement)
  }

  func testDiffMergesOntoCurrent() throws {
    let lines = try fixtureLines()
    var state: PlaybackState?
    for line in lines[1...3] {
      if case .nowPlaying(_, let s) = AdapterParser.parse(line: line, current: state) {
        state = s
      }
    }
    let final = try XCTUnwrap(state)
    XCTAssertEqual(final.title, "Paranoid Android")  // survives diffs
    XCTAssertEqual(final.elapsed, 14.7, accuracy: 0.001)
    XCTAssertFalse(final.isPlaying)  // updated by diff
  }

  func testNullValueClearsField() throws {
    let lines = try fixtureLines()
    var state: PlaybackState?
    for line in lines[1...4] {
      if case .nowPlaying(_, let s) = AdapterParser.parse(line: line, current: state) {
        state = s
      }
    }
    XCTAssertNil(try XCTUnwrap(state).artwork)
  }

  func testDiffWithoutCurrentIgnored() throws {
    let lines = try fixtureLines()
    XCTAssertEqual(AdapterParser.parse(line: lines[2], current: nil), .ignored)
  }

  func testGarbageLineIgnored() {
    XCTAssertEqual(AdapterParser.parse(line: "not json", current: nil), .ignored)
  }

  func testSourceKeyResolvesParentAsDisplayIdentity() throws {
    let lines = try fixtureLines()
    guard case .nowPlaying(let key, _) = AdapterParser.parse(line: lines[1], current: nil)
    else { return XCTFail("expected nowPlaying") }
    XCTAssertEqual(key.bundleIdentifier, "com.apple.WebKit.GPU")
    XCTAssertEqual(key.pid, 6712)
    XCTAssertEqual(key.displayBundleIdentifier, "com.apple.Safari")
  }

  func testTwoSourcesParseToDistinctKeys() throws {
    let lines = try twoSourceLines()
    guard case .nowPlaying(let safari, let safariState) =
      AdapterParser.parse(line: lines[0], current: nil)
    else { return XCTFail("expected nowPlaying for Safari") }
    guard case .nowPlaying(let spotify, let spotifyState) =
      AdapterParser.parse(line: lines[2], current: nil)
    else { return XCTFail("expected nowPlaying for Spotify") }

    XCTAssertNotEqual(safari, spotify)
    XCTAssertEqual(safari.displayBundleIdentifier, "com.apple.Safari")
    XCTAssertEqual(spotify.displayBundleIdentifier, "com.spotify.client")
    XCTAssertEqual(safariState.title, "Paranoid Android")
    XCTAssertEqual(spotifyState.title, "Weird Fishes")
  }

  func testSameBundleDifferentPidIsADistinctSource() throws {
    let lines = try twoSourceLines()
    guard case .nowPlaying(let first, _) = AdapterParser.parse(line: lines[0], current: nil),
      case .nowPlaying(let second, _) = AdapterParser.parse(line: lines[4], current: nil)
    else { return XCTFail("expected two nowPlaying updates") }
    XCTAssertEqual(first.bundleIdentifier, second.bundleIdentifier)
    XCTAssertNotEqual(first.pid, second.pid)
    XCTAssertNotEqual(first, second)
  }

  func testDiffMergesOntoTheSourceItWasGivenAsCurrent() throws {
    let lines = try twoSourceLines()
    guard case .nowPlaying(let spotify, let base) =
      AdapterParser.parse(line: lines[2], current: nil)
    else { return XCTFail("expected nowPlaying for Spotify") }
    guard case .nowPlaying(let merged, let state) =
      AdapterParser.parse(line: lines[3], current: base)
    else { return XCTFail("expected nowPlaying after diff") }
    XCTAssertEqual(merged, spotify)  // the diff inherits the key it merged onto
    XCTAssertEqual(state.title, "Weird Fishes")
    XCTAssertEqual(state.elapsed, 9.5, accuracy: 0.001)
  }
}
```

- [ ] **Step 4: Run the test to verify it fails**

Run: `xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`
Expected: `** TEST FAILED **`, with compile errors on the two-element `case .nowPlaying(_, let state)`
patterns: `tuple pattern has the wrong length for tuple type '(PlaybackState)'`.

- [ ] **Step 5: Update `AdapterParser`**

In `Islet/Activities/NowPlaying/AdapterParser.swift`, replace lines 7-11:

```swift
enum AdapterUpdate: Equatable {
  case ignored
  case nowPlaying(PlaybackState)
  case idle
}
```

with:

```swift
enum AdapterUpdate: Equatable {
  case ignored
  case nowPlaying(SourceID, PlaybackState)
  /// A source Islet was tracking has ended. The vendored adapter cannot report this itself; it is
  /// synthesised by `MediaWatcher.expand` when the adapter's single live record changes hands.
  case sourceGone(SourceID)
  case idle
}
```

Replace lines 30-34:

```swift
    apply(payload, to: &state)

    // Mandatory keys per adapter's keys.m: a state without a title is "nothing playing".
    if state.title.isEmpty { return .idle }
    return .nowPlaying(state)
```

with:

```swift
    apply(payload, to: &state)

    // Mandatory keys per adapter's keys.m: a state without a title is "nothing playing".
    if state.title.isEmpty { return .idle }
    return .nowPlaying(SourceID(state: state), state)
```

Replace line 42:

```swift
    if let v = payload["bundleIdentifier"] as? String { state.bundleIdentifier = v }
```

with:

```swift
    if let v = payload["bundleIdentifier"] as? String { state.bundleIdentifier = v }
    if let v = payload["processIdentifier"] as? Int {
      state.processIdentifier = Int32(truncatingIfNeeded: v)
    }
```

- [ ] **Step 6: Fix the two remaining call sites so the app compiles**

In `Islet/Activities/NowPlaying/MediaWatcher.swift`, replace lines 118-120:

```swift
    case .nowPlaying(let state):
      failureCount = 0
      lastState = state
```

with:

```swift
    case .nowPlaying(_, let state):
      failureCount = 0
      lastState = state
    case .sourceGone:
      break
```

In `Islet/Activities/NowPlaying/NowPlayingActivity.swift`, replace line 35:

```swift
        case .nowPlaying(let state):
```

with:

```swift
        case .sourceGone:
          continue
        case .nowPlaying(_, let state):
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`
Expected: `** TEST SUCCEEDED **`, 89 tests.

- [ ] **Step 8: Commit**

```bash
git add Islet/Activities/NowPlaying/AdapterParser.swift Islet/Activities/NowPlaying/MediaWatcher.swift Islet/Activities/NowPlaying/NowPlayingActivity.swift IsletTests/AdapterParserTests.swift IsletTests/Fixtures/adapter-stream-two-sources.jsonl Islet.xcodeproj
git commit -m "Media: carry the source key through the adapter parser"
```

---

## Task 4: `MediaSourceTable` — the sources state machine

**Files:**
- Create: `Islet/Activities/NowPlaying/MediaSourceTable.swift`
- Test: `IsletTests/MediaSourceTableTests.swift`

**Interfaces:**
- Consumes: `SourceID`, `PlaybackState`, `SourceFilter.rank(bundleID:mode:priorityList:) -> Int?`, `MediaSourceMode`
- Produces:
  - `struct MediaSourceTable: Equatable`
  - `MediaSourceTable.init(idleTimeout: TimeInterval = 60)`
  - `MediaSourceTable.states: [SourceID: PlaybackState] { get }`
  - `MediaSourceTable.isEmpty: Bool { get }`
  - `MediaSourceTable.nextDeadline: Date? { get }`
  - `@discardableResult mutating func upsert(_ key: SourceID, _ state: PlaybackState, now: Date) -> Bool`
  - `@discardableResult mutating func remove(_ key: SourceID) -> Bool`
  - `mutating func removeAll()`
  - `@discardableResult mutating func expire(now: Date) -> [SourceID]`
  - `func ordered(mode: MediaSourceMode, priorityList: [String]) -> [SourceID]`
  - `func primaryKey(mode: MediaSourceMode, priorityList: [String]) -> SourceID?`

- [ ] **Step 1: Write the failing test**

Create `IsletTests/MediaSourceTableTests.swift`:

```swift
import XCTest

@testable import Islet

final class MediaSourceTableTests: XCTestCase {
  let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)

  func key(_ bundle: String, _ pid: Int32, parent: String = "") -> SourceID {
    SourceID(bundleIdentifier: bundle, pid: pid, parentBundleIdentifier: parent)
  }

  func state(_ title: String, playing: Bool) -> PlaybackState {
    var s = PlaybackState()
    s.title = title
    s.isPlaying = playing
    return s
  }

  func testUpsertInsertsAndReportsNew() {
    var table = MediaSourceTable()
    let spotify = key("com.spotify.client", 1)
    XCTAssertTrue(table.upsert(spotify, state("A", playing: true), now: t0))
    XCTAssertEqual(table.states.count, 1)
    XCTAssertEqual(table.states[spotify]?.title, "A")
    XCTAssertFalse(table.isEmpty)
  }

  func testUpsertOfAKnownKeyIsAnUpdateNotAnInsert() {
    var table = MediaSourceTable()
    let spotify = key("com.spotify.client", 1)
    table.upsert(spotify, state("A", playing: true), now: t0)
    XCTAssertFalse(table.upsert(spotify, state("B", playing: true), now: t0.addingTimeInterval(5)))
    XCTAssertEqual(table.states.count, 1)
    XCTAssertEqual(table.states[spotify]?.title, "B")
  }

  func testTwoSourcesCoexist() {
    var table = MediaSourceTable()
    table.upsert(key("com.spotify.client", 1), state("A", playing: true), now: t0)
    table.upsert(key("com.apple.Music", 2), state("B", playing: true), now: t0)
    XCTAssertEqual(table.states.count, 2)
  }

  func testRemoveDropsOneSourceOnly() {
    var table = MediaSourceTable()
    let spotify = key("com.spotify.client", 1)
    let music = key("com.apple.Music", 2)
    table.upsert(spotify, state("A", playing: true), now: t0)
    table.upsert(music, state("B", playing: true), now: t0)
    XCTAssertTrue(table.remove(spotify))
    XCTAssertEqual(Array(table.states.keys), [music])
    XCTAssertFalse(table.remove(spotify))  // already gone
  }

  func testRemoveAllClears() {
    var table = MediaSourceTable()
    table.upsert(key("com.spotify.client", 1), state("A", playing: false), now: t0)
    table.upsert(key("com.apple.Music", 2), state("B", playing: false), now: t0)
    table.removeAll()
    XCTAssertTrue(table.isEmpty)
    XCTAssertNil(table.nextDeadline)
  }

  func testPausingSetsADeadlineAndPlayingClearsIt() {
    var table = MediaSourceTable(idleTimeout: 60)
    let spotify = key("com.spotify.client", 1)
    table.upsert(spotify, state("A", playing: true), now: t0)
    XCTAssertNil(table.nextDeadline)
    table.upsert(spotify, state("A", playing: false), now: t0)
    XCTAssertEqual(table.nextDeadline, t0.addingTimeInterval(60))
    table.upsert(spotify, state("A", playing: true), now: t0.addingTimeInterval(5))
    XCTAssertNil(table.nextDeadline)
  }

  func testAContinuingPauseDoesNotPushTheDeadlineBack() {
    var table = MediaSourceTable(idleTimeout: 60)
    let spotify = key("com.spotify.client", 1)
    table.upsert(spotify, state("A", playing: false), now: t0)
    table.upsert(spotify, state("A", playing: false), now: t0.addingTimeInterval(30))
    XCTAssertEqual(table.nextDeadline, t0.addingTimeInterval(60))
  }

  func testExpireIsANoOpBeforeTheDeadline() {
    var table = MediaSourceTable(idleTimeout: 60)
    table.upsert(key("com.spotify.client", 1), state("A", playing: false), now: t0)
    XCTAssertEqual(table.expire(now: t0.addingTimeInterval(59)), [])
    XCTAssertEqual(table.states.count, 1)
  }

  func testExpireEvictsOnlyPastDeadlineSources() {
    var table = MediaSourceTable(idleTimeout: 60)
    let early = key("com.spotify.client", 1)
    let late = key("com.apple.Music", 2)
    table.upsert(early, state("A", playing: false), now: t0)
    table.upsert(late, state("B", playing: false), now: t0.addingTimeInterval(30))
    XCTAssertEqual(table.expire(now: t0.addingTimeInterval(61)), [early])
    XCTAssertEqual(Array(table.states.keys), [late])
    XCTAssertEqual(table.expire(now: t0.addingTimeInterval(91)), [late])
    XCTAssertTrue(table.isEmpty)
  }

  func testResumingPlaybackCancelsExpiry() {
    var table = MediaSourceTable(idleTimeout: 60)
    let spotify = key("com.spotify.client", 1)
    table.upsert(spotify, state("A", playing: false), now: t0)
    table.upsert(spotify, state("A", playing: true), now: t0.addingTimeInterval(10))
    XCTAssertEqual(table.expire(now: t0.addingTimeInterval(600)), [])
    XCTAssertEqual(table.states.count, 1)
  }

  func testNextDeadlineIsTheEarliest() {
    var table = MediaSourceTable(idleTimeout: 60)
    table.upsert(key("com.apple.Music", 2), state("B", playing: false), now: t0.addingTimeInterval(30))
    table.upsert(key("com.spotify.client", 1), state("A", playing: false), now: t0)
    XCTAssertEqual(table.nextDeadline, t0.addingTimeInterval(60))
  }

  func testPrimaryPrefersPlayingOverPaused() {
    var table = MediaSourceTable()
    let paused = key("com.apple.Music", 2)
    let playing = key("com.spotify.client", 1)
    table.upsert(paused, state("B", playing: false), now: t0)
    table.upsert(playing, state("A", playing: true), now: t0)
    XCTAssertEqual(table.primaryKey(mode: .auto, priorityList: []), playing)
  }

  func testPrioritizedModeFollowsThePriorityList() {
    var table = MediaSourceTable()
    let music = key("com.apple.Music", 2)
    let spotify = key("com.spotify.client", 1)
    table.upsert(spotify, state("A", playing: true), now: t0)
    table.upsert(music, state("B", playing: true), now: t0)
    XCTAssertEqual(
      table.primaryKey(mode: .prioritized, priorityList: ["com.apple.Music", "com.spotify.client"]),
      music)
    XCTAssertEqual(
      table.primaryKey(mode: .prioritized, priorityList: ["com.spotify.client", "com.apple.Music"]),
      spotify)
  }

  func testOrderedRanksByDisplayIdentityNotTheHelperBundle() {
    var table = MediaSourceTable()
    let safari = key("com.apple.WebKit.GPU", 6712, parent: "com.apple.Safari")
    let spotify = key("com.spotify.client", 1)
    table.upsert(safari, state("A", playing: true), now: t0)
    table.upsert(spotify, state("B", playing: true), now: t0)
    XCTAssertEqual(
      table.ordered(mode: .prioritized, priorityList: ["com.apple.Safari"]),
      [safari, spotify])
  }

  func testDeniedSourcesAreNeverOrderedOrPrimary() {
    var table = MediaSourceTable()
    let denied = key("com.apple.controlcenter", 726)
    let spotify = key("com.spotify.client", 1)
    table.upsert(denied, state("Ping", playing: true), now: t0)
    table.upsert(spotify, state("A", playing: true), now: t0)
    XCTAssertEqual(table.ordered(mode: .auto, priorityList: []), [spotify])
    XCTAssertEqual(table.primaryKey(mode: .auto, priorityList: []), spotify)
  }
}
```

- [ ] **Step 2: Regenerate the project so the new test file is in the target**

Run: `xcodegen generate`
Expected: `Created project at ...`.

- [ ] **Step 3: Run the test to verify it fails**

Run: `xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`
Expected: `** TEST FAILED **`, with compile error `cannot find 'MediaSourceTable' in scope`.

- [ ] **Step 4: Create `MediaSourceTable.swift`**

Create `Islet/Activities/NowPlaying/MediaSourceTable.swift`:

```swift
import Foundation

/// Every media source Islet currently knows about, keyed by `SourceID`.
///
/// Pure and actor-free on purpose: the insert / update / remove / idle-expiry state machine and the
/// display ordering are the parts worth testing, and tests call them synchronously.
struct MediaSourceTable: Equatable {
  /// Deactivate a paused source this long after it paused, so a paused track eventually leaves the
  /// island. Was a single 60s timer on the activity; it is per-source now.
  let idleTimeout: TimeInterval
  private(set) var states: [SourceID: PlaybackState] = [:]
  /// When each source first appeared, used as the recency tiebreaker.
  private(set) var firstSeen: [SourceID: Date] = [:]
  /// When each paused source becomes eligible for eviction. Absent while playing.
  private(set) var idleDeadlines: [SourceID: Date] = [:]

  init(idleTimeout: TimeInterval = 60) { self.idleTimeout = idleTimeout }

  var isEmpty: Bool { states.isEmpty }

  /// The soonest idle deadline, so a single timer can drive expiry for the whole table.
  var nextDeadline: Date? { idleDeadlines.values.min() }

  /// Inserts or updates a source. Returns true when the key was not already present.
  @discardableResult
  mutating func upsert(_ key: SourceID, _ state: PlaybackState, now: Date) -> Bool {
    let isNew = states[key] == nil
    states[key] = state
    if isNew { firstSeen[key] = now }
    if state.isPlaying {
      idleDeadlines[key] = nil
    } else if idleDeadlines[key] == nil {
      // The countdown starts when playback pauses, and repeated paused updates do not push it
      // back — otherwise a chatty player keeps a paused track on screen forever.
      idleDeadlines[key] = now.addingTimeInterval(idleTimeout)
    }
    return isNew
  }

  /// Removes a source. Returns true when something was actually removed.
  @discardableResult
  mutating func remove(_ key: SourceID) -> Bool {
    guard states.removeValue(forKey: key) != nil else { return false }
    firstSeen[key] = nil
    idleDeadlines[key] = nil
    return true
  }

  mutating func removeAll() {
    states.removeAll()
    firstSeen.removeAll()
    idleDeadlines.removeAll()
  }

  /// Evicts every source whose paused deadline has passed. Returns the keys removed.
  @discardableResult
  mutating func expire(now: Date) -> [SourceID] {
    let due = idleDeadlines.filter { $0.value <= now }.keys.sorted { $0.pid < $1.pid }
    for key in due { remove(key) }
    return due
  }

  /// Display order: rank first (hidden sources dropped), then playing before paused, then most
  /// recently seen, then pid so the order is deterministic.
  func ordered(mode: MediaSourceMode, priorityList: [String]) -> [SourceID] {
    states.keys
      .compactMap { key -> (SourceID, Int)? in
        guard
          let rank = SourceFilter.rank(
            bundleID: key.displayBundleIdentifier, mode: mode, priorityList: priorityList)
        else { return nil }
        return (key, rank)
      }
      .sorted { left, right in
        if left.1 != right.1 { return left.1 < right.1 }
        let leftPlaying = states[left.0]?.isPlaying ?? false
        let rightPlaying = states[right.0]?.isPlaying ?? false
        if leftPlaying != rightPlaying { return leftPlaying }
        let leftSeen = firstSeen[left.0] ?? .distantPast
        let rightSeen = firstSeen[right.0] ?? .distantPast
        if leftSeen != rightSeen { return leftSeen > rightSeen }
        return left.0.pid < right.0.pid
      }
      .map(\.0)
  }

  /// The source that owns the hero player.
  func primaryKey(mode: MediaSourceMode, priorityList: [String]) -> SourceID? {
    ordered(mode: mode, priorityList: priorityList).first
  }
}
```

- [ ] **Step 5: Regenerate the project so the new source file is in the target**

Run: `xcodegen generate`
Expected: `Created project at ...`.

- [ ] **Step 6: Run tests to verify they pass**

Run: `xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`
Expected: `** TEST SUCCEEDED **`, 104 tests.

- [ ] **Step 7: Commit**

```bash
git add Islet/Activities/NowPlaying/MediaSourceTable.swift IsletTests/MediaSourceTableTests.swift Islet.xcodeproj
git commit -m "Media: hold every source in a per-source table with its own idle timer"
```

---

## Task 5: `SourceStrip` — merge, secondary selection and the cap-at-3 reduction

**Files:**
- Modify: `Islet/Activities/NowPlaying/MediaSourceTable.swift` (append `SourceStrip`)
- Test: `IsletTests/SourceStripTests.swift`

**Interfaces:**
- Consumes: `SourceID`
- Produces:
  - `enum SourceStrip`
  - `static func SourceStrip.merge(adapter: [SourceID], audio: [SourceID]) -> [SourceID]`
  - `static func SourceStrip.secondary(all: [SourceID], primary: SourceID?) -> [SourceID]`
  - `static func SourceStrip.layout(_ sources: [SourceID], limit: Int = 3) -> (shown: [SourceID], overflow: Int)`

- [ ] **Step 1: Write the failing test**

Create `IsletTests/SourceStripTests.swift`:

```swift
import XCTest

@testable import Islet

final class SourceStripTests: XCTestCase {
  func key(_ bundle: String, _ pid: Int32, parent: String = "") -> SourceID {
    SourceID(bundleIdentifier: bundle, pid: pid, parentBundleIdentifier: parent)
  }

  func testLayoutBelowTheCapShowsEverything() {
    let sources = [key("a", 1), key("b", 2)]
    let layout = SourceStrip.layout(sources)
    XCTAssertEqual(layout.shown, sources)
    XCTAssertEqual(layout.overflow, 0)
  }

  func testLayoutAtTheCapShowsEverything() {
    let sources = [key("a", 1), key("b", 2), key("c", 3)]
    let layout = SourceStrip.layout(sources)
    XCTAssertEqual(layout.shown.count, 3)
    XCTAssertEqual(layout.overflow, 0)
  }

  func testLayoutAboveTheCapShowsThreeAndCountsTheRest() {
    let sources = (1...7).map { key("app\($0)", Int32($0)) }
    let layout = SourceStrip.layout(sources)
    XCTAssertEqual(layout.shown, Array(sources.prefix(3)))
    XCTAssertEqual(layout.overflow, 4)
  }

  func testLayoutOfNothingIsEmpty() {
    let layout = SourceStrip.layout([])
    XCTAssertTrue(layout.shown.isEmpty)
    XCTAssertEqual(layout.overflow, 0)
  }

  func testSecondaryExcludesThePrimaryByDisplayIdentity() {
    // A different pid of the same app is still the same app, so it must not double up.
    let hero = key("com.apple.WebKit.GPU", 1172, parent: "com.apple.Safari")
    let sameApp = key("com.apple.WebKit.GPU", 1469, parent: "com.apple.Safari")
    let spotify = key("com.spotify.client", 9931)
    XCTAssertEqual(SourceStrip.secondary(all: [hero, sameApp, spotify], primary: hero), [spotify])
  }

  func testSecondaryReturnsEverythingWhenThereIsNoPrimary() {
    let sources = [key("a", 1), key("b", 2)]
    XCTAssertEqual(SourceStrip.secondary(all: sources, primary: nil), sources)
  }

  func testMergeKeepsAdapterSourcesFirst() {
    let adapter = [key("com.spotify.client", 1)]
    let audio = [key("com.google.Chrome.helper", 2, parent: "com.google.Chrome")]
    XCTAssertEqual(SourceStrip.merge(adapter: adapter, audio: audio), adapter + audio)
  }

  func testMergeDropsAudioDuplicatesOfAdapterSources() {
    // CoreAudio sees Spotify too; the adapter entry has metadata, so it wins.
    let adapter = [key("com.spotify.client", 1)]
    let audio = [key("com.spotify.client", 1), key("com.apple.Music", 3)]
    XCTAssertEqual(
      SourceStrip.merge(adapter: adapter, audio: audio),
      [key("com.spotify.client", 1), key("com.apple.Music", 3)])
  }
}
```

- [ ] **Step 2: Regenerate the project so the new test file is in the target**

Run: `xcodegen generate`
Expected: `Created project at ...`.

- [ ] **Step 3: Run the test to verify it fails**

Run: `xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`
Expected: `** TEST FAILED **`, with compile error `cannot find 'SourceStrip' in scope`.

- [ ] **Step 4: Append `SourceStrip` to `MediaSourceTable.swift`**

Append to the end of `Islet/Activities/NowPlaying/MediaSourceTable.swift`:

```swift
/// Reduces the known sources into the chip strip drawn under the hero player. Pure so the cap and
/// the de-duplication are testable without a view.
enum SourceStrip {
  /// Adapter sources (which have metadata) come first; CoreAudio sources are appended unless the
  /// same app is already represented, which would draw Spotify twice.
  static func merge(adapter: [SourceID], audio: [SourceID]) -> [SourceID] {
    let known = Set(adapter.map(\.displayBundleIdentifier))
    return adapter + audio.filter { !known.contains($0.displayBundleIdentifier) }
  }

  /// Everything except the app holding the hero. Compared on display identity, so a second
  /// WebKit.GPU process of the same Safari does not become its own chip.
  static func secondary(all: [SourceID], primary: SourceID?) -> [SourceID] {
    guard let primary else { return all }
    return all.filter { $0.displayBundleIdentifier != primary.displayBundleIdentifier }
  }

  /// At most `limit` chips, then a "+N" pill. The collapsed island's width is derived from the
  /// measured widths of its compact slots (`NotchRootView.swift:67`, `:132-134`), so an uncapped
  /// strip would widen the island itself.
  static func layout(_ sources: [SourceID], limit: Int = 3) -> (shown: [SourceID], overflow: Int) {
    guard sources.count > limit else { return (sources, 0) }
    return (Array(sources.prefix(limit)), sources.count - limit)
  }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`
Expected: `** TEST SUCCEEDED **`, 112 tests.

- [ ] **Step 6: Commit**

```bash
git add Islet/Activities/NowPlaying/MediaSourceTable.swift IsletTests/SourceStripTests.swift Islet.xcodeproj
git commit -m "Media: cap the source strip at three chips plus an overflow count"
```

---

## Task 6: `MediaWatcher` tracks adapter state per source

**Files:**
- Modify: `Islet/Activities/NowPlaying/MediaWatcher.swift:12` and its `handle(line:)` method (originally `:110-123`, two lines longer after Task 3)
- Test: `IsletTests/MediaWatcherTests.swift`

**Interfaces:**
- Consumes: `AdapterUpdate`, `SourceID`, `AdapterParser.parse(line:current:) -> AdapterUpdate`
- Produces: `static func MediaWatcher.expand(_ update: AdapterUpdate, current: SourceID?) -> [AdapterUpdate]`

- [ ] **Step 1: Write the failing test**

Replace the entire contents of `IsletTests/MediaWatcherTests.swift` with:

```swift
import XCTest

@testable import Islet

final class MediaWatcherTests: XCTestCase {
  func testBackoffDoublesAndCaps() {
    XCTAssertEqual(MediaWatcher.backoffDelay(failureCount: 1), 1)
    XCTAssertEqual(MediaWatcher.backoffDelay(failureCount: 2), 2)
    XCTAssertEqual(MediaWatcher.backoffDelay(failureCount: 4), 8)
    XCTAssertEqual(MediaWatcher.backoffDelay(failureCount: 10), 60)
  }

  func key(_ bundle: String, _ pid: Int32) -> SourceID {
    SourceID(bundleIdentifier: bundle, pid: pid, parentBundleIdentifier: "")
  }

  /// Build the state ONCE per test and reuse it. `PlaybackState.elapsedAt` defaults to `Date()`,
  /// so two separate constructions are never equal.
  func state(_ title: String) -> PlaybackState {
    var s = PlaybackState()
    s.title = title
    s.isPlaying = true
    return s
  }

  func testIgnoredExpandsToNothing() {
    XCTAssertEqual(MediaWatcher.expand(.ignored, current: nil), [])
    XCTAssertEqual(
      MediaWatcher.expand(.ignored, current: key("com.spotify.client", 1)), [])
  }

  func testFirstSourceJustPublishes() {
    let spotify = key("com.spotify.client", 1)
    let playing = state("A")
    XCTAssertEqual(
      MediaWatcher.expand(.nowPlaying(spotify, playing), current: nil),
      [.nowPlaying(spotify, playing)])
  }

  func testSameSourceDoesNotEvict() {
    let spotify = key("com.spotify.client", 1)
    let playing = state("B")
    XCTAssertEqual(
      MediaWatcher.expand(.nowPlaying(spotify, playing), current: spotify),
      [.nowPlaying(spotify, playing)])
  }

  func testSourceChangeEvictsThePreviousSourceFirst() {
    // The vendored adapter calls resetAll() on a process change, so the previous source is not
    // backgrounded — it is gone.
    let spotify = key("com.spotify.client", 1)
    let music = key("com.apple.Music", 2)
    let playing = state("B")
    XCTAssertEqual(
      MediaWatcher.expand(.nowPlaying(music, playing), current: spotify),
      [.sourceGone(spotify), .nowPlaying(music, playing)])
  }

  func testIdlePassesThrough() {
    XCTAssertEqual(MediaWatcher.expand(.idle, current: key("com.spotify.client", 1)), [.idle])
    XCTAssertEqual(MediaWatcher.expand(.idle, current: nil), [.idle])
  }

  func testSourceGonePassesThrough() {
    let spotify = key("com.spotify.client", 1)
    XCTAssertEqual(
      MediaWatcher.expand(.sourceGone(spotify), current: spotify), [.sourceGone(spotify)])
  }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`
Expected: `** TEST FAILED **`, with compile error `type 'MediaWatcher' has no member 'expand'`.

- [ ] **Step 3: Add per-source tracking and `expand` to `MediaWatcher`**

In `Islet/Activities/NowPlaying/MediaWatcher.swift`, replace line 12:

```swift
  private var lastState: PlaybackState?
```

with:

```swift
  /// Diff base per source. The vendored adapter collapses concurrent players, so this holds at
  /// most one entry today — the shape is what the fork described in the design spec's
  /// "Upgrade path — fork the MediaRemote adapter for true per-source media" section needs.
  private var lastStates: [SourceID: PlaybackState] = [:]
  private var currentSource: SourceID?
```

Replace the whole `handle(line: String)` method, which after Task 3 reads exactly:

```swift
  private func handle(line: String) {
    let update = AdapterParser.parse(line: line, current: lastState)
    switch update {
    case .ignored:
      return
    case .idle:
      failureCount = 0
      lastState = nil
    case .nowPlaying(_, let state):
      failureCount = 0
      lastState = state
    case .sourceGone:
      break
    }
    continuation.yield(update)
  }
```

with:

```swift
  /// Sequences one parsed update into what downstream should actually see.
  ///
  /// `Vendor/mediaremote-adapter-src/src/adapter/stream.m:189` keeps a single `liveData` record and
  /// calls `resetAll()` whenever a notification arrives from a different process (`:396-408`,
  /// `:437-449`). A change of source key therefore means the previous source is *gone*, not
  /// backgrounded, and has to be evicted before the new one lands. Pure so the sequencing is
  /// testable without a process.
  static func expand(_ update: AdapterUpdate, current: SourceID?) -> [AdapterUpdate] {
    switch update {
    case .ignored:
      return []
    case .idle, .sourceGone:
      return [update]
    case .nowPlaying(let key, let state):
      guard let current, current != key else { return [update] }
      return [.sourceGone(current), .nowPlaying(key, state)]
    }
  }

  private func handle(line: String) {
    let base = currentSource.flatMap { lastStates[$0] }
    for update in Self.expand(AdapterParser.parse(line: line, current: base), current: currentSource)
    {
      switch update {
      case .ignored:
        continue
      case .idle:
        failureCount = 0
        lastStates.removeAll()
        currentSource = nil
      case .sourceGone(let key):
        lastStates[key] = nil
        if currentSource == key { currentSource = nil }
      case .nowPlaying(let key, let state):
        failureCount = 0
        lastStates[key] = state
        currentSource = key
      }
      continuation.yield(update)
    }
  }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`
Expected: `** TEST SUCCEEDED **`, 118 tests.

- [ ] **Step 5: Commit**

```bash
git add Islet/Activities/NowPlaying/MediaWatcher.swift IsletTests/MediaWatcherTests.swift
git commit -m "Media: track adapter state per source and evict the one it replaced"
```

---

## Task 7: `AudioProcessReducer` — denylist, helper collapsing and de-duplication

**Files:**
- Create: `Islet/Activities/NowPlaying/AudioProcessMonitor.swift` (pure reducer only in this task)
- Test: `IsletTests/AudioProcessReducerTests.swift`

**Interfaces:**
- Consumes: `SourceID.init(bundleIdentifier:pid:displayBundleIdentifier:)`, `AudioSourceResolver.displayBundleID(bundleID:pid:runningAppBundleID:)`, `SourceFilter.isDenied(_:)`
- Produces:
  - `enum AudioProcessReducer`
  - `struct AudioProcessReducer.RawProcess: Equatable, Sendable { let bundleID: String; let pid: Int32; let isPlayingOutput: Bool }`
  - `static func AudioProcessReducer.reduce(processes: [AudioProcessReducer.RawProcess], runningAppBundleID: (Int32) -> String?) -> [SourceID]`

- [ ] **Step 1: Write the failing test**

Create `IsletTests/AudioProcessReducerTests.swift`:

```swift
import XCTest

@testable import Islet

final class AudioProcessReducerTests: XCTestCase {
  typealias Raw = AudioProcessReducer.RawProcess

  func reduce(_ raw: [Raw]) -> [SourceID] {
    AudioProcessReducer.reduce(processes: raw, runningAppBundleID: { _ in nil })
  }

  func testOnlyProcessesRunningOutputAreIncluded() {
    let out = reduce([
      Raw(bundleID: "com.spotify.client", pid: 1, isPlayingOutput: true),
      Raw(bundleID: "com.apple.Music", pid: 2, isPlayingOutput: false),
    ])
    XCTAssertEqual(out.map(\.displayBundleIdentifier), ["com.spotify.client"])
  }

  func testEmptyBundleIdentifiersAreDropped() {
    // Three process objects reported an empty bundle ID in the probe on this machine.
    XCTAssertTrue(reduce([Raw(bundleID: "", pid: 639, isPlayingOutput: true)]).isEmpty)
  }

  func testDenylistedProcessesAreDropped() {
    let out = reduce([
      Raw(bundleID: "systemsoundserverd", pid: 764, isPlayingOutput: true),
      Raw(bundleID: "com.apple.PowerChime", pid: 27375, isPlayingOutput: true),
      Raw(bundleID: "com.apple.controlcenter", pid: 726, isPlayingOutput: true),
    ])
    XCTAssertTrue(out.isEmpty)
  }

  func testIsletItselfIsDropped() {
    XCTAssertTrue(
      reduce([Raw(bundleID: "dev.cnucifora.Islet", pid: 19449, isPlayingOutput: true)]).isEmpty)
  }

  func testDenylistAppliesAfterHelperCollapsing() {
    // com.apple.audio.Core-Audio-Driver-Service.helper collapses onto its denylisted parent.
    let out = reduce([
      Raw(
        bundleID: "com.apple.audio.Core-Audio-Driver-Service.helper", pid: 590,
        isPlayingOutput: true)
    ])
    XCTAssertTrue(out.isEmpty)
  }

  func testThreeWebKitGPUProcessesCollapseToOneSafariRow() {
    let out = reduce([
      Raw(bundleID: "com.apple.WebKit.GPU", pid: 17670, isPlayingOutput: true),
      Raw(bundleID: "com.apple.WebKit.GPU", pid: 1172, isPlayingOutput: true),
      Raw(bundleID: "com.apple.WebKit.GPU", pid: 1469, isPlayingOutput: true),
    ])
    XCTAssertEqual(out.count, 1)
    XCTAssertEqual(out[0].displayBundleIdentifier, "com.apple.Safari")
    XCTAssertEqual(out[0].pid, 1172)  // lowest pid wins, so the row is stable across refreshes
  }

  func testChromiumHelpersCollapseOntoTheParent() {
    let out = reduce([
      Raw(bundleID: "com.google.Chrome.helper", pid: 11407, isPlayingOutput: true)
    ])
    XCTAssertEqual(out.map(\.displayBundleIdentifier), ["com.google.Chrome"])
    XCTAssertEqual(out[0].bundleIdentifier, "com.google.Chrome.helper")
  }

  func testHelperAndParentBothPresentProduceOneRow() {
    let out = reduce([
      Raw(bundleID: "com.anthropic.claudefordesktop", pid: 49775, isPlayingOutput: true),
      Raw(bundleID: "com.anthropic.claudefordesktop.helper", pid: 50412, isPlayingOutput: true),
      Raw(bundleID: "com.anthropic.claudefordesktop.helper", pid: 50413, isPlayingOutput: true),
    ])
    XCTAssertEqual(out.map(\.displayBundleIdentifier), ["com.anthropic.claudefordesktop"])
  }

  func testResultIsSortedByDisplayIdentity() {
    let out = reduce([
      Raw(bundleID: "com.spotify.client", pid: 3, isPlayingOutput: true),
      Raw(bundleID: "com.apple.Music", pid: 1, isPlayingOutput: true),
      Raw(bundleID: "com.google.Chrome.helper", pid: 2, isPlayingOutput: true),
    ])
    XCTAssertEqual(
      out.map(\.displayBundleIdentifier),
      ["com.apple.Music", "com.google.Chrome", "com.spotify.client"])
  }

  func testUnknownProcessResolvesThroughTheRunningApplicationLookup() {
    let out = AudioProcessReducer.reduce(
      processes: [Raw(bundleID: "some.unknown.xpc", pid: 42, isPlayingOutput: true)],
      runningAppBundleID: { $0 == 42 ? "com.example.Host" : nil })
    XCTAssertEqual(out.map(\.displayBundleIdentifier), ["com.example.Host"])
  }
}
```

- [ ] **Step 2: Create `AudioProcessMonitor.swift` with the reducer**

Create `Islet/Activities/NowPlaying/AudioProcessMonitor.swift`:

```swift
import CoreAudio
import Foundation

/// Turns the raw CoreAudio process list into the source rows Islet draws.
///
/// Pure so the denylist, the helper→parent collapsing and the de-duplication are testable with
/// plain strings — none of which needs CoreAudio to be running.
enum AudioProcessReducer {
  /// One CoreAudio process object, flattened to the three properties Islet reads.
  struct RawProcess: Equatable, Sendable {
    let bundleID: String
    let pid: Int32
    let isPlayingOutput: Bool
  }

  /// One row per app that is currently producing audio output.
  ///
  /// Honest limitation: this flags *any* audio, not just music. A video call, a game and a
  /// notification chime all read as "playing". The denylist covers the system offenders observed
  /// on this machine; a Zoom call will still show a chip.
  static func reduce(
    processes: [RawProcess], runningAppBundleID: (Int32) -> String?
  ) -> [SourceID] {
    var byApp: [String: SourceID] = [:]
    for process in processes where process.isPlayingOutput {
      guard !process.bundleID.isEmpty else { continue }
      let display = AudioSourceResolver.displayBundleID(
        bundleID: process.bundleID, pid: process.pid, runningAppBundleID: runningAppBundleID)
      guard !SourceFilter.isDenied(display), !SourceFilter.isDenied(process.bundleID) else {
        continue
      }
      // Lowest pid wins so the row identity does not flicker as helpers come and go.
      if let existing = byApp[display], existing.pid <= process.pid { continue }
      byApp[display] = SourceID(
        bundleIdentifier: process.bundleID, pid: process.pid, displayBundleIdentifier: display)
    }
    return byApp.values.sorted { $0.displayBundleIdentifier < $1.displayBundleIdentifier }
  }
}
```

- [ ] **Step 3: Regenerate the project so both new files are in their targets**

Run: `xcodegen generate`
Expected: `Created project at ...`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`
Expected: `** TEST SUCCEEDED **`, 128 tests.

- [ ] **Step 5: Commit**

```bash
git add Islet/Activities/NowPlaying/AudioProcessMonitor.swift IsletTests/AudioProcessReducerTests.swift Islet.xcodeproj
git commit -m "Media: reduce CoreAudio process objects to one row per app"
```

---

## Task 8: `AudioProcessMonitor` — push-driven CoreAudio detection

**Files:**
- Modify: `Islet/Activities/NowPlaying/AudioProcessMonitor.swift` (append the monitor class)

**Interfaces:**
- Consumes: `AudioProcessReducer.reduce(processes:runningAppBundleID:)`, `AudioSourceResolver.runningAppBundleID(_:)`, `Log.media` (`Islet/Support/Logging.swift:5`)
- Produces:
  - `@MainActor final class AudioProcessMonitor: ObservableObject`
  - `@Published private(set) var AudioProcessMonitor.sources: [SourceID]`
  - `func AudioProcessMonitor.start()`
  - `func AudioProcessMonitor.stop()`
  - `func AudioProcessMonitor.refresh()`

**No unit test — verified by build plus a manual check.** The class is a thin shell over CoreAudio;
everything worth asserting is already covered by `AudioProcessReducerTests`.

**Why this needs no permission:** `kAudioHardwarePropertyProcessObjectList` (`'prs#'`),
`kAudioProcessPropertyBundleID` (`'pbid'`), `kAudioProcessPropertyPID` (`'ppid'`) and
`kAudioProcessPropertyIsRunningOutput` (`'piro'`) are all public CoreAudio selectors declared in
`AudioHardware.h`. These are process *objects*, not Core Audio process taps — a tap would need
`NSAudioCaptureUsageDescription` in `project.yml` and a TCC grant. Verified end to end from an
ad-hoc-signed binary on this machine: `noErr`, 38 process objects, bundle IDs and flags readable, no
prompt. Do not add an entitlement or an Info.plist key for this.

- [ ] **Step 1: Append the monitor to `AudioProcessMonitor.swift`**

Append to the end of `Islet/Activities/NowPlaying/AudioProcessMonitor.swift`:

```swift
/// Watches which processes are producing audio output, push-driven, with no polling.
///
/// One `AudioObjectPropertyListenerBlock` on the system object's process list, plus one per process
/// on its running-output flag. These are process *objects* (macOS 14+), not Core Audio process taps:
/// no NSAudioCaptureUsageDescription, no TCC prompt.
@MainActor
final class AudioProcessMonitor: ObservableObject {
  /// Apps currently producing audio output, de-duplicated to one entry per app.
  @Published private(set) var sources: [SourceID] = []

  private var started = false
  private var refreshPending = false
  private var listListener: AudioObjectPropertyListenerBlock?
  private var processListeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]

  private static let listAddress = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyProcessObjectList,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)
  private static let runningOutputAddress = AudioObjectPropertyAddress(
    mSelector: kAudioProcessPropertyIsRunningOutput,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)

  func start() {
    guard !started else { return }
    started = true
    let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
      Task { @MainActor in self?.scheduleRefresh() }
    }
    var address = Self.listAddress
    let status = AudioObjectAddPropertyListenerBlock(
      AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
    if status == noErr {
      listListener = block
    } else {
      Log.media.error("CoreAudio process-list listener failed with \(status)")
    }
    refresh()
  }

  func stop() {
    guard started else { return }
    started = false
    if let listListener {
      var address = Self.listAddress
      AudioObjectRemovePropertyListenerBlock(
        AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, listListener)
      self.listListener = nil
    }
    for (object, block) in processListeners {
      var address = Self.runningOutputAddress
      AudioObjectRemovePropertyListenerBlock(object, &address, DispatchQueue.main, block)
    }
    processListeners.removeAll()
    sources = []
  }

  /// Coalesces the burst of callbacks a single play/pause produces — one per listening process —
  /// into one read pass.
  private func scheduleRefresh() {
    guard !refreshPending else { return }
    refreshPending = true
    Task { @MainActor [weak self] in
      guard let self else { return }
      self.refreshPending = false
      self.refresh()
    }
  }

  func refresh() {
    let objects = Self.processObjects()
    syncListeners(for: objects)
    let raw = objects.map {
      AudioProcessReducer.RawProcess(
        bundleID: Self.bundleID($0) ?? "",
        pid: Self.pid($0),
        isPlayingOutput: Self.isRunningOutput($0))
    }
    let next = AudioProcessReducer.reduce(
      processes: raw, runningAppBundleID: AudioSourceResolver.runningAppBundleID)
    if next != sources { sources = next }
  }

  /// Adds a running-output listener to every new process object and removes the ones that died.
  private func syncListeners(for objects: [AudioObjectID]) {
    let live = Set(objects)
    for (object, block) in processListeners where !live.contains(object) {
      var address = Self.runningOutputAddress
      AudioObjectRemovePropertyListenerBlock(object, &address, DispatchQueue.main, block)
      processListeners[object] = nil
    }
    for object in objects where processListeners[object] == nil {
      let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        Task { @MainActor in self?.scheduleRefresh() }
      }
      var address = Self.runningOutputAddress
      guard
        AudioObjectAddPropertyListenerBlock(object, &address, DispatchQueue.main, block) == noErr
      else { continue }
      processListeners[object] = block
    }
  }

  static func processObjects() -> [AudioObjectID] {
    var address = listAddress
    var size: UInt32 = 0
    guard
      AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
      size > 0
    else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard
      AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr
    else { return [] }
    return ids
  }

  static func bundleID(_ object: AudioObjectID) -> String? {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioProcessPropertyBundleID,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr
    else { return nil }
    return value?.takeRetainedValue() as String?
  }

  static func pid(_ object: AudioObjectID) -> Int32 {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioProcessPropertyPID,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var value: pid_t = 0
    var size = UInt32(MemoryLayout<pid_t>.size)
    guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr
    else { return 0 }
    return value
  }

  static func isRunningOutput(_ object: AudioObjectID) -> Bool {
    var address = runningOutputAddress
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr
    else { return false }
    return value != 0
  }
}
```

- [ ] **Step 2: Build to verify it compiles under Swift 6 strict concurrency**

Run: `xcodebuild build -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Run the full suite so nothing regressed**

Run: `xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`
Expected: `** TEST SUCCEEDED **`, 128 tests.

- [ ] **Step 4: Commit**

```bash
git add Islet/Activities/NowPlaying/AudioProcessMonitor.swift
git commit -m "Media: detect secondary players from the CoreAudio process list"
```

---

## Task 9: `NowPlayingActivity` moves onto the source table

**Files:**
- Modify: `Islet/Activities/NowPlaying/NowPlayingActivity.swift` — everything from `import Defaults` down to the closing brace of `scheduleIdle(paused:)` (originally `:1-68`; Tasks 2 and 3 have since shifted those numbers, so work from the anchors, not the line count)
- Test: `IsletTests/NowPlayingActivityTests.swift`

**Interfaces:**
- Consumes: `MediaSourceTable`, `SourceStrip`, `AudioProcessMonitor`, `SourceID`, `AdapterUpdate`, `MediaWatcher.updates`
- Produces:
  - `@Published private(set) var NowPlayingActivity.sources: [SourceID: PlaybackState]`
  - `@Published private(set) var NowPlayingActivity.strip: [SourceID]`
  - `var NowPlayingActivity.primaryKey: SourceID? { get }`
  - `var NowPlayingActivity.primary: PlaybackState? { get }`
  - `var NowPlayingActivity.playback: PlaybackState? { get }` (shim)
  - `func NowPlayingActivity.promote(_ source: SourceID)`

**Behaviour note to preserve:** `isActive` stays `!sources.isEmpty`, i.e. adapter sources only. A
CoreAudio-only source produces a chip beside an existing hero; it never opens the island on its own,
because there would be no hero to put beside it.

- [ ] **Step 1: Write the failing test**

Create `IsletTests/NowPlayingActivityTests.swift`. The class is `@MainActor` because
`NowPlayingActivity` is, exactly as `IsletTests/ActivityCenterTests.swift:7` does it:

```swift
import XCTest

@testable import Islet

@MainActor
final class NowPlayingActivityTests: XCTestCase {
  func testFreshActivityIsInactiveAndHasNoPrimary() {
    let activity = NowPlayingActivity()
    XCTAssertTrue(activity.sources.isEmpty)
    XCTAssertTrue(activity.strip.isEmpty)
    XCTAssertNil(activity.primaryKey)
    XCTAssertNil(activity.primary)
    XCTAssertNil(activity.playback)  // the shim the existing views read
    XCTAssertFalse(activity.isActive)
  }
}
```

- [ ] **Step 2: Regenerate the project so the new test file is in the target**

Run: `xcodegen generate`
Expected: `Created project at ...`.

- [ ] **Step 3: Run the test to verify it fails**

Run: `xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`
Expected: `** TEST FAILED **`, with compile errors `value of type 'NowPlayingActivity' has no member 'sources'`,
`... has no member 'strip'`, `... has no member 'primaryKey'`, `... has no member 'primary'`.

- [ ] **Step 4: Rewrite the head of `NowPlayingActivity`**

In `Islet/Activities/NowPlaying/NowPlayingActivity.swift`, replace everything from `import Defaults`
on the first line down to and including the closing brace of `scheduleIdle(paused:)` with:

```swift
import Combine
import Defaults
import SwiftUI

@MainActor
final class NowPlayingActivity: NotchActivity, ObservableObject {
  let id = "nowPlaying"
  let priority = ActivityPriority.media

  /// Every source the MediaRemote adapter has reported, keyed by `SourceID`.
  ///
  /// At most ONE entry is populated today: the vendored adapter physically collapses concurrent
  /// players (`Vendor/mediaremote-adapter-src/src/adapter/stream.m:189`, which calls `resetAll()`
  /// on a process change at `:396-408` and `:437-449`). The keyed shape is what the design spec's
  /// "Upgrade path — fork the MediaRemote adapter for true per-source media" section needs, and
  /// dropping the fork in behind it requires no model change.
  @Published private(set) var sources: [SourceID: PlaybackState] = [:]
  /// Secondary sources drawn as chips under the hero. Adapter sources first, then CoreAudio ones,
  /// which carry no metadata at all — only "this app is producing audio".
  @Published private(set) var strip: [SourceID] = []
  @Published private(set) var adapterStatus = "Starting…"
  private(set) var activationDate: Date?

  private var table = MediaSourceTable()
  private let watcher = MediaWatcher()
  private let audio = AudioProcessMonitor()
  private var streamTask: Task<Void, Never>?
  private var expiryTask: Task<Void, Never>?
  private var audioCancellable: AnyCancellable?

  /// The source that owns the hero player.
  var primaryKey: SourceID? {
    table.primaryKey(mode: Defaults[.mediaSourceMode], priorityList: Defaults[.mediaPriorityList])
  }
  var primary: PlaybackState? { primaryKey.flatMap { sources[$0] } }
  /// Shim so the single-source views keep compiling unchanged.
  var playback: PlaybackState? { primary }

  /// CoreAudio-only sources never activate the tab on their own — there would be no hero to put
  /// them beside. They are context for an adapter source, not a source in themselves.
  var isActive: Bool { !sources.isEmpty }

  func start() {
    watcher.onStatus = { status in
      Task { @MainActor [weak self] in self?.adapterStatus = status }
    }
    watcher.start()
    audio.start()
    audioCancellable = audio.$sources
      .receive(on: DispatchQueue.main)
      .sink { [weak self] latest in self?.publish(audioSources: latest) }
    streamTask = Task { [weak self] in
      guard let self else { return }
      for await update in self.watcher.updates {
        switch update {
        case .ignored:
          continue
        case .idle:
          self.table.removeAll()
          self.activationDate = nil
          self.expiryTask?.cancel()
          self.expiryTask = nil
          self.publish()
        case .sourceGone(let key):
          guard self.table.remove(key) else { continue }
          if self.table.isEmpty { self.activationDate = nil }
          self.publish()
          self.rescheduleExpiry()
        case .nowPlaying(let key, let state):
          let wasVisible = !self.table.isEmpty
          let previous = self.table.states[key]
          self.table.upsert(key, state, now: Date())
          if !wasVisible { self.activationDate = Date() }
          if let previous, previous.title != state.title, !state.title.isEmpty {
            SneakQueue.shared.submit(Self.trackChangeSneak(for: state))
          }
          self.publish()
          self.rescheduleExpiry()
        }
      }
    }
  }

  /// Tapping a chip. See `MediaRemoteCommands.promote` for what "promote" can actually mean today.
  func promote(_ source: SourceID) {
    Haptics.perform(.alignment)
    MediaRemoteCommands.shared.promote(source)
  }

  /// Mirrors the table (and the audio monitor) into the published properties the views read.
  private func publish(audioSources: [SourceID]? = nil) {
    let mode = Defaults[.mediaSourceMode]
    let priorityList = Defaults[.mediaPriorityList]
    let adapterKeys = table.ordered(mode: mode, priorityList: priorityList)
    let merged = SourceStrip.merge(
      adapter: adapterKeys, audio: audioSources ?? audio.sources)
    let nextStrip = SourceStrip.secondary(all: merged, primary: adapterKeys.first)
    if sources != table.states { sources = table.states }
    if strip != nextStrip { strip = nextStrip }
  }

  /// One timer for the whole table, always aimed at the earliest deadline.
  private func rescheduleExpiry() {
    expiryTask?.cancel()
    guard let deadline = table.nextDeadline else {
      expiryTask = nil
      return
    }
    let delay = max(0, deadline.timeIntervalSinceNow)
    expiryTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(delay))
      guard !Task.isCancelled, let self else { return }
      self.expiryTask = nil
      self.table.expire(now: Date())
      if self.table.isEmpty { self.activationDate = nil }
      self.publish()
      self.rescheduleExpiry()
    }
  }
```

Everything from `static func trackChangeSneak` (originally line 70) to the end of the file is
unchanged, including the `tabIcon` / `compactLeading` / `compactTrailing` / `expandedView` block.

- [ ] **Step 5: Build to verify the shim keeps the views compiling**

Run: `xcodebuild build -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`
Expected: `** BUILD SUCCEEDED **`. `NowPlayingViews.swift:8`, `:24`, `:34` and `:50` still read
`activity.playback` and must not need editing.

- [ ] **Step 6: Run tests to verify they pass**

Run: `xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`
Expected: `** TEST SUCCEEDED **`, 129 tests.

- [ ] **Step 7: Manual check**

Build and run the app, start playing something in Spotify or Safari, hover the notch to expand.
Expected: the hero player looks exactly as it did before this task — 110pt artwork, title, artist,
scrubber, full transport row. Pause the track and leave it for 60 seconds; expected: the media tab
disappears from the switcher, as it did before.

- [ ] **Step 8: Commit**

```bash
git add Islet/Activities/NowPlaying/NowPlayingActivity.swift IsletTests/NowPlayingActivityTests.swift Islet.xcodeproj
git commit -m "Media: move the now playing activity onto the source table"
```

---

## Task 10: `MediaRemoteCommands.promote`

**Files:**
- Modify: `Islet/Activities/NowPlaying/MediaRemoteCommands.swift:1-43`

**Interfaces:**
- Consumes: `SourceID`, `Log.media`
- Produces:
  - `var MediaRemoteCommands.canPromoteDirectly: Bool { get }`
  - `@MainActor @discardableResult func MediaRemoteCommands.promote(_ source: SourceID) -> Bool`

**No unit test — verified by build plus a manual check.** `canPromoteDirectly` depends on the host
OS's private framework, which is not something to assert in CI.

**Read this before implementing.** `MRMediaRemoteSetNowPlayingPlayerIfPossible` *does* resolve through
the existing `CFBundleGetFunctionPointerForName` path (`MediaRemoteCommands.swift:23-30`) — probed on
this machine, non-nil pointer. It is nonetheless not callable: it takes an `MRPlayerPath` object, and
the only calls that produce one (`MRMediaRemoteGetPlayers`, `MRMediaRemoteGetPlayersForClient`) are
the entitled *reads* macOS 15.4 locked down — the entire reason `MediaWatcher` shells out to
`/usr/bin/perl` (`MediaWatcher.swift:70-71`). Passing `nil` into a private framework function that
expects an object is undefined behaviour and can take the whole app down, so this plan resolves the
symbol, records whether it resolved, and does **not** invoke it. The fallback that actually works is
activating the owning app. Lifting this is part of the design spec's "Upgrade path — fork the
MediaRemote adapter for true per-source media" section.

- [ ] **Step 1: Add the symbol probe and `promote`**

In `Islet/Activities/NowPlaying/MediaRemoteCommands.swift`, replace lines 1-31 (from `import Foundation`
through the closing brace of `init`) with:

```swift
import AppKit
import Foundation

/// Send-side MediaRemote still works in-process on macOS 15.4+ (only reads were locked down).
/// Command codes match MRMediaRemoteCommand: play=0, pause=1, toggle=2, next=4, previous=5.
final class MediaRemoteCommands: @unchecked Sendable {
  static let shared = MediaRemoteCommands()

  private typealias SendCommand = @convention(c) (Int, AnyObject?) -> Bool
  private typealias SetElapsed = @convention(c) (Double) -> Void
  private typealias SetPlayerIfPossible = @convention(c) (AnyObject?) -> Bool
  private let sendCommand: SendCommand?
  private let setElapsed: SetElapsed?
  private let setPlayerIfPossible: SetPlayerIfPossible?

  private init() {
    guard
      let bundle = CFBundleCreate(
        kCFAllocatorDefault,
        NSURL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework"))
    else {
      sendCommand = nil
      setElapsed = nil
      setPlayerIfPossible = nil
      return
    }
    sendCommand = CFBundleGetFunctionPointerForName(
      bundle, "MRMediaRemoteSendCommand" as CFString
    )
    .map { unsafeBitCast($0, to: SendCommand.self) }
    setElapsed = CFBundleGetFunctionPointerForName(
      bundle, "MRMediaRemoteSetElapsedTime" as CFString
    )
    .map { unsafeBitCast($0, to: SetElapsed.self) }
    setPlayerIfPossible = CFBundleGetFunctionPointerForName(
      bundle, "MRMediaRemoteSetNowPlayingPlayerIfPossible" as CFString
    )
    .map { unsafeBitCast($0, to: SetPlayerIfPossible.self) }
  }

  /// Whether `MRMediaRemoteSetNowPlayingPlayerIfPossible` resolved in this process. Diagnostic
  /// only — see `promote(_:)` for why it is not called.
  var canPromoteDirectly: Bool { setPlayerIfPossible != nil }

  /// Makes `source` the player the user is looking at.
  ///
  /// `MRMediaRemoteSetNowPlayingPlayerIfPossible` takes an `MRPlayerPath` object, and the only
  /// calls that produce one are the entitled reads macOS 15.4 locked down — the reason
  /// `MediaWatcher` shells out to /usr/bin/perl at all. Islet cannot hand it a player from
  /// in-process, and passing nil into a private framework is undefined behaviour, so the symbol is
  /// resolved (the fork described in the design spec's "Upgrade path — fork the MediaRemote adapter
  /// for true per-source media" section will use it) but never invoked. Activating the owning app
  /// is the fallback that works today, and is what tapping a chip means anyway.
  @MainActor @discardableResult
  func promote(_ source: SourceID) -> Bool {
    if !canPromoteDirectly {
      Log.media.notice("MRMediaRemoteSetNowPlayingPlayerIfPossible did not resolve")
    }
    return Self.activateApp(pid: source.pid, bundleID: source.displayBundleIdentifier)
  }

  @MainActor
  private static func activateApp(pid: Int32, bundleID: String) -> Bool {
    if let app = NSRunningApplication(processIdentifier: pid),
      app.bundleIdentifier == bundleID
    {
      return app.activate()
    }
    if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
      return app.activate()
    }
    Log.media.notice("No running application for \(bundleID, privacy: .public); promote is a no-op")
    return false
  }
```

Everything from `func play()` (old line 33) to the end of the file is unchanged.

- [ ] **Step 2: Build**

Run: `xcodebuild build -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Run tests so nothing regressed**

Run: `xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`
Expected: `** TEST SUCCEEDED **`, 129 tests.

- [ ] **Step 4: Commit**

```bash
git add Islet/Activities/NowPlaying/MediaRemoteCommands.swift
git commit -m "Media: promote a source by activating the app that owns it"
```

---

## Task 11: Hero plus source strip UI

**Files:**
- Modify: `Islet/Activities/NowPlaying/NowPlayingViews.swift:44-165`

**Interfaces:**
- Consumes: `NowPlayingActivity.strip`, `NowPlayingActivity.sources`, `NowPlayingActivity.promote(_:)`, `SourceStrip.layout(_:limit:)`, `ExpandedPlayerView.appIcon(for:)` (`NowPlayingViews.swift:154-159`)
- Produces: `static func ExpandedPlayerView.appName(for bundleID: String) -> String`

**No unit test — verified by build plus a manual check.** The reduction it draws
(`SourceStrip.layout`) is already covered by `IsletTests/SourceStripTests.swift`.

**Vertical budget, because it is tight.** The expanded island is 480 × 190
(`Metrics.swift:4`). `ExpandedContainerView` reserves the notch band at the top and 12pt at the
bottom (`ExpandedContainerView.swift:40`, `:44`), leaving roughly 146pt of content on a MacBook with
a ~32pt notch. The hero measures ~113pt (110pt artwork column). The strip is therefore fixed at 22pt
with 6pt of spacing — 28pt — and must not grow. Do not add padding to it.

- [ ] **Step 1: Restructure `ExpandedPlayerView.body` and add the strip**

In `Islet/Activities/NowPlaying/NowPlayingViews.swift`, replace lines 49-76 (from `var body: some View {`
down to and including the closing brace of `body`) with:

```swift
  var body: some View {
    VStack(spacing: 6) {
      if let pb = activity.playback {
        hero(pb)
      } else {
        Text("Nothing playing")
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      if !activity.strip.isEmpty { sourceStrip }
    }
    .foregroundStyle(.white)
  }

  private func hero(_ pb: PlaybackState) -> some View {
    HStack(spacing: 16) {
      artwork(pb)
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 6) {
          if let icon = Self.appIcon(for: pb.sourceBundleIdentifier) {
            Image(nsImage: icon).resizable().frame(width: 14, height: 14)
          }
          Text(pb.title).font(.headline).lineLimit(1)
          if pb.isAdvertisement {
            Text("Ad")
              .font(.caption2.weight(.bold))
              .padding(.horizontal, 5).padding(.vertical, 1)
              .background(Capsule().fill(.yellow.opacity(0.25)))
              .foregroundStyle(.yellow)
          }
        }
        Text(pb.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
        scrubber(pb)
        controls(pb)
      }
    }
  }

  /// Other apps producing audio right now. Chips only: no title, no artist, no transport — that is
  /// the ceiling of the non-fork approach, and it is why the design spec's "Upgrade path — fork the
  /// MediaRemote adapter for true per-source media" section exists.
  private var sourceStrip: some View {
    let layout = SourceStrip.layout(activity.strip)
    return HStack(spacing: 6) {
      ForEach(layout.shown, id: \.self) { source in
        Button {
          activity.promote(source)
        } label: {
          chip(source)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
          "Switch to \(Self.appName(for: source.displayBundleIdentifier))")
      }
      if layout.overflow > 0 {
        Text("+\(layout.overflow)")
          .font(.caption2.weight(.semibold)).monospacedDigit()
          .foregroundStyle(.secondary)
          .padding(.horizontal, 6)
          .frame(height: 22)
          .background(Capsule().fill(.white.opacity(0.08)))
          .accessibilityLabel("\(layout.overflow) more sources")
      }
      Spacer(minLength: 0)
    }
    .frame(height: 22)
  }

  private func chip(_ source: SourceID) -> some View {
    // CoreAudio sources have no PlaybackState; they are listed precisely because they are
    // producing output, so absent means playing.
    let isPlaying = activity.sources[source]?.isPlaying ?? true
    return HStack(spacing: 4) {
      if let icon = Self.appIcon(for: source.displayBundleIdentifier) {
        Image(nsImage: icon).resizable().frame(width: 14, height: 14)
      } else {
        Image(systemName: "speaker.wave.2.fill").font(.caption2)
      }
      Circle()
        .fill(isPlaying ? Color.green : Color.secondary)
        .frame(width: 5, height: 5)
    }
    .padding(.horizontal, 6)
    .frame(height: 22)
    .background(Capsule().fill(.white.opacity(0.10)))
    .opacity(0.7)
  }
```

- [ ] **Step 2: Add the `appName` resolver next to `appIcon`**

In `Islet/Activities/NowPlaying/NowPlayingViews.swift`, immediately after the closing brace of
`appIcon(for:)` (originally line 159), add:

```swift
  /// Human-readable app name for the chip's accessibility label.
  static func appName(for bundleID: String) -> String {
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    else { return bundleID }
    return FileManager.default.displayName(atPath: url.path)
  }
```

- [ ] **Step 3: Build**

Run: `xcodebuild build -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Run tests so nothing regressed**

Run: `xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`
Expected: `** TEST SUCCEEDED **`, 129 tests.

- [ ] **Step 5: Manual check**

1. Build and run the app. Play something in Spotify (or Apple Music), then start a YouTube video in
   Chrome or Safari. Expand the island.
2. Expected: the hero shows the Spotify track unchanged, and a single dimmed chip appears under the
   transport row with the browser's app icon and a green dot.
3. Expected: **nothing is clipped at the bottom of the island.** If the transport row or the chip
   strip is cut off, see "Deferred follow-ups" below for the one-line tall-tier opt-in.
4. Click the chip. Expected: the browser comes to the front. Check Console.app filtered on subsystem
   `dev.cnucifora.Islet`, category `media` — there should be no
   "MRMediaRemoteSetNowPlayingPlayerIfPossible did not resolve" line on a healthy system, and no
   crash either way.
5. Stop the browser audio. Expected: the chip disappears within a second, with no polling (the
   CoreAudio listener drives it).

- [ ] **Step 6: Commit**

```bash
git add Islet/Activities/NowPlaying/NowPlayingViews.swift
git commit -m "Media: draw secondary sources as a chip strip under the hero"
```

---

## Task 12: Attribute the track-change sneak to its app

**Files:**
- Modify: `Islet/Activities/NowPlaying/NowPlayingActivity.swift` (the `trackChangeSneak` static)
- Test: `IsletTests/NowPlayingActivityTests.swift` (two tests appended)

**Interfaces:**
- Consumes: `PlaybackState.sourceBundleIdentifier`, `ExpandedPlayerView.appName(for:)`
- Produces: unchanged signature `static func NowPlayingActivity.trackChangeSneak(for state: PlaybackState) -> Sneak`

Today the sneak fires on any title change with no indication of which app it came from
(`NowPlayingActivity.swift:70-90`). This adds the app to the spoken announcement and uses the app
icon instead of the generic music note when there is no artwork. Routing the sneak through the Phase
3 `SystemEventBus` is a separate, optional change — see "Deferred follow-ups".

- [ ] **Step 1: Write the failing test**

Append these two tests to `IsletTests/NowPlayingActivityTests.swift`, inside the class (which is
already `@MainActor`):

```swift
  func testTrackChangeSneakNamesTheAppItCameFrom() {
    var state = PlaybackState()
    state.title = "Paranoid Android"
    state.artist = "Radiohead"
    state.bundleIdentifier = "com.apple.WebKit.GPU"
    state.parentBundleIdentifier = "com.apple.Safari"
    let sneak = NowPlayingActivity.trackChangeSneak(for: state)
    XCTAssertEqual(sneak.source, "track")
    XCTAssertEqual(sneak.announcement, "Now playing Paranoid Android by Radiohead in Safari")
  }

  func testTrackChangeSneakOmitsTheAppWhenItCannotBeNamed() {
    var state = PlaybackState()
    state.title = "Untitled"
    state.bundleIdentifier = ""
    let sneak = NowPlayingActivity.trackChangeSneak(for: state)
    XCTAssertEqual(sneak.announcement, "Now playing Untitled")
  }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`
Expected: `** TEST FAILED **`, with
`XCTAssertEqual failed: ("Optional("Now playing Paranoid Android by Radiohead")") is not equal to ("Optional("Now playing Paranoid Android by Radiohead in Safari")")`.

- [ ] **Step 3: Rewrite `trackChangeSneak`**

In `Islet/Activities/NowPlaying/NowPlayingActivity.swift`, replace the whole
`static func trackChangeSneak(for state: PlaybackState) -> Sneak` method (originally lines 70-90) with:

```swift
  static func trackChangeSneak(for state: PlaybackState) -> Sneak {
    let appName = state.sourceBundleIdentifier.isEmpty
      ? nil : ExpandedPlayerView.appName(for: state.sourceBundleIdentifier)
    let thumb: AnyView =
      if let data = state.artwork, let img = NSImage(data: data) {
        AnyView(
          Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
            .frame(width: 16, height: 16)
            .clipShape(RoundedRectangle(cornerRadius: 4)))
      } else if let icon = ExpandedPlayerView.appIcon(for: state.sourceBundleIdentifier) {
        // No artwork, but we know the app — attribution beats a generic music note.
        AnyView(
          Image(nsImage: icon).resizable()
            .frame(width: 16, height: 16)
            .clipShape(RoundedRectangle(cornerRadius: 4)))
      } else {
        AnyView(Image(systemName: "music.note").font(.caption2).foregroundStyle(.secondary))
      }
    let label = state.artist.isEmpty ? state.title : "\(state.title) — \(state.artist)"
    var announcement =
      state.artist.isEmpty
      ? "Now playing \(state.title)" : "Now playing \(state.title) by \(state.artist)"
    if let appName, appName != state.sourceBundleIdentifier {
      announcement += " in \(appName)"
    }
    return Sneak(
      source: "track",
      leading: thumb,
      trailing: AnyView(
        Text(label)
          .font(.caption2).foregroundStyle(.white)
          .lineLimit(1).frame(maxWidth: 170)),
      announcement: announcement)
  }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`
Expected: `** TEST SUCCEEDED **`, 131 tests.

> If `testTrackChangeSneakNamesTheAppItCameFrom` fails because Safari is not installed at
> `/Applications/Safari.app` on the machine running the suite, `appName` falls back to the bundle
> identifier and the announcement ends in `in com.apple.Safari`. In that case change the expected
> string in the test to match, and leave the implementation alone — the guard
> `appName != state.sourceBundleIdentifier` already suppresses the suffix when nothing resolved.

- [ ] **Step 5: Commit**

```bash
git add Islet/Activities/NowPlaying/NowPlayingActivity.swift IsletTests/NowPlayingActivityTests.swift
git commit -m "Media: attribute the track change sneak to the app it came from"
```

---

## Task 13: Settings copy for the retired filter semantics

**Files:**
- Modify: `Islet/Settings/SettingsView.swift:75-96`

**Interfaces:**
- Consumes: `Defaults[.mediaSourceMode]`, `Defaults[.mediaPriorityList]` (`Islet/Settings/DefaultsKeys.swift:11-14`, unchanged)
- Produces: nothing

**No unit test — verified by build plus a manual check.** The section labels currently promise
filtering ("Prioritized players", a list that drops everything unlisted), which Task 2 retired.

- [ ] **Step 1: Rewrite the Media section**

In `Islet/Settings/SettingsView.swift`, replace lines 75-96 (the whole `Section("Media")` block) with:

```swift
      Section("Media") {
        Picker("Player order", selection: $sourceMode) {
          Text("Whatever is playing").tag(MediaSourceMode.auto)
          Text("My order").tag(MediaSourceMode.prioritized)
        }
        Text(
          "Every player is shown. This picks which one gets the big player when more than one is going; the rest appear as icons underneath."
        )
        .font(.caption).foregroundStyle(.secondary)
        if sourceMode == .prioritized {
          List {
            ForEach(priorityList, id: \.self) { Text($0).font(.callout.monospaced()) }
              .onMove { priorityList.move(fromOffsets: $0, toOffset: $1) }
              .onDelete { priorityList.remove(atOffsets: $0) }
          }
          .frame(height: 90)
          HStack {
            TextField("Bundle ID (e.g. com.spotify.client)", text: $newBundleID)
            Button("Add") {
              priorityList.append(newBundleID)
              newBundleID = ""
            }
            .disabled(newBundleID.isEmpty)
          }
        }
      }
```

- [ ] **Step 2: Build**

Run: `xcodebuild build -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Run tests so nothing regressed**

Run: `xcodebuild test -project Islet.xcodeproj -scheme Islet -destination 'platform=macOS' 2>&1 | tail -30`
Expected: `** TEST SUCCEEDED **`, 131 tests.

- [ ] **Step 4: Manual check**

Open Settings (menu bar icon → Settings…). Expected: the Media section reads "Player order" with the
two options "Whatever is playing" and "My order", and the explanatory caption underneath. Switching
to "My order" still shows the editable bundle-identifier list. With two players going, changing the
order changes which one owns the hero and which becomes a chip.

- [ ] **Step 5: Commit**

```bash
git add Islet/Settings/SettingsView.swift
git commit -m "Settings: describe the media priority list as display order"
```

---

## Deferred follow-ups

Not part of Phase 5. Recorded here with exact code so nobody has to rediscover them.

**1. Tall tier for the media tab (needs Phase 1.2).** If the manual check in Task 11 step 5 shows the
strip clipping at the bottom of the island, and Phase 1.2 has landed
(`Metrics.tallExpandedHeight`, `NotchActivity.preferredExpandedHeight`), add this to
`NowPlayingActivity`:

```swift
  /// A second source adds a 22pt strip plus 6pt of spacing, which does not fit the base tier.
  var preferredExpandedHeight: CGFloat {
    strip.isEmpty ? Metrics.expandedSize.height : Metrics.tallExpandedHeight
  }
```

Do not add this before Phase 1.2 lands — `preferredExpandedHeight` does not exist until then, and
the island will not resize.

**2. Route the track-change sneak through the Phase 3 bus.** Once `SystemEventBus` exists, replace
the `SneakQueue.shared.submit(Self.trackChangeSneak(for: state))` call in
`NowPlayingActivity.start()` with:

```swift
            SystemEventBus.shared.emit(
              SystemEvent(
                id: UUID(), sourceID: "track", icon: "music.note",
                title: state.title,
                subtitle: state.artist.isEmpty ? nil : state.artist,
                accentHex: "#34C759", motion: .generic, duration: 2,
                announcement: "Now playing \(state.title)"))
```

That buys per-source enable/disable through `Defaults[.disabledEventSources]` and the debug menu for
free. It costs the artwork thumbnail, since `SystemEvent` carries an SF Symbol name rather than an
`AnyView` — decide whether that trade is worth making before doing it.

**3. Fork the adapter.** The only route to title, artist, artwork and independent transport for every
concurrent source. Fully scoped in
`docs/superpowers/specs/2026-07-29-power-stats-events-media-design.md`, section
**"Upgrade path — fork the MediaRemote adapter for true per-source media"**, including the eight
concrete work items and the cost/risk list. The model built by this plan is its prerequisite and
needs no change when it lands: `sources` simply starts receiving more than one populated entry, and
the chips in `ExpandedPlayerView.sourceStrip` upgrade to full rows.
