# Public EventKit reminder parity design

## Goal

Make reminder creation and editing in Islet fast for common work and complete for every reminder field that macOS EventKit can safely write. Keep Apple-only fields intact and hand them to Reminders.app instead of using private APIs or AppleScript.

GitHub issue: #225

This work builds on issue #21 and PR #180.

## Product boundary

Islet will edit these public EventKit reminder fields:

- title, notes, and URL
- writable reminder list
- start date components
- due date components, including date-only values
- date-component time zones, including floating values
- priority
- completion state and completion date
- absolute, relative, and arrival or departure location alarms
- recurrence frequency, interval, selectors, and end condition
- reminder deletion
- plain reminder-list title and color, plus list creation and deletion where the account permits them

Islet will not claim to edit fields that EventKit does not expose. These include flags, tags, subtasks, sections, attachments, assignees, collaboration settings, Smart Lists, templates, grocery categories, pinned state, list groups, and messaging triggers. It will also preserve inherited calendar-item location and time-zone values rather than presenting them as reminder fields. Islet will launch Reminders.app for those features.

The implementation will not use Reminders scripting. Scripting adds a second data path, an Automation permission, and weaker conflict handling. It also exposes only a small part of the missing native model.

## Existing base

PR #180 supplies:

- `ReminderDraft` and `ReminderWriteRecord`
- a source-revision check before every edit
- a final revision check against the fetched `EKReminder`
- create, update, move, reschedule, complete, and undo operations
- writable-list filtering
- a regular key editor window with keyboard and VoiceOver support

The first repair on that PR keeps New Reminder and completion undo visible when the dashboard is empty. Issue #225 extends those types instead of adding another writer.

## Data model

### Date values

`Date` alone cannot represent EventKit's floating and date-only semantics. The editor will use a validated plain value that stores Gregorian date components:

```swift
struct ReminderDateValue: Equatable, Sendable {
  let components: DateComponents
}
```

No hour, minute, or second means date-only. A nil component time zone means floating time. Construction rejects non-Gregorian calendars, missing dates, and partial clock values before EventKit can raise an Objective-C exception. Conversion back to EventKit preserves the exact date-only, floating, or named-zone form.

The date editor converts through a supplied calendar and time zone. Tests use fixed Gregorian calendars around daylight-saving boundaries. No conversion uses the current machine zone implicitly once the draft contains an explicit zone.

### Alarm values

Alarms become plain values so mapping and validation can be tested without saving EventKit objects:

```swift
enum ReminderAlarmValue: Equatable, Sendable {
  case absolute(date: Date)
  case relative(offset: TimeInterval)
  case location(
    title: String,
    latitude: Double?,
    longitude: Double?,
    radius: Double,
    proximity: ReminderAlarmProximity)
}
```

Semantic alarm values do not contain editor row IDs. The alarm editor wraps each value in a separate row model with a UUID. Re-reading the same `EKAlarm` must produce an equal value and an equal revision fingerprint.

Location search uses public MapKit search. A selected result supplies title and coordinates. The user chooses arrival or departure and a radius. Islet does not need to capture the user's location to resolve a typed place.

EventKit may reject alarms for a provider or truncate excess alarms. Islet stages the save without committing, verifies every changed alarm, commits, then re-fetches and checks again. A staged mismatch resets the EventKit store and keeps the editor open. A provider that normalizes data only after commit returns its actual saved value and an explicit error rather than a false success.

Existing alarm types that the editor cannot represent are never removed. Alarm edits remove and replace only alarms Islet decoded faithfully. Older email, audio, malformed, unknown, and deprecated procedure alarms stay attached. The store treats their original array positions as anchors. It fills the original editable slots from the user's edited values, drops unused editable slots, and appends extra editable alarms after the last original slot. The same deterministic merge applies to recurrence arrays. The editor explains opaque values and offers Open in Reminders.

### Recurrence values

A recurrence value mirrors the writable `EKRecurrenceRule` constructor:

- daily, weekly, monthly, or yearly frequency
- positive interval
- days of the week with optional ordinals
- days of the month
- months of the year
- weeks of the year
- days of the year
- set positions
- no end, end date, or occurrence count

The draft stores an array because `EKCalendarItem.recurrenceRules` is an array. Common presets produce one simple rule. The custom editor exposes every selector supported by the public initializer.

EventKit recurrence rules are immutable. Islet reconstructs a candidate rule and compares every readable property. It replaces only rules it can reproduce through the public initializer and preserves opaque rules, including rules whose calendar identifier or first weekday differs from the reconstructed value. Nil and empty selector arrays have one canonical representation. Set positions require at least one selector that produces a result set. A recurring reminder must have a due date, and validation rejects a recurrence patch without one before EventKit save.

### Editable snapshot and patch

The draft carries the editable source snapshot captured when the window opened. Submitting an edit compares the current draft with that source and creates field changes:

```swift
enum ReminderFieldChange<Value: Equatable & Sendable>: Equatable, Sendable {
  case unchanged
  case value(Value)
}
```

Optional fields use `ReminderFieldChange<Wrapped?>`, so unchanged and explicitly cleared remain distinct.

`ReminderPatch` has one field change for title, notes, URL, list ID, start date, due date, priority, completion state, alarms, and recurrence rules.

The store fetches the existing `EKReminder`, checks the source revision again, then assigns only changed fields. It never constructs a replacement reminder for an update. Fields that EventKit does not expose are never read or assigned, which gives them the best chance of surviving a public-field edit.

Creation uses a full `ReminderEditableFields` value rather than a patch.

### Revisions

The revision fingerprint expands to include every public field Islet exposes, plus `lastModifiedDate`, list identifier, completion date, inherited calendar-item location and time zone, and every readable property on every alarm and recurrence rule. Alarm fingerprints include raw type, absolute date, relative offset, structured-location title, coordinate, radius, proximity, email address, sound name, and any readable URL. Recurrence fingerprints include calendar identifier, frequency, interval, first weekday, every selector, and the full end. Editability is separate from fingerprinting. The implementation never uses `description` as revision data. `lastModifiedDate` remains the first broad signal. The value fingerprint protects accounts that return a missing or coarse modification date.

An external change after the editor opens rejects the submission. Islet does not merge two writers silently. The editor stays open and offers Reload.

Calendar and item identifiers are not sync-proof. Every final operation resolves the current identifier and fails with a missing-item or missing-list error when it no longer exists.

## EventKit adapter

`ReminderWriteCoordinator.swift` is already large. Issue #225 splits responsibilities:

- `ReminderWriteModels.swift` owns date, alarm, recurrence, editable snapshot, patch, and validation values.
- `ReminderEventKitCodec.swift` maps `EKReminder`, `EKAlarm`, and `EKRecurrenceRule` to and from plain values.
- `ReminderWriteCoordinator.swift` owns permission, revision, normalization, patch creation, and user-level result handling.
- `EventKitReminderWriteStore.swift` fetches live EventKit objects, applies patches, saves, deletes, and re-reads.
- `ReminderListWriteCoordinator.swift` owns list and source value models plus create, rename, recolor, and delete operations.

The EventKit store stays on the main actor, matching the existing provider. Tests use a plain fake store for coordinator behavior and direct unsaved EventKit objects for mapper behavior.

## List management

List rows add source identifier, source title, immutability, and item-write capability. A list can accept reminder changes while its own title or color is immutable, so item writability and list editability remain separate flags.

New plain lists use `EKCalendar(for: .reminder, eventStore:)`. The user selects an EventKit source. The default reminder list's source is selected first when available. EventKit has no reliable preflight for every account provider, so source-level save failures appear inline.

Rename, recolor, and delete resolve the live calendar again. Rename and recolor reject immutable calendars. Delete is available only for a non-immutable calendar whose allowed entity types contain reminders alone. Its confirmation names the list and states that its reminders will be deleted. EventKit performs the deletion only after the user confirms it.

Islet does not create Smart Lists, grocery lists, sections, icons, or list groups because public EventKit has no model for them.

## Editor interaction

The editor remains a regular key window. It becomes resizable and uses a scroll view.

The first screen keeps the quick path short:

- focused title
- list
- due date and optional time
- priority
- Add or Save

Details uses disclosure sections:

- Notes and link
- Start, due, and time zone
- Completion state
- Alerts
- Repeat

Alerts and recurrence each open a focused editor instead of placing every advanced field in the main form.

Return saves when focus is not inside a multiline field. Escape cancels. Command-N opens a new reminder. Delete requires a confirmation and never uses Return as its default action.

Editing an existing reminder always shows Open in Reminders. When Islet detects an alarm or recurrence rule it cannot represent, it explains what Islet will preserve and puts that handoff beside the message.

The list manager opens from the reminder column. It supports New List, Rename, Color, and Delete only when the selected account and list allow the operation.

## Provider flow

The write API distinguishes an exact save from a provider-normalized commit:

```swift
struct ReminderNormalizationMismatch: Equatable, Sendable {
  let field: ReminderField
  let reason: String
}

enum ReminderWriteOutcome: Equatable, Sendable {
  case saved(ReminderWriteRecord)
  case committedWithNormalization(
    actual: ReminderWriteRecord,
    mismatches: [ReminderNormalizationMismatch])
}
```

On `.saved`, the provider publishes the returned record and closes the editor. On `.committedWithNormalization`, the provider publishes the provider's actual committed record, keeps the requested field values in the editor, and shows every field-specific mismatch. It also rebases the draft's identifier, origin, baseline, and revision onto `actual`. A normalized create therefore becomes an edit of the committed reminder, and a retry patches that reminder at its new revision instead of creating a duplicate. Only a failure before commit leaves the old dashboard item unchanged. The store applies only fields marked as changed and keeps observing `EKEventStoreChanged` after either committed outcome.

Creating a reminder selects the writable system default. If that list is absent or read-only, Islet selects the first writable list in the same stable order shown by the picker. Once the user chooses a list, a missing or read-only selection fails without falling back.

Delete removes the item only after EventKit confirms success. A store-change reload reconciles later account changes.

List changes refresh available lists and reminder rows. If the selected list disappears while an editor is open, save fails rather than selecting another list.

## Errors

User-facing errors distinguish:

- permission lost
- reminder or list missing
- list became read-only
- reminder changed elsewhere
- invalid title, URL, dates, recurrence, alarm, or location radius
- provider rejected an alarm, recurrence, list change, or deletion
- unsupported alarm representation that requires Reminders.app

Raw EventKit text appears only as a final detail after Islet's actionable message.

## App Intent

After the in-app writer has passed provider and cross-client checks, Islet will add a basic Create Reminder App Intent for title, notes, due date, priority, and writable list. It calls the same coordinator and does not start a second EventKit implementation.

The intent returns a clear permission or provider error. It does not try to represent the full advanced editor in Shortcuts parameters.

## Verification

Automated tests cover:

- date-only, timed, floating, explicit-zone, and daylight-saving round trips
- invalid Gregorian dates, spring-forward gaps, fall-back overlaps, and Mac time-zone changes
- alarm mapping, validation, unsupported-alarm preservation, and provider rejection
- stable alarm fingerprints that ignore editor row identity
- every readable opaque-alarm property participating in stale-write detection
- simple and advanced recurrence mapping and end conditions
- recurrence calendar identifiers, first weekdays, selector canonicalization, and multiple rules
- required due dates for recurrence
- field-level patches and explicit clearing
- external edit rejection across every writable operation
- creation, editing, completion, and deletion
- writable and immutable list behavior
- keyboard-facing presentation decisions and error state
- App Intent input normalization through its writer boundary
- normalized-create and normalized-update retries against the committed identifier and revision

Manual checks cover behavior EventKit cannot emulate in a unit test:

- local and iCloud accounts
- a shared list
- Exchange or another non-iCloud provider when available
- actual date, early, and location notification delivery
- recurrence as shown by Reminders.app
- native-only tags, subtasks, attachments, flags, and assignments surviving an Islet edit
- list creation and deletion sync across devices

Unavailable account types are recorded as not tested. They are not reported as passing.

## Delivery order

1. Land PR #180 after its empty-state and undo repair.
2. Add plain edit models, mapper coverage, field-level patches, core fields, and deletion.
3. Add alarm, location search, and recurrence editors.
4. Add plain-list management.
5. Run provider and cross-client checks.
6. Add the Create Reminder App Intent, rerun regression checks, request Ned's review, and merge only after CI and review pass.
