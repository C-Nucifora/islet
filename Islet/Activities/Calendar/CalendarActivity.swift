import Combine
import Defaults
import EventKit
import SwiftUI

@MainActor
final class CalendarActivity: NotchActivity, ObservableObject {
  let id = "calendar"
  let priority = ActivityPriority.ambient
  private(set) var activationDate: Date?

  @Published private(set) var events: [AgendaEvent] = []
  @Published private(set) var accessDenied = false

  private let store = EKEventStore()
  private var timer: AnyCancellable?
  private var cancellables: Set<AnyCancellable> = []

  var isActive: Bool {
    guard Defaults[.calendarEnabled], let next = nextEvent else { return false }
    return CalendarLogic.shouldCountdown(
      event: next, now: Date(), leadMinutes: Defaults[.calendarLeadMinutes])
  }

  var nextEvent: AgendaEvent? { CalendarLogic.nextRelevant(events: events, now: Date()) }

  func start() {
    if Defaults[.calendarEnabled] { Task { await requestAndLoad() } }
    // Request/refresh when the feature is toggled on; clear when off.
    Defaults.publisher(.calendarEnabled)
      .dropFirst()
      .sink { [weak self] change in
        if change.newValue {
          Task { await self?.requestAndLoad() }
        } else {
          self?.events = []
          self?.objectWillChange.send()
        }
      }
      .store(in: &cancellables)
    // Re-read the agenda and re-evaluate the countdown every 30 s.
    timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()
      .sink { [weak self] _ in
        guard Defaults[.calendarEnabled] else { return }
        Task { await self?.reload() }
        self?.objectWillChange.send()
      }
  }

  private func requestAndLoad() async {
    do {
      let granted = try await store.requestFullAccessToEvents()
      accessDenied = !granted
      if granted { await reload() }
    } catch {
      accessDenied = true
      Log.app.error("Calendar access error: \(error.localizedDescription)")
    }
  }

  private func reload() async {
    guard Defaults[.calendarEnabled], !accessDenied else { return }
    let start = Date()
    let end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start
    let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
    let ekEvents = store.events(matching: predicate)
    let mapped = ekEvents.map { ek in
      AgendaEvent(
        title: ek.title ?? "Untitled",
        start: ek.startDate, end: ek.endDate, isAllDay: ek.isAllDay,
        calendarColorHex: nil,
        joinURL: Self.joinURL(from: ek))
    }
    let wasActive = isActive
    events = mapped.sorted { $0.start < $1.start }
    if !wasActive, isActive { activationDate = Date() }
  }

  /// Pull a video-call link from the event's URL or notes.
  static func joinURL(from event: EKEvent) -> URL? {
    if let url = event.url, Self.isMeetingLink(url) { return url }
    guard let notes = event.notes else { return nil }
    let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    let range = NSRange(notes.startIndex..., in: notes)
    let match = detector?.matches(in: notes, range: range)
      .compactMap(\.url)
      .first(where: Self.isMeetingLink)
    return match
  }

  static func isMeetingLink(_ url: URL) -> Bool {
    let host = url.host?.lowercased() ?? ""
    return ["zoom.us", "meet.google.com", "teams.microsoft.com", "webex.com"]
      .contains { host.contains($0) }
  }

  let tabIcon = "calendar"
  var compactLeading: AnyView {
    AnyView(Image(systemName: "calendar").foregroundStyle(.orange).font(.caption2))
  }

  var compactTrailing: AnyView {
    AnyView(CalendarCountdownView(activity: self))
  }

  var expandedView: AnyView { AnyView(CalendarAgendaView(activity: self)) }
}

struct CalendarCountdownView: View {
  @ObservedObject var activity: CalendarActivity

  var body: some View {
    TimelineView(.periodic(from: .now, by: 10)) { context in
      if let next = activity.nextEvent {
        Text(CalendarLogic.countdownText(to: next.start, now: context.date))
          .font(.caption.weight(.semibold)).monospacedDigit()
          .foregroundStyle(.orange)
      }
    }
  }
}

struct CalendarAgendaView: View {
  @ObservedObject var activity: CalendarActivity

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Today").font(.headline).foregroundStyle(.white)
      if activity.events.isEmpty {
        Text("No more events today").font(.callout).foregroundStyle(.secondary)
      } else {
        ForEach(Array(activity.events.prefix(4).enumerated()), id: \.offset) { _, event in
          HStack(spacing: 8) {
            Text(event.start, format: .dateTime.hour().minute())
              .font(.caption).monospacedDigit().foregroundStyle(.secondary)
              .frame(width: 52, alignment: .leading)
            Text(event.title).font(.callout).foregroundStyle(.white).lineLimit(1)
            Spacer()
            if let url = event.joinURL {
              Button {
                NSWorkspace.shared.open(url)
              } label: {
                Image(systemName: "video.fill").foregroundStyle(.green)
              }
              .buttonStyle(.plain)
            }
          }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
