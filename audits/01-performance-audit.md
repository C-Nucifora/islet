# Islet performance and background-behaviour audit

Audit date: 28 August 2026
Code reviewed: `3cdc9f18b5cc` on `t3code/audit-performance-features-roadmap`
Test machine: Mac15,12, 8 cores, macOS 26.3.1

## Executive verdict

Islet is architecturally better than a typical polling-heavy menu-bar utility: USB, volumes, power, sleep, Wi-Fi, Bluetooth, Focus, audio-process changes, and several other events are notification-driven. The app also slows battery and system-stat sampling from 1 second while visible to 5 seconds while hidden.

However, the current build is too busy for an app intended to run all day. The important problem is lifecycle rather than any single catastrophic loop: most activity monitors are started at launch, and disabling an activity usually hides it without stopping its work. T3 performs frequent local and remote requests, battery performs broad IOKit reads, system metrics sample forever, the media adapter keeps a Perl child process alive, and every global mouse movement enters Islet's interaction pipeline.

**Overall assessment: background design 5/10.** It should not make a modern Mac unusable, but the measured active-background cost is high enough to produce a noticeable battery penalty over a workday. It is particularly poor by menu-bar utility standards and should be fixed before treating Islet as release-ready.

The “Always show the System stats tab” setting is not, by itself, the primary drain: the monitor remains at its slower 5-second cadence until the System view is actually open. The real problem is that it continues sampling even when the entire activity is disabled.

## Live measurements

The live process was the user's existing Debug build from `DerivedData/Build/Products/Debug/Islet.app`. T3 local and remote connections, media playback, battery, Calendar/Reminders, and system metrics were active. These results therefore represent a realistic active background workload, not a clean “all optional features off” idle baseline.

| Measurement | Result | Interpretation |
|---|---:|---|
| CPU, clean 20-second background sample | 1.03 CPU seconds, about **5.2% of one core** | High for an always-on menu utility |
| Longer observed range | roughly 5–8% of one core, with short bursts above 20% | Work is periodic/bursty rather than a tight spin |
| Resident memory | about **85–97 MB RSS** | Not dangerous, but large for this surface area |
| Physical footprint | **99 MB**, peak **194 MB** | Peak is concerning and worth allocation profiling |
| Media helper | about **13 MB RSS**, approximately 0% CPU when quiet | A permanent extra process |
| T3 networking | two established TCP connections | Expected from configured local and remote environments |

A 10-second stack sample found the main thread asleep much of the time, but frequent SwiftUI graph flushes and activity recomputation were visible around T3, battery, and notch updates. This supports the conclusion that the cost is many small periodic publications rather than one runaway function.

Exact watt-hours could not be measured: `powermetrics` energy sampling requires elevated privileges. CPU percentage is not a direct battery measurement, so this report deliberately does not invent a wattage or “hours lost” figure. A controlled Release/Energy Log test is still required for that number.

## How the app works in the background

At launch, one block starts the window system and nearly every activity, regardless of whether its tab is enabled: [AppDelegate.swift](../Islet/App/AppDelegate.swift#L31).

| Subsystem | Mechanism and cadence | Does disabling stop it? | Assessment |
|---|---|---|---|
| USB and ports | IOKit attach/detach notifications | No; Ports starts at launch | Efficient source, incorrect lifecycle |
| Volumes | `NSWorkspace` mount/unmount notifications | Event-source toggle does | Good |
| Power and sleep | IOPower/Workspace notifications | Event-source toggle does | Good |
| Wi-Fi/Bluetooth/audio process | Framework callbacks/listeners | Event-source toggle does; activity toggle generally does not | Mostly good |
| Focus/AirDrop | File dispatch sources / focused filesystem observation | Event-source toggle does | Reasonable, though heuristic |
| Screenshot event | Spotlight `NSMetadataQuery` over the user home scope | Event-source toggle does | Narrow predicate, but initial home-scope gather can be expensive |
| VPN | `getifaddrs` every 5 seconds | Event-source toggle does | Cheap call; still a periodic wake-up |
| Full-screen detection | App/Space notifications plus a 3-second safety poll when enabled | Yes | Acceptable |
| Clipboard | Pasteboard poll every 0.7 seconds | Yes | Expected for this feature, but privacy-sensitive |
| Calendar | EventKit refresh every 30 seconds | The query is skipped when off, but the timer remains | Minor unnecessary wake-up |
| System metrics | Full CPU/GPU/memory/disk/network/thermal sample every 5 seconds, 1 second while visible | **No** | Major always-on cost |
| Battery | Power notification plus deep IOKit/IOPS/peripheral reads every 5 seconds, 1 second while visible | **No** | Major cost and main-thread risk |
| T3 Code | Local and each remote `/api/orchestration/shell` request every 1.5 seconds while busy, 4 seconds while idle | Yes, via its dedicated T3 toggle | Too aggressive; updates are not diffed |
| Now Playing | Long-lived Perl/MediaRemote adapter plus CoreAudio listener | Hiding the activity does not stop it | Permanent process and private-API risk |
| Mouse interaction | Global and local mouse-move/drag/click monitors | No | Every mouse move enters each notch view model |

The activity settings wording says an activity is hidden. That is exactly what the implementation does: `disabledActivities` is applied only while filtering and sorting [ActivityCenter.swift](../Islet/Activities/ActivityCenter.swift#L31). Event-source switches are better designed because they actually start and stop their source.

## Principal performance findings

### P0 — Activity visibility is incorrectly used as activity lifecycle

System, battery, media, ports, and audio-device observation all start unconditionally [AppDelegate.swift](../Islet/App/AppDelegate.swift#L39). A user who turns off Battery, Ports, Media, or System can reasonably expect the associated work to stop; today it usually does not.

**Fix:** give every activity an explicit `start/stop` lifecycle owned by one coordinator. Observe the relevant Defaults key and stop timers, child processes, file queries, callbacks, and network tasks when disabled. Treat `isActive` as presentation state only.

### P0 — Battery does broad synchronous IOKit work too frequently

The battery monitor refreshes all state, deep battery properties, port properties, and peripherals on the main actor every 5 seconds in the background and every second when visible [BatteryMonitor.swift](../Islet/Activities/Battery/BatteryMonitor.swift#L61). The broad AppleSmartBattery property fetch explicitly pulls large blobs such as `RaTableRaw` and `PortControllerInfo` [SmartBatteryReader.swift](../Islet/Activities/Battery/SmartBatteryReader.swift#L7).

**Fix:** move registry reads off the main actor; split fast values from deep/static health data; update charge state from notifications; sample power/temperature every 10–15 seconds while visible and 30–60 seconds while hidden; read cycles/capacity/port topology only on power-source change or every several minutes.

### P0 — T3 polling and publication are too eager

Every environment fetches every 1.5 seconds while an agent is busy and every 4 seconds otherwise [T3CodeActivity.swift](../Islet/Activities/T3Code/T3CodeActivity.swift#L180). `upsert` replaces and sorts the published environments even if the snapshot is unchanged [T3CodeActivity.swift](../Islet/Activities/T3Code/T3CodeActivity.swift#L228), invalidating SwiftUI unnecessarily.

**Fix:** prefer a server-sent-events/WebSocket change stream. Until then, publish only on an equality change, add jitter, use 3–5 seconds while expanded and 10–15 seconds in the background, apply exponential offline backoff, and suspend remote polling during sleep, lock, Low Power Mode, and when T3 is not configured.

### P1 — The media helper has no reliable app-lifetime shutdown

Now Playing launches a long-lived Perl adapter at startup. During this audit, terminating the audit-launched Islet process left its media helper orphaned under PID 1 until it was explicitly cleaned up. That is direct evidence that abrupt or ordinary termination paths need stronger ownership.

**Fix:** stop the watcher from `applicationWillTerminate`, terminate and then kill the child after a short deadline, make the helper exit when its parent disappears, and do not launch it while Media is disabled.

### P1 — SwiftUI invalidation is broader than necessary

`activeActivities` reads Defaults, filters, ranks, and sorts on every access [ActivityCenter.swift](../Islet/Activities/ActivityCenter.swift#L33). A single root view evaluation can request it several times [NotchRootView.swift](../Islet/UI/NotchRootView.swift#L21), while T3 and other activity objects republish centrally.

**Fix:** make the ordered activity list a cached `@Published` snapshot; recompute only when activity state, order, or enabled state actually changes. Batch/coalesce changes per run-loop turn.

### P1 — System history is collected even when nobody wants it

The system monitor intentionally never stops so a graph is immediately populated [SystemMetricsMonitor.swift](../Islet/Activities/System/SystemMetricsMonitor.swift#L4). That convenience is not worth permanent sampling after the user disables the tab.

**Fix:** stop completely when System is disabled. If enabled but hidden, retain the last snapshot and use a 15–30-second history cadence. Switch to 1 second only while the tab is visible.

### P2 — App-wide mouse movement is always observed

Each notch view model subscribes to paired global/local mouse movement [NotchViewModel.swift](../Islet/Core/NotchViewModel.swift#L46). The calculations are small, but on multi-display/high-refresh setups this is avoidable continuous work.

**Fix:** use tracking areas/local monitors near the notch where possible, throttle/coalesce movement to display cadence, and do not deliver drag/move events to panels that are hidden or on inactive displays.

## What is already done well

- Most physical/system events use callbacks rather than polling.
- The battery and system publishers compare values or guard overlapping samples.
- Full-screen panels are ordered out, allowing their SwiftUI trees to stop rendering.
- Clipboard polling exists only while that explicit feature is enabled.
- Event-source settings correctly start and stop observation.
- Background system counter collection already runs at utility priority.

These are good foundations; the app does not need a rewrite. It needs one consistent lifecycle policy and much less publication.

## Recommended performance budget

Treat these as release gates, measured from a signed Release build after five minutes of settling:

| Scenario | CPU target | Physical footprint target | Wake-up/network target |
|---|---:|---:|---|
| All optional activities off, collapsed | <0.3% of one core | <60 MB | No recurring network; <15 wakes/s |
| Default setup, no active work | <0.7% | <75 MB including helper | No poll faster than 10 seconds |
| T3 agent active, media playing | <1.5% average | <100 MB | Change stream or <=1 request/3 s |
| Expanded animation | Smooth 60/120 Hz; short bursts acceptable | No repeated >30 MB allocation spikes | No synchronous IOKit/EventKit work |

## Verification plan after fixes

1. Add lifecycle tests proving every disabled activity has no timer/task/process/source.
2. Add signposts for battery reads, system samples, T3 fetch/parse/publish, and SwiftUI panel updates.
3. Run Instruments Time Profiler, Allocations, Animation Hitches, and Energy Log on a signed Release build.
4. Run four 30-minute scenarios: minimal idle, default idle, active T3, and media plus expanded interactions.
5. Adopt MetricKit for real-world CPU, memory, network, disk, hang, and energy evidence. macOS 26 already supports MetricKit reports; macOS 27's new async `MetricManager` can later segment metrics by Islet activity state ([Apple MetricKit documentation](https://developer.apple.com/documentation/metrickit)).

## Build/test observations

- Debug build: succeeded.
- Release build: succeeded; it is ad-hoc signed and has Hardened Runtime disabled.
- Full suite: 365/365 passed once; a second run produced one timing failure in `SneakSnapshotTests.testSnapshotBluetoothSneak`. The same test passed in other full runs, so this is a genuine flake rather than a deterministic product failure.
- Swift 6 emitted concurrency warnings in `MediaWatcher` for captured state used by concurrent code. These should be resolved before Swift treats them as errors.
