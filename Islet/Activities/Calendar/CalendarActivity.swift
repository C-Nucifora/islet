import AppKit
import Combine
import Defaults
import EventKit
import SwiftUI

struct CalendarChoice: Identifiable, Equatable, Sendable {
  let id: String
  let title: String
  let sourceTitle: String
  let colorHex: String?
  let allowsContentModifications: Bool
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
  @Published private(set) var defaultCalendarID: String?
  @Published private(set) var lastActionError: String?

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
  var agendaDays: [CalendarDayAgenda] { CalendarLogic.days(events: events, now: Date()) }
  var writableCalendars: [CalendarChoice] {
    availableCalendars.filter(\.allowsContentModifications)
  }

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
          self?.defaultCalendarID = nil
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
    NotificationCenter.default.publisher(for: .NSCalendarDayChanged)
      .merge(with: NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange))
      .sink { [weak self] _ in Task { await self?.reload() } }
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
    defaultCalendarID = nil
    loadState = .idle
    lastActionError = nil
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
    let previousAuthorization = authorization
    let currentAuthorization = EventKitPermissionState(
      EKEventStore.authorizationStatus(for: .event))
    authorization = currentAuthorization
    switch CalendarLogic.accessAction(
      from: previousAuthorization, to: currentAuthorization,
      providerEnabled: isRunning && Defaults[.calendarEnabled])
    {
    case .reload:
      await reload()
    case .clear:
      reloadGeneration += 1
      events = []
      availableCalendars = []
      defaultCalendarID = nil
      loadState = .idle
    case .none:
      break
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
      defaultCalendarID = nil
      loadState = .idle
      return
    }
    let calendars = store.calendars(for: .event)
    availableCalendars =
      calendars
      .map {
        CalendarChoice(
          id: $0.calendarIdentifier, title: $0.title,
          sourceTitle: $0.source.title, colorHex: ColorHex.string(from: $0.cgColor),
          allowsContentModifications: $0.allowsContentModifications)
      }
      .sorted {
        let titleOrder = $0.title.localizedStandardCompare($1.title)
        if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
        return $0.sourceTitle.localizedStandardCompare($1.sourceTitle) == .orderedAscending
      }
    defaultCalendarID = store.defaultCalendarForNewEvents?.calendarIdentifier
    let sanitizedHiddenIDs = CalendarLogic.sanitizedHiddenCalendarIDs(
      Defaults[.hiddenCalendarIDs], availableIDs: Set(calendars.map(\.calendarIdentifier)))
    if sanitizedHiddenIDs != Defaults[.hiddenCalendarIDs] {
      Defaults[.hiddenCalendarIDs] = sanitizedHiddenIDs
    }
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
        joinURL: joinURL(from: event), location: normalizedLocation(from: event))
    }
  }

  nonisolated private static func normalizedLocation(from event: EKEvent) -> String? {
    let value = event.structuredLocation?.title ?? event.location
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : trimmed
  }

  @discardableResult
  func createEvent(_ draft: CalendarEventDraft) async -> Bool {
    let currentAuthorization = EventKitPermissionState(
      EKEventStore.authorizationStatus(for: .event))
    authorization = currentAuthorization
    let prepared = CalendarLogic.prepareEvent(
      draft, writableCalendarIDs: Set(writableCalendars.map(\.id)),
      authorization: currentAuthorization)
    switch prepared {
    case .failure(let error):
      lastActionError = error.message
      return false
    case .success(let event):
      let result = await Task.detached(priority: .userInitiated) {
        Self.saveEvent(event)
      }.value
      switch result {
      case .success:
        lastActionError = nil
        await reload()
        return true
      case .failure(let error):
        lastActionError = error.message
        Log.app.error("Failed to add calendar event: \(String(describing: error))")
        return false
      }
    }
  }

  nonisolated private static func saveEvent(
    _ prepared: PreparedCalendarEvent
  ) -> Result<Void, CalendarCreationError> {
    guard EventKitPermissionState(EKEventStore.authorizationStatus(for: .event)).canRead else {
      return .failure(.permissionRequired)
    }
    let store = EKEventStore()
    guard let calendar = store.calendar(withIdentifier: prepared.calendarID),
      calendar.allowsContentModifications
    else { return .failure(.calendarUnavailable) }
    return CalendarLogic.commitEvent(prepared) { prepared in
      let event = EKEvent(eventStore: store)
      event.calendar = calendar
      event.title = prepared.title
      event.startDate = prepared.start
      event.endDate = prepared.end
      event.location = prepared.location
      event.url = prepared.conferenceURL
      try store.save(event, span: .thisEvent, commit: true)
    }
  }

  func dismissActionError() { lastActionError = nil }

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

  var accessibilityPrimaryActionName: String? {
    primaryMeeting.map { "Opened meeting for \($0.event.title)" }
  }

  func performAccessibilityPrimaryAction() -> Bool {
    guard let meeting = primaryMeeting else { return false }
    return NSWorkspace.shared.open(meeting.link.url)
  }

  private var primaryMeeting: (event: AgendaEvent, link: CalendarMeetingLink)? {
    for event in events {
      guard let url = event.joinURL, let link = CalendarMeetingLinkPolicy.candidate(url),
        !link.trust.requiresConfirmation
      else { continue }
      return (event, link)
    }
    return nil
  }
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
      HStack {
        Text("Next three days").font(.headline).appThemeForeground(.calendar)
        Spacer()
        Button {
          activity.dismissActionError()
          CalendarEventEditor.shared.present(activity: activity)
        } label: {
          Image(systemName: "plus.circle.fill")
        }
        .buttonStyle(.plain)
        .help("Add calendar event")
        .accessibilityLabel("Add calendar event")
        .disabled(!activity.authorization.canRead || activity.writableCalendars.isEmpty)
      }
      if !activity.authorization.canRead {
        HStack(spacing: 6) {
          Text("Calendar access: \(activity.authorization.summary)")
            .font(.callout).foregroundStyle(.secondary)
          Button("Review") { Task { await activity.recoverAccess() } }
            .buttonStyle(.link)
        }
      } else if activity.loadState == .loading, activity.events.isEmpty {
        ProgressView().controlSize(.small).accessibilityLabel("Loading calendar")
      } else if case .failed(let message) = activity.loadState {
        HStack(spacing: 6) {
          Text(message).font(.callout).foregroundStyle(.orange).lineLimit(2)
          Button("Retry") { Task { await activity.refreshAuthorization() } }
            .buttonStyle(.link)
        }
      } else {
        ScrollView(.vertical, showsIndicators: false) {
          VStack(alignment: .leading, spacing: 9) {
            ForEach(activity.agendaDays) { day in
              VStack(alignment: .leading, spacing: 4) {
                Text(dayTitle(day.date))
                  .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if day.events.isEmpty {
                  Text("No events").font(.caption).foregroundStyle(.tertiary)
                } else {
                  ForEach(day.events.prefix(5)) { event in
                    CalendarAgendaEventRow(event: event)
                  }
                }
              }
            }
          }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func dayTitle(_ date: Date) -> String {
    if Calendar.current.isDateInToday(date) { return "Today" }
    if Calendar.current.isDateInTomorrow(date) { return "Tomorrow" }
    return date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
  }
}

private struct CalendarAgendaEventRow: View {
  let event: AgendaEvent

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Text(event.isAllDay ? "All day" : event.start.formatted(.dateTime.hour().minute()))
        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
        .lineLimit(1).frame(width: 58, alignment: .leading)
      Capsule()
        .fill(Color(isletHex: event.calendarColorHex) ?? .secondary)
        .frame(width: 3, height: 17)
      VStack(alignment: .leading, spacing: 1) {
        Text(event.title).font(.callout).foregroundStyle(.white).lineLimit(1)
        if let location = event.location {
          Label(location, systemImage: "mappin.and.ellipse")
            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
      }
      Spacer(minLength: 0)
      if let url = event.joinURL, let link = CalendarMeetingLinkPolicy.candidate(url) {
        CalendarMeetingLinkButton(link: link, eventTitle: event.title)
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(eventAccessibilityLabel)
  }

  private var eventAccessibilityLabel: String {
    let time =
      event.isAllDay
      ? "All day"
      : event.start.formatted(date: .omitted, time: .shortened)
    return "\(time), \(event.title)"
  }
}

private struct CalendarEventCreationView: View {
  @ObservedObject var activity: CalendarActivity
  let close: () -> Void
  @State private var draft: CalendarEventDraft
  @State private var isSaving = false

  init(activity: CalendarActivity, close: @escaping () -> Void) {
    self.activity = activity
    self.close = close
    let start =
      Calendar.current.date(
        bySetting: .minute, value: 0, of: Date().addingTimeInterval(60 * 60))
      ?? Date().addingTimeInterval(60 * 60)
    let writableIDs = Set(activity.writableCalendars.map(\.id))
    let initialCalendarID =
      activity.defaultCalendarID.flatMap {
        writableIDs.contains($0) ? $0 : nil
      } ?? activity.writableCalendars.first?.id ?? ""
    _draft = State(
      initialValue: CalendarEventDraft(
        calendarID: initialCalendarID,
        title: "", start: start, end: start.addingTimeInterval(60 * 60), location: "",
        conferenceURL: ""))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Add event").font(.title2.weight(.semibold))
      Form {
        Picker("Calendar", selection: $draft.calendarID) {
          ForEach(activity.writableCalendars) { calendar in
            Text(calendarLabel(calendar)).tag(calendar.id)
          }
        }
        TextField("Title", text: $draft.title)
        DatePicker("Starts", selection: $draft.start)
        DatePicker("Ends", selection: $draft.end)
        TextField("Location", text: $draft.location)
        TextField("Conference URL", text: $draft.conferenceURL)
          .textContentType(.URL)
      }
      .formStyle(.grouped)
      Text(
        "macOS does not share Calendar travel-time estimates, so Islet does not guess when to leave."
      )
      .font(.caption).foregroundStyle(.secondary)
      if let error = activity.lastActionError {
        Text(error).font(.callout).foregroundStyle(.orange)
      }
      HStack {
        Button("Cancel") { close() }.keyboardShortcut(.cancelAction)
        Spacer()
        if isSaving { ProgressView().controlSize(.small) }
        Button("Add") {
          isSaving = true
          Task {
            if await activity.createEvent(draft) { close() }
            isSaving = false
          }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(
          isSaving || !activity.authorization.canRead || activity.writableCalendars.isEmpty)
      }
    }
    .padding(20)
    .frame(width: 430)
    .onChange(of: draft.start) { _, newValue in
      if draft.end <= newValue { draft.end = newValue.addingTimeInterval(60 * 60) }
    }
    .onChange(of: activity.writableCalendars.map(\.id), initial: true) { _, ids in
      guard !ids.contains(draft.calendarID) else { return }
      draft.calendarID = ids.first ?? ""
    }
  }

  private func calendarLabel(_ calendar: CalendarChoice) -> String {
    let duplicateCount = activity.writableCalendars.filter { $0.title == calendar.title }.count
    return duplicateCount > 1 ? "\(calendar.title) · \(calendar.sourceTitle)" : calendar.title
  }
}

/// The notch lives in a non-activating panel and deliberately cannot become key. Event creation
/// needs keyboard focus, so it uses a small regular window rather than placing text fields inside
/// the notch panel.
@MainActor
private final class CalendarEventEditor: NSObject, NSWindowDelegate {
  static let shared = CalendarEventEditor()

  private var window: NSWindow?

  func present(activity: CalendarActivity) {
    if let window {
      NSApp.activate()
      window.makeKeyAndOrderFront(nil)
      return
    }
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 430, height: 430),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.title = "Add calendar event"
    window.isReleasedWhenClosed = false
    window.level = .floating
    window.delegate = self
    window.contentView = NSHostingView(
      rootView: CalendarEventCreationView(activity: activity) { [weak self] in
        self?.close()
      })
    window.center()
    self.window = window
    NSApp.activate()
    window.makeKeyAndOrderFront(nil)
  }

  func windowWillClose(_ notification: Notification) {
    guard let closedWindow = notification.object as? NSWindow, closedWindow === window else {
      return
    }
    closedWindow.contentView = nil
    window = nil
  }

  private func close() {
    window?.close()
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
