# Islet UI Improvement Plan

This plan turns the findings in `docs/audit/2026-08-10-ui-audit.md` into independently reviewable
work. The outer 480-point island, black surface, native macOS Settings appearance, and existing
activity architecture are constraints to preserve unless a phase’s tests prove a change necessary.

## Success criteria

- Every interactive control has a human action label, observable state where relevant, keyboard
  reachability, and visible focus treatment.
- Every essential action remains available without pointer hover.
- Reduce Motion eliminates decorative continuous movement while preserving state communication.
- All island surfaces remain usable with 2×-length content, representative localization fixtures,
  increased contrast, and every supported hardware/fallback notch width.
- Loading, empty, denied, and failed states are distinguishable and provide recovery where possible.
- No image decoding, Launch Services metadata lookup, or avoidable heavy parsing occurs during a
  frequent SwiftUI render without measurement that justifies it.
- The complete unit/hosting suite, app build, screenshot matrix, keyboard pass, and VoiceOver pass
  are green.

## Phase 0 — Accessibility hardening (P1)

### 0.1 Establish reusable action semantics

**Primary files:**

- `Islet/UI/IslandIconButton.swift` (new)
- `Islet/Activities/NowPlaying/NowPlayingViews.swift`
- `Islet/Activities/Timer/TimerActivity.swift`
- `Islet/Activities/Shelf/ShelfActivity.swift`
- `Islet/Activities/Clipboard/ClipboardActivity.swift`
- `Islet/UI/IdleDashboardView.swift`
- `Islet/Activities/Calendar/CalendarActivity.swift`

Build a compact wrapper that requires an action label and supports help text, disabled state,
selected/value semantics, and a consistent keyboard-focus appearance. Do not force every icon to
the same visible container; the wrapper should standardize behavior while allowing toolbar,
transport, and inline-row presentations.

**Acceptance:** Accessibility Inspector reports meaningful labels for every icon button; shuffle
and repeat announce state; keyboard traversal reaches controls in a logical order; focused controls
remain visually identifiable.

### 0.2 Remove hover as an essential shelf dependency

Keep the quiet hover overlay for pointer users, but also expose “Remove from Shelf” through a native
context menu and whenever the item or removal control is keyboard/accessibility focused. Add a
targeted test for the item action model rather than asserting source text.

**Acceptance:** A file can be removed individually using pointer, keyboard, and VoiceOver without
clearing the shelf.

### 0.3 Complete Reduce Motion behavior

Inject the SwiftUI `accessibilityReduceMotion` environment value into playback bars, HUD changes,
and timer progress views. Decorative playback bars become static. HUD and timer state still update,
but without interpolation that implies motion.

**Acceptance:** With Reduce Motion enabled, no decorative continuous motion remains; the timer,
volume, brightness, and playback states remain understandable.

## Phase 1 — State clarity and internal adaptivity (P1/P2)

### 1.1 Model recoverable content states

Introduce explicit loading/ready/empty/denied/failed presentation state for Calendar and Reminders.
Use one compact state row with a message and optional native action. Add “Open Privacy Settings” for
denial and retry only for genuinely recoverable failures.

**Acceptance:** A cold launch never claims an empty agenda before loading completes; denial and
failure are distinguishable; every shown action works.

### 1.2 Add a layout stress harness

Create hosting fixtures for:

- 2× English text length;
- representative German and French labels;
- long media titles, artists, device names, volume names, and filenames;
- hardware notches from the smallest supported width through the widest known width;
- the 200-point fallback notch;
- base and tall island heights.

Capture Home, media, timer, battery, system, clipboard, shelf, ports, event sneak, and HUD surfaces.
Store only stable reference fixtures; do not use pixel snapshots for dynamic animation frames.

### 1.3 Make rows adapt inside the fixed island

Use `ViewThatFits`, layout priorities, compact label variants, and deliberate overflow policies.
Start with the battery grid and switcher ear because they carry the most exact arithmetic. Preserve
the 480-point outer width until evidence shows it cannot support a required configuration.

**Acceptance:** Stress fixtures retain actions and reading order, no text overlaps, and truncation is
limited to user-provided names/content rather than system labels or values.

### 1.4 Make Settings resizable

Change `SettingsOpener` to include `.resizable`, give the content a tested minimum size, and treat
440×520 as the ideal initial size rather than an immutable frame.

**Acceptance:** The minimum remains usable, enlarging reveals more form content, and reopening the
window preserves normal macOS window behavior.

## Phase 2 — Measured performance work (P2)

### 2.1 Profile before changing ownership

Record Time Profiler and SwiftUI update traces while:

- changing tracks with large artwork;
- playing with three visible audio sources;
- scrolling shelf thumbnails;
- loading a deliberately large calendar;
- copying a large image with clipboard history enabled.

Keep traces or a concise measurement table under `docs/performance/`. Define a threshold before
implementation: prioritize work that blocks the main thread for a visible frame or repeats on
unchanged identity.

### 2.2 Cache decoded presentation assets

If profiling confirms the source findings, cache decoded artwork and application metadata by stable
identity. Give caches explicit size/eviction behavior. Decode shelf thumbnails when the model accepts
new data, not when a view body happens to render.

**Acceptance:** Re-rendering unchanged media/shelf content performs no decode or Launch Services
lookup; cache invalidation updates immediately when identity changes; memory stays bounded.

### 2.3 Move calendar mapping off the interaction path if measured

Respect EventKit ownership constraints: extract the minimum immutable event fields from EventKit in
the permitted context, then sort and link-detect immutable values away from the main actor. Publish
one result update.

**Acceptance:** Worst-case reload does not cause a visible input/animation hitch and authorization
changes still update correctly.

## Phase 3 — Document the incumbent visual system (P2)

Create `DESIGN.md` from the implementation; do not redesign it. Define semantic roles for:

- island foreground hierarchy;
- subtle/selected plates and dividers;
- positive, caution, danger, and neutral states;
- activity accents and when they may carry identity versus status;
- compact, supporting, body, value, and display type;
- compact/base/tall spacing and radii;
- motion that communicates state versus decorative motion.

Then extract a small token layer only where at least three real call sites share a role. Avoid a
generic design-system abstraction that obscures SwiftUI’s semantic system styles.

**Acceptance:** A new activity can choose colors, type, plate, spacing, and motion without copying a
literal from an unrelated activity; Settings remains native rather than inheriting island styling.

## Phase 4 — Release-quality validation (P3)

Run one bounded final pass covering:

1. full unit and hosting tests;
2. clean signed and unsigned builds;
3. screenshot matrix from Phase 1 in standard and increased-contrast appearances;
4. Reduce Motion on/off;
5. complete keyboard traversal and focus visibility;
6. complete VoiceOver traversal, action labels, values, and announcements;
7. localized/long-content fixtures;
8. built-in notched display, fallback external display, and multi-display movement;
9. drag/drop, context menus, media controls, permissions, empty/error states, and Settings recovery.

Record results next to the audit and re-score all five dimensions. The target is at least **18/20**,
with no P0/P1 findings and no regression to compact panel alignment or menu-bar click-through.

## Suggested delivery slices

| Slice | Work | Risk | Review evidence |
|---|---|---|---|
| A | 0.1–0.3 accessibility and motion | Low–medium | Inspector/VoiceOver notes, keyboard video, focused tests |
| B | 1.1 state modeling | Medium | state tests and screenshots |
| C | 1.2–1.4 adaptivity and Settings | Medium–high | stress matrix and geometry tests |
| D | 2.1 profiling only | None (read-only) | Instruments table/traces |
| E | 2.2–2.3 measured optimization | Medium | before/after timings and memory |
| F | 3 visual documentation/tokens | Medium | `DESIGN.md`, focused visual diff |
| G | 4 final validation | Low | signed checklist and updated audit |

Each slice should remain separately reviewable and revertible. Accessibility semantics come first
because they improve the current UI without destabilizing the notch geometry; adaptive layout comes
before visual token extraction because it establishes the real component boundaries.

