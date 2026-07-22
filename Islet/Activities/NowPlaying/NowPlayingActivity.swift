import Defaults
import SwiftUI

@MainActor
final class NowPlayingActivity: NotchActivity, ObservableObject {
  let id = "nowPlaying"
  let priority = ActivityPriority.media
  @Published private(set) var playback: PlaybackState?
  private(set) var activationDate: Date?
  private let watcher = MediaWatcher()
  private var streamTask: Task<Void, Never>?

  var isActive: Bool { playback != nil }

  func start() {
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
        case .nowPlaying(let state):
          guard
            SourceFilter.shouldAccept(
              bundleID: state.bundleIdentifier,
              currentBundleID: self.playback?.bundleIdentifier,
              mode: Defaults[.mediaSourceMode],
              priorityList: Defaults[.mediaPriorityList])
          else { continue }
          if self.playback == nil { self.activationDate = Date() }
          self.playback = state
        }
      }
    }
  }

  var compactLeading: AnyView { AnyView(CompactArtworkView(activity: self)) }
  var compactTrailing: AnyView { AnyView(CompactBarsView(activity: self)) }
  var expandedView: AnyView { AnyView(ExpandedPlayerView(activity: self)) }
}
