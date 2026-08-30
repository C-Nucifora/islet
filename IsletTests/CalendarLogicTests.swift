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
    XCTAssertEqual(interval.end, calendar.date(byAdding: .day, value: 3, to: interval.start))
  }

  func testThreeDayIntervalUsesDSTCalendarArithmetic() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
    let date = try XCTUnwrap(
      calendar.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 12)))

    let interval = CalendarLogic.agendaInterval(containing: date, calendar: calendar)

    XCTAssertEqual(interval.duration, 71 * 60 * 60)
    XCTAssertEqual(interval.end, calendar.date(byAdding: .day, value: 3, to: interval.start))
  }

  func testAgendaDayGroupingUsesRequestedTimeZone() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Australia/Brisbane"))
    let localNow = try XCTUnwrap(
      calendar.date(from: DateComponents(year: 2026, month: 6, day: 10, hour: 23, minute: 30)))
    let afterMidnight = AgendaEvent(
      title: "Tomorrow", start: localNow.addingTimeInterval(60 * 60),
      end: localNow.addingTimeInterval(2 * 60 * 60), isAllDay: false,
      calendarColorHex: nil, joinURL: nil)

    let days = CalendarLogic.days(events: [afterMidnight], now: localNow, calendar: calendar)

    XCTAssertEqual(days.count, 3)
    XCTAssertTrue(days[0].events.isEmpty)
    XCTAssertEqual(days[1].events.map(\.title), ["Tomorrow"])
  }

  func testMultiDayAndAllDayEventsAppearOnEveryIntersectedDay() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
    let localNow = try XCTUnwrap(
      calendar.date(from: DateComponents(year: 2026, month: 6, day: 10, hour: 8)))
    let startOfToday = calendar.startOfDay(for: localNow)
    let multiDay = AgendaEvent(
      title: "Conference", start: startOfToday,
      end: try XCTUnwrap(calendar.date(byAdding: .day, value: 2, to: startOfToday)),
      isAllDay: true, calendarColorHex: nil, joinURL: nil)

    let days = CalendarLogic.days(events: [multiDay], now: localNow, calendar: calendar)

    XCTAssertEqual(days[0].events.map(\.title), ["Conference"])
    XCTAssertEqual(days[1].events.map(\.title), ["Conference"])
    XCTAssertTrue(days[2].events.isEmpty)
  }

  func testDeletedCalendarFiltersAreRemovedAndRenamesKeepIdentifiers() {
    XCTAssertEqual(
      CalendarLogic.sanitizedHiddenCalendarIDs(
        ["work-id", "deleted-id", "work-id"], availableIDs: ["work-id", "home-id"]),
      ["work-id"])
  }

  func testPermissionChangesClearOnRevokeAndReloadOnGrant() {
    XCTAssertEqual(
      CalendarLogic.accessAction(
        from: .fullAccess, to: .denied, providerEnabled: true),
      .clear)
    XCTAssertEqual(
      CalendarLogic.accessAction(
        from: .denied, to: .fullAccess, providerEnabled: true),
      .reload)
    XCTAssertEqual(
      CalendarLogic.accessAction(
        from: .fullAccess, to: .denied, providerEnabled: false),
      .none)
  }

  func testQuickEventPreparationNormalizesFields() throws {
    let result = CalendarLogic.prepareEvent(
      CalendarEventDraft(
        calendarID: "work", title: "  Planning  ", start: now, end: now + 3600,
        location: "  Room 2  ", conferenceURL: "https://meet.google.com/abc-defg-hij"),
      writableCalendarIDs: ["work"], authorization: .fullAccess)
    let prepared = try result.get()

    XCTAssertEqual(prepared.title, "Planning")
    XCTAssertEqual(prepared.location, "Room 2")
    XCTAssertEqual(prepared.conferenceURL?.host, "meet.google.com")
  }

  func testQuickEventPreparationReportsPermissionAndDestinationFailures() {
    let draft = CalendarEventDraft(
      calendarID: "work", title: "Planning", start: now, end: now + 3600,
      location: "", conferenceURL: "")

    XCTAssertEqual(
      CalendarLogic.prepareEvent(
        draft, writableCalendarIDs: ["work"], authorization: .denied),
      .failure(.permissionRequired))
    XCTAssertEqual(
      CalendarLogic.prepareEvent(
        draft, writableCalendarIDs: ["personal"], authorization: .fullAccess),
      .failure(.calendarUnavailable))
  }

  func testQuickEventPreparationRejectsInvalidInput() {
    let base = CalendarEventDraft(
      calendarID: "work", title: "Planning", start: now, end: now + 3600,
      location: "", conferenceURL: "")

    XCTAssertEqual(
      CalendarLogic.prepareEvent(
        CalendarEventDraft(
          calendarID: base.calendarID, title: "  ", start: base.start, end: base.end,
          location: base.location, conferenceURL: base.conferenceURL),
        writableCalendarIDs: ["work"], authorization: .fullAccess),
      .failure(.titleRequired))
    XCTAssertEqual(
      CalendarLogic.prepareEvent(
        CalendarEventDraft(
          calendarID: base.calendarID, title: base.title, start: base.start, end: base.start,
          location: base.location, conferenceURL: base.conferenceURL),
        writableCalendarIDs: ["work"], authorization: .fullAccess),
      .failure(.invalidTimeRange))
    XCTAssertEqual(
      CalendarLogic.prepareEvent(
        CalendarEventDraft(
          calendarID: base.calendarID, title: base.title, start: base.start, end: base.end,
          location: base.location, conferenceURL: "http://example.com/meeting"),
        writableCalendarIDs: ["work"], authorization: .fullAccess),
      .failure(.invalidConferenceURL))
  }

  func testQuickEventSaveFailureIsReported() throws {
    struct SaveFailure: LocalizedError {
      var errorDescription: String? { "Account is read-only" }
    }
    let prepared = try CalendarLogic.prepareEvent(
      CalendarEventDraft(
        calendarID: "work", title: "Planning", start: now, end: now + 3600,
        location: "", conferenceURL: ""),
      writableCalendarIDs: ["work"], authorization: .fullAccess
    ).get()

    switch CalendarLogic.commitEvent(prepared, save: { _ in throw SaveFailure() }) {
    case .success:
      XCTFail("Expected the save error to be returned")
    case .failure(let error):
      XCTAssertEqual(error, .saveFailed("Account is read-only"))
    }
  }

  func testLeaveNoticeRequiresSavedTravelTimeAndLocation() {
    let base = AgendaEvent(
      title: "Office", start: now + 45 * 60, end: now + 90 * 60, isAllDay: false,
      calendarColorHex: nil, joinURL: nil, location: "Office", travelTime: 30 * 60)

    XCTAssertEqual(
      CalendarLogic.leaveNotice(for: base, now: now), .leaveIn(minutes: 15))
    XCTAssertNil(CalendarLogic.leaveNotice(for: base, now: now, enabled: false))
    var noEstimate = base
    noEstimate.travelTime = nil
    XCTAssertNil(CalendarLogic.leaveNotice(for: noEstimate, now: now))
    var noLocation = base
    noLocation.location = nil
    XCTAssertNil(CalendarLogic.leaveNotice(for: noLocation, now: now))
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
