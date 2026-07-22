# Islet — Design Spec

*2026-07-22. A Dynamic Island for the MacBook notch. Personal daily-driver; not sandboxed, not App-Store-bound.*

Research foundation: `~/Documents/dev/personal/notch-research/` (report + per-repo source analyses of NotchDrop, boring.notch, DynamicNotchKit, Peninsula, NotchNotification). Patterns referenced below by repo name come from those notes.

## 1. Goals & non-goals

**Goals**
- A persistent, live compact island around the hardware notch: when an activity is active, compact indicators sit beside the notch (album art left, audio bars right); idle = bare notch.
- iOS-style activity semantics: multiple sources (media, battery, calendar, AirPods, HUD) feed one island through a priority-resolved activity model.
- Fluid Dynamic Island animation: spring expansion out of the notch, morphing content, no window jank.
- Never steals focus. Never blocks menu-bar clicks outside its own shape.
- Configurable interaction: hover-with-timeout mode or hover-peek + click-to-pin mode.
- Now playing works with whatever is playing system-wide by default; settings can force/prioritize specific players.

**Non-goals (v1)**
- File shelf / drag-and-drop storage.
- Timers/Pomodoro.
- Multi-display rendering (architecture supports it; only the built-in display renders in v1).
- Mac App Store distribution, sandboxing, notarization (personal machine only).
- Third-party plugin API (the activity protocol is designed so this could come later).

## 2. Target environment

- macOS 26+ (developed against 26.5), Apple Silicon MacBook Pro with notch (Mac15,6 primary target).
- Swift 6, SwiftUI-first with AppKit where required. Xcode 26.6.
- `.accessory` activation policy; `MenuBarExtra` for Settings/Quit; launch-at-login optional.

## 3. Architecture

```
IsletApp (@main, MenuBarExtra)
 ├─ ScreenManager                 screens by display UUID; rebuild on parameter change
 │    └─ NotchWindowController    one per screen (v1: built-in only)
 │         └─ NotchPanel          static transparent NSPanel, never moves/resizes
 │              └─ NSHostingView(NotchRootView)
 ├─ NotchViewModel (per screen)   state machine + geometry, drives all animation
 │    └─ EventMonitors            global+local NSEvent monitors → Combine
 ├─ ActivityCenter                registry + priority resolution + sneak queue
 │    ├─ NowPlayingActivity       MediaWatcher (adapter subprocess) + controllers
 │    ├─ BatteryActivity          IOKit power sources
 │    ├─ CalendarActivity         EventKit
 │    ├─ AirPodsActivity          device connect events (battery best-effort)
 │    └─ HUDActivity              CGEventTap media keys + OSD suppression
 └─ SettingsWindow                SwiftUI; persisted via Defaults package
```

Module boundaries: `Core/` knows nothing about features; activities know nothing about windows — they publish state and views, `ActivityCenter` resolves, `NotchRootView` renders. Each activity is independently testable against the `NotchActivity` protocol.

## 4. Core shell

### 4.1 Window

`NotchPanel: NSPanel` — the consensus recipe validated across all five reference codebases:

- `styleMask: [.borderless, .nonactivatingPanel]`
- `level = .mainMenu + 3`
- `collectionBehavior = [.fullScreenAuxiliary, .stationary, .canJoinAllSpaces, .ignoresCycle]`
- `isOpaque = false`, `backgroundColor = .clear`, `hasShadow = false`, `isMovable = false`, `isReleasedWhenClosed = false`, `isFloatingPanel = true`
- `canBecomeKey = false`, `canBecomeMain = false` — the island never takes focus; all interaction is hover/click (views opt into `acceptsFirstMouse`).
- Ordered with `orderFrontRegardless()`.
- Optional `sharingType = .none` (settings toggle) to hide from screen recording.

The panel is a **fixed-size** transparent canvas: `expandedSize + shadowPadding(20pt)` tall, `expandedSize.width + earMargin` wide, top-centered on the screen. It is positioned once and never moves or resizes; every visual change is SwiftUI layout inside it. Full-screen-width is unnecessary — the hardware notch is centered, so a centered window stays aligned.

Not in v1 (documented escape hatches if window level proves insufficient): boring.notch's private `CGSSpace` at max absolute level, SkyLight lock-screen delegation.

### 4.2 Geometry

`NSScreen` extension (public API, verified against Apple docs):
- notch height = `safeAreaInsets.top`; notch width = `frame.width − auxiliaryTopLeftArea.width − auxiliaryTopRightArea.width` (both must be > 0).
- Drawn closed shape is 2 pt oversized vs hardware so edges hide behind the bezel; hit target is the notch rect inset by −4 pt (bigger than it looks).
- Built-in display: `deviceDescription["NSScreenNumber"]` → `CGDisplayIsBuiltin`.
- Screens identified by `CGDisplayCreateUUIDFromDisplayID` UUID, never by `NSScreen` identity.
- Fallback fake notch (menu-bar height × 200 pt) exists in the geometry type for future external-display support; unused in v1.
- On `NSApplication.didChangeScreenParametersNotification`: tear down and rebuild all windows (never migrate); alpha-flash (0 → move → 1) to hide ghost frames.

### 4.3 State machine

```swift
enum NotchState: Equatable {
    case closed          // live compact island (or bare notch if no activity)
    case peek            // hover acknowledgement: +4pt growth, haptic tick
    case expanded(pinned: Bool)
}
```

Interaction mode is a setting:

- **Hover mode**: `closed → peek` on hover-enter (immediate), `peek → expanded(pinned: false)` after `hoverExpandDelay` (default 0.3 s) of continuous hover, `expanded → closed` after `hoverCollapseTimeout` (configurable, default 0.5 s) once the mouse leaves the expanded rect.
- **Click-to-pin mode**: hover produces only `peek`; click on the notch → `expanded(pinned: true)`; click outside the expanded rect, or on the notch again → `closed`.
- In both modes: `expanded(pinned: true)` never auto-collapses. A `preventAutoClose` guard (set by any modal interaction, e.g. a popover) suppresses all auto-close paths.
- Transitions are pure functions `(state, event, settings) → state` in `NotchStateMachine` — fully unit-tested, no AppKit imports.

Input: `EventMonitors` singleton owning paired global + local `NSEvent` monitors (`.mouseMoved`, `.leftMouseDown`) exposed as Combine publishers; hit-testing compares `NSEvent.mouseLocation` against published screen-coordinate rects (`notchHitRect`, `expandedRect`). Haptics via `NSHapticFeedbackManager` (`.alignment`) on peek, throttled 0.5 s, suppressed while `NSEvent.pressedMouseButtons != 0`.

### 4.4 Shape & animation

- `NotchShape: Shape` — flat top, top corners flaring **outward** into the menu bar, bottom corners rounding inward; `animatableData: AnimatablePair(topRadius, bottomRadius)`.
- Radii: closed 6/14 → expanded 19/24. Expanded size ~640×190 (tunable constants in one file, `Metrics.swift`).
- Springs: `.bouncy(duration: 0.4)` opening, `.smooth(duration: 0.4)` closing (no overshoot on close), `.snappy(duration: 0.4)` for compact-content changes.
- Black backing rect with `.padding(-50)` behind the mask so overshoot never shows an edge; 1 pt black strip at the very top edge; ±0.5 pt mask insets against hairline seams.
- Content transitions: expanded content enters `.blur + .scale(y: 0.6, anchor: .top) + .opacity`; artwork morphs compact↔expanded with `matchedGeometryEffect` (namespace owned by the root view, shared via the view model).
- Compact asymmetry compensation: shape offset by `(trailingWidth − leadingWidth)/2` so the hardware notch stays visually centered.
- Forced `.preferredColorScheme(.dark)` and `NSAppearance(named: .darkAqua)`.
- SwiftUI `.shadow(radius: 16)` with opacity animated 0→1 on expand (window has no AppKit shadow).
- Sequencing: window ordered front first; state animations begin ≥ 0.1 s later.

## 5. Activity system

```swift
enum ActivityPriority: Int, Comparable { case ambient = 0, media = 1 }
// Sneaks are not activities — they are transient events handled by SneakQueue (below)
// and always visually override compact slots while presenting.

@MainActor protocol NotchActivity: AnyObject, Identifiable {
    var id: String { get }
    var priority: ActivityPriority { get }
    var isActive: Bool { get }                      // @Published via ObservableObject
    var compactLeading: AnyView { get }
    var compactTrailing: AnyView { get }
    var expandedView: AnyView { get }
}
```

- `ActivityCenter` (ObservableObject) holds registered activities, observes their `isActive`, and publishes `primaryActivity` (highest priority active, ties broken by most-recently-activated). `NotchRootView` renders the primary's compact slots when `closed` and its expanded view when `expanded`.
- If >1 activity is active, the expanded view shows the primary plus a slim switcher strip (icons of other active activities; tap to make primary).
- **Sneaks** (transient events: charger plugged, AirPods connected, track change while closed): a `SneakQueue` serializes `SneakEvent`s (content view + duration, default 2 s). A sneak temporarily overrides the compact slots (shape swells to fit), then reverts. Sneaks never interrupt `expanded`; they queue and drain, coalescing duplicates (same source replaces its queued predecessor).
- Debug menu (hidden, ⌥-click menu-bar icon): inject fake sneaks/track changes/battery events to exercise every path without real hardware.

## 6. Features

### 6.1 NowPlayingActivity (v1 milestone)

- **Reads**: `MediaWatcher` (actor) spawns bundled `mediaremote-adapter.pl` under `/usr/bin/perl` with bundled `MediaRemoteAdapter.framework` (from ungive/mediaremote-adapter), consuming its JSON-lines stream: title, artist, album, artwork (base64), elapsed/duration, playback rate, source bundle ID. This is the ecosystem-standard workaround for the macOS 15.4+ MediaRemote read lockdown (verified in boring.notch source).
- **Process resilience**: restart on death with exponential backoff (1 s → 60 s cap); after 5 consecutive failures, switch to fallback and surface status in Settings.
- **Fallback**: AppleScript polling controllers for Spotify (`com.spotify.client`) and Apple Music (`com.apple.Music`) — metadata + control without private APIs, 1 s poll while a target app runs.
- **Controls**: `MRMediaRemoteSendCommand` / `MRMediaRemoteSetElapsedTime` loaded in-process via `CFBundle` (send-side still permitted on 15.4+); per-app AppleScript fallback.
- **Source selection**: `auto` (system-reported now-playing app) or `prioritized([bundleID])` — watcher filters/ranks stream events by the ordered list; players not on the list are ignored in prioritized mode.
- **Compact**: artwork (leading) + animated audio bars (trailing, driven by playback state — decorative, not FFT). **Expanded**: large artwork, title/artist (marquee on overflow), scrubber (drag = `SetElapsedTime`), prev/play-pause/next, source-app icon.
- Artwork processing off-main (downscale, corner radius); average-color used as expanded background tint.

### 6.2 BatteryActivity

- IOKit `IOPSNotificationCreateRunLoopSource` for power-source changes.
- Sneaks: charger connected (bolt + %), charger disconnected, low battery at 20/10% (once per threshold crossing).
- Persistent ambient: small charge indicator in a compact slot while charging (yields slots to media when media is primary — priority handles this).

### 6.3 CalendarActivity

- EventKit with full-access request; degraded state (activity off + grant button in Settings) if denied.
- Compact countdown appears `calendarLeadMinutes` (default 10) before the next event with attendees or any non-all-day event; expanded shows today's remaining agenda (time, title, calendar color, join-link detection for video-call URLs → opens in browser).

### 6.4 AirPodsActivity

- Connection/disconnection sneaks for audio output devices (CoreAudio default-device change + IOBluetooth device info): device icon + name.
- Battery levels: best-effort — attempt the known IOBluetooth/`BatteryPercent*` paths; if macOS 26 blocks them, ship connect-sneaks without percentages. This is an accepted-risk item, not a blocker.

### 6.5 HUDActivity

- `CGEventTap` on `NX_SYSDEFINED` media keys (volume up/down/mute, brightness up/down) — requires Accessibility permission (Settings explains + deep-links).
- Suppress the system overlay by suspending `OSDUIHelper` (the boring.notch technique). **Safety invariant**: restoration runs on app termination, on HUD-toggle-off, and defensively at every launch, so a crash can never leave the system HUD dead. If suspension fails on macOS 26, HUD feature disables itself gracefully (keys pass through untouched).
- Volume via CoreAudio; display brightness via the private DisplayServices path (`dlopen`), matching boring.notch.
- UI: slim horizontal level bar as a sneak beside the notch, coalescing rapid key-presses.

## 7. Settings

| Group | Setting | Values (default) |
|---|---|---|
| Interaction | Mode | hover / clickToPin (**hover**) |
| Interaction | Hover expand delay | 0.1–1.0 s (**0.3**) |
| Interaction | Auto-collapse timeout | 0.2–3 s (**0.5**, hover mode only) |
| Interaction | Haptics | on/off (**on**) |
| Media | Source mode | auto / prioritized (**auto**) |
| Media | Player priority list | ordered bundle IDs |
| Activities | Battery / Calendar / AirPods / HUD | per-feature toggles (**battery on, others off until configured**) |
| Calendar | Countdown lead time | 5–60 min (**10**) |
| General | Launch at login | off |
| General | Hide from screen recording | off |
| General | Notch height mode | matchHardware / matchMenuBar (**matchHardware**) |

Persistence: `Defaults` package (typed keys, Combine publishers). Settings window is a normal SwiftUI window (activates the app while open — the only time Islet ever activates).

## 8. Resilience

- Adapter subprocess: restart/backoff/fallback per §6.1; status surfaced in Settings.
- HUD suppression: reversible-by-construction per §6.5.
- Permissions: every permission-gated activity degrades to off-with-explanation; no permission is requested until its feature is enabled.
- Screen changes, wake, lock: rebuild windows; if `showOnLockScreen`-style behavior is ever wanted it is out of scope for v1 (windows close on lock).
- Single instance: PID-file check at launch, terminate elder instance (NotchDrop pattern).

## 9. Testing

- **Unit (XCTest)**: `NotchStateMachine` transition table in both modes (hover timing edges, pin/unpin, preventAutoClose); `ActivityCenter` priority/tie-break resolution and sneak queue (ordering, coalescing, never-during-expanded); geometry math (notch size derivation, hit rects, asymmetry offset) as pure functions; `MediaWatcher` JSON-line parsing against recorded fixtures (Spotify, Music, Safari).
- **Manual/visual**: animation feel, seam checks against the hardware notch, via the debug menu's injectable events.
- No UI-automation tests (cost > value for a one-user overlay app).

## 10. Project

- Repo: `~/Documents/dev/personal/islet`, Xcode project generated by XcodeGen (`project.yml` committed; `.xcodeproj` gitignored).
- Targets: `Islet` (app). Test target `IsletTests`.
- Signing: personal team, automatic. No notarization/Sparkle for v1.
- SPM: `sindresorhus/Defaults`, `sindresorhus/LaunchAtLogin-Modern`.
- Bundled: `mediaremote-adapter.pl` + `MediaRemoteAdapter.framework` (vendored from ungive/mediaremote-adapter release, licence-noted).
- Source layout:

```
Islet/
  App/            IsletApp, AppDelegate, MenuBarExtra, DebugMenu
  Core/           NotchPanel, NotchWindowController, ScreenManager,
                  NotchGeometry, NotchStateMachine, NotchViewModel,
                  EventMonitors, Metrics
  UI/             NotchRootView, NotchShape, CompactLayout, ExpandedLayout,
                  SneakOverlay, transitions
  Activities/     NotchActivity, ActivityCenter, SneakQueue
    NowPlaying/   MediaWatcher, MediaRemoteCommands, AppleScriptControllers,
                  NowPlayingActivity, views
    Battery/      Calendar/   AirPods/   HUD/
  Settings/       SettingsWindow, Defaults+Keys
  Support/        Logging, SingleInstance, Haptics
```

## 11. Milestones

1. **M1 — Core shell**: panel, geometry, state machine (both interaction modes), shape + springs, empty compact/expanded placeholder content. *Exit: it looks and behaves like a Dynamic Island on the real notch.*
2. **M2 — Now playing**: adapter integration, compact artwork/bars, expanded player, source-priority setting. *Exit: daily-drivable.*
3. **M3 — Sneak system + Battery.**
4. **M4 — HUD replacement.**
5. **M5 — Calendar + AirPods.**
6. **M6 — Polish**: fullscreen awareness, multi-display, screen-recording hiding.

## 12. Accepted risks

- `mediaremote-adapter` depends on perl's MediaRemote entitlement surviving future macOS updates; fallback is AppleScript polling (§6.1).
- AirPods battery percentages may be unobtainable on macOS 26 without private API breakage — feature degrades to connect-events only (§6.4).
- `OSDUIHelper` suppression is a hack and may change per-OS; HUD self-disables if it fails (§6.5).
- macOS 26 specifics (Liquid Glass menu bar rendering) may need metric tweaks around the notch — constants centralized in `Metrics.swift` for fast iteration.
