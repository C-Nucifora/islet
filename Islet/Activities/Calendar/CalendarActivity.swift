import AppKit
import Combine
import Defaults
import EventKit
import SwiftUI

struct CalendarChoice: Identifiable, Equatable, Sendable {
  let id: String
  let title: String
  let colorHex: String?
}

@MainActor
final class CalendarActivity: NotchActivity, ObservableObject {
  enum LoadState: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)
  }

  let id = "calendar"
  let priority = ActivityPriority.ambient
  private(set) var activationDate: Date?

  @Published private(set) var events: [AgendaEvent] = []
  @Published private(set) var authorization = EventKitPermissionState(
    EKEventStore.authorizationStatus(for: .event))
  @Published private(set) var loadState: LoadState = .idle
  @Published private(set) var availableCalendars: [CalendarChoice] = []

  /// Compatibility for existing views. New permission UI should render `authorization` so denied,
  /// restricted, write-only, and not-yet-requested states are not conflated.
  var accessDenied: Bool { !authorization.canRead }

  private let store = EKEventStore()
  private var timer: AnyCancellable?
  private var cancellables: Set<AnyCancellable> = []
  private var isRunning = false
  private var lastReloadDate: Date?
  private var reloadGeneration = 0

  var isActive: Bool {
    guard Defaults[.calendarEnabled], let next = nextEvent else { return false }
    return CalendarLogic.shouldCountdown(
      event: next, now: Date(), leadMinutes: Defaults[.calendarLeadMinutes])
  }

  var nextEvent: AgendaEvent? { CalendarLogic.nextRelevant(events: events, now: Date()) }

  func start() {
    guard !isRunning else { return }
    isRunning = true
    if Defaults[.calendarEnabled] { Task { await refreshAuthorization() } }
    // Request/refresh when the feature is toggled on; clear when off.
    Defaults.publisher(.calendarEnabled)
      .dropFirst()
      .sink { [weak self] change in
        if change.newValue {
          Task { await self?.refreshAuthorization() }
        } else {
          self?.events = []
          self?.availableCalendars = []
          self?.loadState = .idle
          self?.activationDate = nil
          self?.objectWillChange.send()
        }
      }
      .store(in: &cancellables)
    Defaults.publisher(.hiddenCalendarIDs)
      .dropFirst()
      .sink { [weak self] _ in Task { await self?.reload() } }
      .store(in: &cancellables)
    // A grant made in System Settings happens out of process. Refresh as soon as the user returns
    // so the dashboard does not keep showing stale "Calendar access off" state.
    NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
      .sink { [weak self] _ in Task { await self?.refreshAuthorization() } }
      .store(in: &cancellables)
    NotificationCenter.default.publisher(for: .EKEventStoreChanged)
      .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
      .sink { [weak self] _ in Task { await self?.refreshAuthorization() } }
      .store(in: &cancellables)
    // Re-evaluate the countdown every 30 s, but only query EventKit every five minutes. Store
    // change and app-activation notifications still trigger immediate refreshes.
    timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()
      .sink { [weak self] _ in
        guard let self, Defaults[.calendarEnabled] else { return }
        if self.lastReloadDate.map({ Date().timeIntervalSince($0) >= 300 }) ?? true {
          Task { await self.reload() }
        }
        self.objectWillChange.send()
      }
  }

  func stop() {
    guard isRunning else { return }
    isRunning = false
    reloadGeneration += 1
    timer = nil
    cancellables.removeAll()
    events = []
    availableCalendars = []
    loadState = .idle
    activationDate = nil
    lastReloadDate = nil
  }

  func requestAccess() async {
    authorization = EventKitPermissionState(EKEventStore.authorizationStatus(for: .event))
    if authorization.canRead {
      if isRunning, Defaults[.calendarEnabled] { await reload() }
      return
    }
    events = []
    // TCC prompts exactly once. Calling the request API again after denial is a dead end, so leave
    // recovery to `recoverAccess()` rather than pretending another prompt can appear.
    guard authorization == .notDetermined else { return }
    do {
      let granted = try await store.requestFullAccessToEvents()
      authorization = EventKitPermissionState(EKEventStore.authorizationStatus(for: .event))
      if granted, authorization.canRead, isRunning, Defaults[.calendarEnabled] { await reload() }
    } catch {
      authorization = EventKitPermissionState(EKEventStore.authorizationStatus(for: .event))
      loadState = .failed(error.localizedDescription)
      Log.app.error("Calendar access error: \(error.localizedDescription)")
    }
  }

  /// Action for permission UI: prompts only when TCC has not decided, otherwise opens the exact
  /// Settings pane where an existing denial or stale app identity can be repaired.
  func recoverAccess() async {
    await refreshAuthorization()
    if authorization == .notDetermined {
      await requestAccess()
    } else if authorization.requiresSettingsRecovery {
      SystemSettingsPrivacyPane.calendars.open()
    }
  }

  func openCalendarPrivacySettings() {
    SystemSettingsPrivacyPane.calendars.open()
  }

  func refreshAuthorization() async {
    authorization = EventKitPermissionState(EKEventStore.authorizationStatus(for: .event))
    if authorization.canRead, isRunning, Defaults[.calendarEnabled] {
      await reload()
    } else if isRunning {
      events = []
      availableCalendars = []
      loadState = .idle
    }
  }

  private func reload() async {
    guard isRunning, Defaults[.calendarEnabled] else { return }
    // Re-check authorization every reload so a mid-session revoke flips to "access off" (and a
    // re-grant recovers), instead of silently showing an empty agenda.
    authorization = EventKitPermissionState(EKEventStore.authorizationStatus(for: .event))
    guard authorization.canRead else {
      events = []
      availableCalendars = []
      loadState = .idle
      return
    }
    availableCalendars = store.calendars(for: .event)
      .map {
        CalendarChoice(
          id: $0.calendarIdentifier, title: $0.title,
          colorHex: ColorHex.string(from: $0.cgColor))
      }
      .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    loadState = .loading
    reloadGeneration += 1
    let generation = reloadGeneration
    let now = Date()
    let interval = CalendarLogic.agendaInterval(containing: now)
    let hiddenCalendarIDs = Set(Defaults[.hiddenCalendarIDs])
    let mapped = await Task.detached(priority: .utility) {
      Self.queryEvents(in: interval, hiddenCalendarIDs: hiddenCalendarIDs)
    }.value
    guard generation == reloadGeneration, isRunning, Defaults[.calendarEnabled] else { return }
    let wasActive = isActive
    events = CalendarLogic.display(events: mapped, now: now, interval: interval)
    lastReloadDate = now
    loadState = .loaded
    if !wasActive, isActive { activationDate = Date() }
    if wasActive, !isActive { activationDate = nil }
  }

  /// EventKit's synchronous event query can traverse a large database. A dedicated store is created
  /// and reduced entirely on a utility executor so no EKEvent crosses actors and island animation
  /// never waits on the query.
  nonisolated private static func queryEvents(
    in interval: DateInterval, hiddenCalendarIDs: Set<String>
  ) -> [AgendaEvent] {
    let store = EKEventStore()
    let calendars = store.calendars(for: .event).filter {
      !hiddenCalendarIDs.contains($0.calendarIdentifier)
    }
    guard !calendars.isEmpty else { return [] }
    let predicate = store.predicateForEvents(
      withStart: interval.start, end: interval.end, calendars: calendars)
    return store.events(matching: predicate).map { event in
      AgendaEvent(
        id: "\(event.calendarItemIdentifier)|\(event.startDate.timeIntervalSinceReferenceDate)",
        title: event.title ?? "Untitled",
        start: event.startDate, end: event.endDate, isAllDay: event.isAllDay,
        calendarColorHex: ColorHex.string(from: event.calendar?.cgColor),
        joinURL: joinURL(from: event))
    }
  }

  /// Pull a video-call link from the event's URL or notes.
  nonisolated static func joinURL(from event: EKEvent) -> URL? {
    if let url = event.url, Self.isMeetingLink(url) { return url }
    let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    for text in [event.location, event.structuredLocation?.title, event.notes].compactMap({ $0 }) {
      let range = NSRange(text.startIndex..., in: text)
      if let match = detector?.matches(in: text, range: range)
        .compactMap(\.url)
        .first(where: Self.isMeetingLink)
      {
        return match
      }
    }
    return nil
  }

  nonisolated static func isMeetingLink(_ url: URL) -> Bool {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      let scheme = components.scheme?.lowercased()
    else { return false }

    // Native call links are useful join targets and do not pass through a browser.
    if ["facetime", "facetime-audio"].contains(scheme) { return true }
    guard scheme == "https", components.user == nil,
      components.password == nil, let host = components.host?.lowercased(), !host.isEmpty
    else { return false }

    // Keep known services for links whose paths are opaque, but match at DNS-label boundaries so
    // a hostname such as `zoom.us.attacker.example` is never accepted.
    let knownDomains = [
      "zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com",
      "webex.com", "whereby.com", "around.co", "meet.jit.si", "chime.aws",
    ]
    if knownDomains.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return true }

    // Corporate and new providers should work without an app release. Prefer semantic host/path
    // and query markers rather than an ever-growing provider allow-list.
    let markers: Set<String> = [
      "call", "calls", "conference", "join", "meet", "meeting", "meetings", "room",
      "video", "videocall", "webinar",
    ]
    if !Set(host.split(separator: ".").map(String.init)).isDisjoint(with: markers) { return true }

    let pathMarkers = Set(
      components.path.split(separator: "/").map {
        $0.lowercased().replacingOccurrences(of: "-", with: "")
      })
    if !pathMarkers.isDisjoint(with: markers) { return true }

    let queryMarkers: Set<String> = [
      "callid", "conferenceid", "confno", "meetingid", "roomid", "webinarid",
    ]
    return components.queryItems?.contains {
      queryMarkers.contains(
        $0.name.lowercased()
          .replacingOccurrences(of: "_", with: "")
          .replacingOccurrences(of: "-", with: ""))
    } == true
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
        ForEach(activity.events.prefix(4)) { event in
          HStack(spacing: 8) {
            if event.isAllDay {
              Text("All day")
                .font(.caption).foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
            } else {
              Text(event.start, format: .dateTime.hour().minute())
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
            }
            Text(event.title).font(.callout).foregroundStyle(.white).lineLimit(1)
            Spacer()
            if let url = event.joinURL {
              Button {
                NSWorkspace.shared.open(url)
              } label: {
                Image(systemName: "video.fill").foregroundStyle(.green)
              }
              .buttonStyle(.plain)
              .help("Join \(event.title)")
              .accessibilityLabel("Join \(event.title)")
            }
          }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
