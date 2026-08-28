# Islet new-feature and product roadmap audit

Audit date: 28 August 2026
Code reviewed: `3cdc9f18b5cc` on `t3code/audit-performance-features-roadmap`

## Product verdict

Islet should not win by becoming a longer list of hard-coded mini-widgets. Apple and other menu-bar utilities can copy individual battery, media, calendar, timer, and system-stat views. Islet's defensible product is a **universal, programmable live surface for Mac**: one place where anything currently important can appear briefly, explain itself, and offer the next action.

The current T3 integration is the clearest proof. An agent that needs input is exactly the kind of transient, actionable state the notch is good at. The same model applies to builds, downloads, CI, file transfers, meetings, focus sessions, deliveries, Home Assistant, and user scripts.

## The killer feature: Islet Pulse

**Build an open Activity Provider protocol and turn the notch into a ranked action stack.**

Today every activity is compiled into the app and every active activity becomes a tab. Pulse would let a local app, script, Shortcut, CLI, or remote service publish a small lifecycle object:

```json
{
  "id": "build-uqr-av-1842",
  "source": "github-actions",
  "title": "UQR-AV build failed",
  "subtitle": "2 tests need attention",
  "progress": 1.0,
  "state": "needsAction",
  "priority": "high",
  "expiresAt": "2026-08-28T04:00:00Z",
  "actions": [
    { "title": "Open logs", "url": "https://…" },
    { "title": "Retry", "intent": "retry-build" }
  ]
}
```

Islet owns rendering, permission boundaries, expiry, ordering, quiet hours, animation, accessibility, and energy policy. Providers never inject SwiftUI or run inside Islet. Start with:

- a local Unix socket or loopback endpoint;
- a tiny `islet` CLI (`show`, `update`, `end`, `event`);
- a signed provider identity and per-provider permission screen;
- URL actions first, then an authenticated callback/App Intent mechanism;
- JSON Schema plus Swift and shell examples;
- rate limits, payload limits, deduplication, and automatic expiry.

The visible UI becomes a maximum of three urgent/relevant items and a labelled “More” stack, fixing the current notch overflow as part of the product improvement. Completed or low-priority items fall into a short history rather than becoming permanent tabs.

Why this is the killer feature:

- It makes the app useful beyond the developer's own compiled integrations.
- It creates a community/integration moat rather than a UI-only moat.
- It turns every existing feature into a reference provider using one lifecycle model.
- It makes the notch feel live and contextual instead of like a cramped preferences toolbar.
- It lets Islet own native Mac workflows that Apple's iPhone-originated Live Activities do not cover.

## The important platform change arriving next

As of this audit, **macOS 27 is still beta**; Apple published beta 7 on 24 August 2026 ([Apple releases](https://developer.apple.com/news/releases/?id=08242026c)). Three platform directions matter:

1. **Foundation Models becomes a multi-provider, multimodal framework.** Apple's macOS 27 guide says apps can use Apple on-device models or other providers through a common Language Model protocol, with tools and Dynamic Profiles ([Apple's macOS 27 guide](https://developer.apple.com/wwdc26/guides/macos/)).
2. **App Intents gains richer Siri schemas and view annotations.** This can expose Islet entities and actions to natural language without teaching users exact phrases (same [macOS 27 guide](https://developer.apple.com/wwdc26/guides/macos/)).
3. **MetricKit gains a modern async `MetricManager` and state-contextualized reports.** Islet can finally measure CPU, memory, network, hangs, and energy by feature state in real use ([Apple MetricKit updates](https://developer.apple.com/documentation/updates/metrickit)).

Apple's Live Activities already surface iPhone activities in the Mac menu bar, using compact and expanded presentations, and tapping them opens the iPhone app through iPhone Mirroring ([Apple HIG](https://developer.apple.com/design/human-interface-guidelines/live-activities)). Islet cannot assume it can read or re-host other apps' Live Activities. Treat them as a competitive signal: Apple validates the menu bar as a live-status surface, while Islet should specialize in local Mac/system/developer activity and programmability.

### The macOS 27 feature to build

After Pulse exists, add an **optional private briefing/action layer**, not a generic chatbot:

- “What needs me now?” summarizes only the currently published Pulse objects.
- “Quiet everything except build failures until 2 pm.” creates a rule through App Intents.
- “Start a 25-minute focus session and hide media.” invokes deterministic Islet actions.
- Before a meeting, combine the next event, overdue reminders, active T3 agents, and relevant provider items into a three-line brief.

All deterministic selection, permissions, and actions must work without AI. The model only summarizes or translates intent into inspectable rules. That preserves speed, privacy, and predictable battery use.

## Prioritized feature recommendations

| Priority | Feature | User value | Important constraint |
|---|---|---|---|
| 0 | Permission & Health Center | Fixes the most confusing current failures; shows Calendar, Reminders, Accessibility, Bluetooth/location, helper, T3 and signing state | Must diagnose app identity/path, not just say “denied” |
| 0 | Energy modes | “Automatic,” “Low energy,” and “Live” policies; suspend nonessential work on battery/Low Power Mode/lock | Implement monitor lifecycle first |
| 1 | Pulse provider API and CLI | Makes Islet universal and community-extensible | Out-of-process, authenticated, rate-limited |
| 1 | Ranked Now Stack and explicit overflow | Eliminates notch collisions and prioritizes action over tabs | At most three visible items; accessible keyboard navigation |
| 1 | Command palette and hotkey | Open/search all activities and act without precise notch pointing | User-configurable; no keylogging-style broad capture |
| 1 | Rules and Focus profiles | “In meetings,” “on battery,” “at work,” “while presenting,” “when this app is frontmost” | Explain every automatic decision |
| 1 | Transfer/download/build provider pack | Immediate high-value activities: browser downloads, Xcode builds, GitHub Actions, AirDrop/share progress | Prefer supported APIs/providers over filesystem polling |
| 2 | Full calendar command center | Multi-day agenda, travel/leave-now, conferencing, timezone, quick snooze, reminder reschedule | Correct permissions and date-only semantics first |
| 2 | Audio/device control center | Per-device route, output capability, AirPods details, microphone-in-use, safe HUD test | Never suppress system controls on failure |
| 2 | Session history | A privacy-conscious “what happened” timeline for dismissed events and completed activities | Local, bounded, opt-in; never retain clipboard contents by default |
| 2 | Cross-device companion | Publish Islet-owned timers/T3/build states as the app's own Live Activities where ActivityKit permits | Do not claim access to other apps' Live Activities |
| 3 | Provider gallery | One-click documented providers for Shortcuts, Home Assistant, CI, dev tools | Signed manifests, permissions, review/revoke UI |

## Settings redesign as a feature

Settings should become a product-quality control center:

- **Overview:** Islet health, current energy mode, permissions, active providers, version/update.
- **Surface:** interaction, size/density, visible priorities, overflow behaviour, all displays.
- **Activities:** built-in providers with separate “run” and “show” semantics only when needed.
- **Events:** grouped event sources with preview/test buttons.
- **Integrations:** T3 and future Pulse providers, credentials, connection health, rate.
- **Permissions & Privacy:** exact OS status, app identity/path, open-System-Settings actions, clipboard exclusions, retained data.
- **Advanced:** sampling rates, diagnostics export, Debug mode, reset/import/export.

Search should find both pages and individual controls. The window should be resizable and preserve its size. Every activity needs a one-line explanation of cost and data access.

## Suggested delivery sequence

### Phase 0 — Trust and efficiency (release blocker)

- Stable Developer ID/development signing and one bundle identity.
- Fix the HUD fail-safe path and expanded rendering.
- Permission & Health Center.
- Stop disabled monitors; reduce Battery/System/T3 cadence; clean up the media helper.
- Replace tab overflow with bounded visible priorities plus More.
- Remove Debug menu from Release; fix concurrency warnings and flaky timing test.

**Exit criterion:** signed Release build meets the performance budgets and can explain every missing permission or inactive feature.

### Phase 1 — Pulse foundation

- Define activity/event/action schemas and lifecycle semantics.
- Refactor built-in activities to the same internal model.
- Ship local socket/CLI provider and diagnostics.
- Add history, deduplication, rate limits, provider enable/revoke, and sample scripts.

**Exit criterion:** a third-party shell script can safely create, update, action, and end an Islet activity without changing Islet's source.

### Phase 2 — Action Stack experience

- Relevance/urgency scoring with deterministic rules.
- Keyboard palette, More/history surface, snooze/mute/source controls.
- Focus, presentation, battery, app-frontmost, and time-based policies.
- Provider pack for Xcode/CI/downloads/Shortcuts.

**Exit criterion:** nine simultaneous activities remain understandable and never collide with the notch.

### Phase 3 — macOS 27 intelligence

- App Intents for timers, activity lookup, snooze, focus rules, T3 actions, and providers.
- Optional on-device “What needs me now?” briefs over already-authorized data.
- MetricKit `MetricManager` plus feature-state reporting to prove energy improvements in the field.

**Exit criterion:** every AI-generated rule is previewable, editable, deterministic at execution time, and optional.

## Features not to add yet

Do not add weather, stocks, generic notifications, more system charts, chat, or more permanent tabs before Phase 0 and the provider model. They would increase polling, permissions, Settings length, and notch pressure while making Islet less distinctive.

The strongest next release is therefore not “ten more widgets.” It is **a reliable Islet with Pulse: the programmable, energy-aware action surface for whatever needs attention on the Mac right now.**
