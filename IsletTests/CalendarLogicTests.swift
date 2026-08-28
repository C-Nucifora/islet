import XCTest

@testable import Islet

final class CalendarLogicTests: XCTestCase {
  let now = Date(timeIntervalSince1970: 1_000_000)

  func event(
    _ title: String, startOffset: TimeInterval, duration: TimeInterval = 3600,
    allDay: Bool = false
  ) -> AgendaEvent {
    AgendaEvent(
      title: title, start: now.addingTimeInterval(startOffset),
      end: now.addingTimeInterval(startOffset + duration), isAllDay: allDay,
      calendarColorHex: nil, joinURL: nil)
  }

  func testNextRelevantPicksSoonestUpcomingTimed() {
    let events = [
      event("later", startOffset: 7200),
      event("soon", startOffset: 600),
      event("allday", startOffset: 300, allDay: true),
      event("past", startOffset: -7200),
    ]
    XCTAssertEqual(CalendarLogic.nextRelevant(events: events, now: now)?.title, "soon")
  }

  func testInProgressEventStillCounts() {
    // started 10 min ago, ends in 50 min → still the "next relevant" if nothing sooner
    let events = [event("ongoing", startOffset: -600, duration: 3600)]
    XCTAssertEqual(CalendarLogic.nextRelevant(events: events, now: now)?.title, "ongoing")
  }

  func testShouldCountdownWithinLead() {
    let e = event("m", startOffset: 8 * 60)
    XCTAssertTrue(CalendarLogic.shouldCountdown(event: e, now: now, leadMinutes: 10))
  }

  func testShouldNotCountdownBeyondLead() {
    let e = event("m", startOffset: 20 * 60)
    XCTAssertFalse(CalendarLogic.shouldCountdown(event: e, now: now, leadMinutes: 10))
  }

  func testShouldNotCountdownAfterStart() {
    let e = event("m", startOffset: -60)
    XCTAssertFalse(CalendarLogic.shouldCountdown(event: e, now: now, leadMinutes: 10))
  }

  func testCountdownCanBeDisabled() {
    let e = event("m", startOffset: 60)
    XCTAssertFalse(CalendarLogic.shouldCountdown(event: e, now: now, leadMinutes: 0))
  }

  func testCountdownText() {
    XCTAssertEqual(CalendarLogic.countdownText(to: now.addingTimeInterval(480), now: now), "8m")
    XCTAssertEqual(CalendarLogic.countdownText(to: now.addingTimeInterval(3000), now: now), "50m")
    XCTAssertEqual(CalendarLogic.countdownText(to: now.addingTimeInterval(3600), now: now), "1h")
    XCTAssertEqual(CalendarLogic.countdownText(to: now.addingTimeInterval(7200), now: now), "2h")
    XCTAssertEqual(CalendarLogic.countdownText(to: now.addingTimeInterval(-5), now: now), "now")
  }

  func testAgendaIntervalUsesCalendarDayBoundary() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Australia/Brisbane"))
    let interval = CalendarLogic.agendaInterval(containing: now, calendar: calendar)
    XCTAssertEqual(interval.start, calendar.startOfDay(for: now))
    XCTAssertEqual(interval.end, calendar.date(byAdding: .day, value: 1, to: interval.start))
  }

  func testDisplayDropsEndedEventsAndOrdersAllDayFirst() {
    let interval = DateInterval(start: now.addingTimeInterval(-3600), duration: 86_400)
    let events = [
      event("future", startOffset: 600),
      event("ended", startOffset: -1800, duration: 60),
      event("all-day", startOffset: -3600, duration: 86_400, allDay: true),
    ]
    XCTAssertEqual(
      CalendarLogic.display(events: events, now: now, interval: interval).map(\.title),
      ["all-day", "future"])
  }

  func testMeetingLinksRecognizeGenericCorporateJoinRoutes() throws {
    XCTAssertTrue(
      CalendarActivity.isMeetingLink(
        try XCTUnwrap(URL(string: "https://collab.example.org/meeting/team-sync"))))
    XCTAssertTrue(
      CalendarActivity.isMeetingLink(
        try XCTUnwrap(URL(string: "https://video.example.org/r/opaque-token"))))
    XCTAssertTrue(
      CalendarActivity.isMeetingLink(
        try XCTUnwrap(URL(string: "facetime://person@example.com"))))
  }

  func testMeetingLinksRejectOrdinaryAndSpoofedWebLinks() throws {
    XCTAssertFalse(
      CalendarActivity.isMeetingLink(
        try XCTUnwrap(URL(string: "https://example.org/project/status"))))
    XCTAssertFalse(
      CalendarActivity.isMeetingLink(
        try XCTUnwrap(URL(string: "https://zoom.us.attacker.example/path"))))
    XCTAssertFalse(
      CalendarActivity.isMeetingLink(
        try XCTUnwrap(URL(string: "javascript:alert(1)"))))
    XCTAssertFalse(
      CalendarActivity.isMeetingLink(
        try XCTUnwrap(URL(string: "http://meet.example.org/join/123"))))
  }
}
