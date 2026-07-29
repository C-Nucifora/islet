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
  private(set) var activationDate: Date?

  private var table = MediaSourceTable()
  private let watcher = MediaWatcher()
  private let audio = AudioProcessMonitor()
  private var streamTask: Task<Void, Never>?
  private var expiryTask: Task<Void, Never>?
  private var audioCancellable: AnyCancellable?

  /// The source that owns the hero player.
  var primaryKey: SourceID? {
    table.primaryKey(mode: Defaults[.mediaSourceMode], priorityList: Defaults[.mediaPriorityList])
  }
  var primary: PlaybackState? { primaryKey.flatMap { sources[$0] } }
  /// Shim so the single-source views keep compiling unchanged.
  var playback: PlaybackState? { primary }

  /// CoreAudio-only sources never activate the tab on their own — there would be no hero to put
  /// them beside. They are context for an adapter source, not a source in themselves.
  var isActive: Bool { !sources.isEmpty }

  func start() {
    watcher.onStatus = { status in
      Task { @MainActor [weak self] in self?.adapterStatus = status }
    }
    watcher.start()
    audio.start()
    audioCancellable = audio.$sources
      .receive(on: DispatchQueue.main)
      .sink { [weak self] latest in self?.publish(audioSources: latest) }
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
            SystemEventBus.shared.emit(Self.trackChangeEvent(for: state))
          }
          self.publish()
          self.rescheduleExpiry()
        }
      }
    }
  }

  /// Tapping a chip. See `MediaRemoteCommands.promote` for what "promote" can actually mean today.
  func promote(_ source: SourceID) {
    Haptics.perform(.alignment)
    MediaRemoteCommands.shared.promote(source)
  }

  /// Mirrors the table (and the audio monitor) into the published properties the views read.
  private func publish(audioSources: [SourceID]? = nil) {
    let mode = Defaults[.mediaSourceMode]
    let priorityList = Defaults[.mediaPriorityList]
    let adapterKeys = table.ordered(mode: mode, priorityList: priorityList)
    let merged = SourceStrip.merge(
      adapter: adapterKeys, audio: audioSources ?? audio.sources)
    let nextStrip = SourceStrip.secondary(all: merged, primary: adapterKeys.first)
    if sources != table.states { sources = table.states }
    if strip != nextStrip { strip = nextStrip }
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
  static func trackChangeEvent(for state: PlaybackState) -> SystemEvent {
    let appName = state.sourceBundleIdentifier.isEmpty
      ? "" : ExpandedPlayerView.appName(for: state.sourceBundleIdentifier)
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
