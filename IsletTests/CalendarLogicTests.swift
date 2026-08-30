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

  func testKnownProviderLinksOpenWithoutConfirmation() throws {
    let links = [
      "https://zoom.us/j/123456789",
      "https://meet.google.com/abc-defg-hij",
      "https://company.webex.com/meet/person",
      "https://8x8.vc/company/team-room",
    ]

    for value in links {
      let url = try XCTUnwrap(URL(string: value))
      let candidate = try XCTUnwrap(CalendarMeetingLinkPolicy.candidate(url))
      XCTAssertFalse(candidate.trust.requiresConfirmation)
    }
  }

  func testKnownProviderMatchingRejectsDeceptiveDomains() throws {
    let deceptive = [
      "https://zoom.us.attacker.example/j/123",
      "https://notzoom.us/j/123",
      "https://teams.microsoft.com.attacker.example/l/meetup-join/123",
      "https://meet.google.com.attacker.example/abc-defg-hij",
      "https://video.zoom.us.attacker.example/room/123",
    ]

    for value in deceptive {
      let url = try XCTUnwrap(URL(string: value))
      XCTAssertNil(CalendarMeetingLinkPolicy.candidate(url))
    }
  }

  func testPathOnlyMeetingMarkersAreNotCandidates() throws {
    let pathOnly = [
      "https://example.org/meeting/team-sync",
      "https://example.org/join/123",
      "https://example.org/project?meeting_id=123",
    ]

    for value in pathOnly {
      let url = try XCTUnwrap(URL(string: value))
      XCTAssertNil(CalendarMeetingLinkPolicy.candidate(url))
    }
  }

  func testCredentialBearingWebLinksAreRejected() throws {
    let links = [
      "https://person@zoom.us/j/123",
      "https://person:secret@meet.example.org/opaque",
      "facetime://person:secret@example.com",
    ]

    for value in links {
      let url = try XCTUnwrap(URL(string: value))
      XCTAssertNil(CalendarMeetingLinkPolicy.candidate(url))
    }
  }

  func testEnterpriseMeetingHostRequiresConfirmation() throws {
    let url = try XCTUnwrap(URL(string: "https://video.corp.example/r/opaque-token"))
    let candidate = try XCTUnwrap(CalendarMeetingLinkPolicy.candidate(url))

    XCTAssertEqual(candidate.trust, .unrecognized(host: "video.corp.example"))
    XCTAssertTrue(candidate.trust.requiresConfirmation)
  }

  func testStructuredEventURLIsPreferredAndRequiresConfirmationWhenUnknown() throws {
    let structured = try XCTUnwrap(URL(string: "https://video.corp.example/session/opaque"))
    let knownProvider = try XCTUnwrap(URL(string: "https://zoom.us/j/123"))

    XCTAssertEqual(
      CalendarActivity.selectJoinURL(
        structuredURL: structured, detectedURLs: [knownProvider]),
      structured)
    XCTAssertEqual(
      CalendarMeetingLinkPolicy.candidate(structured)?.trust,
      .unrecognized(host: "video.corp.example"))
  }

  func testFaceTimeLinksRemainDirectNativeCalls() throws {
    let url = try XCTUnwrap(URL(string: "facetime://person@example.com"))
    let candidate = try XCTUnwrap(CalendarMeetingLinkPolicy.candidate(url))

    XCTAssertEqual(candidate.trust, .nativeCall)
    XCTAssertFalse(candidate.trust.requiresConfirmation)
  }

  func testUnsupportedAndInsecureSchemesAreRejected() throws {
    let links = [
      "https://example.org/project/status",
      "javascript:alert(1)",
      "http://meet.example.org/join/123",
    ]

    for value in links {
      let url = try XCTUnwrap(URL(string: value))
      XCTAssertNil(CalendarMeetingLinkPolicy.candidate(url))
    }
  }
}
