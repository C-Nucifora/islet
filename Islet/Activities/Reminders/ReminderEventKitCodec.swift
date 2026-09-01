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
        validating: reminder.isCompleted, completionDate: reminder.completionDate))
  }

  static func revision(from reminder: EKReminder) -> ReminderWriteRecord.Revision {
    record(from: reminder).revision
  }

  static func apply(
    _ patch: ReminderPatch, to reminder: EKReminder,
    resolveList: (String) -> EKCalendar?
  ) throws {
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

    switch patch.listID {
    case .unchanged:
      break
    case .value(let listID):
      guard let calendar = resolveList(listID),
        calendar.calendarIdentifier == listID,
        calendar.allowsContentModifications
      else {
        throw ReminderWriteError.missingList
      }
      reminder.calendar = calendar
    }

    switch patch.startDate {
    case .unchanged:
      break
    case .value(let startDate):
      reminder.startDateComponents = startDate?.components
    }

    switch patch.dueDate {
    case .unchanged:
      break
    case .value(let dueDate):
      reminder.dueDateComponents = dueDate?.components
    }

    switch patch.priority {
    case .unchanged:
      break
    case .value(let priority):
      reminder.priority = priority
    }

    switch patch.completion {
    case .unchanged:
      break
    case .value(let completion):
      reminder.isCompleted = completion.isCompleted
      reminder.completionDate = completion.completionDate
    }
  }

  private static func alarmRevision(from alarm: EKAlarm) -> ReminderAlarmRevision {
    let location = alarm.structuredLocation
    let coordinate = location?.geoLocation?.coordinate
    return ReminderAlarmRevision(
      typeRawValue: alarm.type.rawValue, absoluteDate: alarm.absoluteDate,
      relativeOffset: alarm.relativeOffset, locationTitle: location?.title,
      latitude: coordinate?.latitude, longitude: coordinate?.longitude,
      radius: location?.radius, proximityRawValue: alarm.proximity.rawValue,
      emailAddress: alarm.emailAddress, soundName: alarm.soundName,
      url: alarm.value(forKey: "url") as? URL)
  }

  private static func recurrenceRevision(from rule: EKRecurrenceRule)
    -> ReminderRecurrenceRevision
  {
    let recurrenceEnd = rule.recurrenceEnd
    let occurrenceCount = recurrenceEnd.flatMap {
      $0.occurrenceCount == 0 ? nil : Int(exactly: $0.occurrenceCount)
    }
    return ReminderRecurrenceRevision(
      calendarIdentifier: calendarIdentifier(from: rule.calendarIdentifier),
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
