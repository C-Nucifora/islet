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
  var location: String?

  init(
    id: String = UUID().uuidString, title: String, start: Date, end: Date, isAllDay: Bool,
    calendarColorHex: String?, joinURL: URL?, location: String? = nil
  ) {
    self.id = id
    self.title = title
    self.start = start
    self.end = end
    self.isAllDay = isAllDay
    self.calendarColorHex = calendarColorHex
    self.joinURL = joinURL
    self.location = location
  }
}

struct CalendarDayAgenda: Identifiable, Equatable, Sendable {
  let date: Date
  let events: [AgendaEvent]

  var id: Date { date }
}

struct CalendarEventDraft: Equatable, Sendable {
  var calendarID: String
  var title: String
  var start: Date
  var end: Date
  var location: String
  var conferenceURL: String
}

struct PreparedCalendarEvent: Equatable, Sendable {
  let calendarID: String
  let title: String
  let start: Date
  let end: Date
  let location: String?
  let conferenceURL: URL?
}

enum CalendarCreationError: Error, Equatable, Sendable {
  case permissionRequired
  case calendarUnavailable
  case titleRequired
  case invalidTimeRange
  case invalidConferenceURL
  case saveFailed(String)

  var message: String {
    switch self {
    case .permissionRequired: "Calendar access is required to add an event."
    case .calendarUnavailable: "That calendar is no longer available for new events."
    case .titleRequired: "Enter an event title."
    case .invalidTimeRange: "The event must end after it starts."
    case .invalidConferenceURL: "Enter a secure conference link, such as https://meet.example.com."
    case .saveFailed(let detail): "The event could not be saved. \(detail)"
    }
  }
}

enum CalendarAccessAction: Equatable, Sendable {
  case reload
  case clear
  case none
}

enum CalendarLogic {
  static let agendaDayCount = 3

  /// The local-day range rendered by the agenda. Calendar arithmetic matters here because three
  /// local days can contain 71 or 73 hours around daylight-saving changes.
  static func agendaInterval(
    containing date: Date, days: Int = agendaDayCount, calendar: Calendar = .current
  ) -> DateInterval {
    let start = calendar.startOfDay(for: date)
    let end = calendar.date(byAdding: .day, value: max(days, 1), to: start) ?? start
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

  static func days(
    events: [AgendaEvent], now: Date, calendar: Calendar = .current, includeEmpty: Bool = true
  ) -> [CalendarDayAgenda] {
    let interval = agendaInterval(containing: now, calendar: calendar)
    let visible = display(events: events, now: now, interval: interval)
    return (0..<agendaDayCount).compactMap { offset in
      guard let date = calendar.date(byAdding: .day, value: offset, to: interval.start),
        let end = calendar.date(byAdding: .day, value: 1, to: date)
      else { return nil }
      let dayEvents = visible.filter { $0.start < end && $0.end > date }
      guard includeEmpty || !dayEvents.isEmpty else { return nil }
      return CalendarDayAgenda(date: date, events: dayEvents)
    }
  }

  static func sanitizedHiddenCalendarIDs(
    _ hiddenIDs: [String], availableIDs: Set<String>
  ) -> [String] {
    var seen: Set<String> = []
    return hiddenIDs.filter { availableIDs.contains($0) && seen.insert($0).inserted }
  }

  static func accessAction(
    from oldValue: EventKitPermissionState, to newValue: EventKitPermissionState,
    providerEnabled: Bool
  ) -> CalendarAccessAction {
    guard providerEnabled else { return .none }
    if newValue.canRead { return .reload }
    if oldValue.canRead || !newValue.canRead { return .clear }
    return .none
  }

  static func prepareEvent(
    _ draft: CalendarEventDraft, writableCalendarIDs: Set<String>,
    authorization: EventKitPermissionState
  ) -> Result<PreparedCalendarEvent, CalendarCreationError> {
    guard authorization.canRead else { return .failure(.permissionRequired) }
    guard writableCalendarIDs.contains(draft.calendarID) else {
      return .failure(.calendarUnavailable)
    }
    let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else { return .failure(.titleRequired) }
    guard draft.end > draft.start else { return .failure(.invalidTimeRange) }
    let location = draft.location.trimmingCharacters(in: .whitespacesAndNewlines)
    let conferenceText = draft.conferenceURL.trimmingCharacters(in: .whitespacesAndNewlines)
    let conferenceURL: URL?
    if conferenceText.isEmpty {
      conferenceURL = nil
    } else {
      guard let components = URLComponents(string: conferenceText),
        components.scheme?.lowercased() == "https", components.user == nil,
        components.password == nil, components.host?.isEmpty == false,
        let parsed = components.url
      else { return .failure(.invalidConferenceURL) }
      conferenceURL = parsed
    }
    return .success(
      PreparedCalendarEvent(
        calendarID: draft.calendarID, title: title, start: draft.start, end: draft.end,
        location: location.isEmpty ? nil : location, conferenceURL: conferenceURL))
  }

  static func commitEvent(
    _ event: PreparedCalendarEvent,
    save: (PreparedCalendarEvent) throws -> Void
  ) -> Result<Void, CalendarCreationError> {
    do {
      try save(event)
      return .success(())
    } catch {
      return .failure(.saveFailed(error.localizedDescription))
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
    guard leadMinutes > 0 else { return false }
    let secondsUntil = event.start.timeIntervalSince(now)
    return secondsUntil > 0 && secondsUntil <= Double(leadMinutes) * 60
  }

  /// Short countdown label, e.g. "8m", "1h", or "now".
  static func countdownText(to start: Date, now: Date) -> String {
    let seconds = Int(start.timeIntervalSince(now))
    if seconds <= 0 { return String(localized: "now") }
    let minutes = (seconds + 59) / 60
    if minutes < 60 { return String(localized: "\(LocalizedFormat.integer(minutes))m") }
    let hours = minutes / 60
    return String(localized: "\(LocalizedFormat.integer(hours))h")
  }
}
