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
            SneakQueue.shared.submit(Self.trackChangeSneak(for: state))
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

  static func trackChangeSneak(for state: PlaybackState) -> Sneak {
    let thumb: AnyView =
      if let data = state.artwork, let img = NSImage(data: data) {
        AnyView(
          Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
            .frame(width: 16, height: 16)
            .clipShape(RoundedRectangle(cornerRadius: 4)))
      } else {
        AnyView(Image(systemName: "music.note").font(.caption2).foregroundStyle(.secondary))
      }
    let label = state.artist.isEmpty ? state.title : "\(state.title) — \(state.artist)"
    return Sneak(
      source: "track",
      leading: thumb,
      trailing: AnyView(
        Text(label)
          .font(.caption2).foregroundStyle(.white)
          .lineLimit(1).frame(maxWidth: 170)),
      announcement: state.artist.isEmpty
        ? "Now playing \(state.title)" : "Now playing \(state.title) by \(state.artist)")
  }

  let tabIcon = "music.note"
  var compactLeading: AnyView { AnyView(CompactArtworkView(activity: self)) }
  var compactTrailing: AnyView { AnyView(CompactBarsView(activity: self)) }
  var expandedView: AnyView { AnyView(ExpandedPlayerView(activity: self)) }
}
