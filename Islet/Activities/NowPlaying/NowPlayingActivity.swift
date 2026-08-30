import AppKit
import Combine
import Defaults
import SwiftUI

@MainActor
final class NowPlayingActivity: NotchActivity, ObservableObject {
  typealias CommandPerformer =
    @Sendable (MediaCommand, SourceID, Bool) async -> MediaCommandResult
  typealias AnnouncementHandler = (String) -> Void

  let id = "nowPlaying"
  let priority = ActivityPriority.media

  /// Every source the MediaRemote adapter has reported, keyed by `SourceID`.
  ///
  /// At most ONE entry is populated today: the vendored adapter physically collapses concurrent
  /// players (`Vendor/mediaremote-adapter-src/src/adapter/stream.m:189`, which calls `resetAll()`
  /// on a process change at `:396-408` and `:437-449`). The keyed shape is what the design spec's
  /// "Upgrade path — fork the MediaRemote adapter for true per-source media" section needs, and
  /// dropping the fork in behind it requires no model change.
  @Published private(set) var sources: [SourceID: PlaybackState] = [:]
  /// Secondary sources drawn as chips under the hero. Adapter sources first, then CoreAudio ones,
  /// which carry no metadata at all — only "this app is producing audio".
  @Published private(set) var strip: [SourceID] = []
  @Published private(set) var adapterStatus = String(localized: "Starting…")
  @Published private(set) var mediaControlNotice: String?
  /// The most recent command result. The view uses the accompanying notice only for failures,
  /// while this preserves the success or failure result for observers and tests.
  @Published private(set) var lastMediaCommandResult: MediaCommandResult?
  @Published private(set) var adapterFailure: String?
  private(set) var activationDate: Date?

  private(set) var table = MediaSourceTable()
  private var artworkPayloads: [SourceID: Data] = [:]
  private var artworkImages: [SourceID: NSImage] = [:]
  private var artworkDecodeTasks: [SourceID: Task<Void, Never>] = [:]
  private var artworkRequestIDs: [SourceID: UUID] = [:]
  private var appNames: [String: String] = [:]
  private var appIcons: [String: NSImage] = [:]
  private var resolvedBundleIdentifiers: Set<String> = []
  private let watcher = MediaWatcher()
  private let audio = AudioProcessMonitor()
  private var streamTask: Task<Void, Never>?
  private var expiryTask: Task<Void, Never>?
  private var mediaControlNoticeTask: Task<Void, Never>?
  private var audioCancellable: AnyCancellable?
  private var preferenceCancellables: Set<AnyCancellable> = []
  /// Last primary reflected to observers. Defaults changes can alter this without changing the
  /// underlying source dictionary, so it participates in diffing separately.
  private var publishedPrimaryKey: SourceID?
  private var isMonitoring = false
  private var mediaControlRequest = 0
  private let commandPerformer: CommandPerformer
  private let announce: AnnouncementHandler

  init(
    commandPerformer: @escaping CommandPerformer = {
      command, source, isAdapterBacked in
      await MediaRemoteCommands.shared.perform(
        command,
        shownSource: source,
        sourceIsAdapterBacked: isAdapterBacked)
    },
    announce: @escaping AnnouncementHandler = { A11y.announce($0) }
  ) {
    self.commandPerformer = commandPerformer
    self.announce = announce
  }

  /// The source that owns the hero player.
  var primaryKey: SourceID? {
    table.primaryKey(mode: Defaults[.mediaSourceMode], priorityList: Defaults[.mediaPriorityList])
  }
  var primary: PlaybackState? { primaryKey.flatMap { sources[$0] } }
  /// Shim so the single-source views keep compiling unchanged.
  var playback: PlaybackState? { primary }

  /// CoreAudio-only sources never activate the tab on their own — there would be no hero to put
  /// them beside. They are context for an adapter source, not a source in themselves.
  /// A source hidden by the user's media filter must not leave behind an empty, selectable tab.
  var isActive: Bool { publishedPrimaryKey != nil }

  func receive(_ update: AdapterUpdate, now: Date = Date()) {
    switch update {
    case .ignored:
      return
    case .idle:
      table.removeAll()
      activationDate = nil
      expiryTask?.cancel()
      expiryTask = nil
      publish()
    case .sourceGone(let key):
      guard table.remove(key) else { return }
      if table.isEmpty { activationDate = nil }
      publish()
      rescheduleExpiry()
    case .nowPlaying(let key, let state):
      let wasVisible = !table.isEmpty
      let previous = table.states[key]
      table.upsert(key, state, now: now)
      if !wasVisible { activationDate = now }
      if let previous, previous.title != state.title, !state.title.isEmpty {
        let appName = resolvedApplicationName(for: key.displayBundleIdentifier)
        SystemEventBus.shared.emit(Self.trackChangeEvent(for: state, appName: appName))
      }
      publish()
      rescheduleExpiry()
    }
  }

  func start() {
    guard !isMonitoring else { return }
    isMonitoring = true
    migrateAudioOnlySourceExclusions()
    watcher.onStatus = { status in
      Task { @MainActor [weak self] in self?.adapterStatus = status }
    }
    watcher.onDiagnostic = { diagnostic in
      Task { @MainActor [weak self] in self?.adapterFailure = diagnostic }
    }
    watcher.start()
    audio.start()
    audioCancellable = audio.$sources
      .receive(on: DispatchQueue.main)
      .sink { [weak self] latest in self?.audioSourcesChanged(latest) }
    Defaults.publisher(.mediaSourceMode)
      .dropFirst()
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in self?.publish() }
      .store(in: &preferenceCancellables)
    Defaults.publisher(.mediaPriorityList)
      .dropFirst()
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in self?.publish() }
      .store(in: &preferenceCancellables)
    Defaults.publisher(.excludedAudioOnlySourceBundleIdentifiers)
      .dropFirst()
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in self?.publish() }
      .store(in: &preferenceCancellables)
    streamTask = Task { [weak self] in
      guard let self else { return }
      for await update in self.watcher.updates {
        self.receive(update)
      }
    }
  }

  func stop() {
    guard isMonitoring else { return }
    isMonitoring = false
    streamTask?.cancel()
    streamTask = nil
    expiryTask?.cancel()
    expiryTask = nil
    audioCancellable = nil
    preferenceCancellables.removeAll()
    audio.stop()
    watcher.stop()
    table.removeAll()
    publishedPrimaryKey = nil
    sources = [:]
    strip = []
    artworkPayloads = [:]
    artworkImages = [:]
    for task in artworkDecodeTasks.values { task.cancel() }
    artworkDecodeTasks = [:]
    artworkRequestIDs = [:]
    appNames = [:]
    appIcons = [:]
    resolvedBundleIdentifiers = []
    activationDate = nil
    adapterStatus = String(localized: "Stopped")
    mediaControlRequest &+= 1
    clearMediaControlFeedback()
    adapterFailure = nil
  }

  /// Tapping a source makes its display identity the first configured preference and brings the
  /// app forward. The current adapter cannot focus a MediaRemote player by source.
  func promote(_ source: SourceID) {
    let selection = MediaSourceChooser.selection(
      for: source, priorityList: Defaults[.mediaPriorityList])
    Defaults[.mediaSourceMode] = selection.mode
    Defaults[.mediaPriorityList] = selection.priorityList
    publish()
    MediaRemoteCommands.shared.promote(source)
  }

  @discardableResult
  func perform(_ command: MediaCommand, for source: SourceID) async -> MediaCommandResult {
    mediaControlRequest &+= 1
    let request = mediaControlRequest
    // Do not leave an old failure beside a newer action while its command is still running.
    mediaControlNoticeTask?.cancel()
    mediaControlNoticeTask = nil
    mediaControlNotice = nil
    let result = await commandPerformer(command, source, sources[source] != nil)

    if let reason = MediaControlFeedback.logReason(for: result) {
      Log.media.notice(
        "Media command \(command.feedbackName, privacy: .public) failed: \(reason, privacy: .public)"
      )
    }

    // A later tap or source change owns the displayed feedback. The command queue still records
    // the older result above, but it must not overwrite the user's newer action.
    guard request == mediaControlRequest else { return result }
    lastMediaCommandResult = result
    guard let notice = MediaControlFeedback.message(for: command, result: result) else {
      mediaControlNoticeTask?.cancel()
      mediaControlNoticeTask = nil
      mediaControlNotice = nil
      return result
    }
    mediaControlNotice = notice
    announce("Media control error: \(notice)")
    mediaControlNoticeTask?.cancel()
    mediaControlNoticeTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 4_000_000_000)
      guard !Task.isCancelled, let self, self.mediaControlRequest == request else { return }
      self.mediaControlNotice = nil
      self.mediaControlNoticeTask = nil
    }
    return result
  }

  /// A control stays disabled unless the player capability and a source-scoped transport are
  /// available.
  func canPerform(_ command: MediaCommand, for source: SourceID) -> Bool {
    guard mediaControlsAvailable(for: source), let state = sources[source], !state.isAdvertisement
    else { return false }
    switch command {
    case .seek:
      return state.duration.isFinite && state.duration > 0
    case .skipBackward15:
      return state.supportsSkipBackward15
    case .skipForward15:
      return state.supportsSkipForward15
    default:
      return true
    }
  }

  func mediaControlsAvailable(for source: SourceID) -> Bool {
    sources[source] != nil && MediaRemoteCommands.shared.targeting.controlsAvailable
  }

  func mediaControlScopeLabel(for source: SourceID) -> String {
    MediaControlPresentation.scopeLabel(
      appName: sourceName(for: source),
      targeting: MediaRemoteCommands.shared.targeting)
  }

  func mediaControlHelp(action: String, for source: SourceID) -> String {
    MediaControlPresentation.help(
      action: action,
      appName: sourceName(for: source),
      targeting: MediaRemoteCommands.shared.targeting)
  }

  func mediaControlAccessibilityLabel(action: String) -> String {
    MediaControlPresentation.accessibilityLabel(
      action: action,
      targeting: MediaRemoteCommands.shared.targeting)
  }

  /// A scrub can finish after SwiftUI has redrawn for another primary source. Check the source at
  /// the command boundary so a stale completion cannot seek the newly selected player.
  func seek(to position: TimeInterval, for source: SourceID) async {
    guard primaryKey == source, let target = table.seek(source, to: position, now: Date()) else {
      return
    }
    publish()
    await perform(.seek(to: target), for: source)
  }

  func artwork(for source: SourceID?) -> NSImage? {
    source.flatMap { artworkImages[$0] }
  }

  func sourceIcon(for source: SourceID) -> NSImage? {
    appIcons[source.displayBundleIdentifier]
  }

  func sourceName(for source: SourceID) -> String {
    appNames[source.displayBundleIdentifier] ?? source.displayBundleIdentifier
  }

  func sourceAccessibilityLabel(for source: SourceID, isPrimary: Bool) -> String {
    MediaSourceChooser.accessibilityLabel(
      appName: sourceName(for: source),
      isPlaying: sources[source]?.isPlaying ?? true,
      isPrimary: isPrimary,
      isAdapterBacked: sources[source] != nil)
  }

  func sourceSelectionAccessibilityHint(for source: SourceID) -> String {
    MediaSourceChooser.accessibilityHint(
      appName: sourceName(for: source), isAdapterBacked: sources[source] != nil)
  }

  var knownBundleIdentifiers: [String] {
    Array(
      Set(
        sources.keys.map(\.displayBundleIdentifier) + strip.map(\.displayBundleIdentifier)
          + audio.sources.map(\.displayBundleIdentifier))
    )
    .filter { !$0.isEmpty }
    .sorted {
      applicationName(for: $0).localizedStandardCompare(applicationName(for: $1))
        == .orderedAscending
    }
  }

  /// The current CoreAudio-only choices for Settings. They are deliberately derived from the live
  /// process list and never persisted, which avoids retaining a history of apps that made sound.
  var observedAudioOnlyBundleIdentifiers: [String] {
    Array(Set(audio.sources.map(\.displayBundleIdentifier)))
      .filter { !SourceFilter.isDenied($0) }
      .sorted {
        applicationName(for: $0).localizedStandardCompare(applicationName(for: $1))
          == .orderedAscending
      }
  }

  /// Keeps explicit exclusions manageable even when the app is no longer producing audio. Only
  /// user-selected exclusions persist; other observed apps disappear when CoreAudio drops them.
  var manageableAudioOnlyBundleIdentifiers: [String] {
    Array(
      Set(
        observedAudioOnlyBundleIdentifiers
          + Defaults[.excludedAudioOnlySourceBundleIdentifiers])
    )
    .filter { !SourceFilter.isDenied($0) }
    .sorted {
      applicationName(for: $0).localizedStandardCompare(applicationName(for: $1))
        == .orderedAscending
    }
  }

  func applicationName(for bundleIdentifier: String) -> String {
    resolveApplication(for: bundleIdentifier)
    return appNames[bundleIdentifier] ?? bundleIdentifier
  }

  func applicationIcon(for bundleIdentifier: String) -> NSImage? {
    resolveApplication(for: bundleIdentifier)
    return appIcons[bundleIdentifier]
  }

  /// Mirrors the table (and the audio monitor) into the published properties the views read.
  func audioSourcesChanged(_ latest: [SourceID]) {
    watcher.setPlaybackRecoverySources(Set(latest.map(\.displayBundleIdentifier)))
    publish(audioSources: latest)
    rescheduleExpiry()
  }

  private func publish(audioSources: [SourceID]? = nil) {
    let mode = Defaults[.mediaSourceMode]
    let priorityList = Defaults[.mediaPriorityList]
    let audioSources = audioSources ?? audio.sources
    let adapterKeys = table.ordered(mode: mode, priorityList: priorityList)
    let visibleAudioSources = audioSources.filter {
      SourceFilter.acceptsAudioOnlySource(
        $0.displayBundleIdentifier,
        excludedBundleIdentifiers: Set(Defaults[.excludedAudioOnlySourceBundleIdentifiers]))
    }
    let merged = SourceStrip.merge(
      adapter: adapterKeys, audio: visibleAudioSources)
    let nextStrip = SourceStrip.secondary(all: merged, primary: adapterKeys.first)
    let nextPrimaryKey = adapterKeys.first
    let presentationChanged = publishedPrimaryKey != nextPrimaryKey
    publishedPrimaryKey = nextPrimaryKey
    if presentationChanged {
      mediaControlRequest &+= 1
      clearMediaControlFeedback()
    }
    for source in merged + audioSources { resolveApplication(for: source.displayBundleIdentifier) }
    var publishedPropertyChanged = false
    let presentationStates = table.presentationStates
    if sources != presentationStates {
      reconcileArtwork(with: presentationStates)
      sources = presentationStates
      publishedPropertyChanged = true
    }
    if strip != nextStrip {
      strip = nextStrip
      publishedPropertyChanged = true
    }
    // Preference changes can hide every adapter source without changing `table.states`. Keep
    // activation and ActivityCenter invalidation in sync with what the user can actually select.
    if adapterKeys.isEmpty {
      activationDate = nil
    } else if activationDate == nil {
      activationDate = Date()
    }
    if presentationChanged, !publishedPropertyChanged { objectWillChange.send() }
  }

  private func clearMediaControlFeedback() {
    mediaControlNoticeTask?.cancel()
    mediaControlNoticeTask = nil
    mediaControlNotice = nil
    lastMediaCommandResult = nil
  }

  /// Decode artwork and resolve application metadata when the model changes, not from SwiftUI's
  /// `body`. Body can be recomputed many times per second while scrubbing or animating bars; doing
  /// AppKit workspace and image-decoding work there caused avoidable UI and energy spikes.
  private func reconcileArtwork(with states: [SourceID: PlaybackState]) {
    let activeKeys = Set(states.keys)
    let staleKeys = artworkDecodeTasks.keys.filter { !activeKeys.contains($0) }
    for key in staleKeys {
      artworkDecodeTasks[key]?.cancel()
      artworkDecodeTasks[key] = nil
      artworkRequestIDs[key] = nil
    }
    artworkPayloads = artworkPayloads.filter { activeKeys.contains($0.key) }
    artworkImages = artworkImages.filter { activeKeys.contains($0.key) }
    for (key, state) in states {
      guard artworkPayloads[key] != state.artwork else { continue }
      artworkDecodeTasks[key]?.cancel()
      artworkDecodeTasks[key] = nil
      artworkRequestIDs[key] = nil
      artworkPayloads[key] = state.artwork
      artworkImages[key] = nil
      guard let data = state.artwork else { continue }

      let requestID = UUID()
      artworkRequestIDs[key] = requestID
      artworkDecodeTasks[key] = Task.detached(priority: .utility) { [weak self] in
        let decoded = ArtworkDecoder.decode(data)
        guard !Task.isCancelled else { return }
        await self?.acceptArtwork(decoded, payload: data, requestID: requestID, for: key)
      }
    }
  }

  private func acceptArtwork(
    _ decoded: DecodedArtwork?, payload: Data, requestID: UUID, for key: SourceID
  ) {
    guard artworkPayloads[key] == payload, artworkRequestIDs[key] == requestID else { return }
    artworkDecodeTasks[key] = nil
    artworkRequestIDs[key] = nil
    artworkImages[key] = decoded.map { NSImage(cgImage: $0.cgImage, size: .zero) }
    objectWillChange.send()
  }

  private func resolveApplication(for bundleIdentifier: String) {
    guard !bundleIdentifier.isEmpty,
      resolvedBundleIdentifiers.insert(bundleIdentifier).inserted
    else { return }
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    else {
      appNames[bundleIdentifier] = bundleIdentifier
      return
    }
    appNames[bundleIdentifier] = FileManager.default.displayName(atPath: url.path)
    appIcons[bundleIdentifier] = NSWorkspace.shared.icon(forFile: url.path)
  }

  private func migrateAudioOnlySourceExclusions() {
    let stored = Defaults[.excludedAudioOnlySourceBundleIdentifiers]
    let migrated = SourceFilter.migratedAudioOnlyExclusions(stored)
    if migrated != stored { Defaults[.excludedAudioOnlySourceBundleIdentifiers] = migrated }
  }

  private func resolvedApplicationName(for bundleIdentifier: String) -> String {
    resolveApplication(for: bundleIdentifier)
    return appNames[bundleIdentifier] ?? bundleIdentifier
  }

  /// One timer for the whole table, always aimed at the earliest deadline.
  private func rescheduleExpiry() {
    expiryTask?.cancel()
    guard let deadline = table.nextDeadline else {
      expiryTask = nil
      return
    }
    let delay = max(0, deadline.timeIntervalSinceNow)
    expiryTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(delay))
      guard !Task.isCancelled, let self else { return }
      self.expiryTask = nil
      self.table.expire(now: Date())
      if self.table.isEmpty { self.activationDate = nil }
      self.publish()
      self.rescheduleExpiry()
    }
  }

  /// Track changes go through the Phase 3 event bus, not `SneakQueue` directly: the bus is the only
  /// thing that may enqueue a sneak, which is what gives track changes a Settings toggle, an entry
  /// in the generated Debug menu, and burst coalescing for free.
  ///
  /// Artwork is deliberately not used for the icon. Every other event's leading slot is an SF
  /// Symbol, and a 16pt bitmap there measures differently — which would change the island's width
  /// for track changes alone. The app name goes in the subtitle instead, which is the attribution
  /// the artwork was carrying.
  static func trackChangeEvent(for state: PlaybackState, appName: String? = nil) -> SystemEvent {
    let appName = appName ?? state.sourceBundleIdentifier
    let subtitle = [state.artist, appName].filter { !$0.isEmpty }.joined(separator: " · ")
    var announcement =
      state.artist.isEmpty
      ? "Now playing \(state.title)" : "Now playing \(state.title) by \(state.artist)"
    if !appName.isEmpty, appName != state.sourceBundleIdentifier {
      announcement += " in \(appName)"
    }
    return SystemEvent(
      sourceID: "nowPlaying",
      icon: "music.note",
      title: state.title,
      subtitle: subtitle.isEmpty ? nil : subtitle,
      accentHex: EventAccent.positive,
      motion: .generic,
      urgency: .ambient,
      announcement: announcement)
  }

  // MARK: - NotchActivity presentation

  let tabIcon = "music.note"

  var compactLeading: AnyView { AnyView(CompactArtworkView(activity: self)) }
  var compactTrailing: AnyView { AnyView(CompactBarsView(activity: self)) }
  var expandedView: AnyView { AnyView(ExpandedPlayerView(activity: self)) }

  var accessibilityPrimaryActionName: String? {
    guard let playback, !playback.isAdvertisement else { return nil }
    return playback.isPlaying ? "Playback paused" : "Playback started"
  }

  func performAccessibilityPrimaryAction() async -> Bool {
    guard let playback, !playback.isAdvertisement, let primaryKey,
      canPerform(.togglePlayPause, for: primaryKey)
    else { return false }
    if case .sent = await perform(.togglePlayPause, for: primaryKey) { return true }
    return false
  }
}
