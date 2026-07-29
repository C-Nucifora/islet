import Defaults
import SwiftUI

@MainActor
final class NowPlayingActivity: NotchActivity, ObservableObject {
  let id = "nowPlaying"
  let priority = ActivityPriority.media
  @Published private(set) var playback: PlaybackState?
  @Published private(set) var adapterStatus = "Starting…"
  private(set) var activationDate: Date?
  private let watcher = MediaWatcher()
  private var streamTask: Task<Void, Never>?
  private var idleTask: Task<Void, Never>?
  private var idledOut = false
  /// Deactivate this long after playback pauses, so a paused track eventually leaves the island.
  private let idleTimeout: TimeInterval = 60

  var isActive: Bool { playback != nil && !idledOut }

  func start() {
    watcher.onStatus = { status in
      Task { @MainActor [weak self] in self?.adapterStatus = status }
    }
    watcher.start()
    streamTask = Task { [weak self] in
      guard let self else { return }
      for await update in self.watcher.updates {
        switch update {
        case .ignored:
          continue
        case .idle:
          self.playback = nil
          self.activationDate = nil
          self.idleTask?.cancel()
        case .nowPlaying(let state):
          guard
            SourceFilter.shouldAccept(
              bundleID: state.bundleIdentifier,
              currentBundleID: self.playback?.bundleIdentifier,
              mode: Defaults[.mediaSourceMode],
              priorityList: Defaults[.mediaPriorityList])
          else { continue }
          let wasVisible = self.playback != nil && !self.idledOut
          self.idledOut = false
          if !wasVisible { self.activationDate = Date() }
          let previous = self.playback
          self.playback = state
          if let previous, previous.title != state.title, !state.title.isEmpty {
            SystemEventBus.shared.emit(Self.trackChangeEvent(for: state))
          }
          self.scheduleIdle(paused: !state.isPlaying)
        }
      }
    }
  }

  /// While paused, hide the island after `idleTimeout`. Playing cancels any pending idle-out.
  private func scheduleIdle(paused: Bool) {
    idleTask?.cancel()
    guard paused else { return }
    idleTask = Task { [weak self] in
      guard let self else { return }
      try? await Task.sleep(for: .seconds(self.idleTimeout))
      guard !Task.isCancelled else { return }
      self.idledOut = true
      self.objectWillChange.send()
    }
  }

  /// Track changes go through the bus so they gain a Settings toggle, an entry in the generated
  /// Debug menu, and app attribution in the subtitle — none of which the hand-built sneak had.
  ///
  /// Artwork is deliberately dropped in favour of the source app's name. The sneak's leading slot is
  /// an SF Symbol for every other event, and a 16pt bitmap in that slot measures differently, which
  /// changes the island's width for track changes only.
  static func trackChangeEvent(for state: PlaybackState) -> SystemEvent {
    let app = ExpandedPlayerView.appName(for: state.sourceBundleIdentifier)
    let subtitle = [state.artist, app].filter { !$0.isEmpty }.joined(separator: " · ")
    return SystemEvent(
      sourceID: "nowPlaying",
      icon: "music.note",
      title: state.title,
      subtitle: subtitle.isEmpty ? nil : subtitle,
      accentHex: EventAccent.positive,
      motion: .generic,
      urgency: .ambient,
      announcement: "\(state.title), \(state.artist)")
  }

  let tabIcon = "music.note"
  var compactLeading: AnyView { AnyView(CompactArtworkView(activity: self)) }
  var compactTrailing: AnyView { AnyView(CompactBarsView(activity: self)) }
  var expandedView: AnyView { AnyView(ExpandedPlayerView(activity: self)) }
}
