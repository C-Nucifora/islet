# Islet current features and issue audit

Audit date: 28 August 2026
Code reviewed: `3cdc9f18b5cc` on `t3code/audit-performance-features-roadmap`

## Executive verdict

Islet already has an unusually broad and useful feature set, and the core notch interaction is distinctive. The current blocker is not lack of features: it is reliability and product coherence. Permission identity, the replacement HUD, overflowing top navigation, and Settings all need work before more permanent activities are added.

The four user-reported problems are supported by the audit:

- **System/Performance tab colliding with the notch:** confirmed as a deterministic overflow design flaw. The current five-chip state fit in the live screenshot, but the strip is only about 126 pt wide on a 14-inch MacBook Pro and every tab is forced into the left ear. One more active activity makes scrolling/cropping unavoidable.
- **Calendar says access is off despite being granted:** confirmed as a permission-identity/recovery problem. System Settings showed two enabled `Islet.app` records, while an Islet instance displayed “Calendar access off.” Both checked builds use the same bundle identifier but different ad-hoc CDHashes and no team identity.
- **Audio/brightness HUD not working:** confirmed by multiple code defects, including a guaranteed invisible-HUD state while the island is expanded.
- **Settings layout is terrible:** confirmed live and in code. It is one 440 × 520 non-resizable Form with the longest expert section first, no navigation, no search, and unrelated controls in one scroll.

## Current feature inventory

| Area | Current capability | Maturity |
|---|---|---|
| Notch shell | Hover “push through” or click-to-pin expansion; compact and expanded tiers; haptics; multi-display option | Strong concept, geometry/overflow issues |
| Now Playing | Multi-player detection, artwork, transport controls, source priority, audio-process activity | Useful, private adapter and helper lifecycle risks |
| Battery | Charge, health, cycles, temperature, power, time estimate, charger and connected peripheral batteries | Rich, over-sampled |
| Calendar and Reminders | Today's agenda, countdown, meeting join links, incomplete reminders and completion | Permission and date-format defects |
| T3 Code | Local/remote environments, active agents, pairing/reconnect | Valuable differentiator, polling-heavy |
| Timer | Presets, Pomodoro/break, compact countdown, completion event | Solid basic feature |
| Shelf | File drag target and AirDrop/share flow | Promising, discoverability/accessibility gaps |
| Clipboard | Session-only clipboard history | Functional, high privacy sensitivity |
| Ports/audio devices | Attached devices and AirPods/audio status | Useful, lifecycle not tied to visibility setting |
| System stats | CPU/GPU/memory/disk/network/thermal with histories and display styles | Comprehensive, permanent sampling and tab pressure |
| System events | USB, volumes, displays, power, sleep, peripheral battery, Wi-Fi, Bluetooth, lock/Caps Lock, screenshots, AirDrop, Focus, VPN | Broad; some events are inferred |
| HUD replacement | Volume/mute and brightness interception with bar/gauge UI | Not reliable enough to enable |
| General | Launch at login, all displays, fullscreen hide, screen-recording hide | Good baseline controls |

## Critical and high-priority issues

### P0 — HUD is invisible whenever the island is expanded

The event tap can apply the media key and consume both key-down and key-up [HUDController.swift](../Islet/Activities/HUD/HUDController.swift#L82). The only HUD render path is guarded by `!vm.state.isExpanded` [NotchRootView.swift](../Islet/UI/NotchRootView.swift#L13).

Result: press a volume or brightness key while Islet is open and Islet can suppress the macOS OSD, change the value, and render nothing. This alone is enough to make the feature feel completely broken.

**Required fix:** HUD must pre-empt expanded content or render as an overlay inside the expanded island. Never consume a system key until the app has both changed the device successfully and committed a visible HUD state.

### P0 — HUD consumes keys on devices it cannot actually control

For volume, `canHandle` checks only that a default output device exists [HUDController.swift](../Islet/Activities/HUD/HUDController.swift#L101). `setVolume` can then fail every property write, discard the `wrote` result, and still show/consume the event [VolumeController.swift](../Islet/Activities/HUD/VolumeController.swift#L43). HDMI, AirPlay, USB interfaces, and displays frequently expose an output device without a writable scalar-volume property.

Brightness availability similarly checks only whether private DisplayServices symbols loaded, not whether the current display accepts get/set operations [BrightnessController.swift](../Islet/Activities/HUD/BrightnessController.swift#L31).

**Required fix:** capability-probe the current device/display, return success from setters, verify the read-back value, and pass the event through on any failure. Add automatic event-tap health/status and a “Test HUD” control.

### P0 — Permission identity is unstable across builds

System Settings showed two `Islet.app` entries enabled under both Calendars and Accessibility. Code-sign inspection found:

- both builds used the same development bundle identifier;
- both are ad-hoc signed;
- neither has a TeamIdentifier;
- the builds have different CDHashes.

The project enforces manual ad-hoc signing and disables Hardened Runtime [project.yml](../project.yml#L11). macOS therefore has multiple code identities carrying the same display name. A grant attached to one build is not a reliable grant for another, which explains the intermittent “it is enabled in Settings but Islet says it is not” experience during development.

The app's Calendar recovery button only calls `requestFullAccessToEvents()` again [CalendarActivity.swift](../Islet/Activities/Calendar/CalendarActivity.swift#L56). Once macOS has recorded a denial or the running identity differs, that may not present a new prompt. The UI does not show the actual EventKit status, app path, bundle ID, signing identity, or a button to open the correct Privacy pane.

**Required fix:** use one stable development signing identity and bundle identifier, and a stable signed distribution build. Add a Permission Center that shows `.notDetermined`, `.denied`, `.restricted`, `.writeOnly`, and `.fullAccess` distinctly, opens System Settings when re-prompting cannot work, and displays a copyable diagnostics block. Avoid running two Islet builds at once.

### P1 — The tab strip is designed to overflow into an unclear scroll state

All activity tabs plus Home are placed in a horizontal ScrollView constrained to the left side of the physical notch. Settings alone occupies the right ear [ExpandedContainerView.swift](../Islet/UI/ExpandedContainerView.swift#L77). The source calculates only about 126 pt—five 22 pt chips—on the reference Mac. Calendar, Timer, Shelf, Clipboard, Ports, System, T3, Media, and Battery can make the list substantially longer.

The live five-tab screenshot fit, so the exact collision was not reproduced in that moment. The code and the user's reported state nevertheless establish the conditional failure: forcing System always visible can be the extra chip that pushes the selected centered item into a clipped/scrolling edge. Indicators are hidden, so there is no cue that more items exist.

**Required fix:** stop treating every activity as a permanent tab. Keep at most three priority items plus Home visible, use a labelled overflow button, and place overflow content in a popover/grid below the notch. Alternatively use both ears symmetrically and reserve hard masks around the physical notch. Add snapshot tests at 5, 6, 9, and 12 activities for every supported notch width.

### P1 — Settings has no information architecture

Live inspection showed the initial viewport almost entirely consumed by “System stats,” with T3 only beginning below it. Code confirms one grouped Form fixed at 440 × 520 [SettingsView.swift](../Islet/Settings/SettingsView.swift#L60), hosted in a non-resizable window [SettingsOpener.swift](../Islet/Support/SettingsOpener.swift#L17).

Problems include:

- advanced per-metric presentation controls are the first thing every user sees;
- activities, event sources, media, interaction, permissions, privacy, and general settings share one long scroll;
- the 240 pt reorder List is embedded inside that scroll;
- there is no sidebar, search, reset, import/export, status summary, version, or diagnostics;
- controls appear/disappear vertically as toggles change, making the page jump;
- permission state can go stale because `hudTrusted` is initialized once and is not published.

**Required redesign:** a resizable `NavigationSplitView` with Overview, Activities, Events, Appearance & Interaction, Permissions, Integrations, and Advanced. Overview should contain setup health and only the common toggles. Put system metric styles and event source taxonomy in their own pages. Add search and “Restore defaults.”

### P1 — Calendar permission and empty-state UX are indistinguishable from faults

The dashboard exposes only “Calendar access off” [IdleDashboardView.swift](../Islet/UI/IdleDashboardView.swift#L47). There is no action there and no explanation. Other states—loading, denied, restricted, query failed, no calendars, and truly no events—collapse into either that row or an empty list. EventKit queries are synchronous on the main actor [CalendarActivity.swift](../Islet/Activities/Calendar/CalendarActivity.swift#L73).

**Required fix:** explicit load state and error model, an actionable denied card, event-store work off the animation path, and a refresh affordance. Observe `EKEventStoreChanged`, not only a 30-second timer.

### P1 — Date-only reminders are rendered as midnight

The live dashboard displayed several reminders at “12:00 am.” `dueDateComponents?.date` loses whether the reminder had time components [RemindersProvider.swift](../Islet/Activities/Reminders/RemindersProvider.swift#L86), then the view always formats hour and minute [IdleDashboardView.swift](../Islet/UI/IdleDashboardView.swift#L107).

**Required fix:** preserve `DateComponents`, detect date-only reminders, and render “Today,” “Tomorrow,” or a date instead of a fabricated midnight time.

### P1 — Release builds include the entire Debug menu

The menu-bar app always exposes “Debug,” event injection, demo activity, forced expansion, and HUD test actions [IsletApp.swift](../Islet/App/IsletApp.swift#L93). There is no `#if DEBUG` guard.

**Required fix:** compile the menu only in Debug, or hide it behind a deliberate diagnostics mode.

### P1 — “Turn one off” often means hide, not stop

Activity toggles modify only `disabledActivities`; the monitors continue running. This is both a performance defect and misleading product copy. Event-source toggles do correctly stop their sources, which makes the inconsistency harder to understand.

**Required fix:** split “Show in Islet” from “Monitor in background” only where that distinction is genuinely useful; otherwise stop the feature when it is off.

## Medium-priority issues

### P2 — Expanded panel reserves the tallest click area

The panel is grown to the tall 250 pt tier while expanded even when the visible island is only 190 pt. This avoids a prior crash but leaves transparent panel area capable of intercepting input. The content also uses fixed 480 pt width [Metrics.swift](../Islet/Core/Metrics.swift#L3), which is not adaptive to narrow notches, scaled displays, or localization.

### P2 — Accessibility remains incomplete

- Several icon-only actions rely on visual meaning; the meeting join button has no explicit label [IdleDashboardView.swift](../Islet/UI/IdleDashboardView.swift#L69).
- Shelf deletion is hover-discovered rather than persistently available.
- 9 pt secondary text is used for reminder details.
- Reduce Motion gating does not cover every continuous or decorative animation.
- Long fixed-width layouts and truncated single-line labels are poor for larger text and localization.

### P2 — Calendar join-link support is unnecessarily hard-coded

Only Zoom, Google Meet, Microsoft Teams, and Webex hosts are recognized [CalendarActivity.swift](../Islet/Activities/Calendar/CalendarActivity.swift#L98). FaceTime and valid conferencing URLs from other providers are ignored. Use EventKit's structured location/URL data where possible and a safer generic URL presentation rather than a four-provider allowlist.

### P2 — Clipboard history can capture secrets

The app correctly warns that it may capture passwords, and storage is session-only. It still needs an exclusion model: ignore transient/concealed pasteboard types, password managers, selected apps, and user-defined patterns; provide pause and clear controls in the expanded surface.

### P2 — Media uses private integration and does work during view rendering

The vendored MediaRemote adapter and private DisplayServices calls increase OS-update and distribution risk. Artwork decoding and application/icon lookup should be cached away from SwiftUI body evaluation. The current Swift 6 concurrency warnings in `MediaWatcher` also signal unsafe ownership around the helper.

### P2 — Distribution posture is development-only

Hardened Runtime is disabled, signing is ad hoc, MediaRemote/DisplayServices are private, and there is no visible update/release channel. This is not an App Store-ready build. Even for direct distribution, Islet needs stable Developer ID signing, notarization, Sparkle or another updater, a privacy explanation, and a documented compatibility matrix.

### P2 — Tests do not cover the product's riskiest surfaces

The suite has strong pure-logic and hosting coverage, but no end-to-end UI/permission/media-key tests. One full run passed all 365 tests; a second run failed the Bluetooth sneak snapshot drain, while other runs passed it. Add deterministic clock/queue control instead of fixed real-time waits.

## Recommended fix order

1. **Stabilize signing and permissions.** One app identity, Permission Center, direct System Settings recovery.
2. **Make HUD fail-safe.** Never consume without successful control and visible feedback; support expanded state.
3. **Replace the tab strip overflow.** Bounded visible priorities plus explicit overflow.
4. **Rebuild Settings.** Sidebar, search, status, categories, resizable window.
5. **Tie activity toggles to monitor lifecycle.** This also resolves much of the performance audit.
6. **Fix reminders at midnight and Calendar state/error handling.**
7. **Remove Debug UI from Release and establish a signed/notarized release path.**
8. **Finish accessibility, localization, and UI automation before expanding the feature count.**

## Audit limitations

- The exact user-reported tab collision was not visible with the five active chips captured; it is confirmed as a conditional overflow through the layout calculation and reported configured state.
- A second audit-launched Islet instance briefly coexisted with the user's build. It was removed and its orphaned media helper cleaned up. Performance figures in the performance report target only the user's original PID; the initial Calendar screenshot may have belonged to either overlay, so the stronger permission conclusion comes from the duplicate System Settings records plus distinct code signatures rather than that screenshot alone.
- Physical media-key injection was not automated. The HUD findings are direct control-flow defects and do not depend on subjective visual testing.

## Second features/issues loop — implementation addendum

This source-only follow-up was completed on 28 August 2026. It did not build, sign, install, or
launch Islet, so the items below describe implemented code paths and static validation rather than
a claim that macOS permissions or hardware behavior have been exercised on a release binary.

### Additional fixes and features implemented

- Replaced the remaining incorrect tab-strip width calculation with a centered-notch, left-ear
  budget. The layout now reduces visible priority tabs on narrower ears, always reserves an explicit
  More control, and promotes an overflow selection without hiding Home. Pure regression coverage
  now exercises 5, 6, 9, and 12 total tabs plus a narrow-ear case.
- Added Automatic, Low Energy, and Live energy modes. Battery, System, T3, and tunnel polling react
  live to the selected policy and macOS Low Power Mode; optional remote T3 polling stops under a
  constrained policy.
- Stopped global mouse-move processing entirely in click-to-pin mode. Hover mode now forwards only
  movement in a bounded top-of-display interaction band plus the first exit event.
- Hardened monitor lifecycle further: stopped/restarted detached samples cannot publish stale
  results, T3 clears stale sleep/session state, USB setup rolls back partial notification
  registration, and application termination explicitly stops panels, HUD, reminders, activities,
  shared monitors, and event sources.
- Calendar now queries the local calendar day rather than `now + 24 hours`, removes ended meetings,
  keeps all-day events correctly, refreshes EventKit on a slower five-minute query cadence, and
  recognizes safe generic conferencing routes and FaceTime links without a four-provider ceiling.
- Clipboard history now rejects transient/concealed/password-manager pasteboard types and
  high-confidence credential formats, caps text/images/session memory, and exposes Pause and Clear
  controls in both the expanded surface and Quick Actions.
- Now Playing caches decoded artwork and application metadata outside SwiftUI render bodies, while
  media transport, Shelf, Calendar, Timer, and reminder controls gained explicit accessibility
  labels and help.
- Reminder dates retain date-only semantics and declared time zones. Permission recovery is
  idempotent, lifecycle cleanup is explicit, and a reschedule operation is available to actions and
  future snooze surfaces.
- Shelf file copies and deletion run off the main actor, concurrent destination names are reserved,
  capacity is bounded, failures are visible, thumbnails are decoded outside the hot render path,
  and remove/reveal actions no longer depend only on hover discovery.
- Timer input is validated and capped, paused countdown views stop ticking, time can be adjusted,
  completed timers can be repeated, and the new actions are available to App Intents.
- Pulse gained privacy-safe bounded session history, non-destructive delivery profiles, session
  Allow/Mute/Revoke routing for declared source names, provider gallery/health, richer CLI examples,
  and a searchable Quick Actions panel. The UI explicitly states that source names are routing
  labels rather than cryptographically verified provider identities.

### Issues intentionally still open

- The expanded panel still reserves the tallest hosting height. Shrinking the AppKit hosting window
  during a SwiftUI tier transition has a documented reproducible constraint crash; replacing this
  workaround safely needs a separate hosting/window architecture and live UI verification.
- Stable Developer ID signing, Hardened Runtime, notarization, updates, and permission identity were
  not changed. They require an intentional distribution/signing decision and were expressly outside
  this source-only pass.
- MediaRemote and DisplayServices remain private integrations with OS-update and distribution risk.
- Pulse source policy is honest session routing over one local bearer token, not process attestation.
  A future signed-provider design needs per-provider credentials and a migration/revocation model.
- EventKit queries are less frequent and isolated from countdown ticks, but the synchronous
  `events(matching:)` bridge remains on the owning actor to avoid unsafely sending EventKit objects.
- Permission, media-key, display, audio-route, and full UI behavior still need testing against an
  actually signed and launched build. Static Swift parsing cannot prove those OS integration paths.

### Second-loop validation

- Swift frontend parsing passed for all 67 changed or new Swift files.
- Both changed/new JSON files passed `jq` validation.
- The provider shell example passed `bash -n`.
- `git diff --check` passed and no merge markers were present.
- No Xcode build, test build, signing, installation, app launch, permission prompt, commit, or staging
  operation was performed.

## Third features/issues loop — implementation addendum

This source-only pass was completed on 28 August 2026. It concentrated on lifecycle races,
failure-state clarity, protocol integrity, and small user-facing actions that were still absent after
the second loop. As requested, it did not build, sign, install, or launch Islet.

### Additional fixes and features implemented

- Fullscreen detection now takes one window-server snapshot and evaluates windows in each display's
  Quartz coordinate space. This avoids repeated global queries and fixes multi-display origin
  assumptions. Activity lifecycle catalogue coverage is now exact and checked against launch
  registration in Debug builds.
- System-event delivery now has an explicit running state, monotonic timing, and resettable burst
  coalescing. Late callbacks after shutdown are ignored, reconfiguration cannot leak a pending burst,
  and peripheral battery baselines are removed when devices disconnect.
- Battery refreshes coalesce a notification received during an in-flight sample instead of dropping
  it, and the smart-battery reader distinguishes the internal battery from attached UPS devices.
  T3 removes duplicate remote profiles, namespaces cancellation handles, and resets reconnect
  backoff after healthy responses.
- Focus observation watches the containing directory so first creation and atomic file replacement
  recover without restarting Islet. Shelf and Now Playing start/stop paths are now idempotent, and
  media-adapter records are bounded whether or not they include a newline.
- Calendar work is lifecycle-guarded, EventKit change storms are debounced, and rendered occurrences
  have stable identity. Reminders expose loading and actionable failure states, discard stale
  EventKit callbacks, and add calendar-correct **In 1 Hour** and **Tomorrow Morning** snooze actions.
- Clipboard concealment checks are case-insensitive, cover additional high-confidence credential
  formats, preserve the actual PNG/TIFF representation, and show pasteboard write failures. Audio
  reconnects through a no-device interval are detected.
- HUD decoding rejects unknown key states, zero-level bars render correctly, accessible values are
  announced, and CoreAudio prefers a writable master volume element so changing volume does not
  overwrite channel balance. Timer labels and invalid durations are sanitized, paused-zero timers
  complete correctly, and countdown values have spoken duration text.
- Pulse now rejects cross-source identifier overwrites and out-of-range progress, supports guarded
  `end` operations, request/response correlation, stable error codes, strict unknown-field checks,
  fractional ISO-8601 dates, and a token-wide rolling rate limit that survives reconnects. Token
  rotation atomically replaces the credential and disconnects every provider with an explicit
  Settings confirmation.
- The Pulse UI distinguishes visible from retained/filtered work, exposes delivery and stack actions,
  filters payload-free session history, and adds Shortcuts actions for stable event IDs, progress
  updates, and guarded completion. Settings deep links and Quick Actions now route directly to the
  relevant integration page.

### Issues intentionally still open

- Stable Developer ID signing, Hardened Runtime, notarization, updates, and the resulting macOS
  permission identity remain distribution decisions. Source changes cannot make grants portable
  between differently signed development builds.
- Fullscreen detection is still a heuristic based on visible, layer-zero, screen-sized windows.
  There is no supported API that reports every application's Space/fullscreen intent directly.
- Focus continues to depend on Apple's undocumented Assertions file, and MediaRemote and
  DisplayServices remain private integrations with OS-update and distribution risk.
- Pulse uses one user-level bearer token. Source names are routing labels, not authenticated process
  identities; rotating the token revokes every provider rather than one independently credentialed
  provider.
- EventKit, media keys, audio routes, display geometry, clipboard interoperability, and permission
  recovery still need a signed on-device verification pass. Frontend parsing cannot establish that
  those framework and hardware paths behave correctly at runtime.

### Third-loop validation

- Swift frontend parsing passed for every changed or new Swift source file.
- Changed JSON files passed `jq` validation, the shell provider example passed `bash -n`, and the
  standalone Pulse CLI passed Swift frontend parsing.
- `git diff --check` passed and no conflict markers were present.
- No Xcode build, test build, signing, installation, app launch, or permission prompt was performed.
