# Islet Improvement Roadmap — 2026-07-23

Synthesized from multi-angle web research (competitor features, notch UX patterns, macOS 26 APIs, robustness, battery tooling). 62 raw ideas from 14 sources, de-duplicated and filtered against what Islet already ships. *(The workflow's own synthesis+feasibility steps were cut off by a spend limit; this is the recovered synthesis, with feasibility notes inline.)*

## Top 5 highest-impact additions

1. **File shelf + AirDrop drop-zone** — the single most-requested notch feature (surfaced independently 4×; the flagship of NotchDrop/NotchNook/boring.notch). Drop files onto the expanded notch to stash them, drag them back out, or one-tap AirDrop. *Approach:* SwiftUI `.onDrop`/`NSItemProvider` into a session shelf model + `.onDrag` out; `NSSharingService(named: .sendViaAirDrop)`. Public APIs, **M**.
2. **Timers / Pomodoro as a determinate progress activity** — the canonical Dynamic Island use case and the best showcase for Islet's activity system: a progress ring + live countdown in compact, controls when expanded. *Approach:* pure SwiftUI + a `Timer`; model as an activity with a determinate progress ring. Public, **S–M**.
3. **Now-playing depth pack** — shuffle/repeat toggles, podcast/audiobook ±15 s skip, ad labelling, and locally-interpolated scrubber position — all from data Islet's adapter already streams. *Approach:* read `shuffleMode`/`repeatMode`/`isAdvertisement`/`supports*15Seconds` from the payload; `send` command IDs (6/7 shuffle/repeat, 12/13 skip); compute position as `elapsedTime + (now - timestamp) × playbackRate` instead of polling. Public (to Islet), **S each**.
4. **Trackpad / scroll gestures over the notch** — swipe to switch activities, scroll to expand/dismiss; a big fluidity upgrade beyond hover/click. *Approach:* an `NSEvent` `.scrollWheel`/swipe monitor gated to the notch region, driving the collapse/expand animation from live translation. Public, **M**.
5. **App Intents + Focus Filter integration** — define `AppIntent`s once and get Shortcuts, a Control Center Control, and Action-button support for free; add a `SetFocusFilterIntent` so the island auto-slims/hides per Focus mode (the *sanctioned* path vs. reading private DND state). Future-proof. Public (macOS 13+), **M**.

---

## Backlog by theme

### New activities / features
| Idea | Value | Effort | Approach |
|---|---|---|---|
| **File shelf + AirDrop** | High | M | `.onDrop`/`.onDrag`, `NSSharingService(.sendViaAirDrop)` |
| **Timers / Pomodoro** | High | S–M | SwiftUI progress ring + `Timer`; determinate activity |
| **Synced lyrics** under the notch during playback | High delight | M | LRCLIB (free, keyless, on-device `.lrc` by title/artist/album/duration); Lyrics.ovh plaintext fallback |
| **Bluetooth peripheral batteries** (Magic Mouse/Keyboard/Trackpad, headphones) | Med-High | M | IOKit/IORegistry `BatteryPercent*` or IOBluetooth device props; extend the existing battery/AirPods path |
| **Clipboard history** | Med | M | No pasteboard notification — poll `NSPasteboard.general.changeCount` on a timer; capped persisted ring buffer |
| **Weather** (compact conditions + short forecast) | Med | M | WeatherKit + one-shot `CLLocationManager`; needs WeatherKit entitlement |
| **Camera / mic in-use privacy indicator** | Med | M | CoreMediaIO (camera) + CoreAudio input running-state; render a small pill while capture is live |
| **Screen-recording indicator** | Med | S–M | ScreenCaptureKit active-content / capture-in-progress signal |
| **Downloads progress** | Med | M | FSEvents/`DispatchSource` watch on `~/Downloads` for `*.download`/`*.crdownload`/`*.part`, animate to final size |
| **Long-task progress** (Time Machine, copies, exports) | Med | M | `tmutil status`, `NSMetadataQuery`/FSEvents; no single public "all progress" feed |
| **Camera mirror** (quick self-check before a call) | Low-Med | M | `AVCaptureSession` preview; needs camera permission |
| **iPhone Mirroring launcher** | Low | S | `NSWorkspace.open` bundle `com.apple.ScreenContinuity` (bundle id may change) |

### Now-playing depth
- **Shuffle/repeat controls** reflecting current state (payload `shuffleMode`/`repeatMode`; `send` 6/7). **S**
- **Podcast/audiobook mode**: ±15 s skip gated on `supportsRewind/FastForward15Seconds` (`send` 12/13). **S**
- **Locally-interpolated scrubber** (also fixes audit L2 redraw): position from `elapsedTime + (now−timestamp)×playbackRate`. **S**
- **Ad awareness**: label + dim transport when `isAdvertisement` (best-effort per service). **S**
- **Better source attribution**: prefer `parentApplicationBundleIdentifier` over `bundleIdentifier` for browser/helper-hosted playback. **S**
- **Adapter health self-check**: run the adapter's `test` subcommand at launch/wake; show a clear "now-playing unavailable — macOS may have changed" state instead of silence (also addresses audit resilience). **S**
- **Real FFT visualizer** from live system audio — *see risky section.*

### HUD depth
- **Keyboard-backlight HUD** — extend the existing `CGEventTap` to `NX_KEYTYPE_ILLUMINATION_UP/DOWN`, completing volume/brightness/backlight. **S**
- **Output device in the volume HUD** (speaker vs AirPods vs external) — CoreAudio `kAudioDevicePropertyTransportType`. **S**
- **HUD style option** — edge-pinned bar vs. circular `Gauge`; pure SwiftUI, no new API. **S**
- **External-display brightness** via DDC/CI (VCP `0x10` over I2C) — *see risky section.*

### UX & interaction polish
- **Dual concurrent activities** — split the compact island into independent leading/trailing regions around the physical notch (e.g. now-playing + charging shown together as first-class, not a glyph). Layout change, no new API. **M**
- **Auto-cycle** compact display when more activities are live than the split can hold (timed rotation, pause on hover). **S–M**
- **Interruption levels** per activity (`.passive`/`.active`/`.timeSensitive`, modeled on ActivityKit) gating what may auto-expand or sneak. **S**
- **Auto-expand on action-required events** (fired reminder/alarm, incoming call) with complete/snooze buttons. **M**
- **matchedGeometryEffect** for coherent compact↔expanded morphing of shared elements (art, indicators). **S–M**
- **Expanded height tiers** (`.pill` vs `.tall`) per activity instead of content-derived height. **S**
- **Primary-tap deep-linking** into the source app + an explicit dismiss control on persistent activities. **S–M**
- **Per-app exclusion** rules (suppress island/HUD for chosen apps) via `NSWorkspace` frontmost-app observation. **S**
- **Notchless floating pill** on external displays instead of a faked notch. **M**
- **Compact readability guardrails** — cap compact to one datum + one icon; validate with Apple's "blur test". **S** (design discipline)

### Platform integration
- **App Intents** as the backbone — one intent set drives Shortcuts, Control Center Controls, and the Action button. **M**
- **Control Center / menu-bar Control** (`ControlWidgetToggle`) to pin/expand or toggle a "focus notch" mode. **S–M** (after App Intents)
- **Focus Filter** (`SetFocusFilterIntent`) for per-Focus behavior — the sanctioned alternative to reading private DND state. **S–M**
- **Third-party plugin / Live-Activity API** — model on ActivityKit's leading/trailing/center/expanded schema; expose via App Intent + a light local IPC (`islet://activity?…` URL scheme or a Unix socket) so any app/script can post a titled activity. **L**
- **Liquid Glass rendering** for any Widget/Control — honor `@Environment(\.widgetRenderingMode)` + `.widgetAccentedRenderingMode`. **S**

### Accessibility (currently a likely weak spot — worth a dedicated pass)
- **Decouple VoiceOver labels from the visual refresh cadence** — drive `accessibilityLabel` from a separate value that only changes on semantic transitions, so the a11y tree isn't spammed by the ~6.6×/s visual updates. **S**
- **Hide decorative high-frequency visuals** from a11y (`.accessibilityHidden(true)` on bars/scrubber/art animation) and collapse each activity to one labelled element. **S**
- **Announce sneaks** (charger, low battery, AirPods, track change) via `NSAccessibility.post(…, .announcementRequested)`. **S**
- **Quiet mode under VoiceOver** — detect `NSWorkspace.isVoiceOverEnabled`, gate live-region churn to semantic changes. **S**
- **Honor Increase Contrast / Reduce Transparency / Dynamic Type / Reduce Motion** across all activities. **S–M**

---

## Risky / private-API-dependent (do carefully or defer)
- **Real FFT audio visualizer** — macOS 14.4+ `AudioHardwareCreateProcessTap` + `CATapDescription` is the public route, but capturing system audio needs the audio-capture permission and adds real cost; treat as opt-in.
- **External-display brightness (DDC/CI)** — I2C to `IOFramebuffer`; fragile, monitor-dependent, can fail/garble on some displays.
- **Battery charge limiting (SMC)** — writing SMC charge/discharge keys (AlDente/Battery-Toolkit territory) can affect hardware and is version-fragile; **high risk, recommend not shipping** without deep testing, or defer entirely.
- **Focus status via `~/Library/DoNotDisturb` files / controlcenter** — private and breaks across releases; use the **Focus Filter intent** instead.
- **iPhone Mirroring / continuity presence** — launching by bundle id is fine; "nearby iPhone" detection has no clean public API.

## Quick wins (small, high value)
- Locally-interpolated scrubber (also a perf fix) · shuffle/repeat + ±15 s skip · adapter `test` health-state · keyboard-backlight HUD · HUD style toggle · per-app exclusion · Focus Filter intent · the accessibility `accessibilityHidden`/announcement pass.

## Built (2026-07-23/24 implementation pass)
Timers/Pomodoro · now-playing depth pack (shuffle/repeat, ±15 s skip, ad pill, source-app icon, local scrubber) · **file shelf + AirDrop** · **clipboard history** (opt-in) · **Ports tab** (live USB device list via IOKit attach/detach) · **Bluetooth peripheral batteries** · HUD style option (bar/gauge) · user-defined menu (tab) order · in-notch settings window fix · haptics across interactions · calendar/reminder colours · AlDente-style battery metrics + **charger wattage** · accessibility pass (VoiceOver announcements, hidden decorative visuals, labelled controls) · switcher moved into the notch band. Plus the audit fixes (HUD key gate, MediaWatcher race/leak, fullscreen orderOut, runtime permission re-check, redraw gating).

## TODO — Power feature (needs further work)
Beyond the metrics + charger-wattage now shown, the power feature should grow into a real battery-management surface:
- **Charge limiting** (cap charging at e.g. 80%) via SMC keys — AlDente/Battery-Toolkit territory. **Risky/private**; needs careful testing, possibly a privileged helper. Highest-value power feature but most dangerous.
- **Discharge / "sail"** control and MagSafe LED control (SMC).
- Richer adapter details (name, voltage/current, PD negotiation), charge-rate history graph, per-app energy impact.
- Low-battery *peripheral* sneaks (Magic Mouse/Keyboard) — reader already exists.

## Still deferred (unbuilt; risky, entitlement-bound, or unverifiable in an ad-hoc build)
Adapter `test` health-state · keyboard-backlight HUD (private brightness API) · volume-HUD output-device readout · Weather (WeatherKit entitlement) · camera mirror (camera permission) · camera/mic privacy indicator · App Intents + Control Center Control + Focus Filter · third-party plugin/Live-Activity API · FFT visualizer (audio-capture permission) · external-display DDC/CI brightness · gestures · per-app exclusion · notchless floating pill · matchedGeometryEffect compact↔expanded morph.

## Sources
How-To Geek & review roundups (NotchNook/Alcove/MediaMate/Boring Notch), DynamicNotch & mediaremote-adapter GitHub, Apple docs (App Intents, Focus Filters, WidgetKit/Controls, Live Activities/ActivityKit, Core Audio taps), UI/UX Dynamic Island design write-ups, Notchy/CoreMediaIO privacy-indicator notes, AlDente/coconutBattery/Battery-Toolkit internals.
