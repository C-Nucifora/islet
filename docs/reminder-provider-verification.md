# Reminder provider verification

Issue #225 adds public EventKit reminder editing to the existing keyboard creation flow.

## Implemented

- New Reminder remains available in the empty Home dashboard and Reminder Commands window. Command-N opens the editor and focuses the title. Return saves, Escape cancels, and Return in Notes inserts a newline.
- The quick form contains title, writable list, due date, optional time, and priority. Details contains notes, URL, start date, floating or explicit time zones, completion date, alerts, and repeat rules.
- Alerts support absolute dates, relative offsets, and arrival or departure locations. Place search uses MapKit. Coordinates and radius can also be entered directly.
- Repeat rules support frequency, interval, weekday ordinals, month days, months, week numbers, year days, set positions, and date or count ends. Invalid combinations stay in the rule editor with an error.
- Manage lists creates plain lists in a selected account, and changes the name or color of mutable lists. Account and source failures stay inline. An unconfirmed commit disables retry to avoid duplicate creation.
- Reminder deletion uses the existing revision check and confirmation. List deletion, sharing, Smart Lists, and list groups open in Reminders.

Islet edits the fetched reminder object and only assigns changed fields. Alarms and repeat rules that cannot be recreated exactly remain attached. Revisions include all readable alarm and recurrence properties. A stale revision rejects a save. Provider normalization retains the editor and publishes the actual saved values.

Flags, tags, subtasks, sections, attachments, assignees, shared-list management, templates, grocery categorization, pinning, groups, and messaging triggers are not editable through public EventKit. Use Open in Reminders for those fields. Islet does not script Reminders or use private reminder APIs.

## Automated checks

Focused tests cover core patches and explicit clearing, date-only and time-zone handling, stale-write rejection, unknown commits, retry identities, deletion, alarm and recurrence round trips, opaque alarm preservation, invalid coordinates and selectors, provider normalization, list immutability, external list changes, keyboard command routing, and dashboard reconciliation.

Run all reminder test classes with the repository's safe test workflow. Tests must run serially, with the installed Islet app stopped, a hard timeout, and a DerivedData directory belonging to the current worktree.

## Recorded automated run

On 12 September 2026, the final full run completed with xcodebuild exit 0. XCTest executed 1,763 tests with zero failures and one skip. The live menu-bar accessibility check skipped because the test host lacked Accessibility permission. All seven Swift Testing localization tests passed.

The run used `.build/provider-full-tests`, disabled parallel testing, and a 1,200-second hard timeout. `pgrep -x Islet` found no running app before or after the run. XCTest completed in 64.14 seconds without cancellation, timeout, or process termination. Production preferences were unchanged.

The repository test wrapper records the owned process tree and limits timeout cleanup to the permitted test-host and compiler executables.

The localization catalog contains 1,733 keys. Catalog synchronization reports no missing or stale entries. Existing English localizations and plural variants remain intact; the pseudolocale follows the tested key and plural expansion rules.

## Manual provider matrix

These checks require real accounts and cross-client observation. The available personal iCloud account was partially exercised on 12 September 2026. Local and Exchange accounts were not configured on the test Mac. A shared iCloud list was present but was not modified.

| Provider | Reminder fields and deletion | Alerts and recurrence | Plain-list name and color | Native-only metadata | Status |
| --- | --- | --- | --- | --- | --- |
| Local | Unavailable | Unavailable | Unavailable | Unavailable | Not configured |
| iCloud | Create and cross-client readback passed; deletion pending | Weekly recurrence and a departure alert appeared in Reminders; remaining alerts and delivery pending | Create and rename passed; color pending | Pending | Partial |
| Shared iCloud list | Pending | Pending | Pending, where permitted | Pending | Available, not modified |
| Exchange | Unavailable | Unavailable | Unavailable | Unavailable | Not configured |

The iCloud run also exposed EventKit normalization when a floating date-only start is combined with a timed due date in an explicit time zone. Islet now permits the instant-preserving staged conversion, commits it, and keeps the editor open with the provider's changed start and due values highlighted. Reloading showed the provider's actual floating midnight start and floating timed due value; Reminders showed the same due instant.

For each available provider:

1. Create from an empty dashboard using only the keyboard. Verify the selected list and title focus, then reopen the reminder in Reminders.
2. Set notes, URL, start and due dates, date-only values, floating time, an explicit time zone, every priority category, and completion state. Reopen from each client and compare values. A date-only value must remain without a clock time.
3. Add absolute, early, arrival, and departure alerts. Check delivered notifications separately from saved alarm data.
4. Save daily, weekly, monthly, and yearly rules, custom selectors, and count and date ends. Complete an occurrence in Reminders and verify the next occurrence.
5. Edit the same reminder in Reminders while its Islet editor is open. Verify Islet rejects the stale save. Remove or make its list read-only and verify Islet does not select a different list.
6. Add tags, flags, subtasks, attachments, or assignments in Reminders. Change only notes in Islet. Reopen in Reminders and confirm those fields remain.
7. Create a plain list, rename it, and change its color. Verify another client sees each change. Test an immutable list and a provider that denies list creation.
8. Delete a reminder in Islet, confirm it disappears in Reminders, and verify cancelling the confirmation leaves it intact.

The optional Create Reminder App Intent remains deferred until account and cross-client verification is complete.
