import Foundation
import XCTest

@testable import Islet

final class ReminderEditorPresentationTests: XCTestCase {
  private let utc = TimeZone(secondsFromGMT: 0)!

  func testReturnSavesOutsideMultilineFields() {
    XCTAssertEqual(
      ReminderEditorPresentation.action(for: .returnKey, focus: .title, isPending: false),
      .submit)
    XCTAssertEqual(
      ReminderEditorPresentation.action(for: .returnKey, focus: nil, isPending: false),
      .submit)
  }

  func testReturnDoesNotSaveInsideNotes() {
    XCTAssertEqual(
      ReminderEditorPresentation.action(for: .returnKey, focus: .notes, isPending: false),
      .none)
  }

  func testReturnCannotSubmitPendingOrRetryBlockedDraft() {
    XCTAssertEqual(
      ReminderEditorPresentation.action(
        for: .returnKey, focus: .title, isPending: true,
        isSubmissionEnabled: false),
      .none)
    XCTAssertEqual(
      ReminderEditorPresentation.action(
        for: .returnKey, focus: .title, isPending: false,
        isSubmissionEnabled: false),
      .none)
  }

  func testSaveButtonSubmitsInsideNotes() {
    XCTAssertEqual(
      ReminderEditorPresentation.action(for: .saveButton, focus: .notes, isPending: false),
      .submit)
  }

  func testEscapeDismissesWithoutAbandoningPendingCommit() {
    XCTAssertEqual(
      ReminderEditorPresentation.action(for: .escape, focus: .notes, isPending: true),
      .dismiss)
  }

  func testCommandNStartsNewDraftWhenReadyAndReopensPendingDraft() {
    XCTAssertEqual(
      ReminderEditorPresentation.action(for: .commandN, focus: .title, isPending: false),
      .startNew)
    XCTAssertEqual(
      ReminderEditorPresentation.action(for: .commandN, focus: .title, isPending: true),
      .reopenPending)
  }

  func testDeleteNeverUsesTheDefaultActionShortcut() {
    XCTAssertEqual(
      ReminderEditorPresentation.action(for: .deleteShortcut, focus: .title, isPending: false),
      .none)
    XCTAssertFalse(ReminderEditorPresentation.deleteUsesDefaultAction)
  }

  func testDeleteConfirmationMakesCancelDefaultAndDeleteSecond() {
    XCTAssertEqual(
      ReminderEditorAlertConfiguration.deleteButtons.map(\.title), ["Cancel", "Delete"])
    XCTAssertTrue(ReminderEditorAlertConfiguration.deleteButtons[0].isDefault)
    XCTAssertFalse(ReminderEditorAlertConfiguration.deleteButtons[1].isDefault)
    XCTAssertTrue(ReminderEditorAlertConfiguration.deleteButtons[1].isDestructive)
  }

  func testExistingReminderAlwaysOffersOpenInReminders() {
    XCTAssertTrue(ReminderEditorPresentation.offersOpenInReminders(for: draft(id: "item-1")))
    XCTAssertFalse(ReminderEditorPresentation.offersOpenInReminders(for: draft(id: nil)))
  }

  func testExistingReminderContentURLDoesNotChangeAppHandoff() {
    var value = draft(id: "item-1")
    value.urlText = "https://example.com/reminder-content"

    XCTAssertEqual(
      ReminderEditorPresentation.handoff(for: value), .remindersApplication)
  }

  func testUnknownCreateAlsoOffersPlainRemindersHandoff() {
    var value = draft(id: nil)
    value.pendingCommitReceipt = ReminderCommitReceipt(
      itemIdentifier: nil, externalIdentifier: "external")

    XCTAssertTrue(ReminderEditorPresentation.offersOpenInReminders(for: value))
  }

  func testStopWaitingConfirmationIsNonDefault() {
    XCTAssertEqual(
      ReminderEditorAlertConfiguration.stopWaitingButtons.map(\.title),
      ["Cancel", "Open Reminders and Stop Waiting"])
    XCTAssertTrue(ReminderEditorAlertConfiguration.stopWaitingButtons[0].isDefault)
    XCTAssertFalse(ReminderEditorAlertConfiguration.stopWaitingButtons[1].isDefault)
  }

  func testInvalidURLKeepsEditorOpenWithFieldError() {
    var value = draft(id: nil)
    value.urlText = "not a URL"

    let validation = ReminderEditorPresentation.prepareForSubmission(value)

    guard case .invalid(let returned, let messages) = validation else {
      return XCTFail("Expected invalid presentation result")
    }
    XCTAssertEqual(returned.urlText, "not a URL")
    XCTAssertEqual(messages.map(\.field), [.url])
    XCTAssertEqual(messages.first?.message, "Enter a valid reminder URL.")
  }

  func testEmptyNotesBecomeNil() {
    var value = draft(id: nil)
    value.notes = "  \n "

    guard case .valid(let prepared) = ReminderEditorPresentation.prepareForSubmission(value) else {
      return XCTFail("Expected valid presentation result")
    }
    XCTAssertNil(prepared.notes)
  }

  func testDateOnlyToggleRemovesClockWithoutChangingDate() throws {
    let source = try dateValue(
      year: 2026, month: 9, day: 14, hour: 22, minute: 45,
      timeZone: TimeZone(identifier: "Australia/Brisbane"))

    let dateOnly = try ReminderEditorPresentation.removingTime(from: source)

    XCTAssertEqual(dateOnly.components.era, source.components.era)
    XCTAssertEqual(dateOnly.components.year, 2026)
    XCTAssertEqual(dateOnly.components.month, 9)
    XCTAssertEqual(dateOnly.components.day, 14)
    XCTAssertNil(dateOnly.components.hour)
    XCTAssertNil(dateOnly.components.minute)
    XCTAssertNil(dateOnly.components.second)
    XCTAssertNil(dateOnly.components.nanosecond)
    XCTAssertEqual(dateOnly.components.timeZone, source.components.timeZone)
  }

  func testEditorSessionKeepsStableIdentityErrorsAndDisplayContext() {
    let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Australia/Brisbane")!
    var session = ReminderEditorSession(
      id: id, draft: draft(id: "item-1"), calendar: calendar,
      displayTimeZone: calendar.timeZone)

    session.draft.title = "Edited"
    session.fieldMessages = [ReminderEditorFieldMessage(field: .title, message: "Changed")]
    session.generalMessage = "Keep open"

    XCTAssertEqual(session.id, id)
    XCTAssertEqual(session.draft.title, "Edited")
    XCTAssertEqual(session.fieldMessages.first?.field, .title)
    XCTAssertEqual(session.generalMessage, "Keep open")
    XCTAssertEqual(session.calendar.timeZone, calendar.timeZone)
    XCTAssertEqual(session.displayTimeZone, calendar.timeZone)
  }

  func testPendingSessionCannotBeReplacedByEditNewOrSnoozeRouting() {
    var pending = draft(id: "item-1")
    pending.pendingCommitReceipt = ReminderCommitReceipt(
      itemIdentifier: "item-1", externalIdentifier: nil)

    XCTAssertEqual(
      ReminderEditorPresentation.windowRoute(currentDraft: pending, request: .edit), .editor)
    XCTAssertEqual(
      ReminderEditorPresentation.windowRoute(currentDraft: pending, request: .new), .editor)
    XCTAssertEqual(
      ReminderEditorPresentation.windowRoute(currentDraft: pending, request: .snooze), .editor)
  }

  func testAnyRetainedSessionReopensForDashboardNewEditAndSnooze() {
    let retained = draft(id: "item-1")

    XCTAssertEqual(
      ReminderEditorPresentation.windowRoute(currentDraft: retained, request: .edit), .editor)
    XCTAssertEqual(
      ReminderEditorPresentation.windowRoute(currentDraft: retained, request: .new), .editor)
    XCTAssertEqual(
      ReminderEditorPresentation.windowRoute(currentDraft: retained, request: .snooze), .editor)
    XCTAssertEqual(
      ReminderEditorPresentation.windowRoute(currentDraft: nil, request: .snooze), .snooze)
  }

  func testPendingAndRetryBlockedDraftsAreReadOnly() {
    var pending = draft(id: "item-1")
    pending.pendingCommitReceipt = ReminderCommitReceipt(
      itemIdentifier: "item-1", externalIdentifier: nil)
    var blocked = draft(id: "item-1")
    blocked.retryBlockedReason = "Open in Reminders."

    XCTAssertTrue(ReminderEditorPresentation.isReadOnly(pending))
    XCTAssertTrue(ReminderEditorPresentation.isReadOnly(blocked))
    XCTAssertFalse(ReminderEditorPresentation.isReadOnly(draft(id: "item-1")))
  }

  func testQuickUnknownRetentionInvalidatesOlderReloads() {
    let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    var requested = draft(id: "item-1")
    requested.pendingCommitReceipt = ReminderCommitReceipt(
      itemIdentifier: "item-1", externalIdentifier: "external")
    let write = ReminderCoordinatorWrite(
      outcome: .commitStatusUnknown(requested.pendingCommitReceipt!), draft: requested)

    let retention = ReminderEditorPresentation.retention(
      for: write, existingSession: nil, newSessionID: id,
      calendar: fixedCalendar(), displayTimeZone: utc)

    XCTAssertEqual(retention?.session.id, id)
    XCTAssertEqual(retention?.session.draft, requested)
    XCTAssertTrue(retention?.invalidatesReloadGeneration == true)
    XCTAssertTrue(retention?.requestsReload == true)
  }

  func testQuickNormalizedRetentionKeepsRequestedDraftAndMessages() {
    let requested = draft(id: "item-1")
    let write = ReminderCoordinatorWrite(
      outcome: .committedWithNormalization(
        actual: makeRecord(id: "item-1"),
        mismatches: [
          ReminderNormalizationMismatch(field: .title, reason: "title changed"),
          ReminderNormalizationMismatch(field: .priority, reason: "priority changed"),
        ]),
      draft: requested)

    let retention = ReminderEditorPresentation.retention(
      for: write, existingSession: nil,
      calendar: fixedCalendar(), displayTimeZone: utc)

    XCTAssertEqual(retention?.session.draft, requested)
    XCTAssertEqual(retention?.session.fieldMessages.map(\.field), [.title, .priority])
    XCTAssertFalse(retention?.invalidatesReloadGeneration == true)
    XCTAssertTrue(retention?.requestsReload == true)
  }

  func testResolvedRetryBlockedDraftUsesBlockReason() {
    var resolved = draft(id: "item-1")
    resolved.retryBlockedReason = "This provider value needs Reminders."
    let message = ReminderEditorPresentation.reviewMessage(
      for: resolved,
      fieldMessages: [ReminderEditorFieldMessage(field: .title, message: "title changed")])

    XCTAssertEqual(message, "This provider value needs Reminders.")
  }

  func testOlderReloadGenerationCannotResolveNewPendingSession() {
    var state = ReminderReloadState()
    let older = state.beginReload()
    state.invalidate(clearOptimisticCompletions: false)

    XCTAssertNil(state.finish([], generation: older))
    let later = state.beginReload()
    XCTAssertEqual(state.finish([], generation: later), [])
  }

  func testPendingReloadIdentityRequiresSameSessionAndReceipt() {
    let sessionID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let otherSessionID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let receipt = ReminderCommitReceipt(itemIdentifier: "item-1", externalIdentifier: "external")
    let identity = ReminderEditorPendingIdentity(sessionID: sessionID, receipt: receipt)
    var pending = draft(id: "item-1")
    pending.pendingCommitReceipt = receipt

    XCTAssertTrue(identity.matches(sessionID: sessionID, draft: pending))
    XCTAssertFalse(identity.matches(sessionID: otherSessionID, draft: pending))
    pending.pendingCommitReceipt = ReminderCommitReceipt(
      itemIdentifier: "item-1", externalIdentifier: "different")
    XCTAssertFalse(identity.matches(sessionID: sessionID, draft: pending))
    pending.pendingCommitReceipt = nil
    XCTAssertFalse(identity.matches(sessionID: sessionID, draft: pending))
  }

  func testHandoffCompletionRequiresSamePendingSessionAndRunningApplication() {
    let expected = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let other = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let expectedReceipt = ReminderCommitReceipt(
      itemIdentifier: "item-1", externalIdentifier: "external")
    let newerReceipt = ReminderCommitReceipt(
      itemIdentifier: "item-1", externalIdentifier: "newer")

    XCTAssertEqual(
      ReminderEditorPresentation.handoffCompletion(
        expectedSessionID: expected, expectedReceipt: expectedReceipt,
        currentSessionID: expected, currentReceipt: expectedReceipt,
        currentSessionIsPending: true, openedRunningApplication: true,
        errorDescription: nil),
      .abandon)
    XCTAssertEqual(
      ReminderEditorPresentation.handoffCompletion(
        expectedSessionID: expected, expectedReceipt: expectedReceipt,
        currentSessionID: other, currentReceipt: expectedReceipt,
        currentSessionIsPending: true, openedRunningApplication: true,
        errorDescription: nil),
      .ignore)
    XCTAssertEqual(
      ReminderEditorPresentation.handoffCompletion(
        expectedSessionID: expected, expectedReceipt: expectedReceipt,
        currentSessionID: expected, currentReceipt: newerReceipt,
        currentSessionIsPending: true, openedRunningApplication: true,
        errorDescription: nil),
      .ignore)
    XCTAssertEqual(
      ReminderEditorPresentation.handoffCompletion(
        expectedSessionID: expected, expectedReceipt: expectedReceipt,
        currentSessionID: expected, currentReceipt: expectedReceipt,
        currentSessionIsPending: true, openedRunningApplication: false,
        errorDescription: "Launch failed"),
      .retain(message: "Couldn’t open Reminders. Launch failed"))
  }

  func testWindowTitleTracksNewAndCommittedDraftModes() {
    XCTAssertEqual(ReminderEditorPresentation.windowTitle(for: draft(id: nil)), "New reminder")
    XCTAssertEqual(
      ReminderEditorPresentation.windowTitle(for: draft(id: "item-1")), "Edit reminder")
  }

  func testPrimaryActionUsesFixedFooter() {
    XCTAssertEqual(ReminderEditorPresentation.primaryActionPlacement, .fixedFooter)
  }

  func testDateOnlyToggleWorksForStartAndDueValues() throws {
    let start = try dateValue(year: 2026, month: 9, day: 14, hour: 8, minute: 10)
    let due = try dateValue(year: 2026, month: 9, day: 15, hour: 17, minute: 20)

    XCTAssertNil(try ReminderEditorPresentation.removingTime(from: start).components.hour)
    XCTAssertNil(try ReminderEditorPresentation.removingTime(from: due).components.hour)
    XCTAssertEqual(try ReminderEditorPresentation.removingTime(from: start).components.day, 14)
    XCTAssertEqual(try ReminderEditorPresentation.removingTime(from: due).components.day, 15)
  }

  func testTimeToggleAddsInjectedClockWithoutChangingDateOrZone() throws {
    let zone = TimeZone(identifier: "Australia/Brisbane")!
    let source = try dateValue(year: 2026, month: 9, day: 14, timeZone: zone)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    let clock = calendar.date(
      from: DateComponents(year: 2026, month: 9, day: 1, hour: 17, minute: 35))!

    let timed = try ReminderEditorPresentation.addingTime(
      to: source, clock: clock, calendar: calendar, displayTimeZone: utc)

    XCTAssertEqual(timed.components.year, 2026)
    XCTAssertEqual(timed.components.month, 9)
    XCTAssertEqual(timed.components.day, 14)
    XCTAssertEqual(timed.components.hour, 17)
    XCTAssertEqual(timed.components.minute, 35)
    XCTAssertEqual(timed.components.timeZone, zone)
  }

  func testFloatingZoneChoiceStoresNoTimeZone() throws {
    let source = try dateValue(
      year: 2026, month: 9, day: 14, hour: 9, minute: 30,
      timeZone: TimeZone(identifier: "America/Los_Angeles"))

    let floating = try ReminderEditorPresentation.assigningTimeZone(nil, to: source)

    XCTAssertNil(floating.components.timeZone)
    XCTAssertEqual(floating.components.hour, 9)
    XCTAssertEqual(floating.components.minute, 30)
  }

  func testNamedZoneChoicePreservesWallClockComponents() throws {
    let source = try dateValue(year: 2026, month: 11, day: 1, hour: 9, minute: 30)
    let zone = TimeZone(identifier: "America/Los_Angeles")!

    let zoned = try ReminderEditorPresentation.assigningTimeZone(zone, to: source)

    XCTAssertEqual(zoned.components.timeZone, zone)
    XCTAssertEqual(zoned.components.year, 2026)
    XCTAssertEqual(zoned.components.month, 11)
    XCTAssertEqual(zoned.components.day, 1)
    XCTAssertEqual(zoned.components.hour, 9)
    XCTAssertEqual(zoned.components.minute, 30)
  }

  func testTimeZonePickerRetainsStoredIdentifierOutsideKnownList() {
    let customIdentifier = "GMT+0530"

    let identifiers = ReminderEditorPresentation.timeZoneIdentifiers(
      selectedIdentifier: customIdentifier, knownIdentifiers: ["UTC", "Australia/Brisbane"])

    XCTAssertEqual(identifiers, [customIdentifier, "UTC", "Australia/Brisbane"])
  }

  func testDSTInvalidNamedZoneEditIsRejected() throws {
    let floatingGap = try dateValue(year: 2026, month: 3, day: 8, hour: 2, minute: 30)

    XCTAssertThrowsError(
      try ReminderEditorPresentation.assigningTimeZone(
        TimeZone(identifier: "America/Los_Angeles")!, to: floatingGap)
    ) { error in
      XCTAssertEqual(error as? ReminderWriteError, .invalidDateComponents)
    }
    XCTAssertNil(floatingGap.components.timeZone)
    XCTAssertEqual(floatingGap.components.hour, 2)
  }

  func testTimedFloatingEditUsesInjectedDisplayZone() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = utc
    let selected = calendar.date(
      from: DateComponents(year: 2026, month: 9, day: 14, hour: 16, minute: 5))!

    let value = try ReminderEditorPresentation.dateValue(
      from: selected, includesTime: true, timeZone: nil,
      calendar: calendar, displayTimeZone: utc)

    XCTAssertNil(value.components.timeZone)
    XCTAssertEqual(value.components.year, 2026)
    XCTAssertEqual(value.components.month, 9)
    XCTAssertEqual(value.components.day, 14)
    XCTAssertEqual(value.components.hour, 16)
    XCTAssertEqual(value.components.minute, 5)
  }

  func testExplicitZoneDateEditKeepsZone() throws {
    var calendar = Calendar(identifier: .gregorian)
    let zone = TimeZone(identifier: "Australia/Brisbane")!
    calendar.timeZone = zone
    let selected = calendar.date(
      from: DateComponents(year: 2026, month: 9, day: 20, hour: 7, minute: 25))!

    let value = try ReminderEditorPresentation.dateValue(
      from: selected, includesTime: true, timeZone: zone,
      calendar: calendar, displayTimeZone: utc)

    XCTAssertEqual(value.components.timeZone, zone)
    XCTAssertEqual(value.components.day, 20)
    XCTAssertEqual(value.components.hour, 7)
    XCTAssertEqual(value.components.minute, 25)
  }

  func testInjectedZoneMakesDisplayIndependentOfProcessDefaultZone() throws {
    let source = try dateValue(year: 2026, month: 9, day: 14, hour: 9, minute: 30)
    var calendar = Calendar(identifier: .gregorian)
    let originalDefault = NSTimeZone.default
    defer { NSTimeZone.default = originalDefault }

    NSTimeZone.default = TimeZone(identifier: "Pacific/Honolulu")!
    let first = try ReminderEditorPresentation.displayDate(
      for: source, calendar: calendar, displayTimeZone: utc)
    NSTimeZone.default = TimeZone(identifier: "Pacific/Kiritimati")!
    calendar = Calendar(identifier: .gregorian)
    let second = try ReminderEditorPresentation.displayDate(
      for: source, calendar: calendar, displayTimeZone: utc)

    XCTAssertEqual(first, second)
  }

  func testCompletionToggleUsesInjectedNowAndClearsDate() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var value = draft(id: "item-1")

    value = ReminderEditorPresentation.settingCompletion(true, in: value, now: now)
    XCTAssertTrue(value.isCompleted)
    XCTAssertEqual(value.completionDate, now)

    value = ReminderEditorPresentation.settingCompletion(
      false, in: value, now: now.addingTimeInterval(60))
    XCTAssertFalse(value.isCompleted)
    XCTAssertNil(value.completionDate)
  }

  func testUnavailableSelectedListIsRetainedAndMarkedUnavailable() {
    let options = ReminderEditorPresentation.listOptions(
      lists: [list(id: "available", title: "Available")], selectedID: "gone")

    XCTAssertEqual(options.map(\.id), ["available", "gone"])
    XCTAssertEqual(options.last?.title, "Unavailable list")
    XCTAssertTrue(options.last?.isUnavailable == true)
  }

  func testNewDraftListUsesDefaultThenStableFirstList() {
    let lists = [list(id: "first", title: "First"), list(id: "second", title: "Second")]

    XCTAssertEqual(
      ReminderEditorPresentation.initialListID(defaultID: "second", lists: lists), "second")
    XCTAssertEqual(ReminderEditorPresentation.initialListID(defaultID: nil, lists: lists), "first")
  }

  func testProviderNormalizationKeepsEditorOpenWithFieldMessages() {
    let value = draft(id: "actual-id")
    let record = makeRecord(id: "actual-id")
    let mismatches = [
      ReminderNormalizationMismatch(field: .title, reason: "title changed"),
      ReminderNormalizationMismatch(field: .dueDate, reason: "due changed"),
    ]
    let write = ReminderCoordinatorWrite(
      outcome: .committedWithNormalization(actual: record, mismatches: mismatches),
      draft: value)

    guard
      case .keepOpen(let returned, let messages) =
        ReminderEditorPresentation.disposition(for: write)
    else {
      return XCTFail("Expected keep-open disposition")
    }
    XCTAssertEqual(returned, value)
    XCTAssertEqual(messages.map(\.field), [.title, .dueDate])
    XCTAssertEqual(messages.map(\.message), ["title changed", "due changed"])
  }

  func testEveryNormalizationFieldMapsToItsControl() {
    let fields: [ReminderField] = [
      .title, .notes, .url, .list, .startDate, .dueDate, .priority, .completion,
    ]
    let write = ReminderCoordinatorWrite(
      outcome: .committedWithNormalization(
        actual: makeRecord(id: "item-1"),
        mismatches: fields.map { ReminderNormalizationMismatch(field: $0, reason: $0.rawValue) }),
      draft: draft(id: "item-1"))

    guard case .keepOpen(_, let messages) = ReminderEditorPresentation.disposition(for: write)
    else {
      return XCTFail("Expected keep-open disposition")
    }
    XCTAssertEqual(messages.map(\.field), fields)
  }

  func testUnknownCommitKeepsEditorOpenAndDisablesRetry() {
    var value = draft(id: nil)
    value.pendingCommitReceipt = ReminderCommitReceipt(
      itemIdentifier: "committed-id", externalIdentifier: "external-id")
    let write = ReminderCoordinatorWrite(
      outcome: .commitStatusUnknown(value.pendingCommitReceipt!), draft: value)

    guard
      case .pending(let returned, let message) =
        ReminderEditorPresentation.disposition(for: write)
    else {
      return XCTFail("Expected pending disposition")
    }
    XCTAssertEqual(returned, value)
    XCTAssertFalse(ReminderEditorPresentation.canSubmit(returned))
    XCTAssertTrue(message.contains("waiting for Reminders to reload"))
  }

  func testRetryBlockedKnownReminderCannotSubmitButCanDelete() {
    var value = draft(id: "item-1")
    value.retryBlockedReason = "Open in Reminders."

    XCTAssertFalse(ReminderEditorPresentation.canSubmit(value))
    XCTAssertTrue(ReminderEditorPresentation.canDelete(value))
  }

  func testRetryBlockedKnownCommitStaysOpenForRemindersHandoff() {
    var value = draft(id: "item-1")
    value.retryBlockedReason = "Open in Reminders."
    let write = ReminderCoordinatorWrite(
      outcome: .saved(makeRecord(id: "item-1")), draft: value)

    guard
      case .keepOpen(let returned, let messages) =
        ReminderEditorPresentation.disposition(for: write)
    else {
      return XCTFail("Expected retry-blocked commit to stay open")
    }
    XCTAssertEqual(returned, value)
    XCTAssertTrue(messages.isEmpty)
  }

  func testPendingCommitCannotDelete() {
    var value = draft(id: "item-1")
    value.pendingCommitReceipt = ReminderCommitReceipt(
      itemIdentifier: "item-1", externalIdentifier: nil)

    XCTAssertFalse(ReminderEditorPresentation.canDelete(value))
  }

  func testDeletionPayloadCapturesExactIDAndRevision() {
    let original = draft(id: "item-1", revisionTitle: "captured")
    let payload = ReminderEditorDeletionPayload(draft: original)
    let replacement = draft(id: "item-2", revisionTitle: "later")

    XCTAssertEqual(payload.draft.reminderID, "item-1")
    XCTAssertEqual(payload.draft.sourceRevision?.title, "captured")
    XCTAssertNotEqual(payload.draft.sourceRevision, replacement.sourceRevision)
  }

  func testExactIDPendingResolutionAcceptsSameRevisionAndCompletedRecord() {
    var pending = draft(id: "item-1", revisionTitle: "same")
    pending.pendingCommitReceipt = ReminderCommitReceipt(
      itemIdentifier: "item-1", externalIdentifier: "external")
    var completed = makeRecord(id: "item-1", title: "same")
    completed.isCompleted = true
    completed.completionDate = Date(timeIntervalSince1970: 1_800_000_000)

    XCTAssertEqual(
      ReminderEditorPresentation.authoritativePendingRecord(
        for: pending, acceptedReloadGeneration: true, record: completed),
      completed)
  }

  func testPendingResolutionRejectsWrongIDRejectedGenerationAndNilIDCreate() {
    var pending = draft(id: "item-1")
    pending.pendingCommitReceipt = ReminderCommitReceipt(
      itemIdentifier: "item-1", externalIdentifier: nil)
    let wrong = makeRecord(id: "item-2")

    XCTAssertNil(
      ReminderEditorPresentation.authoritativePendingRecord(
        for: pending, acceptedReloadGeneration: true, record: wrong))
    XCTAssertNil(
      ReminderEditorPresentation.authoritativePendingRecord(
        for: pending, acceptedReloadGeneration: false, record: makeRecord(id: "item-1")))

    var nilID = draft(id: nil)
    nilID.pendingCommitReceipt = ReminderCommitReceipt(
      itemIdentifier: nil, externalIdentifier: "external")
    XCTAssertNil(ReminderEditorPresentation.pendingLookupID(for: nilID))
    XCTAssertNil(
      ReminderEditorPresentation.authoritativePendingRecord(
        for: nilID, acceptedReloadGeneration: true, record: makeRecord(id: "item-1")))
  }

  func testPendingRetryUsesBoundedNonzeroBackoff() {
    XCTAssertEqual(
      ReminderEditorPresentation.pendingRetryDelays,
      [.milliseconds(250), .milliseconds(750), .seconds(2), .seconds(4)])
    XCTAssertEqual(ReminderEditorPresentation.pendingRetryDelays.count, 4)
  }

  private func fixedCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = utc
    return calendar
  }

  private func list(id: String, title: String) -> ReminderListItem {
    ReminderListItem(
      id: id, title: title, colorHex: nil, isDefault: false, isWritable: true)
  }

  private func dateValue(
    year: Int, month: Int, day: Int, hour: Int? = nil, minute: Int? = nil,
    timeZone: TimeZone? = nil
  ) throws -> ReminderDateValue {
    var components = DateComponents()
    components.calendar = Calendar(identifier: .gregorian)
    components.timeZone = timeZone
    components.year = year
    components.month = month
    components.day = day
    components.hour = hour
    components.minute = minute
    return try ReminderDateValue(validating: components)
  }

  private func draft(
    id: String?, revisionTitle: String = "Reminder"
  ) -> ReminderCoordinatorDraft {
    let record = id.map { makeRecord(id: $0, title: revisionTitle) }
    return ReminderCoordinatorDraft(
      reminderID: id, title: "Reminder", listID: "list-1", priority: 0,
      baselineRecord: record, sourceRevision: record?.revision)
  }

  private func makeRecord(id: String, title: String = "Reminder") -> ReminderWriteRecord {
    ReminderWriteRecord(
      id: id, title: title, notes: nil, priority: 0, dueDateComponents: nil,
      listID: "list-1", listTitle: "List", listColorHex: nil, isCompleted: false,
      lastModified: nil)
  }
}
