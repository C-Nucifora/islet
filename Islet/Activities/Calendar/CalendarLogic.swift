import Foundation

/// A calendar event reduced to what the island needs (keeps EventKit out of unit tests).
struct AgendaEvent: Equatable {
  var title: String
  var start: Date
  var end: Date
  var isAllDay: Bool
  var calendarColorHex: String?
  var joinURL: URL?
}

enum CalendarLogic {
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
