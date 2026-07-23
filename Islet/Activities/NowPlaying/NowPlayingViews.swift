import SwiftUI

struct CompactArtworkView: View {
  @ObservedObject var activity: NowPlayingActivity

  var body: some View {
    Group {
      if let data = activity.playback?.artwork, let img = NSImage(data: data) {
        Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
      } else {
        Image(systemName: "music.note").font(.caption).foregroundStyle(.secondary)
      }
    }
    .frame(width: 18, height: 18)
    .clipShape(RoundedRectangle(cornerRadius: 4))
  }
}

struct CompactBarsView: View {
  @ObservedObject var activity: NowPlayingActivity

  var body: some View {
    TimelineView(
      .animation(minimumInterval: 0.15, paused: activity.playback?.isPlaying != true)
    ) { context in
      let t = context.date.timeIntervalSinceReferenceDate
      HStack(spacing: 2) {
        ForEach(0..<4) { i in
          let phase = t * 3 + Double(i) * 0.9
          Capsule()
            .fill(.green)
            .frame(
              width: 2.5,
              height: activity.playback?.isPlaying == true
                ? 4 + 10 * abs(sin(phase)) : 4)
        }
      }
      .frame(width: 20, height: 18, alignment: .center)
    }
    .accessibilityHidden(true)  // decorative; the track is announced via a sneak
  }
}

struct ExpandedPlayerView: View {
  @ObservedObject var activity: NowPlayingActivity
  @State private var scrubbing = false
  @State private var scrubValue: Double = 0

  var body: some View {
    if let pb = activity.playback {
      HStack(spacing: 16) {
        artwork(pb)
        VStack(alignment: .leading, spacing: 6) {
          HStack(spacing: 6) {
            if let icon = Self.appIcon(for: pb.sourceBundleIdentifier) {
              Image(nsImage: icon).resizable().frame(width: 14, height: 14)
            }
            Text(pb.title).font(.headline).lineLimit(1)
            if pb.isAdvertisement {
              Text("Ad")
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Capsule().fill(.yellow.opacity(0.25)))
                .foregroundStyle(.yellow)
            }
          }
          Text(pb.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
          scrubber(pb)
          controls(pb)
        }
      }
      .foregroundStyle(.white)
    } else {
      Text("Nothing playing").foregroundStyle(.secondary)
    }
  }

  private func artwork(_ pb: PlaybackState) -> some View {
    Group {
      if let data = pb.artwork, let img = NSImage(data: data) {
        Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
      } else {
        RoundedRectangle(cornerRadius: 13).fill(.quaternary)
          .overlay(Image(systemName: "music.note").font(.largeTitle))
      }
    }
    .frame(width: 110, height: 110)
    .clipShape(RoundedRectangle(cornerRadius: 13))
  }

  private func scrubber(_ pb: PlaybackState) -> some View {
    // Only tick while actually playing; a paused track's position is fixed, so no redraw is needed.
    TimelineView(.animation(minimumInterval: 0.5, paused: pb.isPlaying == false)) { _ in
      VStack(spacing: 2) {
        Slider(
          value: Binding(
            get: { scrubbing ? scrubValue : pb.currentElapsed },
            set: { scrubValue = $0 }),
          in: 0...max(pb.duration, 1)
        ) { editing in
          scrubbing = editing
          if !editing { MediaRemoteCommands.shared.seek(to: scrubValue) }
        }
        HStack {
          Text(format(pb.currentElapsed)).monospacedDigit()
          Spacer()
          Text(format(pb.duration)).monospacedDigit()
        }
        .font(.caption2).foregroundStyle(.secondary)
      }
    }
  }

  private func controls(_ pb: PlaybackState) -> some View {
    HStack(spacing: 20) {
      Button {
        MediaRemoteCommands.shared.toggleShuffle()
      } label: {
        Image(systemName: "shuffle").foregroundStyle(pb.isShuffleOn ? .green : .secondary)
      }
      // Podcasts/audiobooks get ±15 s skip; music gets prev/next.
      Button {
        pb.supportsSkip15
          ? MediaRemoteCommands.shared.skipBackward15() : MediaRemoteCommands.shared.previous()
      } label: {
        Image(systemName: pb.supportsSkip15 ? "gobackward.15" : "backward.fill")
      }
      Button {
        Haptics.perform()
        MediaRemoteCommands.shared.togglePlayPause()
      } label: {
        Image(systemName: pb.isPlaying ? "pause.fill" : "play.fill").font(.title2)
      }
      Button {
        pb.supportsSkip15
          ? MediaRemoteCommands.shared.skipForward15() : MediaRemoteCommands.shared.next()
      } label: {
        Image(systemName: pb.supportsSkip15 ? "goforward.15" : "forward.fill")
      }
      Button {
        MediaRemoteCommands.shared.cycleRepeat()
      } label: {
        Image(systemName: pb.repeatMode == 1 ? "repeat.1" : "repeat")
          .foregroundStyle(pb.repeatMode != 0 ? .green : .secondary)
      }
    }
    .buttonStyle(.plain)
    .frame(maxWidth: .infinity)
    .disabled(pb.isAdvertisement)
    .opacity(pb.isAdvertisement ? 0.4 : 1)
  }

  /// Resolves the source app's icon for attribution (parent app for browser-hosted media).
  static func appIcon(for bundleID: String) -> NSImage? {
    guard !bundleID.isEmpty,
      let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    else { return nil }
    return NSWorkspace.shared.icon(forFile: url.path)
  }

  private func format(_ t: TimeInterval) -> String {
    let s = Int(t.rounded())
    return String(format: "%d:%02d", s / 60, s % 60)
  }
}
