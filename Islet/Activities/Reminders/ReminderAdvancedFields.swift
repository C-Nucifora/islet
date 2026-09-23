import CoreLocation
import EventKit
import Foundation

enum ReminderAlarmValue: Equatable, Sendable {
  case absolute(Date)
  case relative(TimeInterval)
  case location(title: String, latitude: Double, longitude: Double, radius: Double, onArrival: Bool)
}

struct ReminderRecurrenceValue: Equatable, Sendable {
  enum Frequency: Int, CaseIterable, Sendable {
    case daily, weekly, monthly, yearly
    var title: String {
      switch self {
      case .daily: String(localized: "Daily")
      case .weekly: String(localized: "Weekly")
      case .monthly: String(localized: "Monthly")
      case .yearly: String(localized: "Yearly")
      }
    }
  }
  struct Weekday: Equatable, Sendable {
    var day: Int
    var ordinal: Int = 0
  }
  enum End: Equatable, Sendable {
    case never
    case date(Date)
    case count(Int)
  }
  var frequency: Frequency
  var interval: Int = 1
  var weekdays: [Weekday] = []
  var monthDays: [Int] = []
  var months: [Int] = []
  var weeks: [Int] = []
  var yearDays: [Int] = []
  var positions: [Int] = []
  var end: End = .never
}

enum ReminderAdvancedCodec {
  static func alarm(from value: ReminderAlarmValue) throws -> EKAlarm {
    switch value {
    case .absolute(let date):
      guard date.timeIntervalSinceReferenceDate.isFinite else { throw invalidAlarm }
      return EKAlarm(absoluteDate: date)
    case .relative(let offset):
      guard offset.isFinite else { throw invalidAlarm }
      return EKAlarm(relativeOffset: offset)
    case .location(let title, let latitude, let longitude, let radius, let onArrival):
      guard latitude.isFinite, longitude.isFinite, radius.isFinite,
        (-90...90).contains(latitude), (-180...180).contains(longitude), radius >= 0
      else { throw invalidAlarm }
      let alarm = EKAlarm()
      let location = EKStructuredLocation(title: title)
      location.geoLocation = CLLocation(latitude: latitude, longitude: longitude)
      location.radius = radius
      alarm.structuredLocation = location
      alarm.proximity = onArrival ? .enter : .leave
      return alarm
    }
  }

  static func alarmValue(from alarm: EKAlarm) -> ReminderAlarmValue? {
    alarmValue(from: ReminderEventKitCodec.alarmRevision(from: alarm))
  }

  static func alarmValue(from revision: ReminderAlarmRevision) -> ReminderAlarmValue? {
    guard revision.typeRawValue == EKAlarmType.display.rawValue,
      revision.emailAddress == nil, revision.soundName == nil, revision.url == nil
    else { return nil }
    if revision.locationTitle != nil || revision.latitude != nil || revision.longitude != nil {
      guard let latitude = revision.latitude, let longitude = revision.longitude,
        let radius = revision.radius,
        revision.proximityRawValue == EKAlarmProximity.enter.rawValue
          || revision.proximityRawValue == EKAlarmProximity.leave.rawValue,
        revision.absoluteDate == nil, revision.relativeOffset == 0
      else { return nil }
      let value = ReminderAlarmValue.location(
        title: revision.locationTitle ?? "",
        latitude: latitude, longitude: longitude, radius: radius,
        onArrival: revision.proximityRawValue == EKAlarmProximity.enter.rawValue)
      guard let encoded = try? alarm(from: value),
        ReminderEventKitCodec.alarmRevision(from: encoded) == revision
      else { return nil }
      return value
    }
    guard revision.proximityRawValue == EKAlarmProximity.none.rawValue else { return nil }
    let value =
      revision.absoluteDate.map(ReminderAlarmValue.absolute)
      ?? .relative(revision.relativeOffset)
    guard let encoded = try? alarm(from: value),
      ReminderEventKitCodec.alarmRevision(from: encoded) == revision
    else { return nil }
    return value
  }

  static func recurrence(from value: ReminderRecurrenceValue) throws -> EKRecurrenceRule {
    func valid(_ values: [Int], limit: Int, signed: Bool = true) -> Bool {
      values.allSatisfy { $0 != 0 && $0 <= limit && $0 >= (signed ? -limit : 1) }
    }
    guard value.interval > 0,
      value.weekdays.allSatisfy({ (1...7).contains($0.day) && (-53...53).contains($0.ordinal) }),
      valid(value.monthDays, limit: 31), valid(value.months, limit: 12, signed: false),
      valid(value.weeks, limit: 53), valid(value.yearDays, limit: 366),
      valid(value.positions, limit: 366),
      value.positions.isEmpty || !value.weekdays.isEmpty || !value.monthDays.isEmpty
        || !value.months.isEmpty || !value.weeks.isEmpty || !value.yearDays.isEmpty
    else { throw invalidRecurrence }
    let end: EKRecurrenceEnd?
    switch value.end {
    case .never: end = nil
    case .date(let date):
      guard date.timeIntervalSinceReferenceDate.isFinite else { throw invalidRecurrence }
      end = EKRecurrenceEnd(end: date)
    case .count(let count):
      guard count > 0 else { throw invalidRecurrence }
      end = EKRecurrenceEnd(occurrenceCount: count)
    }
    func numbers(_ values: [Int]) -> [NSNumber]? {
      values.isEmpty ? nil : values.map { NSNumber(value: $0) }
    }
    let rule = EKRecurrenceRule(
      recurrenceWith: EKRecurrenceFrequency(rawValue: value.frequency.rawValue)!,
      interval: value.interval,
      daysOfTheWeek: value.weekdays.isEmpty
        ? nil
        : value.weekdays.map {
          EKRecurrenceDayOfWeek(EKWeekday(rawValue: $0.day)!, weekNumber: $0.ordinal)
        }, daysOfTheMonth: numbers(value.monthDays), monthsOfTheYear: numbers(value.months),
      weeksOfTheYear: numbers(value.weeks), daysOfTheYear: numbers(value.yearDays),
      setPositions: numbers(value.positions), end: end)
    guard rawValue(from: ReminderEventKitCodec.recurrenceRevision(from: rule)) == value else {
      throw invalidRecurrence
    }
    return rule
  }

  static func recurrenceValue(from rule: EKRecurrenceRule) -> ReminderRecurrenceValue? {
    recurrenceValue(from: ReminderEventKitCodec.recurrenceRevision(from: rule))
  }

  static func recurrenceValue(from revision: ReminderRecurrenceRevision) -> ReminderRecurrenceValue?
  {
    guard let value = rawValue(from: revision), let encoded = try? recurrence(from: value),
      ReminderEventKitCodec.recurrenceRevision(from: encoded) == revision
    else { return nil }
    return value
  }

  private static func rawValue(from revision: ReminderRecurrenceRevision)
    -> ReminderRecurrenceValue?
  {
    guard let frequency = ReminderRecurrenceValue.Frequency(rawValue: revision.frequencyRawValue)
    else { return nil }
    let end: ReminderRecurrenceValue.End
    if let date = revision.endDate {
      end = .date(date)
    } else if let count = revision.occurrenceCount {
      end = .count(count)
    } else {
      end = .never
    }
    return ReminderRecurrenceValue(
      frequency: frequency, interval: revision.interval,
      weekdays: revision.daysOfTheWeek.map {
        .init(day: $0.dayOfTheWeekRawValue, ordinal: $0.weekNumber)
      },
      monthDays: revision.daysOfTheMonth, months: revision.monthsOfTheYear,
      weeks: revision.weeksOfTheYear, yearDays: revision.daysOfTheYear,
      positions: revision.setPositions, end: end)
  }

  /// Keep opaque objects in their original slots while replacing only values we can reproduce.
  static func merging<Object, Value>(
    original: [Object], edited: [Value],
    decode: (Object) -> Value?, encode: (Value) throws -> Object
  ) rethrows -> [Object] {
    var result: [Object] = []
    var next = edited.startIndex
    for object in original {
      if decode(object) == nil {
        result.append(object)
      } else if next < edited.endIndex {
        result.append(try encode(edited[next]))
        next += 1
      }
    }
    for value in edited[next...] { result.append(try encode(value)) }
    return result
  }

  static func sameValues<Value: Equatable>(_ lhs: [Value], _ rhs: [Value]) -> Bool {
    guard lhs.count == rhs.count else { return false }
    var unmatched = rhs
    for value in lhs {
      guard let index = unmatched.firstIndex(of: value) else { return false }
      unmatched.remove(at: index)
    }
    return unmatched.isEmpty
  }

  static let invalidAlarm = ReminderWriteError.eventKit(
    String(
      localized:
        "Enter a valid alert date, offset, or location. Latitude must be between -90 and 90, longitude between -180 and 180, and radius cannot be negative."
    ))
  static let invalidRecurrence = ReminderWriteError.eventKit(
    String(
      localized:
        "Enter a valid repeat interval, selector, and end. This combination must be supported by EventKit."
    ))
}
