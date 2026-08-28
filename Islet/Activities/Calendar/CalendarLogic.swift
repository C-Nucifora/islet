import Foundation

/// A calendar event reduced to what the island needs (keeps EventKit out of unit tests).
struct AgendaEvent: Identifiable, Equatable, Sendable {
  let id: String
  var title: String
  var start: Date
  var end: Date
  var isAllDay: Bool
  var calendarColorHex: String?
  var joinURL: URL?

  init(
    id: String = UUID().uuidString, title: String, start: Date, end: Date, isAllDay: Bool,
    calendarColorHex: String?, joinURL: URL?
  ) {
    self.id = id
    self.title = title
    self.start = start
    self.end = end
    self.isAllDay = isAllDay
    self.calendarColorHex = calendarColorHex
    self.joinURL = joinURL
  }
}

enum CalendarLogic {
  /// The local-day range rendered by the dashboard. Using calendar boundaries avoids the old
  /// `now + 24 hours` query leaking tomorrow's morning events into a view labelled "Today" (and
  /// remains correct across daylight-saving transitions).
  static func agendaInterval(containing date: Date, calendar: Calendar = .current) -> DateInterval {
    let start = calendar.startOfDay(for: date)
    let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
    return DateInterval(start: start, end: end)
  }

  /// Removes events that have already ended while retaining all-day events for the current day.
  /// EventKit's predicate returns every event intersecting the requested interval, including old
  /// meetings from earlier today, which are not useful in the compact agenda.
  static func display(
    events: [AgendaEvent], now: Date, interval: DateInterval
  ) -> [AgendaEvent] {
    events
      .filter { event in
        event.start < interval.end && event.end > interval.start
          && (event.isAllDay || event.end > now)
      }
      .sorted {
        if $0.isAllDay != $1.isAllDay { return $0.isAllDay }
        if $0.start != $1.start { return $0.start < $1.start }
        return $0.title.localizedStandardCompare($1.title) == .orderedAscending
      }
  }

  /// The next event worth a countdown: soonest upcoming, timed (not all-day), not yet ended.
  static func nextRelevant(events: [AgendaEvent], now: Date) -> AgendaEvent? {
    events
      .filter { !$0.isAllDay && $0.end > now }
      .min { $0.start < $1.start }
  }

  /// Whether a countdown should show yet: event starts within `leadMinutes` (and hasn't started).
  static func shouldCountdown(event: AgendaEvent, now: Date, leadMinutes: Int) -> Bool {
    let secondsUntil = event.start.timeIntervalSince(now)
    return secondsUntil > 0 && secondsUntil <= Double(leadMinutes) * 60
  }

  /// Short countdown label, e.g. "8m", "1h", or "now".
  static func countdownText(to start: Date, now: Date) -> String {
    let seconds = Int(start.timeIntervalSince(now))
    if seconds <= 0 { return "now" }
    let minutes = (seconds + 59) / 60
    if minutes < 60 { return "\(minutes)m" }
    let hours = minutes / 60
    return "\(hours)h"
  }
}
