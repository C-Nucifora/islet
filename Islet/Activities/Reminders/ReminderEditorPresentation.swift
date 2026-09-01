import Foundation

enum ReminderEditorFocus: Hashable, Sendable {
  case title
  case notes
  case url
  case startDate
  case dueDate
  case completionDate
}

enum ReminderEditorCommand: Equatable, Sendable {
  case returnKey
  case saveButton
  case escape
  case commandN
  case deleteShortcut
}

enum ReminderEditorCommandAction: Equatable, Sendable {
  case submit
  case dismiss
  case startNew
  case reopenPending
  case none
}

enum ReminderEditorHandoff: Equatable, Sendable {
  case remindersApplication
}

struct ReminderEditorFieldMessage: Equatable, Sendable {
  let field: ReminderField
  let message: String
}

struct ReminderEditorListOption: Identifiable, Equatable, Sendable {
  let id: String
  let title: String
  let isUnavailable: Bool
}

struct ReminderEditorDeletionPayload: Equatable, Sendable {
  let sessionID: UUID?
  let draft: ReminderCoordinatorDraft

  init(sessionID: UUID? = nil, draft: ReminderCoordinatorDraft) {
    self.sessionID = sessionID
    self.draft = draft
  }
}

struct ReminderEditorAlertButton: Equatable, Sendable {
  let title: String
  let isDefault: Bool
  let isDestructive: Bool
}

enum ReminderEditorAlertConfiguration {
  static let deleteButtons = [
    ReminderEditorAlertButton(title: "Cancel", isDefault: true, isDestructive: false),
    ReminderEditorAlertButton(title: "Delete", isDefault: false, isDestructive: true),
  ]

  static let stopWaitingButtons = [
    ReminderEditorAlertButton(title: "Cancel", isDefault: true, isDestructive: false),
    ReminderEditorAlertButton(
      title: "Open Reminders and Stop Waiting", isDefault: false, isDestructive: true),
  ]
}

struct ReminderEditorSession: Equatable, Sendable {
  let id: UUID
  var draft: ReminderCoordinatorDraft
  var fieldMessages: [ReminderEditorFieldMessage]
  var generalMessage: String?
  let calendar: Calendar
  let displayTimeZone: TimeZone

  init(
    id: UUID = UUID(), draft: ReminderCoordinatorDraft,
    fieldMessages: [ReminderEditorFieldMessage] = [], generalMessage: String? = nil,
    calendar: Calendar, displayTimeZone: TimeZone
  ) {
    self.id = id
    self.draft = draft
    self.fieldMessages = fieldMessages
    self.generalMessage = generalMessage
    self.calendar = calendar
    self.displayTimeZone = displayTimeZone
  }

  var isPending: Bool { draft.pendingCommitReceipt != nil }
}

enum ReminderEditorWindowRequest: Equatable, Sendable {
  case new
  case edit
  case snooze
}

enum ReminderEditorWindowRoute: Equatable, Sendable {
  case editor
  case snooze
}

enum ReminderEditorDraftValidation: Equatable, Sendable {
  case valid(ReminderCoordinatorDraft)
  case invalid(ReminderCoordinatorDraft, messages: [ReminderEditorFieldMessage])
}

enum ReminderEditorSubmissionDisposition: Equatable, Sendable {
  case close(ReminderCoordinatorDraft)
  case keepOpen(ReminderCoordinatorDraft, messages: [ReminderEditorFieldMessage])
  case pending(ReminderCoordinatorDraft, message: String)
}

enum ReminderEditorPresentation {
  static let deleteUsesDefaultAction = false
  static let pendingRetryDelays: [Duration] = [
    .milliseconds(250), .milliseconds(750), .seconds(2), .seconds(4),
  ]

  static func action(
    for command: ReminderEditorCommand, focus: ReminderEditorFocus?, isPending: Bool,
    isSubmissionEnabled: Bool = true
  ) -> ReminderEditorCommandAction {
    switch command {
    case .returnKey:
      guard !isPending, isSubmissionEnabled else { return .none }
      return focus == .notes ? .none : .submit
    case .saveButton:
      return isSubmissionEnabled ? .submit : .none
    case .escape:
      return .dismiss
    case .commandN:
      return isPending ? .reopenPending : .startNew
    case .deleteShortcut:
      return .none
    }
  }

  static func offersOpenInReminders(for draft: ReminderCoordinatorDraft) -> Bool {
    draft.reminderID != nil || draft.pendingCommitReceipt != nil
  }

  static func handoff(for draft: ReminderCoordinatorDraft) -> ReminderEditorHandoff {
    .remindersApplication
  }

  static func canSubmit(_ draft: ReminderCoordinatorDraft) -> Bool {
    draft.canRetry
      && !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  static func canDelete(_ draft: ReminderCoordinatorDraft) -> Bool {
    draft.reminderID != nil && draft.pendingCommitReceipt == nil
  }

  static func windowRoute(
    currentDraft: ReminderCoordinatorDraft?, request: ReminderEditorWindowRequest
  ) -> ReminderEditorWindowRoute {
    if currentDraft?.pendingCommitReceipt != nil { return .editor }
    return request == .snooze ? .snooze : .editor
  }

  static func prepareForSubmission(
    _ draft: ReminderCoordinatorDraft
  ) -> ReminderEditorDraftValidation {
    var prepared = draft
    if prepared.notes?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
      prepared.notes = nil
    }

    let trimmedURL = prepared.urlText.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmedURL.isEmpty {
      prepared.urlText = ""
      return .valid(prepared)
    }
    guard let url = URL(string: trimmedURL), url.scheme?.isEmpty == false else {
      return .invalid(
        prepared,
        messages: [
          ReminderEditorFieldMessage(field: .url, message: "Enter a valid reminder URL.")
        ])
    }
    prepared.urlText = url.absoluteString
    return .valid(prepared)
  }

  static func disposition(
    for write: ReminderCoordinatorWrite
  ) -> ReminderEditorSubmissionDisposition {
    switch write.outcome {
    case .noChanges, .saved:
      if write.draft.retryBlockedReason != nil {
        return .keepOpen(write.draft, messages: [])
      }
      return .close(write.draft)
    case .committedWithNormalization(_, let mismatches):
      return .keepOpen(
        write.draft,
        messages: mismatches.map {
          ReminderEditorFieldMessage(field: $0.field, message: $0.reason)
        })
    case .commitStatusUnknown:
      return .pending(
        write.draft,
        message:
          "Islet is waiting for Reminders to reload this commit. Add or Save is disabled until the reminder can be confirmed."
      )
    }
  }

  static func initialListID(
    defaultID: String?, lists: [ReminderListItem]
  ) -> String? {
    if let defaultID, lists.contains(where: { $0.id == defaultID }) { return defaultID }
    return lists.first?.id
  }

  static func listOptions(
    lists: [ReminderListItem], selectedID: String?
  ) -> [ReminderEditorListOption] {
    var options = lists.map {
      ReminderEditorListOption(id: $0.id, title: $0.title, isUnavailable: false)
    }
    if let selectedID, !lists.contains(where: { $0.id == selectedID }) {
      options.append(
        ReminderEditorListOption(
          id: selectedID, title: "Unavailable list", isUnavailable: true))
    }
    return options
  }

  static func timeZoneIdentifiers(
    selectedIdentifier: String?, knownIdentifiers: [String] = TimeZone.knownTimeZoneIdentifiers
  ) -> [String] {
    guard let selectedIdentifier, !knownIdentifiers.contains(selectedIdentifier) else {
      return knownIdentifiers
    }
    return [selectedIdentifier] + knownIdentifiers
  }

  static func settingCompletion(
    _ isCompleted: Bool, in draft: ReminderCoordinatorDraft, now: Date
  ) -> ReminderCoordinatorDraft {
    var changed = draft
    changed.isCompleted = isCompleted
    changed.completionDate = isCompleted ? now : nil
    return changed
  }

  static func removingTime(from value: ReminderDateValue) throws -> ReminderDateValue {
    var components = value.components
    components.hour = nil
    components.minute = nil
    components.second = nil
    components.nanosecond = nil
    return try ReminderDateValue(validating: components)
  }

  static func assigningTimeZone(
    _ timeZone: TimeZone?, to value: ReminderDateValue
  ) throws -> ReminderDateValue {
    var components = value.components
    components.timeZone = timeZone
    return try ReminderDateValue(validating: components)
  }

  static func addingTime(
    to value: ReminderDateValue, clock: Date, calendar: Calendar,
    displayTimeZone: TimeZone
  ) throws -> ReminderDateValue {
    guard calendar.identifier == .gregorian else {
      throw ReminderWriteError.invalidDateComponents
    }
    var extractionCalendar = calendar
    extractionCalendar.timeZone = value.components.timeZone ?? displayTimeZone
    let clockComponents = extractionCalendar.dateComponents([.hour, .minute], from: clock)
    var components = value.components
    components.hour = clockComponents.hour
    components.minute = clockComponents.minute
    components.second = nil
    components.nanosecond = nil
    return try ReminderDateValue(validating: components)
  }

  static func dateValue(
    from date: Date, includesTime: Bool, timeZone: TimeZone?, calendar: Calendar,
    displayTimeZone: TimeZone
  ) throws -> ReminderDateValue {
    guard calendar.identifier == .gregorian else {
      throw ReminderWriteError.invalidDateComponents
    }
    let effectiveTimeZone = timeZone ?? displayTimeZone
    var extractionCalendar = calendar
    extractionCalendar.timeZone = effectiveTimeZone
    let requestedComponents: Set<Calendar.Component> =
      includesTime
      ? [.era, .year, .month, .day, .hour, .minute]
      : [.era, .year, .month, .day]
    var components = extractionCalendar.dateComponents(requestedComponents, from: date)
    components.calendar = extractionCalendar
    components.timeZone = timeZone
    return try ReminderDateValue(validating: components)
  }

  static func displayDate(
    for value: ReminderDateValue, calendar: Calendar, displayTimeZone: TimeZone
  ) throws -> Date {
    guard calendar.identifier == .gregorian else {
      throw ReminderWriteError.invalidDateComponents
    }
    var conversionCalendar = calendar
    conversionCalendar.timeZone = value.components.timeZone ?? displayTimeZone
    return try value.date(in: conversionCalendar)
  }

  static func pendingLookupID(for draft: ReminderCoordinatorDraft) -> String? {
    draft.pendingCommitReceipt?.itemIdentifier ?? draft.reminderID
  }

  static func authoritativePendingRecord(
    for draft: ReminderCoordinatorDraft, acceptedReloadGeneration: Bool,
    record: ReminderWriteRecord?
  ) -> ReminderWriteRecord? {
    guard acceptedReloadGeneration, let identifier = pendingLookupID(for: draft),
      let record, record.id == identifier
    else {
      return nil
    }
    return record
  }
}
