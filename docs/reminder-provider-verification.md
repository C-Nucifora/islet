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
| iCloud | Create, cross-client readback, stale-write rejection, deletion, and cancelling deletion passed | Daily, monthly, and yearly rules and arrival alerts also appeared in Reminders; count-ended recurrence, early-alert interpretation, and notification delivery remain pending | Create and rename passed; color pending | A Reminders flag survived a notes-only Islet edit | Partial |
| Shared iCloud list | Owner-side create/readback, priorities, date normalization, stale-write rejection, deletion and cancellation passed | Daily count exhaustion, weekly/monthly/yearly rules, date-end readback, and saved absolute/relative/location alarms passed; delivery pending | Rename and restoration passed; color pending | Flags, owner assignment, tags and a subtask survived notes-only edits | Partial; owner-to-Ned marker sync observed, reverse-direction receipt pending |
| Exchange | Unavailable | Unavailable | Unavailable | Unavailable | Not configured |

The iCloud run also exposed EventKit normalization when a floating date-only start is combined with a timed due date in an explicit time zone. Islet now permits the instant-preserving staged conversion, commits it, and keeps the editor open with the provider's changed start and due values highlighted. Reloading showed the provider's actual floating midnight start and floating timed due value; Reminders showed the same due instant.

## Personal iCloud follow-up, 12 September 2026

The follow-up used commit `fa6f0e872fe1369f750597c349b490604c7188b5`, built locally as a signed arm64 Debug app. The build passed under a 600-second timeout with `.build/pr-249-provider-dd` as its DerivedData directory. The installed app was stopped before launching this build. No app-hosted tests ran during this manual check.

The owner authorized creating and removing disposable records in personal iCloud only, and explicitly left shared-list checks pending. Tests used a new personal list, renamed to `Islet PR249 personal verification`. An Exchange list was visible on this Mac but was outside that authorization. The earlier matrix's account-availability notes describe the original reviewer's Mac.

| Check | Observed result |
| --- | --- |
| Plain-list creation and rename | Both saved through Islet and appeared in Reminders. |
| Daily recurrence | The date-only reminder appeared as Daily in Reminders. Completing it in Reminders produced an incomplete occurrence due tomorrow. |
| Count-ended recurrence | A three-occurrence daily rule was entered in Islet, but Reminders showed End Repeat as Never after completion. The remaining count was not read back in Islet or exercised to exhaustion, so this case is unconfirmed. |
| Custom monthly recurrence and date end | Every two months on the last Monday appeared in Reminders. Its native details showed an end date of 31 December 2030. Reopening in Islet retained the two-month interval and end date. |
| Yearly recurrence and arrival alert | Editing the same record to February 1 each year and adding an arrival alert at a public landmark saved successfully. Reminders showed Yearly and the matching arrival-location title. Geofence delivery was not exercised. |
| Relative alert | A 15-minute early alert survived saving and reopening in Islet. Reminders displayed the alert's earlier time on its row. Native early-reminder interpretation and delivery remain unconfirmed. |
| Absolute alert | An alert for 10:38 pm on 12 September saved through Islet and appeared at that time in Reminders and the calendar widget. No delivered notification was verified. |
| Delete and cancel | Cancelling Islet's deletion confirmation left the record in both apps. Confirming deletion of the yearly test removed it from Reminders and moved it to Recently Deleted. |
| List color | The UI automation could not open a usable color picker through the color well, its accessibility action, or keyboard navigation. No color change was verified. |

UI automation also encountered repeated ScreenCaptureKit capture failures and window lookup errors. These blocked further inspection; they do not establish an Islet defect. No production-code change resulted from this run.

Cleanup removed the disposable list and its remaining test records through Reminders. The temporary PR app exited before the installed `/Applications/Islet.app` was restored. Shared lists and existing reminders were not edited. This PR remains a draft until the outstanding provider and delivery checks have evidence.

## Shared iCloud setup, 12 September 2026

The owner subsequently authorized a dedicated list shared with `nedlane` for the remaining checks. `Islet PR249 shared verification` was created under iCloud in Reminders, and its collaboration invitation was sent to Ned Lane through Messages at 10:48 pm. The list was empty when invited. Existing lists were not shared or modified.

At the end of the 12 September setup, invitation acceptance and shared-list round trips had not been verified. Native UI access began returning `cgWindowNotFound` and invalid-element errors, preventing further inspection. The test list was left available for Ned to join; the setup alone was not a passing shared-provider result.

## Shared iCloud follow-up, 13 September 2026

Native UI access recovered. Reminders' sharing sheet listed two participants, the owner and Ned Lane, without a pending-invitation label. This establishes the displayed membership only; no observation from Ned's device was available.

The run used the previously built signed arm64 Debug app from `fa6f0e872fe1369f750597c349b490604c7188b5`. PR head `1018164e44647e0eeda06a4c59e56c28be24b463` contains the same production code and subsequent verification documentation. No Islet process was running before launch. No app-hosted tests or production-code edits were needed for this manual run.

All mutations were confined to `Islet PR249 shared verification` and its disposable records. The following results compare Islet with native Reminders on the owner's Mac, using the shared iCloud provider. They do not establish synchronization to a second participant's device.

| Check | Observed result |
| --- | --- |
| Create and readback | Islet selected the shared list and created `PR249 shared fields test`. Native Reminders displayed the title, notes, date-only 1 January 2020 due date, and high priority. A later marker with no due date also appeared. |
| URL | The PR URL survived saving and reopening in Islet, including native edits between saves. The native details URL field did not display it. Native URL presentation remains unconfirmed. |
| Priority categories | None, High, Medium, and Low each appeared in Reminders after Islet saves. |
| Native flags and assignment | Reminders added a flag and assigned the first record to the owner. Both remained after a notes-only Islet save. |
| Stale-write rejection and reload | An edited Islet draft was left open while Reminders committed a conflicting title. Islet rejected Save with "That reminder changed in another app, so it was not overwritten." Reload showed the native title and notes. An earlier attempt had left the native row editing, so it was not counted as a committed conflict. |
| Daily recurrence and count end | A daily rule ending after two occurrences saved. Completing it in Reminders produced an incomplete occurrence due tomorrow. Completing that occurrence left two completed records and no incomplete successor. |
| Weekly selectors | Every two weeks on Monday and Wednesday appeared with that exact rule in Reminders. Reopening in Islet retained interval 2 and weekday selectors `2:0,4:0`. |
| Monthly selectors and date end | Every two months on the last Monday appeared in Reminders. Reopening the rule in Islet retained the interval and 31 December 2030, 9:00 am end date. |
| Yearly selectors | Changing the rule to every year, month 2 and month day 1, saved. Reminders displayed "Every year in February". The native row does not establish the month-day selector independently. |
| Start/due normalization | A floating, date-only start on 31 December 2019 and a timed 1 January 2020 due date in `Australia/Sydney` saved with normalization warnings. Islet kept the editor open and highlighted start and due changes. Reload showed a floating midnight start and floating 9:00 am due value. |
| Relative alarm | The minus-15-minute alarm survived save and reload. Reminders displayed 8:45 am while Islet retained the 9:00 am due time. Native Early Reminder semantics were not independently confirmed. |
| Absolute alarm | An alarm for 13 September 2026 at 8:02 am saved and survived reopening alongside the relative alarm. No delivered notification was observed. Notification Centre exposed a calendar widget, and attempts to inspect system controls timed out, so this is saved-data evidence only. |
| Arrival and departure alarms | An arrival alarm at a public landmark appeared as Arriving in Reminders. Reopening retained latitude -33.8568, longitude 151.2153 and radius 100 metres. Changing the same alarm to Leaving appeared in Reminders. No physical geofence crossing was performed. |
| Native tags and subtask | A native `PR249Test` tag survived a notes-only Islet edit. A native subtask then survived a further notes-only edit, along with the tag, departure alarm and yearly recurrence. Reopening the native list refreshed its initially stale displayed notes. |
| Shared-list rename | Islet renamed the list to `Islet PR249 shared verification renamed`; Reminders displayed the change and retained the shared badge. Islet then restored the original name, which also appeared in Reminders. |
| List color | The color well's accessibility action and a click on the visible control did not expose a usable picker. No color mutation was verified. |
| Delete and cancel | Cancelling Islet's confirmation retained the parent and native subtask. Confirming deletion removed both from the shared list and added two records to Recently Deleted. |

Cleanup removed both completed daily occurrences through Reminders' recoverable deletion. The shared list then showed zero incomplete and zero completed reminders. The test-only tag disappeared from the active tag list. A single new, undated `PR249 owner sync check` marker was then created through Islet and verified in Reminders. It has no alarms and remains for Ned's device check; its notes ask Ned to add `PR249 Ned sync check` after he sees it. The shared list itself remains available. The temporary PR app exited, and `pgrep -x Islet` confirmed no Islet process remained.

Remaining shared acceptance work:

- Confirm receipt of `PR249 Ned sync check` on the owner's device. The owner marker has now been observed on Ned's Mac, and Ned's marker was created and read back there; the reverse-direction receipt remains pending.
- Verify delivered time and location notifications, native Early Reminder interpretation, and native URL presentation.
- Verify list color through a usable picker. Native reminder-info actions also stopped opening a details popover, so attachment preservation and exact completion-date comparison were not exercised.
- Exercise a participant with read-only or revoked access, or a provider that refuses list creation. The current owner remains writable; no such account or permission condition was available in this run.

No new code defect was established. The PR remains a draft while the unverified acceptance cases are outstanding.

## Ned's sync check and integration follow-up, 13 September 2026

On Ned's Mac, native Reminders and a fresh public EventKit read both found `PR249 owner sync check` in `Islet PR249 shared verification`. This provides a second-device observation of the marker created on the owner's Mac.

Ned explicitly authorized one undated, alarm-free `PR249 Ned sync check` and a PR update. A public EventKit helper created that single reminder in the existing shared list. A separate EventKit process read it back as incomplete, with no start date, due date, or alarms. Native Reminders displayed both markers and a list count of two. No existing reminder or list was changed. The new marker remains for the owner to observe.

Owner-to-Ned synchronization is observed. Ned-to-owner synchronization still requires confirmation on the owner's device. This check used public EventKit and native Reminders, not a new Islet-editor round trip. It does not verify notification delivery or any other outstanding provider-matrix item.

Current `main` was merged into the PR branch. The only merge conflict was in the localization catalog: `Complete %@` from the Home layout changes now coexists with `Completed` and `Completion date` from reminder editing. Existing branch deletions and translations were retained.

## Provider acceptance checklist

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
