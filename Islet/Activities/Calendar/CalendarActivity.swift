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

enum CalendarMeetingLinkTrust: Equatable, Sendable {
  case nativeCall
  case knownProvider(host: String)
  case unrecognized(host: String)

  var requiresConfirmation: Bool {
    if case .unrecognized = self { return true }
    return false
  }

  var destinationHost: String? {
    switch self {
    case .nativeCall: return nil
    case .knownProvider(let host), .unrecognized(let host): return host
    }
  }
}

struct CalendarMeetingLink: Equatable, Sendable {
  let url: URL
  let trust: CalendarMeetingLinkTrust
}

enum CalendarMeetingLinkPolicy {
  /// Add providers here only when the registrable domain is controlled by the meeting service.
  /// Matching happens at a DNS-label boundary, so provider names inside an attacker's domain do
  /// not inherit trust.
  static let knownProviderDomains: Set<String> = [
    "8x8.vc",
    "chime.aws",
    "meet.google.com",
    "meet.jit.si",
    "teams.live.com",
    "teams.microsoft.com",
    "webex.com",
    "whereby.com",
    "zoom.us",
  ]

  /// A custom provider must identify itself in a complete hostname label. A path such as
  /// `/meeting/notes` is not enough because event URLs, locations, and notes can all contain links
  /// unrelated to a call.
  private static let enterpriseHostLabels: Set<String> = [
    "call", "calls", "conference", "meet", "meeting", "meetings", "video", "webinar",
  ]

  static func candidate(_ url: URL) -> CalendarMeetingLink? {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      let scheme = components.scheme?.lowercased()
    else { return nil }

    if ["facetime", "facetime-audio"].contains(scheme) {
      guard components.password == nil,
        components.user != nil || components.host != nil || !components.path.isEmpty
      else { return nil }
      return CalendarMeetingLink(url: url, trust: .nativeCall)
    }

    guard scheme == "https", components.user == nil, components.password == nil,
      let host = components.host?.lowercased(), !host.isEmpty
    else { return nil }

    if knownProviderDomains.contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
      return CalendarMeetingLink(url: url, trust: .knownProvider(host: host))
    }
    // Do not downgrade a provider-shaped lookalike into a generic candidate. A host such as
    // `meet.google.com.attacker.example` should disappear rather than borrow Google's name in a
    // confirmation prompt.
    if knownProviderDomains.contains(where: { containsDomainLabels($0, in: host) }) { return nil }

    let hostLabels = Set(host.split(separator: ".").map(String.init))
    guard !hostLabels.isDisjoint(with: enterpriseHostLabels) else { return nil }

    return CalendarMeetingLink(url: url, trust: .unrecognized(host: host))
  }

  private static func containsDomainLabels(_ domain: String, in host: String) -> Bool {
    let hostLabels = host.split(separator: ".")
    let domainLabels = domain.split(separator: ".")
    guard hostLabels.count >= domainLabels.count else { return false }
    return (0...(hostLabels.count - domainLabels.count)).contains { start in
      hostLabels[start..<(start + domainLabels.count)].elementsEqual(domainLabels)
    }
  }
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

  /// Today's agenda remains reachable from Home even before the compact countdown window begins.
  var isAvailableWhenInactive: Bool { Defaults[.calendarEnabled] }

  var nextEvent: AgendaEvent? { CalendarLogic.nextRelevant(events: events, now: Date()) }

  func start() {
    guard !isRunning else { return }
    isRunning = true
    if Defaults[.calendarEnabled] { Task { await refreshAuthorization() } }
    // Request/refresh when the feature is toggled on; clear when off.
    Defaults.publisher(.calendarEnabled)
      .dropFirst()
      .receive(on: DispatchQueue.main)
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
      .receive(on: DispatchQueue.main)
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

  /// Pull a video-call link from the event's dedicated URL or unstructured text. EventKit's URL
  /// field wins even when a known provider also appears in the notes.
  nonisolated static func joinURL(from event: EKEvent) -> URL? {
    let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    var detectedURLs: [URL] = []
    for text in [event.location, event.structuredLocation?.title, event.notes].compactMap({ $0 }) {
      let range = NSRange(text.startIndex..., in: text)
      detectedURLs.append(
        contentsOf: detector?.matches(in: text, range: range).compactMap(\.url) ?? [])
    }
    return selectJoinURL(structuredURL: event.url, detectedURLs: detectedURLs)
  }

  nonisolated static func selectJoinURL(
    structuredURL: URL?, detectedURLs: [URL]
  ) -> URL? {
    if let structuredURL, CalendarMeetingLinkPolicy.candidate(structuredURL) != nil {
      return structuredURL
    }
    return detectedURLs.first { CalendarMeetingLinkPolicy.candidate($0) != nil }
  }

  nonisolated static func isMeetingLink(_ url: URL) -> Bool {
    CalendarMeetingLinkPolicy.candidate(url) != nil
  }

  let tabIcon = "calendar"
  var compactLeading: AnyView {
    AnyView(Image(systemName: "calendar").appThemeForeground(.calendar).font(.caption2))
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
          .appThemeForeground(.calendar)
      }
    }
  }
}

struct CalendarAgendaView: View {
  @ObservedObject var activity: CalendarActivity

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Today").font(.headline).appThemeForeground(.calendar)
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
            if let url = event.joinURL, let link = CalendarMeetingLinkPolicy.candidate(url) {
              CalendarMeetingLinkButton(link: link, eventTitle: event.title)
            }
          }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

enum CalendarMeetingLinkPresentation {
  static func activate(_ link: CalendarMeetingLink, requestConfirmation: () -> Void) {
    if link.trust.requiresConfirmation {
      requestConfirmation()
    } else {
      NSWorkspace.shared.open(link.url)
    }
  }
}

private struct CalendarMeetingLinkConfirmationModifier: ViewModifier {
  let link: CalendarMeetingLink
  @Binding var isPresented: Bool

  func body(content: Content) -> some View {
    content.confirmationDialog(
      confirmationTitle,
      isPresented: $isPresented,
      titleVisibility: .visible
    ) {
      if let host = link.trust.destinationHost {
        Button("Open \(host)") { NSWorkspace.shared.open(link.url) }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      if let host = link.trust.destinationHost {
        Text(
          "Islet does not recognize \(host) as a meeting provider. Check the address before opening it."
        )
      }
    }
  }

  private var confirmationTitle: String {
    guard let host = link.trust.destinationHost else { return "Open meeting link?" }
    return "Open \(host)?"
  }
}

extension View {
  func calendarMeetingLinkConfirmation(
    link: CalendarMeetingLink, isPresented: Binding<Bool>
  ) -> some View {
    modifier(
      CalendarMeetingLinkConfirmationModifier(
        link: link, isPresented: isPresented))
  }
}

struct CalendarMeetingLinkButton: View {
  let link: CalendarMeetingLink
  let eventTitle: String
  @State private var confirmationPresented = false

  var body: some View {
    Button {
      CalendarMeetingLinkPresentation.activate(link) {
        confirmationPresented = true
      }
    } label: {
      if case .unrecognized(let host) = link.trust {
        Label(host, systemImage: "video.fill")
          .font(.caption2)
          .lineLimit(1)
          .foregroundStyle(.green)
      } else {
        Image(systemName: "video.fill").foregroundStyle(.green)
      }
    }
    .buttonStyle(.plain)
    .help(link.trust.destinationHost.map { "Join \(eventTitle) at \($0)" } ?? "Join \(eventTitle)")
    .accessibilityLabel(
      link.trust.destinationHost.map { "Join \(eventTitle) at \($0)" } ?? "Join \(eventTitle)"
    )
    .calendarMeetingLinkConfirmation(
      link: link, isPresented: $confirmationPresented)
  }
}
