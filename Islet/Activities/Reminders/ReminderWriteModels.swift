import Foundation

enum ReminderFieldChange<Value: Equatable & Sendable>: Equatable, Sendable {
  case unchanged
  case value(Value)
}

struct ReminderDateValue: Equatable, Sendable {
  let components: DateComponents

  init(validating components: DateComponents) throws {
    guard components.calendar == nil || components.calendar?.identifier == .gregorian else {
      throw ReminderWriteError.invalidDateComponents
    }

    var normalized = components
    normalized.era = components.era ?? 1

    guard normalized.year != nil, normalized.month != nil, normalized.day != nil else {
      throw ReminderWriteError.invalidDateComponents
    }

    let hasHour = normalized.hour != nil
    let hasMinute = normalized.minute != nil
    guard hasHour == hasMinute, normalized.second == nil || hasHour else {
      throw ReminderWriteError.invalidDateComponents
    }

    let validationCalendar = Self.validationCalendar(for: normalized)
    guard Self.resolvedDate(for: normalized, in: validationCalendar) != nil else {
      throw ReminderWriteError.invalidDateComponents
    }

    self.components = normalized
  }

  static func semanticallyEqual(_ lhs: DateComponents?, _ rhs: DateComponents?) -> Bool {
    guard let lhs, let rhs else { return lhs == nil && rhs == nil }
    let lhsHasTime = lhs.hour != nil || lhs.minute != nil || lhs.second != nil
    let rhsHasTime = rhs.hour != nil || rhs.minute != nil || rhs.second != nil
    return lhsHasTime == rhsHasTime && lhs.timeZone == rhs.timeZone
      && (lhs.era ?? 1) == (rhs.era ?? 1)
      && lhs.year == rhs.year && lhs.month == rhs.month && lhs.day == rhs.day
      && lhs.hour == rhs.hour && lhs.minute == rhs.minute
      && (!lhsHasTime || (lhs.second ?? 0) == (rhs.second ?? 0))
      && (lhs.calendar?.identifier ?? .gregorian) == (rhs.calendar?.identifier ?? .gregorian)
  }

  func date(in calendar: Calendar) throws -> Date {
    guard calendar.identifier == .gregorian,
      let date = Self.resolvedDate(
        for: components, in: Self.conversionCalendar(calendar, for: components))
    else {
      throw ReminderWriteError.invalidDateComponents
    }
    return date
  }

  private static func validationCalendar(for components: DateComponents) -> Calendar {
    var calendar = components.calendar ?? Calendar(identifier: .gregorian)
    if let timeZone = components.timeZone {
      calendar.timeZone = timeZone
    }
    return calendar
  }

  private static func conversionCalendar(_ calendar: Calendar, for components: DateComponents)
    -> Calendar
  {
    var calendar = calendar
    if let timeZone = components.timeZone {
      calendar.timeZone = timeZone
    }
    return calendar
  }

  private static func resolvedDate(for components: DateComponents, in calendar: Calendar) -> Date? {
    guard let date = calendar.date(from: components) else { return nil }
    let resolved = calendar.dateComponents(
      [.era, .year, .month, .day, .hour, .minute, .second], from: date)
    guard resolved.era == components.era,
      resolved.year == components.year,
      resolved.month == components.month,
      resolved.day == components.day
    else {
      return nil
    }

    if let hour = components.hour, resolved.hour != hour { return nil }
    if let minute = components.minute, resolved.minute != minute { return nil }
    if let second = components.second, resolved.second != second { return nil }
    return date
  }
}

struct ReminderCompletionValue: Equatable, Sendable {
  let isCompleted: Bool
  let completionDate: Date?

  init(validating isCompleted: Bool, completionDate: Date?) throws {
    guard !isCompleted || completionDate != nil else {
      throw ReminderWriteError.missingCompletionDate
    }
    self.isCompleted = isCompleted
    self.completionDate = isCompleted ? completionDate : nil
  }
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
  var alarms: [ReminderAlarmValue] = []
  var recurrenceRules: [ReminderRecurrenceValue] = []

  init(
    validating title: String, notes: String?, url: URL?, listID: String,
    startDate: ReminderDateValue?, dueDate: ReminderDateValue?, priority: Int,
    completion: ReminderCompletionValue, alarms: [ReminderAlarmValue] = [],
    recurrenceRules: [ReminderRecurrenceValue] = []
  ) throws {
    guard (0...9).contains(priority) else {
      throw ReminderWriteError.invalidPriority
    }
    self.title = title
    self.notes = notes
    self.url = url
    self.listID = listID
    self.startDate = startDate
    self.dueDate = dueDate
    self.priority = priority
    self.completion = completion
    self.alarms = alarms
    self.recurrenceRules = recurrenceRules
  }
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
  var alarms: ReminderFieldChange<[ReminderAlarmValue]>
  var recurrenceRules: ReminderFieldChange<[ReminderRecurrenceValue]>

  init(from baseline: ReminderEditableFields, to edited: ReminderEditableFields) {
    title = Self.change(from: baseline.title, to: edited.title)
    notes = Self.change(from: baseline.notes, to: edited.notes)
    url = Self.change(from: baseline.url, to: edited.url)
    listID = Self.change(from: baseline.listID, to: edited.listID)
    startDate = Self.change(from: baseline.startDate, to: edited.startDate)
    dueDate = Self.change(from: baseline.dueDate, to: edited.dueDate)
    priority = Self.change(from: baseline.priority, to: edited.priority)
    completion = Self.change(from: baseline.completion, to: edited.completion)
    alarms = Self.change(from: baseline.alarms, to: edited.alarms)
    recurrenceRules = Self.change(from: baseline.recurrenceRules, to: edited.recurrenceRules)
  }

  var isEmpty: Bool {
    title == .unchanged && notes == .unchanged && url == .unchanged && listID == .unchanged
      && startDate == .unchanged && dueDate == .unchanged && priority == .unchanged
      && completion == .unchanged && alarms == .unchanged && recurrenceRules == .unchanged
  }

  private static func change<Value: Equatable & Sendable>(
    from baseline: Value, to edited: Value
  ) -> ReminderFieldChange<Value> {
    baseline == edited ? .unchanged : .value(edited)
  }
}

enum ReminderField: String, Equatable, Sendable {
  case title, notes, url, list, startDate, dueDate, priority, completion, alarms, recurrence,
    nativeMetadata

  var displayName: String {
    switch self {
    case .title: String(localized: "title")
    case .notes: String(localized: "notes")
    case .url: String(localized: "link")
    case .list: String(localized: "list")
    case .startDate: String(localized: "start date")
    case .dueDate: String(localized: "due date")
    case .priority: String(localized: "priority")
    case .completion: String(localized: "completion")
    case .alarms: String(localized: "alerts")
    case .recurrence: String(localized: "repeat rules")
    case .nativeMetadata: String(localized: "other reminder details")
    }
  }
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

struct ReminderDraft: Equatable, Sendable {
  var title: String
  var listID: String?
  var dueDate: Date?
  var hasDueTime: Bool
  var priority: Int
  var sourceRevision: ReminderWriteRecord.Revision? = nil

  static let empty = ReminderDraft(
    title: "", listID: nil, dueDate: nil, hasDueTime: false, priority: 0)
}

struct ReminderWeekdayRevision: Equatable, Sendable {
  let dayOfTheWeekRawValue: Int
  let weekNumber: Int
}

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
  let calendarIdentifierRawValue: String
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

struct ReminderWriteRecord: Equatable, Sendable {
  struct Revision: Equatable, Sendable {
    let lastModifiedDate: Date?
    let title: String
    let notes: String?
    let url: URL?
    let startDateComponents: DateComponents?
    let dueDateComponents: DateComponents?
    let priority: Int
    let isCompleted: Bool
    let completionDate: Date?
    let location: String?
    let timeZone: TimeZone?
    let alarms: [ReminderAlarmRevision]
    let recurrenceRules: [ReminderRecurrenceRevision]
    let listID: String
  }

  let id: String
  var title: String
  var notes: String?
  var priority: Int
  var dueDateComponents: DateComponents?
  var listID: String
  var listTitle: String
  var listColorHex: String?
  var isCompleted: Bool
  var lastModified: Date?
  var url: URL? = nil
  var startDateComponents: DateComponents? = nil
  var completionDate: Date? = nil
  var location: String? = nil
  var timeZone: TimeZone? = nil
  var alarmRevisions: [ReminderAlarmRevision] = []
  var recurrenceRevisions: [ReminderRecurrenceRevision] = []

  var revision: Revision {
    Revision(
      lastModifiedDate: lastModified, title: title, notes: notes, url: url,
      startDateComponents: startDateComponents, dueDateComponents: dueDateComponents,
      priority: priority, isCompleted: isCompleted, completionDate: completionDate,
      location: location, timeZone: timeZone, alarms: alarmRevisions,
      recurrenceRules: recurrenceRevisions, listID: listID)
  }
}

enum ReminderWriteError: LocalizedError, Equatable {
  case permissionDenied
  case missingList
  case missingReminder
  case changedElsewhere
  case undoExpired
  case noUndoAvailable
  case emptyTitle
  case invalidDateComponents
  case invalidPriority
  case missingCompletionDate
  case eventKit(String)

  var errorDescription: String? {
    switch self {
    case .permissionDenied:
      "Reminders access is no longer available."
    case .missingList:
      "That reminder list is no longer available."
    case .missingReminder:
      "That reminder is no longer available."
    case .changedElsewhere:
      "That reminder changed in another app, so it was not overwritten."
    case .undoExpired:
      "The undo period has expired."
    case .noUndoAvailable:
      "There is no completion to undo."
    case .emptyTitle:
      "Enter a reminder title."
    case .invalidDateComponents:
      "Enter a valid reminder date and time."
    case .invalidPriority:
      "Choose a supported reminder priority."
    case .missingCompletionDate:
      "Completed reminders need a completion date."
    case .eventKit(let message):
      message
    }
  }
}
