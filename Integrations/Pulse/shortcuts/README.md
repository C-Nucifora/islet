# Pulse Shortcuts starter kit

These are signed macOS Shortcut files for Islet 1.0 on macOS 26 or later. Open a `.shortcut`
file in Finder, review the actions in Shortcuts, then choose **Add Shortcut**. Islet must be
installed before import so Shortcuts can resolve the `dev.islet` App Intents.

The files are normal signed Shortcut payloads. They are not JSON exports. The readable `.wflow`
sources are kept beside them so changes can be reviewed and re-signed with Apple's `shortcuts`
tool.

| Shortcut | What it sends to Islet |
| --- | --- |
| [01-transient-event.shortcut](01-transient-event.shortcut) | A succeeded event with a title, details, normal priority, and an eight-second expiry. |
| [02-progress-task.shortcut](02-progress-task.shortcut) | Two progress updates at 15% and 75%, then an end command, all for `shortcuts.islet.report-export`. |
| [03-failed-task.shortcut](03-failed-task.shortcut) | A high-priority failed event that stays visible for 30 seconds. |
| [04-guarded-completion.shortcut](04-guarded-completion.shortcut) | An 80% progress item, a local text confirmation, then a succeeded update and end for `shortcuts.islet.guarded-sync`. |
| [05-focus-profile.shortcut](05-focus-profile.shortcut) | The local Pulse delivery profile changes to Focus for ten seconds, then returns to Everything. It sends no Pulse item. |
| [06-focus-timer.shortcut](06-focus-timer.shortcut) | A 25-minute `Focus session` timer and an eight-second event confirming that it started. |

None of these shortcuts read files, contacts, calendar data, network credentials, or Pulse's
provider token. Their only app calls are Islet App Intents. The Focus and timer samples change
only Islet's local state.

## Stable identifiers

The starter kit prefixes every fixed ID with `shortcuts.islet.` so its items remain recognizable.
Keep that prefix when copying a sample. Use one stable ID for the lifetime of one job, and pass the
exact same value to every update and end action.

For example, an export workflow can use `shortcuts.islet.invoice-export-2026-08-31`. Re-running
an update with that ID replaces the existing item instead of adding another row. Generate a new
suffix only when a separate job can overlap. Do not reuse an ID owned by a different Pulse source.

The samples deliberately use fixed IDs so their update and end behavior is easy to inspect. If
you keep a sample for daily use, replace the suffix with an identifier from the work it tracks.

## Troubleshooting

**The Islet action is missing or marked unavailable.** Install and launch the current Islet build,
then quit and reopen Shortcuts. These files target the release bundle identifier `dev.islet`.

**The shortcut reports that Pulse is disabled.** In Islet Settings, enable the Pulse activity under
Activity order. Turning it off closes the listener and rejects Shortcuts updates too.

**A shortcut runs but no item appears.** Check the Shortcuts row in Islet Settings. A muted source
accepts updates without showing them. A revoked source rejects new show, update, and event
commands until you change it back to Allow.

**Progress is rejected.** Use a finite number from `0` to `1`. `0.5` means 50%; `50` is invalid.
Keep the identifier under 128 characters and use the same source, `shortcuts`, for updates and
cleanup.

**An update creates another item.** The identifier changed. Edit the copied Update and End Islet
actions so they use the same literal ID. The progress and guarded-completion samples show the
required pattern.

## Maintaining the files

Run the ordinary release check to confirm the six signed files, their source workflows, and this
guide are present:

```sh
Scripts/validate-pulse-shortcuts.sh
```

On macOS, the deeper check asks the system Shortcuts tool to parse each source workflow and to
re-sign each bundled payload. It does not import anything into your Shortcut library:

```sh
Scripts/validate-pulse-shortcuts.sh --verify-importability
```

When changing a source workflow, create a replacement signed file with the system tool:

```sh
shortcuts sign --mode anyone \
  --input Integrations/Pulse/shortcuts/sources/01-transient-event.wflow \
  --output Integrations/Pulse/shortcuts/01-transient-event.shortcut
```

Use a neutral signing mode, never a personal sharing mode. The checked-in `.shortcut` files are
the files people import; the `.wflow` files are their reviewable sources.
