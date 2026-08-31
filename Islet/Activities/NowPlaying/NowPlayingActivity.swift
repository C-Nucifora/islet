import AppKit
import Combine
import Defaults
import SwiftUI

@MainActor
final class NowPlayingActivity: NotchActivity, ObservableObject {
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
  @Published private(set) var adapterStatus = "Starting…"
  @Published private(set) var adapterFailure: String?
  private(set) var activationDate: Date?

  private var table = MediaSourceTable()
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
  private var audioCancellable: AnyCancellable?
  private var preferenceCancellables: Set<AnyCancellable> = []
  /// Last primary reflected to observers. Defaults changes can alter this without changing the
  /// underlying source dictionary, so it participates in diffing separately.
  private var publishedPrimaryKey: SourceID?
  private var isMonitoring = false

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

  func start() {
    guard !isMonitoring else { return }
    isMonitoring = true
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
      .sink { [weak self] latest in self?.publish(audioSources: latest) }
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
    streamTask = Task { [weak self] in
      guard let self else { return }
      for await update in self.watcher.updates {
        switch update {
        case .ignored:
          continue
        case .idle:
          self.table.removeAll()
          self.activationDate = nil
          self.expiryTask?.cancel()
          self.expiryTask = nil
          self.publish()
        case .sourceGone(let key):
          guard self.table.remove(key) else { continue }
          if self.table.isEmpty { self.activationDate = nil }
          self.publish()
          self.rescheduleExpiry()
        case .nowPlaying(let key, let state):
          let wasVisible = !self.table.isEmpty
          let previous = self.table.states[key]
          self.table.upsert(key, state, now: Date())
          if !wasVisible { self.activationDate = Date() }
          if let previous, previous.title != state.title, !state.title.isEmpty {
            let appName = self.resolvedApplicationName(for: key.displayBundleIdentifier)
            SystemEventBus.shared.emit(Self.trackChangeEvent(for: state, appName: appName))
          }
          self.publish()
          self.rescheduleExpiry()
        }
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
    adapterStatus = "Stopped"
    adapterFailure = nil
  }

  /// Tapping a source makes its display identity the first configured primary player, then asks
  /// MediaRemote to focus it. See `MediaRemoteCommands.promote` for the activation fallback.
  func promote(_ source: SourceID) {
    let selection = MediaSourceChooser.selection(
      for: source, priorityList: Defaults[.mediaPriorityList])
    Defaults[.mediaSourceMode] = selection.mode
    Defaults[.mediaPriorityList] = selection.priorityList
    publish()
    MediaRemoteCommands.shared.promote(source)
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
      isPrimary: isPrimary)
  }

  func sourceSelectionAccessibilityHint(for source: SourceID) -> String {
    MediaSourceChooser.accessibilityHint(appName: sourceName(for: source))
  }

  var knownBundleIdentifiers: [String] {
    Array(Set(sources.keys.map(\.displayBundleIdentifier) + strip.map(\.displayBundleIdentifier)))
      .filter { !$0.isEmpty }
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
  private func publish(audioSources: [SourceID]? = nil) {
    let mode = Defaults[.mediaSourceMode]
    let priorityList = Defaults[.mediaPriorityList]
    let adapterKeys = table.ordered(mode: mode, priorityList: priorityList)
    let merged = SourceStrip.merge(
      adapter: adapterKeys, audio: audioSources ?? audio.sources)
    let nextStrip = SourceStrip.secondary(all: merged, primary: adapterKeys.first)
    let nextPrimaryKey = adapterKeys.first
    let presentationChanged = publishedPrimaryKey != nextPrimaryKey
    publishedPrimaryKey = nextPrimaryKey
    for source in merged { resolveApplication(for: source.displayBundleIdentifier) }
    var publishedPropertyChanged = false
    if sources != table.states {
      reconcileArtwork(with: table.states)
      sources = table.states
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

  /// Schedule bounded artwork decoding when the payload changes, not from SwiftUI's `body`.
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
}
