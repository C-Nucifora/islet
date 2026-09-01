# Public EventKit Reminder Core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add safe editing for every non-alarm, non-recurrence public `EKReminder` field, provider-normalization reporting, deletion, and an explicit Reminders.app handoff.

**Architecture:** Plain Sendable values preserve EventKit date semantics and produce field-level patches. A dedicated codec fingerprints and maps live EventKit objects, while a main-actor store applies only changed fields after a final revision check. The existing coordinator, provider, and key-window editor remain the user-facing path.

**Tech Stack:** Swift 6, SwiftUI, AppKit, EventKit, XCTest, macOS 26.

**Spec:** `docs/plans/2026-09-01-public-eventkit-reminder-parity-design.md`

## Global Constraints

- Build on PR #180 exact head `7a5d680580c7477e33a8ba49802d67db066cb281`; this branch already merges that head at `2c7a9c4`.
- Use only public EventKit, AppKit, and SwiftUI APIs. Do not use AppleScript or private Reminders APIs.
- Preserve date-only values, floating time zones, explicit time zones, and native-only metadata.
- Re-fetch and compare the full source revision immediately before every update or deletion.
- Apply only fields represented by a non-`.unchanged` patch.
- Never fall back after a selected reminder or list disappears or becomes read-only.
- Keep a failed editor open and show an actionable error.
- Do not run `xcodebuild test` while `/Applications/Islet.app` is running. Check `pgrep -x Islet` first, use one suite at a time, a unique DerivedData directory, and a hard timeout.
- Until PR #228 is on the branch, do not invoke local Xcode. Use compiler checks, deterministic standalone probes, and GitHub CI.

---

### Task 1: Plain date, editable-field, and patch models

**Files:**
- Create: `Islet/Activities/Reminders/ReminderWriteModels.swift`
- Create: `IsletTests/ReminderWriteModelsTests.swift`
- Modify: `Islet/Activities/Reminders/ReminderWriteCoordinator.swift`

**Interfaces:**
- Produces: `ReminderDateValue`, `ReminderCompletionValue`, `ReminderFieldChange`, `ReminderEditableFields`, `ReminderPatch`, `ReminderWriteRecord`, and `ReminderWriteError`.
- Consumes: `ReminderListItem` and `ReminderItem` from the existing reminder implementation.

- [ ] **Step 1: Write failing model tests**

Add tests with fixed Gregorian calendars for these cases:

```swift
func testDateOnlyValuePreservesMissingClockAndFloatingZone() throws
func testTimedValueRequiresHourAndMinuteTogether() throws
func testExplicitZoneSurvivesRoundTrip() throws
func testInvalidGregorianDateIsRejected() throws
func testPatchDistinguishesUnchangedFromExplicitClear() throws
func testPatchContainsOnlyFieldsChangedFromBaseline() throws
func testCompletedValueRequiresACompletionDate() throws
```

Use `America/Los_Angeles` values on 2026-03-08 and 2026-11-01 to cover the daylight-saving gap and overlap. Assert exact `DateComponents`; do not compare through the current machine time zone.

- [ ] **Step 2: Verify RED without Xcode**

Run:

```bash
swiftc -swift-version 6 -warnings-as-errors -typecheck \
  Islet/Activities/Reminders/ReminderWriteModels.swift \
  IsletTests/ReminderWriteModelsTests.swift
```

Expected: failure because the new model types and their validation do not exist yet. Capture the first relevant compiler error.

- [ ] **Step 3: Implement the plain values**

Use these public shapes:

```swift
enum ReminderFieldChange<Value: Equatable & Sendable>: Equatable, Sendable {
  case unchanged
  case value(Value)
}

struct ReminderDateValue: Equatable, Sendable {
  let components: DateComponents

  init(validating components: DateComponents) throws
  func date(in calendar: Calendar) throws -> Date
}

struct ReminderCompletionValue: Equatable, Sendable {
  let isCompleted: Bool
  let completionDate: Date?
}

struct ReminderEditableFields: Equatable, Sendable {
  var title: String
  var notes: String?
  var url: URL?
  var listID: String
  var startDate: ReminderDateValue?
  var dueDate: ReminderDateValue?
  var priority: Int
  var completion: ReminderCompletionValue
}

struct ReminderPatch: Equatable, Sendable {
  var title: ReminderFieldChange<String>
  var notes: ReminderFieldChange<String?>
  var url: ReminderFieldChange<URL?>
  var listID: ReminderFieldChange<String>
  var startDate: ReminderFieldChange<ReminderDateValue?>
  var dueDate: ReminderFieldChange<ReminderDateValue?>
  var priority: ReminderFieldChange<Int>
  var completion: ReminderFieldChange<ReminderCompletionValue>

  init(from baseline: ReminderEditableFields, to edited: ReminderEditableFields)
  var isEmpty: Bool { get }
}

enum ReminderField: String, Equatable, Sendable {
  case title, notes, url, list, startDate, dueDate, priority, completion
}

struct ReminderNormalizationMismatch: Equatable, Sendable {
  let field: ReminderField
  let reason: String
}

struct ReminderCommitReceipt: Equatable, Sendable {
  let itemIdentifier: String?
  let externalIdentifier: String?
}

enum ReminderWriteOutcome: Equatable, Sendable {
  case saved(ReminderWriteRecord)
  case committedWithNormalization(
    actual: ReminderWriteRecord,
    mismatches: [ReminderNormalizationMismatch])
  case commitStatusUnknown(ReminderCommitReceipt)
}
```

Validation rules are exact:

- Calendar is nil or Gregorian.
- Era defaults to 1, but year, month, and day are required.
- Hour and minute are both present or both absent; second requires a clock.
- Numeric fields must form a real date in the supplied calendar.
- A nil time zone stays nil.
- Priority is one of `0`, `1`, `5`, or `9`.
- `isCompleted == true` requires a completion date; incomplete values store no completion date.

Move `ReminderDraft`, `ReminderWriteRecord`, and related validation errors from `ReminderWriteCoordinator.swift` into this file. Keep compatibility accessors for the current editor until Task 5 changes its bindings.

- [ ] **Step 4: Verify GREEN with compiler and a standalone probe**

Compile the model file with `-warnings-as-errors`. Build a temporary executable that constructs the date-only, explicit-zone, invalid-date, and explicit-clear cases and exits nonzero on a mismatch. Run it through `/private/tmp/islet-test-timeout.pl 8`.

- [ ] **Step 5: Commit**

```bash
git add Islet/Activities/Reminders/ReminderWriteModels.swift \
  Islet/Activities/Reminders/ReminderWriteCoordinator.swift \
  IsletTests/ReminderWriteModelsTests.swift
git commit -m "Model exact reminder field changes"
```

### Task 2: EventKit codec and complete stale-write fingerprint

**Files:**
- Create: `Islet/Activities/Reminders/ReminderEventKitCodec.swift`
- Create: `IsletTests/ReminderEventKitCodecTests.swift`
- Modify: `Islet/Activities/Reminders/ReminderWriteModels.swift`

**Interfaces:**
- Consumes: the Task 1 plain models.
- Produces: `ReminderEventKitCodec.record(from:)`, `editableFields(from:)`, `revision(from:)`, `apply(_:to:resolveList:)`, and stable alarm and recurrence fingerprints.

- [ ] **Step 1: Write failing codec tests**

Construct unsaved `EKReminder`, `EKAlarm`, `EKStructuredLocation`, and `EKRecurrenceRule` objects. Cover:

```swift
func testRecordPreservesNotesURLStartDuePriorityAndCompletion() throws
func testDateOnlyAndFloatingComponentsRoundTripExactly() throws
func testRevisionChangesForEveryEditableCoreField() throws
func testRevisionIncludesInheritedLocationAndTimeZone() throws
func testRevisionIncludesEveryReadableAlarmProperty() throws
func testRevisionIncludesEveryReadableRecurrenceProperty() throws
func testApplyLeavesUnchangedFieldsAndOpaqueMetadataUntouched() throws
func testApplyClearsOnlyExplicitlyClearedFields() throws
```

The opaque metadata assertion must seed alarms and recurrence rules, apply a notes-only patch, and confirm the original arrays remain object-for-object unchanged.

- [ ] **Step 2: Verify RED**

Type-check the focused production and test sources against EventKit. Expected: failure because `ReminderEventKitCodec` and the expanded revision do not exist.

- [ ] **Step 3: Implement mapping and fingerprints**

Add plain fingerprint types that contain readable values, not `description` strings:

```swift
struct ReminderAlarmRevision: Equatable, Sendable {
  let typeRawValue: Int
  let absoluteDate: Date?
  let relativeOffset: TimeInterval
  let locationTitle: String?
  let latitude: Double?
  let longitude: Double?
  let radius: Double?
  let proximityRawValue: Int?
  let emailAddress: String?
  let soundName: String?
  let url: URL?
}

struct ReminderRecurrenceRevision: Equatable, Sendable {
  let calendarIdentifier: Calendar.Identifier?
  let frequencyRawValue: Int
  let interval: Int
  let firstDayOfTheWeek: Int
  let daysOfTheWeek: [ReminderWeekdayRevision]
  let daysOfTheMonth: [Int]
  let monthsOfTheYear: [Int]
  let weeksOfTheYear: [Int]
  let daysOfTheYear: [Int]
  let setPositions: [Int]
  let endDate: Date?
  let occurrenceCount: Int?
}
```

Expand `ReminderWriteRecord.Revision` with the editable fields, completion date, inherited `location` and `timeZone`, alarm revisions, recurrence revisions, `lastModifiedDate`, and list identifier. Canonicalize nil and empty selector arrays to `[]`, but preserve array order. Do not decide editability here; fingerprint every readable value.

`apply` switches over every `ReminderFieldChange`. It assigns only `.value` cases. A list change resolves an exact writable calendar or throws `.missingList`. It never assigns alarms or recurrence rules in this phase.

- [ ] **Step 4: Verify GREEN**

Run strict formatting, `swiftc -parse`, focused type-checks with warnings as errors, and a standalone EventKit probe for a notes-only patch. The probe must show unchanged URL, dates, alarms, and recurrence objects.

- [ ] **Step 5: Commit**

```bash
git add Islet/Activities/Reminders/ReminderEventKitCodec.swift \
  Islet/Activities/Reminders/ReminderWriteModels.swift \
  IsletTests/ReminderEventKitCodecTests.swift
git commit -m "Map public reminder fields safely"
```

### Task 3: Extract a patch-based EventKit store

**Files:**
- Create: `Islet/Activities/Reminders/EventKitReminderWriteStore.swift`
- Create: `IsletTests/EventKitReminderWriteStoreTests.swift`
- Modify: `Islet/Activities/Reminders/ReminderWriteModels.swift`
- Modify: `Islet/Activities/Reminders/ReminderWriteCoordinator.swift`

**Interfaces:**
- Consumes: `ReminderPatch`, `ReminderEditableFields`, `ReminderWriteRecord`, and `ReminderEventKitCodec`.
- Produces: the revised `ReminderWriteStore` protocol and the production EventKit implementation.

- [ ] **Step 1: Write failing store-contract tests**

Use a plain fake store to prove the contract:

```swift
func testCreateUsesExactSelectedWritableList() throws
func testSaveRejectsARevisionChangedAfterEditorOpen() throws
func testSaveAppliesOnlyChangedFields() throws
func testSaveRejectsAListThatBecameReadOnly() throws
func testDeleteChecksRevisionBeforeRemoving() throws
func testDeleteDoesNotRemoveAfterExternalChange() throws
func testNormalizedCreateReturnsTheCommittedIdentifier() throws
func testNormalizedUpdateReportsEveryChangedFieldMismatch() throws
func testUnreadablePostCommitCreateReturnsUnknownStatusWithoutRetrying() throws
```

- [ ] **Step 2: Verify RED**

Type-check the fake against the current protocol. Expected: failure because the protocol still accepts a whole mutable record and has no delete operation.

- [ ] **Step 3: Replace the store interface**

Use this contract:

```swift
@MainActor
protocol ReminderWriteStore: AnyObject {
  var authorization: EventKitPermissionState { get }
  func reminderLists() -> [ReminderListItem]
  func defaultListID() -> String?
  func record(withID id: String) -> ReminderWriteRecord?
  func create(_ fields: ReminderEditableFields) throws -> ReminderWriteOutcome
  func save(
    reminderID: String,
    patch: ReminderPatch,
    expectedRevision: ReminderWriteRecord.Revision
  ) throws -> ReminderWriteOutcome
  func delete(
    reminderID: String,
    expectedRevision: ReminderWriteRecord.Revision
  ) throws
}
```

The production `save` and `delete` flow is:

1. Resolve the current `EKReminder` by identifier.
2. Build its current revision through the codec.
3. Compare the current and expected revisions.
4. Resolve any changed list identifier to the exact writable calendar.
5. Apply the patch to the existing object.
6. Stage a save with `commit: false`, read back every changed field, and reset the store if the staged object cannot represent the request.
7. Commit, re-fetch, and compare every changed field again.
8. Return `.saved` for an exact commit, `.committedWithNormalization(actual:mismatches:)` for a provider-normalized commit, or `.commitStatusUnknown` when the commit call returns but no authoritative post-commit record can be fetched.

A normalized create returns the committed identifier. A retry targets that reminder and never creates a duplicate. A pre-commit mismatch resets the EventKit store and throws without changing the dashboard. After a commit-status-unknown outcome, preserve any nonempty item and external identifiers as a receipt, publish no unverified record, and never issue a second create automatically. Do not match by title or external identifier. Later tasks keep the editor pending and disable retry until a reload resolves an authoritative record or the user hands off to Reminders.app.

Keep all EventKit object access on the main actor. Remove the production store implementation from `ReminderWriteCoordinator.swift` after the new file compiles.

- [ ] **Step 4: Verify GREEN**

Type-check the focused store module and tests. Run a standalone fake-store probe that mutates the revision between read and save and confirms `.changedElsewhere` with no applied patch.

- [ ] **Step 5: Commit**

```bash
git add Islet/Activities/Reminders/EventKitReminderWriteStore.swift \
  Islet/Activities/Reminders/ReminderWriteModels.swift \
  Islet/Activities/Reminders/ReminderWriteCoordinator.swift \
  IsletTests/EventKitReminderWriteStoreTests.swift
git commit -m "Apply reminder edits as field patches"
```

### Task 4: Coordinator support for core fields and deletion

**Files:**
- Modify: `Islet/Activities/Reminders/ReminderWriteCoordinator.swift`
- Modify: `IsletTests/ReminderWriteCoordinatorTests.swift`

**Interfaces:**
- Consumes: the patch-based store from Task 3.
- Produces: full core drafts, create, update, completion, undo, and revision-bound delete results.

- [ ] **Step 1: Extend the fake and add failing behavior tests**

Add these cases:

```swift
func testCreateRoundTripsNotesURLStartDueAndCompletion() throws
func testUpdateBuildsAnExplicitClearForNotesAndURL() throws
func testUpdateDoesNotPatchUnchangedFields() throws
func testUpdateRejectsEveryExternalCoreFieldMutation() throws
func testCompletionWritesCompletionDateAndUndoClearsIt() throws
func testDeleteRemovesTheExactUnchangedReminder() throws
func testDeleteRejectsAnExternallyChangedReminder() throws
func testMissingSelectedListNeverFallsBack() throws
func testMissingOrReadOnlySystemDefaultUsesFirstWritableList() throws
func testNormalizedCreateRebasesOntoCommittedIdentifierAndRevision() throws
func testNormalizedUpdateKeepsRequestedFieldsAndRebasesBaseline() throws
func testUnknownCreateCommitRemainsPendingAndCannotRetryCreate() throws
```

- [ ] **Step 2: Verify RED**

Type-check the coordinator tests against the Task 3 module. Expected: failures for the missing expanded draft and delete method.

- [ ] **Step 3: Implement coordinator operations**

The edit draft carries both the baseline editable fields and source revision. `update` validates the edited fields, creates `ReminderPatch(from:to:)`, and calls `save` only when the patch is nonempty. `delete` accepts the reminder identifier and captured source revision; it does not fetch a fresh revision and then delete against itself.

For a new draft with no explicit list, use the writable system default. If it is missing or read-only, use the first writable list in the same stable order returned by `lists()`. Once `draft.listID` is nonnil, a missing or read-only selection fails with `.missingList` and never falls back.

Completion uses `ReminderCompletionValue(isCompleted: true, completionDate: now)`. Undo compares the committed completion revision, then patches to `ReminderCompletionValue(isCompleted: false, completionDate: nil)`.

Add user-facing errors for invalid URL, invalid date components, missing completion date, and provider-rejected deletion. Keep raw EventKit text as the final detail after the actionable message.

Propagate `ReminderWriteOutcome` to the provider. On `.committedWithNormalization`, keep the requested fields in the open draft, replace its identifier, baseline, and source revision with `actual`, and attach the field-specific mismatches. A second save patches the committed reminder. On `.commitStatusUnknown`, preserve the receipt as pending reconciliation and prevent the coordinator from issuing another create.

- [ ] **Step 4: Verify GREEN**

Run focused compiler checks and standalone fake-store probes for explicit clear, no-op update, stale update, exact delete, and stale delete.

- [ ] **Step 5: Commit**

```bash
git add Islet/Activities/Reminders/ReminderWriteCoordinator.swift \
  IsletTests/ReminderWriteCoordinatorTests.swift
git commit -m "Complete core reminder write operations"
```

### Task 5: Resizable details editor, deletion confirmation, and Reminders handoff

**Files:**
- Create: `Islet/Activities/Reminders/ReminderEditorPresentation.swift`
- Create: `IsletTests/ReminderEditorPresentationTests.swift`
- Modify: `Islet/Activities/Reminders/ReminderEditorView.swift`
- Modify: `Islet/Activities/Reminders/RemindersProvider.swift`

**Interfaces:**
- Consumes: the full core draft and coordinator operations from Task 4.
- Produces: editor bindings for notes, URL, start, due, time zone, completion, delete, and Open in Reminders.

- [ ] **Step 1: Add failing presentation tests**

Cover these pure decisions:

```swift
func testReturnSavesOutsideMultilineFields()
func testReturnDoesNotSaveInsideNotes()
func testDeleteNeverUsesTheDefaultActionShortcut()
func testExistingReminderAlwaysOffersOpenInReminders()
func testInvalidURLKeepsEditorOpenWithFieldError()
func testDateOnlyToggleRemovesClockWithoutChangingDate()
func testFloatingZoneChoiceStoresNoTimeZone()
func testProviderNormalizationKeepsEditorOpenWithFieldMessages()
func testUnknownCommitKeepsEditorOpenAndDisablesRetry()
```

- [ ] **Step 2: Verify RED**

Type-check the test with the current editor sources. Expected: failure because `ReminderEditorPresentation` does not exist.

- [ ] **Step 3: Implement the editor**

Keep title, list, due date, optional time, priority, and Add or Save in the first section. Put these controls under Details:

- Notes in a multiline editor.
- URL with field-level validation.
- Start date, optional time, and time-zone choice.
- Due time-zone choice.
- Completion state and completion date.

Wrap the form in `ScrollView`, use a minimum content width of 420 points, and give the window `.resizable` style. Keep initial title focus, Escape cancellation, Command-N creation, and VoiceOver labels. Return saves only when focus is not in notes.

Existing reminders show Open in Reminders. Use the public Reminders application URL when an item-specific URL is unavailable; never invent a private deep link.

An unknown commit status keeps the requested values visible, disables Add or Save, explains that Islet is waiting for Reminders to reload, and offers the same public Reminders.app handoff. It must not allow another create while pending.

Delete opens an `NSAlert` that names the reminder. The destructive button is not the default button. On confirmed success, close the editor. On failure, keep it open and show the provider error.

- [ ] **Step 4: Verify GREEN**

Run strict formatting, `swiftc -parse`, presentation-model type-checks with warnings as errors, and a focused stubbed SwiftUI type-check. Do not open or automate the editor during this task.

- [ ] **Step 5: Commit**

```bash
git add Islet/Activities/Reminders/ReminderEditorPresentation.swift \
  Islet/Activities/Reminders/ReminderEditorView.swift \
  Islet/Activities/Reminders/RemindersProvider.swift \
  IsletTests/ReminderEditorPresentationTests.swift
git commit -m "Expose core reminder details safely"
```

### Task 6: Provider reconciliation, documentation, and review gate

**Files:**
- Modify: `Islet/Activities/Reminders/RemindersProvider.swift`
- Modify: `IsletTests/ReminderDashboardReconciliationTests.swift`
- Create: `docs/reminder-eventkit-verification.md`

**Interfaces:**
- Consumes: committed `ReminderWriteRecord` values and deletion results.
- Produces: correct dashboard mutations, reload behavior, and an honest provider test record.

- [ ] **Step 1: Add failing reconciliation tests**

Prove that a committed create or update uses the returned provider value, an unknown commit publishes no speculative item and requests a reload, a deletion removes the visible item, and any mutation with hidden ranked reminders requests a reload.

- [ ] **Step 2: Verify RED**

Run the pure reconciliation type-check and standalone probe. Expected: the deletion or returned-record case fails before the provider path is wired.

- [ ] **Step 3: Wire committed outcomes**

Publish only records returned after EventKit commit. Refresh lists after every write. Keep observing `EKEventStoreChanged`. On `.saved`, publish the returned record and close the editor. On `.committedWithNormalization`, publish `actual`, rebase the still-open editor, and show every mismatch. On `.commitStatusUnknown`, publish nothing, request a reload, and keep the editor pending with retry disabled. On delete success, reconcile `.remove(id)`; on failure, leave the item and editor untouched. If `hasMoreReminders` is true, request a reload after create, update, completion, undo, or deletion.

- [ ] **Step 4: Write the manual verification matrix**

Document exact checks for local, iCloud, shared, and Exchange accounts. Include notes, URL, date-only, timed floating, explicit zone, start, due, priority, completion date, deletion, stale edits from Reminders.app, and survival of native-only tags, subtasks, attachments, flags, and assignments. Mark unavailable accounts as not tested.

- [ ] **Step 5: Run final safe verification**

Run:

```bash
xcrun swift-format lint --strict \
  Islet/Activities/Reminders/*.swift \
  IsletTests/Reminder*.swift \
  IsletTests/EventKitReminderWriteStoreTests.swift
swiftc -parse Islet/Activities/Reminders/*.swift IsletTests/Reminder*.swift
git diff --check
```

Run all focused standalone probes through the hard timeout wrapper and confirm no helper remains. Do not run local Xcode before PR #228 is incorporated. Push the branch, open a stacked PR against `feature/reminder-editing`, and use both GitHub CI jobs as the full-suite gate. Request Ned's review. Do not merge until PR #180 lands, the branch is rebased onto `main`, both CI jobs pass, and Ned approves.

- [ ] **Step 6: Commit**

```bash
git add Islet/Activities/Reminders/RemindersProvider.swift \
  IsletTests/ReminderDashboardReconciliationTests.swift \
  docs/reminder-eventkit-verification.md
git commit -m "Document core reminder provider checks"
```

## Follow-up Plans

After this slice is reviewed, write separate implementation plans for:

1. Editable alarms, MapKit location search, opaque-alarm preservation, and alarm-specific provider normalization.
2. Full public recurrence mapping, opaque-rule preservation, and recurrence editors.
3. Plain-list creation, rename, recolor, and guarded deletion.
4. Cross-provider verification and the basic Create Reminder App Intent.
