import EventKit
import Foundation

enum ReminderEventKitCodec {
  static func record(from reminder: EKReminder) -> ReminderWriteRecord {
    let calendar = reminder.calendar
    let alarmRevisions = (reminder.alarms ?? []).map(alarmRevision(from:))
    let recurrenceRevisions = (reminder.recurrenceRules ?? []).map(recurrenceRevision(from:))
    return ReminderWriteRecord(
      id: reminder.calendarItemIdentifier, title: reminder.title ?? "Untitled",
      notes: reminder.notes, priority: reminder.priority,
      dueDateComponents: reminder.dueDateComponents,
      listID: calendar?.calendarIdentifier ?? "", listTitle: calendar?.title ?? "",
      listColorHex: ColorHex.string(from: calendar?.cgColor),
      isCompleted: reminder.isCompleted, lastModified: reminder.lastModifiedDate,
      url: reminder.url, startDateComponents: reminder.startDateComponents,
      completionDate: reminder.completionDate, location: reminder.location,
      timeZone: reminder.timeZone, alarmRevisions: alarmRevisions,
      recurrenceRevisions: recurrenceRevisions)
  }

  static func editableFields(from reminder: EKReminder) throws -> ReminderEditableFields {
    try ReminderEditableFields(
      validating: reminder.title ?? "Untitled", notes: reminder.notes, url: reminder.url,
      listID: reminder.calendar?.calendarIdentifier ?? "",
      startDate: try reminder.startDateComponents.map(ReminderDateValue.init(validating:)),
      dueDate: try reminder.dueDateComponents.map(ReminderDateValue.init(validating:)),
      priority: reminder.priority,
      completion: ReminderCompletionValue(
        validating: reminder.isCompleted, completionDate: reminder.completionDate),
      alarms: (reminder.alarms ?? []).compactMap(ReminderAdvancedCodec.alarmValue(from:)),
      recurrenceRules: (reminder.recurrenceRules ?? []).compactMap(
        ReminderAdvancedCodec.recurrenceValue(from:)))
  }

  static func revision(from reminder: EKReminder) -> ReminderWriteRecord.Revision {
    record(from: reminder).revision
  }

  static func apply(
    _ patch: ReminderPatch, to reminder: EKReminder,
    resolveList: (String) -> EKCalendar?
  ) throws {
    let selectedList: EKCalendar?
    switch patch.listID {
    case .unchanged:
      selectedList = nil
    case .value(let listID):
      guard let calendar = resolveList(listID),
        calendar.calendarIdentifier == listID,
        calendar.allowsContentModifications
      else {
        throw ReminderWriteError.missingList
      }
      selectedList = calendar
    }
    let alarms: [EKAlarm]?
    if case .value(let values) = patch.alarms {
      alarms = try ReminderAdvancedCodec.merging(
        original: reminder.alarms ?? [], edited: values,
        decode: ReminderAdvancedCodec.alarmValue(from:), encode: ReminderAdvancedCodec.alarm(from:))
    } else {
      alarms = nil
    }
    let recurrenceRules: [EKRecurrenceRule]?
    if case .value(let values) = patch.recurrenceRules {
      recurrenceRules = try ReminderAdvancedCodec.merging(
        original: reminder.recurrenceRules ?? [], edited: values,
        decode: ReminderAdvancedCodec.recurrenceValue(from:),
        encode: ReminderAdvancedCodec.recurrence(from:))
    } else {
      recurrenceRules = nil
    }
    let resultingDue: DateComponents?
    if case .value(let due) = patch.dueDate {
      resultingDue = due?.components
    } else {
      resultingDue = reminder.dueDateComponents
    }
    if patch.recurrenceRules != .unchanged || patch.dueDate != .unchanged,
      !(recurrenceRules ?? reminder.recurrenceRules ?? []).isEmpty, resultingDue == nil
    {
      throw ReminderWriteError.eventKit(
        String(localized: "Repeating reminders need a due date. Add one before saving."))
    }
    if let selectedList { reminder.calendar = selectedList }

    switch patch.title {
    case .unchanged:
      break
    case .value(let title):
      reminder.title = title
    }

    switch patch.notes {
    case .unchanged:
      break
    case .value(let notes):
      reminder.notes = notes
    }

    switch patch.url {
    case .unchanged:
      break
    case .value(let url):
      reminder.url = url
    }

    if patch.startDate != .unchanged || patch.dueDate != .unchanged {
      let start: DateComponents?
      let due: DateComponents?
      if case .value(let value) = patch.startDate {
        start = value?.components
      } else {
        start = reminder.startDateComponents
      }
      if case .value(let value) = patch.dueDate {
        due = value?.components
      } else {
        due = reminder.dueDateComponents
      }
      // Setting a date-only start can clear the due clock. Setting due can synthesize start.
      // Apply a present start first, then due, and clear an absent start last.
      if let start, reminder.startDateComponents != start { reminder.startDateComponents = start }
      if reminder.dueDateComponents != due { reminder.dueDateComponents = due }
      if start == nil, reminder.startDateComponents != nil { reminder.startDateComponents = nil }
    }

    switch patch.priority {
    case .unchanged:
      break
    case .value(let priority):
      reminder.priority = priority
    }

    if let alarms { reminder.alarms = alarms }
    if let recurrenceRules { reminder.recurrenceRules = recurrenceRules }

    switch patch.completion {
    case .unchanged:
      break
    case .value(let completion):
      reminder.isCompleted = completion.isCompleted
      reminder.completionDate = completion.completionDate
    }
  }

  static func alarmRevision(from alarm: EKAlarm) -> ReminderAlarmRevision {
    let location = alarm.structuredLocation
    let coordinate = location?.geoLocation?.coordinate
    return ReminderAlarmRevision(
      typeRawValue: alarm.type.rawValue, absoluteDate: alarm.absoluteDate,
      relativeOffset: alarm.relativeOffset, locationTitle: location?.title,
      latitude: coordinate?.latitude, longitude: coordinate?.longitude,
      radius: location?.radius, proximityRawValue: alarm.proximity.rawValue,
      emailAddress: alarm.emailAddress, soundName: alarm.soundName, url: nil)
  }

  static func recurrenceRevision(from rule: EKRecurrenceRule)
    -> ReminderRecurrenceRevision
  {
    let recurrenceEnd = rule.recurrenceEnd
    let calendarIdentifier = recurrenceCalendarIdentifier(from: rule.calendarIdentifier)
    let occurrenceCount = recurrenceEnd.flatMap {
      $0.occurrenceCount == 0 ? nil : Int(exactly: $0.occurrenceCount)
    }
    return ReminderRecurrenceRevision(
      calendarIdentifierRawValue: calendarIdentifier.rawValue,
      calendarIdentifier: calendarIdentifier.typedValue,
      frequencyRawValue: rule.frequency.rawValue, interval: rule.interval,
      firstDayOfTheWeek: rule.firstDayOfTheWeek,
      daysOfTheWeek: (rule.daysOfTheWeek ?? []).map {
        ReminderWeekdayRevision(
          dayOfTheWeekRawValue: $0.dayOfTheWeek.rawValue, weekNumber: $0.weekNumber)
      },
      daysOfTheMonth: integers(from: rule.daysOfTheMonth),
      monthsOfTheYear: integers(from: rule.monthsOfTheYear),
      weeksOfTheYear: integers(from: rule.weeksOfTheYear),
      daysOfTheYear: integers(from: rule.daysOfTheYear),
      setPositions: integers(from: rule.setPositions), endDate: recurrenceEnd?.endDate,
      occurrenceCount: occurrenceCount)
  }

  private static func integers(from values: [NSNumber]?) -> [Int] {
    (values ?? []).map(\.intValue)
  }

  static func recurrenceCalendarIdentifier(from rawValue: String) -> (
    rawValue: String, typedValue: Calendar.Identifier?
  ) {
    (rawValue, calendarIdentifier(from: rawValue))
  }

  private static func calendarIdentifier(from value: String) -> Calendar.Identifier? {
    let identifiers: [Calendar.Identifier] = [
      .gregorian, .buddhist, .chinese, .coptic, .ethiopicAmeteMihret,
      .ethiopicAmeteAlem, .hebrew, .iso8601, .indian, .islamic, .islamicCivil,
      .japanese, .persian, .republicOfChina, .islamicTabular, .islamicUmmAlQura,
      .bangla, .gujarati, .kannada, .malayalam, .marathi, .odia, .tamil, .telugu,
      .vikram, .dangi, .vietnamese,
    ]
    return identifiers.first {
      (Calendar(identifier: $0) as NSCalendar).calendarIdentifier.rawValue == value
    }
  }
}
