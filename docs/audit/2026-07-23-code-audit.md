# Islet Code Audit — 2026-07-23

Multi-agent audit with adversarial verification. 4 of 6 dimensions completed (concurrency, memory/lifecycle, resilience, performance); **UI/UX and correctness dimensions were cut off by a spend limit** and should be re-run. 16 findings verified, 13 confirmed, 1 false-positive, 2 concurrency findings unverified-but-code-confirmed.

## Executive summary — top 5 to fix

1. **HUD key black-hole (real bug).** The event tap consumes volume/brightness keys and suppresses the system OSD *unconditionally* once a key is decoded — even if the volume/brightness change didn't actually happen (CoreAudio device missing, DisplayServices symbol unavailable). Result: the key does nothing *and* the system OSD never appears. `HUDController.swift:81-118`.
2. **Fullscreen "hidden" panels stay fully live.** With hide-in-fullscreen on, panels are only set to `alphaValue = 0` — the whole SwiftUI tree keeps rendering/animating — plus a 1 s `CGWindowListCopyWindowInfo` poll over every window. `ScreenManager.swift:88-110`.
3. **Battery state freezes silently if the IOKit power-source notification fails to register.** The 5 s timer only refreshes `metrics`, never `state`, so plug/unplug/percent would be stuck forever with no fallback poll. `BatteryMonitor.swift:23-36`.
4. **Runtime permission revocation goes undetected.** `accessDenied` is only set during the one-time `requestAndLoad()`; revoking Calendar/Reminders in System Settings while running shows an empty "No events / All clear" instead of the "access off" state. `CalendarActivity.swift:50-77`, `RemindersProvider.swift:43-79`.
5. **Always-on redraw cost.** Several `TimelineView`s and timers redraw continuously regardless of visibility (compact audio bars ~6.6×/s while any audio plays even when the notch is closed; scrubber 2×/s even when paused; SmartBattery IORegistry opened every 5 s though only shown in the expanded view). Individually low, collectively meaningful for a 24/7 overlay.

---

## Findings by severity

### High

**H1 — HUD consumes media keys even when the action no-ops, with no OSD fallback** · `Islet/Activities/HUD/HUDController.swift:81-118`
`handle()` returns `true` (consume + suppress OSD) as soon as `HUDKey.decode` succeeds, without checking whether `apply()` actually changed volume/brightness. If CoreAudio has no default output device, or `DisplayServices` symbols failed to `dlopen`, the key is swallowed and the system OSD is suppressed → the key becomes dead. *Fix:* make `apply()` return whether it changed the value (thread through `VolumeController`/`BrightnessController.isAvailable`); only `return true` on success, else `return false` so the system handles the key and shows its own OSD.

### Medium

**M1 — Fullscreen-hidden panels keep their SwiftUI tree live + 1 s window poll** · `ScreenManager.swift:88-110`
`hideInFullscreen` installs a `Timer.publish(every: 1)` running `FullscreenDetector.hasFullscreenWindow` (a `CGWindowListCopyWindowInfo` over all on-screen windows, per screen) forever, and hides only via `alphaValue = 0` so every timer/animation in the tree keeps running behind the fullscreen app. *Fix:* `orderOut()` the panel (or drop its `contentView`) when covered so rendering stops; drive show/hide from `NSWorkspace.activeSpace`/fullscreen notifications instead of a 1 s poll.

**M2 — Battery state freezes if the IOPS notification source fails** · `BatteryMonitor.swift:23-36`
On `IOPSNotificationCreateRunLoopSource == nil` the code logs and returns; the 5 s timer only refreshes `metrics`, never `state`, so charge/charging is stuck permanently with no visible degradation. *Fix:* have the timer also call `refresh()` (state + metrics) as a fallback poll, or surface the failure.

**M3 — Runtime permission revocation not detected (Calendar & Reminders)** · `CalendarActivity.swift:50-77`, `RemindersProvider.swift:43-79`
`accessDenied` is computed once in `requestAndLoad()`; `reload()` never re-checks `EKEventStore.authorizationStatus(for:)`. Revoking access mid-session shows empty state, not "access off"; re-granting doesn't recover. *Fix:* re-read authorization status in `reload()` / the store-change handler and flip `accessDenied`.

**M4 — MediaWatcher never clears the pipe handlers on restart/stop** · `MediaWatcher.swift:57-63, 100-112, 32-39`
The adapter subprocess is *designed* to die and respawn (backoff machinery exists), but each `launch()` installs a new `readabilityHandler`/`terminationHandler` on a fresh `Pipe` and none of the teardown paths (`stop()`, `processDied()`) ever nil them, nor is there an EOF (`data.isEmpty`) guard → leaked file handles and a possible EOF busy-loop across repeated restarts. *Fix:* hold the `Pipe`, nil `readabilityHandler`/`terminationHandler` before dropping the process, and treat empty reads as EOF.

**M5 — MediaWatcher `continuation` data race (unverified — verifier cut off, but code-confirmed)** · `MediaWatcher.swift:16-18, 97`
`MediaWatcher` is `@unchecked Sendable`; every field is confined to its serial `queue` *except* `continuation`, which is written in the `lazy var updates` initializer (on the consumer/MainActor) and read on the producer `queue`. Unsynchronized cross-thread access; early stream updates can be raced/dropped depending on when `updates` is first accessed. *Fix:* create the `AsyncStream` in `init` (assign `continuation` before any `queue.async` runs), or only touch `continuation` inside `queue.async`.

### Low

**L1 — Compact audio bars animate ~6.6×/s even when the notch is closed or fullscreen-hidden** · `NowPlayingViews.swift:19-41` — `TimelineView(.animation(minimumInterval: 0.15))` is paused only on `!isPlaying`, not on notch visibility. *Fix:* thread notch-visible state in and also pause when collapsed/off-screen.

**L2 — Expanded scrubber `TimelineView(.periodic by: 0.5)` never paused** · `NowPlayingViews.swift:78-98` — redraws the slider twice a second even when paused (identical frames). *Fix:* `paused: playback?.isPlaying != true`.

**L3 — AppleSmartBattery IORegistry opened/read/closed every 5 s, 24/7** · `BatteryMonitor.swift:33-35` — deep metrics are only shown in the expanded battery view. *Fix:* gate the 5 s metrics refresh on the battery view being on-screen (`onAppear`/`onDisappear`).

**L4 — Redundant main-queue hop on every app-wide mouse move** · `NotchViewModel.swift:24-31` — `.receive(on: DispatchQueue.main)` on events already delivered on main; adds an async hop per mouse move per screen. *Fix:* drop it (events are already main-thread); throttle at source if coalescing is wanted.

**L5 — Calendar 30 s timer invalidates the whole UI even when nothing changed** · `CalendarActivity.swift:42-47` — unconditional `objectWillChange.send()` → `ActivityCenter` fan-out → every `NotchRootView` recomputes every 30 s. *Fix:* only reassign `events` when the mapped agenda actually differs (it's value-comparable); drop the explicit `objectWillChange`.

**L6 — `Defaults.publisher` sinks call MainActor work with no isolation hop (unverified — verifier cut off)** · `ScreenManager.swift:46-52`, `HUDController.swift:29-33` — `.showOnAllDisplays → rebuild()` (creates NSPanel/NSHostingView) and `.hideInFullscreen → updateFullscreenObserving()` run directly in the sink, unlike the sibling sink at `ScreenManager:38` which hops. Relies on Defaults delivering on main. *Fix:* apply `.receive(on: .main)` / `Task { @MainActor }` uniformly.

**L7 — Leaked/un-removable observers (latent; benign only because these are app-lifetime singletons)**
- `BatteryMonitor.swift:15-36` — no `stop()`/teardown, no idempotency guard, `CFRunLoopSource` + timer never removed.
- `AudioDeviceMonitor.swift:19-28` — `AudioObjectPropertyListenerBlock` not stored, so unremovable by construction.
- `AppDelegate.swift:31-35` — `didBecomeActive` observer token discarded (can't be removed), unlike the `launchAtLoginObserver` pattern used two lines up.
*Fix:* store the tokens/blocks/sources and add symmetric `stop()`/teardown, matching the pattern already used elsewhere.

### False positive

**FP1 — "MediaWatcher wedges permanently if adapter bundle missing."** The mechanical observation (bundle-missing branch returns without resetting `isRunning`, so `start()` won't retry) is true, but "wedges permanently / cannot recover" is overstated for a bundled-resource case that only fails if the app itself is corrupt. Still worth the one-line `isRunning = false` reset on that branch, but not the severity claimed.

---

## Quick wins (safe, high value)

- [ ] H1: gate HUD key consumption on action success (real bug).
- [ ] L2: pause the scrubber `TimelineView` when not playing.
- [ ] L1: pause compact audio bars when the notch is collapsed/hidden.
- [ ] L4: drop the redundant `.receive(on: .main)` in `NotchViewModel`.
- [ ] L3: gate the 5 s SmartBattery timer on the expanded battery view.
- [ ] M2: make the battery timer also refresh `state` as a fallback poll.
- [ ] M3: re-check `authorizationStatus` in `reload()`.

## Systemic themes

- **Visibility-unaware work.** Multiple timers/animations run at full rate regardless of whether the notch is visible — the biggest lever for a 24/7 overlay's energy footprint. Introduce a single "is the notch visible/expanded" signal and gate live work on it.
- **Fire-and-forget observers.** `start()` methods register run-loop sources, CoreAudio/IOKit listeners, and NotificationCenter blocks with no symmetric teardown. Safe today because everything is an app-lifetime singleton, but fragile the moment anything becomes per-screen or restartable (ScreenManager already rebuilds per display).
- **Consume-then-act ordering.** The HUD decides to suppress the OS before knowing the action worked. Prefer act-then-decide for anything that swallows system input.
- **Not re-audited:** correctness (geometry/state-machine/sneak/parsing edge cases) and UI/UX (hit-testing, multi-display, accessibility) — re-run those two dimensions.
