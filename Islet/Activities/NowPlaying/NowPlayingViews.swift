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
          Text(pb.title).font(.headline).lineLimit(1)
          Text(pb.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
          scrubber(pb)
          controls
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
    TimelineView(.periodic(from: .now, by: 0.5)) { _ in
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

  private var controls: some View {
    HStack(spacing: 28) {
      Button {
        MediaRemoteCommands.shared.previous()
      } label: {
        Image(systemName: "backward.fill")
      }
      Button {
        MediaRemoteCommands.shared.togglePlayPause()
      } label: {
        Image(
          systemName: activity.playback?.isPlaying == true ? "pause.fill" : "play.fill"
        )
        .font(.title2)
      }
      Button {
        MediaRemoteCommands.shared.next()
      } label: {
        Image(systemName: "forward.fill")
      }
    }
    .buttonStyle(.plain)
    .frame(maxWidth: .infinity)
  }

  private func format(_ t: TimeInterval) -> String {
    let s = Int(t.rounded())
    return String(format: "%d:%02d", s / 60, s % 60)
  }
}
