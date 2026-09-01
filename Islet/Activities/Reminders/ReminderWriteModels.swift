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

  func date(in calendar: Calendar) throws -> Date {
    guard calendar.identifier == .gregorian,
      let date = Self.resolvedDate(for: components, in: Self.conversionCalendar(calendar, for: components))
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

  private static func conversionCalendar(_ calendar: Calendar, for components: DateComponents) -> Calendar {
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

  init(
    validating title: String, notes: String?, url: URL?, listID: String,
    startDate: ReminderDateValue?, dueDate: ReminderDateValue?, priority: Int,
    completion: ReminderCompletionValue
  ) throws {
    guard [0, 1, 5, 9].contains(priority) else {
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

  init(from baseline: ReminderEditableFields, to edited: ReminderEditableFields) {
    title = Self.change(from: baseline.title, to: edited.title)
    notes = Self.change(from: baseline.notes, to: edited.notes)
    url = Self.change(from: baseline.url, to: edited.url)
    listID = Self.change(from: baseline.listID, to: edited.listID)
    startDate = Self.change(from: baseline.startDate, to: edited.startDate)
    dueDate = Self.change(from: baseline.dueDate, to: edited.dueDate)
    priority = Self.change(from: baseline.priority, to: edited.priority)
    completion = Self.change(from: baseline.completion, to: edited.completion)
  }

  var isEmpty: Bool {
    title == .unchanged && notes == .unchanged && url == .unchanged && listID == .unchanged
      && startDate == .unchanged && dueDate == .unchanged && priority == .unchanged
      && completion == .unchanged
  }

  private static func change<Value: Equatable & Sendable>(
    from baseline: Value, to edited: Value
  ) -> ReminderFieldChange<Value> {
    baseline == edited ? .unchanged : .value(edited)
  }
}

enum ReminderField: String, Equatable, Sendable {
  case title, notes, url, list, startDate, dueDate, priority, completion
}

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

struct ReminderWriteRecord: Equatable, Sendable {
  struct Revision: Equatable, Sendable {
    let lastModified: Date?
    let title: String
    let notes: String?
    let priority: Int
    let dueDateComponents: DateComponents?
    let listID: String
    let isCompleted: Bool
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

  var revision: Revision {
    Revision(
      lastModified: lastModified, title: title, notes: notes, priority: priority,
      dueDateComponents: dueDateComponents, listID: listID, isCompleted: isCompleted)
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
