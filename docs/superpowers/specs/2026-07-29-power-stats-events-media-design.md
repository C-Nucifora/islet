# Islet — power screen, system stats, event animations, multi-source media, position drift

Date: 2026-07-29
Status: approved, ready for implementation planning

Five asks, scoped together because three of them contend for the same 146pt of vertical space and
two of them need the same infrastructure.

1. Rebuild the power screen to AlDente-level information density.
2. Add Stats-style system resource readouts.
3. Give every system event an animation, including Wi-Fi, Bluetooth and AirDrop.
4. Support multiple simultaneous media sources in the expanded panel.
5. Fix the collapsed island drifting right and sliding under the hardware notch.

---

## Decisions taken

| # | Decision | Chosen |
|---|---|---|
| 1 | Power scope | Read-only telemetry parity. **No charge control.** |
| 2 | Expanded island size | Per-tab height tiers |
| 3 | System metrics location | Dedicated System tab |
| 4 | Multi-source media | See + switch (no adapter fork in this pass) |
| 5 | Event source scope | All three tiers, Tier 3 labelled heuristic |
| 6 | Motion vocabulary | Bespoke per source |
| 7 | Metric display style | Build every style, configurable per metric in Settings |
| 8 | Battery health | Show both numbers, labelled |

Charge control is explicitly out of scope and should stay out. It requires SMC writes behind an
`SMAppService` root daemon, which forces Islet from ad-hoc signing to Developer ID with hardened
runtime and an entitlements file, permanently rules out the App Store, duplicates macOS 26's own
80% limit, and was already assessed as "high risk, recommend not shipping" in
`docs/research/2026-07-23-improvement-roadmap.md:79`. Battery Toolkit, the reference implementation
for this architecture, was archived on 2026-03-21.

---

## Phase 0 — Position drift bug

### Diagnosis

`NotchRootView.islandOffset` (`Islet/UI/NotchRootView.swift:58-62`) aligns the drawn island using
`vm.geometry.notchRect.midX - vm.panelFrame.midX` — the frame the app *requested* — while the island
is actually drawn centred in the *real* window (`:128` + `:103`). Any divergence between requested
and real frame maps 1:1 to a horizontal shift of the drawn island.

Divergence is possible and, once it happens, permanent:

- `NotchPanel` (24 lines) does not override `constrainFrameRect(_:to:)`, so AppKit is free to adjust
  the rect passed to `setFrame`. The adjustment is never fed back.
- `panel.setFrame(frame, display: false)` (`Islet/Core/ScreenManager.swift:87`) is fire-and-forget;
  nothing reads `panel.frame` back.
- The only reposition path sits behind `.removeDuplicates()` (`ScreenManager.swift:84`), so
  republishing an unchanged value emits nothing.
- No `activeSpaceDidChange` / `didActivateApplication` / `didMove` observer re-asserts the frame. The
  Space observer that exists (`ScreenManager.swift:99-105`) is registered only when `hideInFullscreen`
  is on — which defaults to `false` (`DefaultsKeys.swift:28`) — and only toggles visibility.
- `targetPanelFrame` returns the **same value for `.closed` and `.peek`**
  (`Islet/Core/NotchViewModel.swift:82-87`), so hovering the notch never republishes. A drift survives
  every hover and clears only on a real expand.

This is a regression against the spec's own invariant — "positioned once and never moves"
(`docs/superpowers/specs/2026-07-22-islet-design.md:65`) — introduced by `372c645`, which replaced a
constant `.offset(x: (T − L)/2)` with the window-relative `islandOffset`.

**Diagnostic that confirms it:** when drifted, expanding the island snaps it back into alignment;
hovering alone does not.

### Ruled out

- **frame vs visibleFrame on x** — `visibleFrame` appears once (`NSScreen+Notch.swift:31`) and feeds
  only `menuBarHeight`, which affects the fallback notch's *height*. Every x term uses `screenFrame`.
- **Stale width** — origin and width are always computed in one expression from the same inputs
  (`NotchGeometry.swift:53`, `:69-70`). `61cf4d5` (640 → 480) is **not** implicated.
- **Centring on the wrong screen** — `NSScreen.main` is read only in `targetScreens()` at rebuild time;
  per-panel geometry always comes from that panel's own `NSScreen`.
- **SwiftUI resizing the window** — no `setContentSize` / `sizeToFit` / `sizingOptions` in the tree.
- **Accumulating fractional error** — every frame is recomputed from `screenFrame`, never from the
  previous frame.
- **`collectionBehavior`** — `[.fullScreenAuxiliary, .stationary, .canJoinAllSpaces, .ignoresCycle]`
  is the documented-correct combination.

### Fix

1. `NotchPanel.constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }`.
2. `NotchViewModel` gains `@Published private(set) var actualPanelFrame: CGRect`. `ScreenManager` reads
   `panel.frame` back after every `setFrame` and pushes it in. `islandOffset` uses `actualPanelFrame`.
   Log whenever `panel.frame != vm.panelFrame` after a set.
3. `ScreenManager.Instance.reassert()` — unconditional `panel.setFrame(vm.panelFrame, display: false)`,
   bypassing `removeDuplicates`. Called from `NSWorkspace.activeSpaceDidChangeNotification` (registered
   unconditionally, not gated on `hideInFullscreen`), `NSWorkspace.didActivateApplicationNotification`,
   an undebounced `NSApplication.didChangeScreenParametersNotification` (in addition to the existing
   debounced rebuild), and `NSWindow.didMoveNotification` on the panel — the last with a re-entrancy
   guard so `reassert()` cannot loop.
4. `NotchGeometry` stores `auxLeftWidth` and derives `notchRect.minX` as
   `screenFrame.minX + auxLeftWidth` when `hasHardwareNotch`, instead of `midX - notchWidth/2`. The
   current form shifts the island by `(auxRight − auxLeft)/2` — rightward when `auxRight > auxLeft`.
5. Hardware-notch stickiness: cache the last known notch size per display UUID; refuse to downgrade a
   `CGDisplayIsBuiltin` screen to the 200pt fallback (`NotchGeometry.swift:16`, `:23`) when the aux
   areas transiently read empty. Written as a defensive floor, not as a claim about undocumented API
   behaviour — log the transition before relying on it.
6. `NotchViewModel.debounce` (`:133-143`) clears `shrinkTask` inside the body, which is skipped on
   cancel — a cancelled shrink strands `shrinkTask` non-nil and permanently blocks the
   `guard … shrinkTask == nil` at `:99`. Clear it on the cancelled path too.
7. The two independent `onGeometryChange` closures under `.id(...)` (`NotchRootView.swift:161-172`) let
   an outgoing subtree write the shared `@State` widths after the incoming one, stranding a stale
   measurement. Key the widths to the same identity, or reduce through a single `onPreferenceChange`.

### Testability

Lift the alignment maths out of the View into `NotchGeometry` as pure functions:

```swift
extension NotchGeometry {
  func islandOffset(inPanel panel: CGRect, compactLeading: CGFloat, compactTrailing: CGFloat) -> CGFloat
  func collapsedIslandRect(inPanel panel: CGRect, compactLeading: CGFloat, compactTrailing: CGFloat) -> CGRect
}
```

New cases for `IsletTests/NotchGeometryTests.swift` (every existing fixture uses a screen at origin
`(0,0)` with symmetric 716/716 aux areas, so none of this is covered today):

- **The regression:** island screen position is invariant under an arbitrary panel frame. Feed a
  drifted panel (`sized.offsetBy(dx: 37)`, `dx: -12.5`, and the expanded frame) and assert
  `body.minX == notchRect.minX - closedOversize - L` every time.
- Panels centre on the notch for a screen at a non-zero origin (secondary display).
- A sized panel fully contains its island on both flanks, for asymmetric slot widths.
- `notchRect.minX` follows `auxLeftWidth`, not the screen centre (fails today: 716 vs 712).
- A known-notched built-in display keeps its notch when aux areas read empty.

---

## Phase 1 — Shared infrastructure

Everything after this depends on some of it. Land it in one pass.

**1.1 `Islet/Core/Motion.swift`** — move the four animation constants out of `Metrics.swift:20-26`
(five call sites), add per-source motion profiles, and add `Motion.gated(_:)` which collapses any
animation to `nil` when `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` is true. Nothing
in the codebase checks Reduce Motion today.

**1.2 Per-tab height tiers.** `Metrics.expandedSize` is a single global feeding
`NotchGeometry.expandedRect` / `panelFrame` and the mask in `NotchRootView`. Introduce a per-activity
`preferredExpandedHeight` (default 190; power and system tabs request 250) threaded through
`NotchGeometry` and the `ScreenManager` resize path. **This must land before any Phase 2 or Phase 4
layout is authored** — retrofitting it costs both layouts twice.

**1.3 Switcher-bar overflow.** `ExpandedContainerView.swift:54-88` renders one 26×20 chip per active
activity in a left ear of ~135.5pt. Eight chips already total ~497pt in a 480pt row — a pre-existing
break, and a System tab makes it a ninth. Shrink chips to 22pt and make the ear horizontally
scrollable with the selected chip kept visible.

**1.4 Refcounted visibility gate.** `BatteryMonitor.setLiveMetrics` (`:39-44`) is a Bool. With two
monitors sharing the pattern, a cross-fade's `onDisappear` fires after the incoming view's `onAppear`
and silently freezes sampling. Replace with `retain()` / `release()`.

**1.5 Bulk IORegistry read.** `BatteryMonitor.refresh` (`:52-56`) walks three IORegistry sources at
1 Hz with N per-key `IORegistryEntryCreateCFProperty` calls and republishes unconditionally. Replace
with one `IORegistryEntryCreateCFProperties` pass plus an `Equatable` diff before assigning to the
`@Published` (`BatteryMetrics` is already `Equatable`).

**1.6 Generalised threshold-crossing detector**, extracted from `BatteryEventDetector`
(`BatteryState.swift:17-35`). Reused for peripheral low battery, charge complete, low disk space, and
CPU/thermal thresholds.

---

## Phase 2 — Power screen

Target: 480 × 250, content box ~452 × 206.

```
╭───────╮   Health 90%    Raw 86%     Cycles 142 / 1000
│  87%  │   Temp 31.2°C   Volt 11.25V Amps −0.49 A
│ ◍ring │   Capacity 5364 / 6249 mAh  Condition Normal
╰───────╯   Left 4h 12m   Charger 96 W · pd charger
 Charging  ────────────────────────────────────────────
 ⚡ Adapter 96.0 W  →  System 28.1 W  →  Battery +67.9 W
 ────────────────────────────────────────────────────
 🖱 92%   ⌨️ 78%   🖲 55%                  Low Power ○
```

Pinned `.topLeading` (today it floats centred, unlike `PortsView.swift:81`).

### New telemetry — all confirmed present on this machine, none guessed

From `AppleSmartBattery`, currently read-but-not-displayed or not read at all:

- `Voltage`, `InstantAmperage` (the un-averaged figure AlDente shows; both use the 2^64 two's-complement
  encoding already handled in `BatteryMetrics.swift:47-49`)
- `AppleRawMaxCapacity` / `NominalChargeCapacity` / `DesignCapacity` → the "5364 / 6249 mAh" line and
  both health numbers
- `DesignCycleCount9C` → renders cycles as "142 / 1000"
- `ChargerData.NotChargingReason` — a bitfield. The current three-string status
  (`BatteryActivity.swift:106-110`) renders AC-attached-but-not-charging as the misleading
  "Plugged in"; this replaces it with the real reason.
- `AdapterDetails.Description` ("pd charger"), `AdapterVoltage`, `Current`, `IsWireless`,
  `AdapterPowerTier`, and `UsbHvcMenu` (the negotiated PD ladder: 5V/2.96A … 20V/1.49A)
- `PowerTelemetryData` — `SystemPowerIn`, `SystemVoltageIn`, `SystemCurrentIn`, `SystemLoad`,
  `BatteryPower`, `AdapterEfficiencyLoss`. This is the entire Power Flow row.
- `BatteryData.LifetimeData` — `AverageTemperature`, `MaximumTemperature`, `MinimumTemperature`,
  `TotalOperatingTime`. A free history panel if wanted later.

From IOPS: `kIOPSBatteryHealthKey` ("Good"/"Fair"/"Poor") and `kIOPSBatteryHealthConditionKey`
("Normal"). Prefer the public, documented `IOPSCopyExternalPowerAdapterDetails()` as the primary
adapter source with the raw registry `AdapterDetails` as fallback.

Low Power Mode: `ProcessInfo.processInfo.isLowPowerModeEnabled` plus
`.NSProcessInfoPowerStateDidChange`. Never shell out to `pmset`.

### Health, both ways

- **Health** = `NominalChargeCapacity / DesignCapacity` ≈ 88–90%, matching System Settings → Battery.
- **Raw** = `AppleRawMaxCapacity / DesignCapacity` ≈ 86%, matching AlDente and coconutBattery.

Two labelled tiles. Nothing worse than two of your own readouts disagreeing with no explanation.

### Other changes

- `isActive` drops `&& onAC` (`BatteryActivity.swift:16-18`) so the tab survives unplugging.
- All undocumented keys (`PowerTelemetryData`, `UsbHvcMenu`, `NotChargingReason`, `BatteryData`)
  optional-parsed, tile omitted when absent, exactly as `BatteryMetrics.hasAny` already does.
- Volatile values (amperage, watts, temperature) get light smoothing or the panel strobes at 1 Hz.
- Pure-function tests for the health formulas, sign handling, unit conversion and formatting, beside
  `BatteryEventDetectorTests`. None of this logic is tested today.

---

## Phase 3 — SystemEventBus and event animations

### Architecture

`Sneak` (`Activities/Sneaks/Sneak.swift:4-12`) carries `source`, `duration`, two `AnyView`s and an
announcement — no kind, icon, accent or urgency, so nothing downstream can style or reason about an
event. Four sources emit today (battery AC/low, audio device, track change, timer) with hand-typed
coalescing keys and inconsistent gating: battery and audio check a Defaults key, timer and track
change check nothing.

Add, mirroring `ActivityCenter` (`:13-19`, `:34-40`):

- `SystemEvent` — `id`, `source`, `kind`, `icon`, `title`, `subtitle`, `accent`, `urgency`,
  `motionProfile`.
- `SystemEventSource` protocol — `id`, `displayName`, `tier`, `start()`, `stop()`.
- `SystemEventBus` — registration, per-source enable/disable through Defaults, sources started and
  stopped on toggle so a disabled source costs zero observation. Feeds the existing `SneakQueue`
  unchanged.

Settings section and a debug menu (fire any event without the hardware) both generate from the
catalogue. The four existing producers migrate onto the bus.

### Sources

**Tier 1 — free, callback-driven, always reliable.**

| Source | API |
|---|---|
| USB attach/detach | Already fully observed in `Ports.swift:80-112` and completely silent. Cheapest win in the repo — just diff and emit. |
| Volume mount/unmount | `NSWorkspace.didMountNotification` / `didUnmountNotification` |
| Display connect/disconnect | `NSApplication.didChangeScreenParametersNotification` + screen-set diff |
| Sleep/wake | `NSWorkspace.willSleepNotification` / `didWakeNotification` |
| Charge complete | New event in `BatteryEventDetector`; not modelled today (`BatteryState.swift:20-34`) |
| Low Power Mode | `.NSProcessInfoPowerStateDidChange` |
| Peripheral low battery | `PeripheralBattery` is read every tick and never announced |

**Tier 2 — public, reliable, one optional prompt.**

| Source | API | Note |
|---|---|---|
| Wi-Fi connect/disconnect/SSID | `CWWiFiClient` + `CWEventDelegate` (`ssidDidChangeForWiFiInterface`, `linkDidChangeForWiFiInterface`, `powerStateDidChangeForWiFiInterface`) | Reading the SSID *name* triggers a one-time Location Services prompt on macOS 14+. Nameless connect/disconnect is free. Show the name, prompt once, degrade to nameless on denial. |
| Bluetooth connect/disconnect | `IOBluetoothDevice` register-for-connect + per-device disconnect notification | No prompt |
| Screen lock/unlock | `DistributedNotificationCenter` `com.apple.screenIsLocked` / `com.apple.screenIsUnlocked` | |
| Caps lock | `NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged)` | Event tap already exists for HUD keys |
| Screenshot taken | `NSMetadataQuery` on `kMDItemIsScreenCapture` | |

**Tier 3 — labelled "heuristic" in Settings, because they will occasionally be wrong.**

| Source | API | Honest limitation |
|---|---|---|
| AirDrop outbound | `NSSharingServiceDelegate` | Real and reliable — the only trustworthy AirDrop signal |
| AirDrop inbound | FSEvents on `~/Downloads` + `LSQuarantineAgentName == "sharingd"` | Fires *after* the transfer completes. No progress, no sender name. |
| Focus mode | File watch on `~/Library/DoNotDisturb/DB/Assertions.json` | Chosen over an App Intents `SetFocusFilterIntent` extension, which would need a whole new target in `project.yml`. Format is undocumented and can change. |
| VPN up/down | `getifaddrs` diff on `utun*` interfaces | False-positives on Handoff and iCloud Private Relay, both of which create utun interfaces |

### Motion — bespoke per source

Wi-Fi arcs fill outward · Bluetooth glyph pulses · USB plug slides in · AirDrop radar sweep · drive
icon rises · display glyph expands · charge complete draws a checkmark · low power pulses amber ·
screenshot flashes and shrinks · lock snaps shut · sleep fades down · peripheral low battery shakes.

Built with `symbolEffect`, `phaseAnimator`, `contentTransition` and `matchedGeometryEffect` — none of
which appear anywhere in the codebase today.

**Hard constraint: all overshoot must be inward.** `Metrics.islandMargin` is 4pt and
`collapsedDepth` is 12pt, and both the `NotchShape` mask and the panel itself clip. Scale from
0.6 → 1.0, never past 1.0. Widening the margins would give back the menu-bar clickability that
`372c645` and `61cf4d5` were fighting for.

**Burst coalescing.** Docking fires display + USB hub + power + audio device + volume mount within
~2s. At the current 2s duration + 250ms gap that is ~11 seconds of island churn. Coalesce a burst
into one summary sneak ("MacBook docked — 4 devices") and cap queue depth.

All motion gated on Reduce Motion via `Motion.gated(_:)`.

---

## Phase 4 — System tab

New `SystemActivity` + `SystemMetricsMonitor`. `isActive` gated on a threshold (sustained CPU > 80%,
or `thermalState != .nominal`) rather than a bare Defaults Bool — otherwise it becomes a permanent
secondary glyph in `NotchRootView.swift:24-31` and, if the glyph carries digits, drives
`onGeometryChange` → `updateCompactWidths` → `NSPanel.setFrame` once per second forever.

```
CPU   38%  ▁▂▅▃▂▁▄█▅▃   P 44%  E 18%   load 3.51
GPU   12%  ▁▁▂▁▁▁▃▂▁▁
RAM   14.2 / 36 GB  ▃▃▄▄▄▅▅▅   wired 4.2   swap 12 MB
Disk  ↓ 1.2 MB/s  ↑ 340 KB/s   412 GB free
Net   ↓ 8.4 Mb/s  ↑ 1.1 Mb/s   en0
Therm nominal   31.2 °C
```

### Sources, with measured cost on this machine (M3 Pro, 200 iterations, `-O`)

| Metric | API | Cost |
|---|---|---|
| CPU total + per-core | `host_processor_info(PROCESSOR_CPU_LOAD_INFO)` | 0.005 ms |
| Memory | `host_statistics64(HOST_VM_INFO64)` | 0.001 ms |
| Memory pressure | `sysctlbyname("kern.memorystatus_vm_pressure_level")` | — |
| Swap | `sysctlbyname("vm.swapusage")` | — |
| Load average | `getloadavg()` | — |
| GPU | `IOAccelerator` → `PerformanceStatistics` → `Device Utilization %` | 0.023 ms |
| Disk throughput | `IOBlockStorageDriver` → `Statistics` → `Bytes (Read)`/`(Write)` | 0.045 ms |
| Disk free | `volumeAvailableCapacityForImportantUsage` | — |
| Network | `getifaddrs` → `if_data.ifi_ibytes`/`ifi_obytes` | 0.024 ms |
| Thermal | `ProcessInfo.thermalState` + the battery `Temperature` already read | free |

**~0.10 ms total per sample. 0.01% of one core at 1 Hz.** No entitlements, no TCC, no helper.

### Deliberately excluded

- **SMC** (fan RPM, die temperatures, `PSTR` system watts) — 0.83 ms for 6 keys, and it requires a
  hand-laid-out 80-byte kernel struct with no header. A natural Swift struct lays out at 76 bytes and
  every call returns `kIOReturnBadArgument`. Key names are per-SoC with no list (`Tp05`/`TB0T`/`TW0P`
  exist on M3 Pro; `Tp01`/`Tg0f` do not), so it needs a hand-maintained per-generation table or
  startup probing. The battery temperature is already available without it.
- **IOReport** — its unique value is CPU/GPU watts and per-cluster frequency residency, and it is
  dyld-cache-only with no header. GPU utilisation, the thing actually wanted, is available from
  `PerformanceStatistics` with no private symbols.
- **CPU frequency on Apple Silicon** — no public API. `hw.cpufrequency` is Intel-only.
- **Public IP** — requires an outbound HTTP call to a third party.

### Correctness requirements

- `host_processor_info`'s returned array **must** be `vm_deallocate`d or it leaks ~192 bytes per
  sample (~11 MB/day at 1 Hz).
- CPU, disk and network are all **counter deltas**. Retain a previous sample plus elapsed seconds.
  The first sample after a gap must be discarded, not rendered as a spike. Handle 32-bit `ifi_ibytes`
  wraparound (~34s at 1 Gb/s on some interfaces).
- E-core/P-core: `hw.perflevelN.name` and `.logicalcpu` give labels and counts but **not** the index
  ranges into `host_processor_info`'s array. The convention is perflevel0 (Performance) first, but
  that is undocumented — verify empirically before shipping the split.
- `IOBlockStorageDriver` matching returns several nodes including all-zero ones. Filter or sum
  deliberately.

All delta maths as pure free functions so `IsletTests` can cover ticks, byte rates, wraparound and
gap detection.

### Display styles — configurable per metric

Per decision 7, build all of them and expose the choice in Settings per metric:

```swift
enum MetricDisplayStyle: String, Defaults.Serializable, CaseIterable {
  case number            // 38%
  case numberAndBar      // 38%  ▓▓▓▓░░░░░░
  case sparkline         //      ▁▂▅▃▂▁▄█▅▃
  case sparklineAndNumber // 38%  ▁▂▅▃▂▁▄█▅▃
  case combined          // 38%  ▁▂▅▃▂▁▄█▅▃  P 44%  E 18%  load 3.51
}
```

60-sample ring buffer per series. The ring must outlive the view, so the monitor keeps sampling at a
slow cadence (5s) when the tab is closed and switches to 1 Hz when open via the Phase 1.4 refcounted
gate. `.number` and `.numberAndBar` need no history and are the cheap path.

---

## Phase 5 — Multi-source media

### What blocks the obvious approach

Islet is single-source end to end: one `@Published playback: PlaybackState?`
(`NowPlayingActivity.swift:8`), one `lastState` diff base (`MediaWatcher.swift:12`), and
`AdapterUpdate` carries no source identity. `SourceFilter.shouldAccept` (`SourceFilter.swift:6-21`)
is a *suppressor* — in `.prioritized`, an unlisted bundle is dropped with `continue`, so a second
player becomes invisible rather than secondary. Transport is globally addressed:
`MRMediaRemoteSendCommand(code, nil)` (`MediaRemoteCommands.swift:33-42`) hits whatever macOS
considers now-playing, so even if two rows were drawn today both would drive the same player.

The real blocker is below the app. **The vendored adapter physically collapses concurrent players.**
`Vendor/mediaremote-adapter-src/src/adapter/stream.m:189` keeps one `__block NSMutableDictionary
*liveData` and calls `resetAll()` when a notification arrives from a different process (`:396-408`,
`:437-449`):

```objc
if (liveData[kMRABundleIdentifier] != nil && process.bundleIdentifier != nil &&
    ![liveData[kMRABundleIdentifier] isEqual:process.bundleIdentifier]) {
    // This is a different process, reset all data.
    resetAll();
}
```

`nm -gU Vendor/MediaRemoteAdapter.framework/Versions/A/MediaRemoteAdapter` exports only the singular
set — no `*Clients`, no `*ForClient`, no `SendCommandTo*`.

### What ships in this pass

**A. Model refactor.** `struct SourceID: Hashable` carrying bundle identifier **and pid** — three
distinct `com.apple.WebKit.GPU` processes coexist, confirmed by probe. Display identity still resolves
via `parentApplicationBundleIdentifier`, as `PlaybackState.sourceBundleIdentifier` already does.
`NowPlayingActivity.playback` becomes `private(set) var sources: [SourceID: PlaybackState]` with a
computed `primary`; keep `var playback: PlaybackState? { primary }` as a shim so existing views
compile. `AdapterUpdate` carries the source key and gains `.sourceGone(SourceID)`. The 60s pause-idle
timer (`NowPlayingActivity.swift:16`, `:57-68`) becomes per-source. `SourceFilter.shouldAccept -> Bool`
becomes `SourceFilter.rank(...) -> Int?` (nil = hidden); `mediaPriorityList` becomes display order
rather than a filter, retiring `.prioritized`'s drop behaviour. `SourceFilterTests.swift:13-43` locks
in the replacement semantics and gets rewritten.

**C. CoreAudio secondary detection.** `kAudioHardwarePropertyProcessObjectList` (`'prs#'`) on the
system object, then `kAudioProcessPropertyBundleID` (`'pbid'`) and
`kAudioProcessPropertyIsRunningOutput` (`'piro'`) per process, with `AudioObjectPropertyListener`s on
the list and on each process's running-output property — push-driven, no polling. Verified end-to-end
on this machine from an ad-hoc-signed binary: `noErr`, 38 process objects, bundle IDs and flags
readable, **no TCC prompt**. These are process *objects*, not Core Audio process taps — taps would
need `NSAudioCaptureUsageDescription` and a user grant; this does not. Requires helper→parent
collapsing (three `WebKit.GPU` processes → one Safari row) and a denylist (`systemsoundserverd`,
`com.apple.PowerChime`, `com.apple.controlcenter`, and `dev.cnucifora.Islet` itself all appear).
Will also flag non-music audio — a video call reads as "playing".

**E. Hero + source strip UI.**

```
╭──────╮  ♪ Track title                          [Ad]
│ art  │  Artist
│      │  ──────●─────────────────  1:42 / 3:58
╰──────╯  ⤨   ⏮   ⏸   ⏭   ↻
────────────────────────────────────────────────────
[ Spotify ● ]  [ Safari ● ]  [ VLC ○ ]   ← tap to switch
```

The primary keeps today's full hero — 110pt artwork, title, scrubber, complete transport. Others render
as a ~24pt strip of app-icon chips using the existing `ExpandedPlayerView.appIcon(for:)` resolver
(`:154-159`), dimmed, with a playing dot and no transport. Tapping promotes that source via
`MRMediaRemoteSetNowPlayingPlayerIfPossible`, after which it gets the full hero. Cap the strip at 3
extras then "+N" — collapsed-island glyphs widen the island, since panel width derives from measured
slot widths.

Track-change sneaks route through the Phase 3 bus so they gain app attribution for free (today they
fire on any title change with no indication of which app they came from).

### Honest limitation

Secondary sources show **that** something is playing and let you switch to it — not what it is. No
title, no artist, no artwork, no transport. That is the ceiling of the non-fork approach, and it is
why the fork below is recorded in full.

---

## Upgrade path — fork the MediaRemote adapter for true per-source media

**Status: not scheduled. Fully scoped. Pick this up to lift Phase 5's limitation.**

This is the only route to title, artist, artwork, scrubber and independent transport for every
concurrent source simultaneously. Phase 5's model refactor (A) is a strict prerequisite and is
designed so this drops in behind it — `sources: [SourceID: PlaybackState]` simply starts receiving
more than one populated entry, and the hero/strip UI upgrades secondary chips to full rows without a
model change.

### The system framework already exposes everything needed

Confirmed via `dyld_info -exports /System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote`
(5134 symbols):

- Enumeration — `MRMediaRemoteGetNowPlayingClients`, `MRMediaRemoteGetNowPlayingClientsForOrigin`,
  `MRMediaRemoteGetPlayers`, `MRMediaRemoteGetPlayersForClient`,
  `MRMediaRemoteGetActivePlayerPathsForOrigin`
- Per-source reads — `MRMediaRemoteGetNowPlayingInfoForClient` / `ForPlayer` / `ForApp`,
  `MRMediaRemoteGetPlaybackStateForClient` / `ForPlayer`,
  `MRMediaRemoteGetSupportedCommandsForClient` / `ForPlayer`
- Per-source commands — `MRMediaRemoteSendCommandToClient` / `ToPlayer` / `ToApp`
- Promotion — `MRMediaRemoteSetNowPlayingPlayer`, `MRMediaRemoteSetNowPlayingPlayerIfPossible`
- Identity accessors — `MRNowPlayingClientGetBundleIdentifier`, `GetDisplayName`,
  `GetParentAppBundleIdentifier`, `GetProcessIdentifier`, `CopyAppIconURL`, `GetTintColor`

The OS models N clients and N players with per-player command routing and per-player supported-command
sets. **This is a fork problem, not an impossibility.**

### Where the code must live

These are *read* APIs, and reads are exactly what macOS 15.4+ locked down — the entire reason
`MediaWatcher` shells out to `/usr/bin/perl` (`MediaWatcher.swift:70-71`), which upstream documents as
"using a system binary — `/usr/bin/perl` — which is entitled to use the MediaRemote framework"
(`Vendor/mediaremote-adapter-src/README.md:28-31`).

**Multi-client reads therefore cannot run in-process** via `CFBundleGetFunctionPointerForName` the way
`MediaRemoteCommands` does. They must be added inside the perl-hosted framework. Sends differ —
`MediaRemoteCommands.swift:3` records that send-side still works in-process on 15.4+, and
`MRMediaRemoteSendCommandToPlayer` may too, but it needs a player-path object that only an entitled
read can produce.

### Concrete work items

1. Declare the multi-client symbols in `Vendor/mediaremote-adapter-src/src/private/MediaRemote.h`
   (currently only the four singular getters, `:113-129`).
2. Add `src/adapter/stream_all.m` — a copy of `stream.m` keyed by client instead of the single
   `liveData` (`:189`), with `resetAll()` scoped per client rather than global (`:396-408`, `:437-449`).
3. Add it to `ADAPTER_SOURCES` in `CMakeLists.txt:17-32`.
4. Whitelist the new subcommand in `bin/mediaremote-adapter.pl:116-123` (symbols resolve via
   `adapter_$function_name`, `:183`).
5. Emit `{"type":"data","source":"<pid>:<bundle>","diff":Bool,"payload":{...}}` — the current shape
   (`stream.m:23-31`) is flat with a single `bundleIdentifier` and nowhere to put a second source.
6. Add a `send-to` subcommand wrapping `MRMediaRemoteSendCommandToClient` for per-source transport.
7. Extend `AdapterParser` to read the `source` field; the fixture
   `IsletTests/Fixtures/adapter-stream.jsonl` is single-source and needs a two-source sibling.
8. Route `MediaRemoteCommands` through `send-to` when a non-primary source is targeted.

### Costs and risks — read before starting

- You maintain a fork of a third-party vendored framework, pinned at `3ac3d4b`, and must rebuild and
  re-sign a universal binary on every upstream update — `project.yml:31-34` embeds it with
  `codeSign: true`.
- The `*ForClient` / `*ForPlayer` **completion-block signatures are undocumented and unverified**. A
  wrong signature crashes the perl host. That fails safe — `MediaWatcher.processDied` restarts with
  exponential backoff capped at 60s (`:29-31`, `:125-138`) — but a crash loop surfaces as a stuck
  "Restarting in Ns" in Settings (`SettingsView.swift:129-131`).
- **A runtime capability probe is mandatory**: do the symbols resolve, does the first call return? Fall
  back to today's single-source `stream` on any failure.
- Deeper private-API surface than today, on calls upstream never exercised, and Apple already
  restricted this area once at 15.4.
- Definitively App-Store-ineligible — though `project.yml:15-18` (ad-hoc signing, hardened runtime off,
  no entitlements file) confirms Islet already spent that optionality.

### Rejected alternative, recorded so it is not re-litigated

**AppleScript bridge for Music + Spotify.** Public and stable, and the only non-private route to real
per-source control — `player state`, `name of current track`, `artist`, `duration`, `player position`,
and `playpause` / `next track` / `previous track` all work. Rejected because it covers two apps out of
the ecosystem (browsers, Podcasts, VLC, IINA, TIDAL, Apple TV all miss), producing inconsistency users
notice immediately; it needs `NSAppleEventsUsageDescription` (absent from `project.yml:38-43`) plus a
per-app TCC Automation grant that must degrade silently on denial; it polls where the adapter is
push-driven; and launching a not-running app via Apple Events is a real hazard requiring an
`NSWorkspace.runningApplications` guard. Viable as a targeted enhancement layered on the Phase 5
model, never as the mechanism.

---

## Build order

**Phase 0** — the drift bug. Small, independent, unblocks trusting anything visual.

**Phase 1** — shared infrastructure. Per-tab height tiers (1.2) must complete before Phase 2 or 4
authors any layout.

**Phase 2** — power screen. Uses 1.2, 1.4, 1.5.

**Phase 3** — SystemEventBus + all three tiers. Uses 1.1, 1.6.

**Phase 4** — System tab. Uses 1.2, 1.3, 1.4, 1.5, and 1.6 for its threshold `isActive`.

**Phase 5** — multi-source media. Uses 1.3. Model refactor (A) → CoreAudio detection (C) → hero +
strip UI (E).

**Later, unscheduled** — the adapter fork above; SMC sensors; sneak urgency, TTL and sticky progress
(only once a real transfer source exists — AirDrop outbound is the first candidate).

---

## Defaults taken without asking

- Battery tab stays visible on battery (`isActive = batteryEnabled`).
- All motion gated on Reduce Motion.
- SMC and IOReport deferred; `ProcessInfo.thermalState` plus the existing battery temperature cover
  the thermal readout.
- Docking bursts coalesce into one summary sneak with a queue-depth cap.
- `mediaPriorityList` becomes display order rather than a filter.
- Peripheral low battery ships in event Tier 1.
- The drift bug is fixed directly rather than instrumented first — the fixes are cheap, non-conflicting,
  and correct under every ranked hypothesis.
