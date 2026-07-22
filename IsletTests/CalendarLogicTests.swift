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

  func testCountdownText() {
    XCTAssertEqual(CalendarLogic.countdownText(to: now.addingTimeInterval(480), now: now), "8m")
    XCTAssertEqual(CalendarLogic.countdownText(to: now.addingTimeInterval(3000), now: now), "50m")
    XCTAssertEqual(CalendarLogic.countdownText(to: now.addingTimeInterval(3600), now: now), "1h")
    XCTAssertEqual(CalendarLogic.countdownText(to: now.addingTimeInterval(7200), now: now), "2h")
    XCTAssertEqual(CalendarLogic.countdownText(to: now.addingTimeInterval(-5), now: now), "now")
  }
}
