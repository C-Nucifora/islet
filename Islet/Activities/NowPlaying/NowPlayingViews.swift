import SwiftUI

struct CompactArtworkView: View {
  @ObservedObject var activity: NowPlayingActivity

  var body: some View {
    Group {
      if let img = activity.artwork(for: activity.primaryKey) {
        Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
      } else {
        Image(systemName: "music.note").font(.caption).appThemeForeground(.nowPlaying)
      }
    }
    .frame(width: 18, height: 18)
    .clipShape(RoundedRectangle(cornerRadius: 4))
    .accessibilityHidden(true)
  }
}

struct CompactBarsView: View {
  @ObservedObject var activity: NowPlayingActivity
  @Environment(\.appTheme) private var appTheme

  var body: some View {
    TimelineView(
      .animation(minimumInterval: 0.15, paused: activity.playback?.isPlaying != true)
    ) { context in
      let t = context.date.timeIntervalSinceReferenceDate
      HStack(spacing: 2) {
        ForEach(0..<4) { i in
          let phase = t * 3 + Double(i) * 0.9
          Capsule()
            .fill(appTheme.color(for: .nowPlaying))
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
    VStack(spacing: 6) {
      if let pb = activity.playback {
        hero(pb, source: activity.primaryKey)
      } else {
        Text("Nothing playing")
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      if !activity.strip.isEmpty { sourceStrip }
    }
    .foregroundStyle(.white)
  }

  private func hero(_ pb: PlaybackState, source: SourceID?) -> some View {
    HStack(spacing: 16) {
      artwork(source)
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 6) {
          if let source, let icon = activity.sourceIcon(for: source) {
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
        scrubber(pb, source: source)
        controls(pb, source: source)
        if let source {
          Text(activity.mediaControlNotice ?? activity.mediaControlScopeLabel(for: source))
            .font(.caption2)
            .foregroundStyle(activity.mediaControlNotice == nil ? Color.secondary : Color.yellow)
            .lineLimit(2)
        }
      }
    }
  }

  /// Other apps producing audio right now. Chips only: no title, no artist, no transport — that is
  /// the ceiling of the non-fork approach, and it is why the design spec's "Upgrade path — fork the
  /// MediaRemote adapter for true per-source media" section exists.
  private var sourceStrip: some View {
    let layout = MediaSourceChooser.layout(
      primary: activity.primaryKey, secondary: activity.strip)
    return HStack(spacing: 6) {
      ForEach(layout.shown, id: \.self) { source in
        Button {
          activity.promote(source)
        } label: {
          chip(source)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(activity.sourceAccessibilityLabel(for: source, isPrimary: false))
        .accessibilityHint(activity.sourceSelectionAccessibilityHint(for: source))
      }
      if !layout.hidden.isEmpty {
        sourceChooser(layout)
      }
      Spacer(minLength: 0)
    }
    .frame(height: 22)
  }

  @ViewBuilder
  private func sourceChooser(_ layout: MediaSourceChooser.Layout) -> some View {
    Menu {
      if let primary = layout.primary {
        Section("Primary source") {
          sourceChooserRow(primary, isPrimary: true)
            .accessibilityLabel(activity.sourceAccessibilityLabel(for: primary, isPrimary: true))
        }
      }
      Section("More sources") {
        ForEach(layout.hidden, id: \.self) { source in
          Button {
            activity.promote(source)
          } label: {
            sourceChooserRow(source, isPrimary: false)
          }
          .accessibilityLabel(activity.sourceAccessibilityLabel(for: source, isPrimary: false))
          .accessibilityHint(activity.sourceSelectionAccessibilityHint(for: source))
        }
      }
    } label: {
      Text("+\(layout.hidden.count)")
        .font(.caption2.weight(.semibold)).monospacedDigit()
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .frame(height: 22)
        .background(Capsule().fill(.white.opacity(0.08)))
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .accessibilityLabel("Choose from \(layout.hidden.count) more sources")
    .accessibilityHint("Opens a list of additional media sources")
  }

  private func sourceChooserRow(_ source: SourceID, isPrimary: Bool) -> some View {
    let playback = activity.sources[source]
    return HStack(spacing: 8) {
      if let icon = activity.sourceIcon(for: source) {
        Image(nsImage: icon).resizable().frame(width: 16, height: 16)
      } else {
        Image(systemName: "speaker.wave.2.fill").frame(width: 16, height: 16)
      }
      VStack(alignment: .leading, spacing: 1) {
        Text(activity.sourceName(for: source))
        Text(playback.map { $0.isPlaying ? "Playing" : "Paused" } ?? "Audio detected")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      if isPrimary {
        Text("Primary")
          .font(.caption.weight(.medium))
          .foregroundStyle(.secondary)
      }
    }
  }

  private func chip(_ source: SourceID) -> some View {
    // CoreAudio sources have no PlaybackState; they are listed precisely because they are
    // producing output, so absent means playing.
    let isPlaying = activity.sources[source]?.isPlaying ?? true
    return HStack(spacing: 4) {
      if let icon = activity.sourceIcon(for: source) {
        Image(nsImage: icon).resizable().frame(width: 14, height: 14)
      } else {
        Image(systemName: "speaker.wave.2.fill").font(.caption2)
      }
      Circle()
        .fill(isPlaying ? Color.green : Color.secondary)
        .frame(width: 5, height: 5)
    }
    .padding(.horizontal, 6)
    .frame(height: 22)
    .background(Capsule().fill(.white.opacity(0.10)))
    .opacity(0.7)
  }

  private func artwork(_ source: SourceID?) -> some View {
    Group {
      if let img = activity.artwork(for: source) {
        Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
      } else {
        RoundedRectangle(cornerRadius: 13).fill(.quaternary)
          .overlay(Image(systemName: "music.note").font(.largeTitle))
      }
    }
    .frame(width: 110, height: 110)
    .clipShape(RoundedRectangle(cornerRadius: 13))
    .accessibilityHidden(true)
  }

  private func scrubber(_ pb: PlaybackState, source: SourceID?) -> some View {
    let controlsAvailable = source.map { activity.mediaControlsAvailable(for: $0) } ?? false
    // Only tick while actually playing; a paused track's position is fixed, so no redraw is needed.
    return TimelineView(.animation(minimumInterval: 0.5, paused: pb.isPlaying == false)) { _ in
      VStack(spacing: 2) {
        Slider(
          value: Binding(
            get: { scrubbing ? scrubValue : pb.currentElapsed },
            set: { scrubValue = $0 }),
          in: 0...max(pb.duration, 1)
        ) { editing in
          scrubbing = editing
          if !editing, let source {
            Task { await activity.perform(.seek(to: scrubValue), for: source) }
          }
        }
        .accessibilityLabel("Playback position")
        .accessibilityValue(
          "\(format(scrubbing ? scrubValue : pb.currentElapsed)) of \(format(pb.duration))"
        )
        .disabled(!controlsAvailable)
        .opacity(controlsAvailable ? 1 : 0.4)
        HStack {
          Text(format(pb.currentElapsed)).monospacedDigit()
          Spacer()
          Text(format(pb.duration)).monospacedDigit()
        }
        .font(.caption2).foregroundStyle(.secondary)
      }
    }
  }

  private func controls(_ pb: PlaybackState, source: SourceID?) -> some View {
    let controlsAvailable = source.map { activity.mediaControlsAvailable(for: $0) } ?? false
    return HStack(spacing: 20) {
      Button {
        if let source { Task { await activity.perform(.toggleShuffle, for: source) } }
      } label: {
        Image(systemName: "shuffle").foregroundStyle(pb.isShuffleOn ? .green : .secondary)
      }
      .help(controlHelp(pb.isShuffleOn ? "Turn shuffle off" : "Turn shuffle on", source: source))
      .accessibilityLabel(
        activity.mediaControlAccessibilityLabel(
          action: pb.isShuffleOn ? "Turn shuffle off" : "Turn shuffle on"))
      // Podcasts/audiobooks get ±15 s skip; music gets prev/next.
      Button {
        guard let source else { return }
        Task {
          await activity.perform(pb.supportsSkip15 ? .skipBackward15 : .previous, for: source)
        }
      } label: {
        Image(systemName: pb.supportsSkip15 ? "gobackward.15" : "backward.fill")
      }
      .help(controlHelp(pb.supportsSkip15 ? "Back 15 seconds" : "Previous track", source: source))
      .accessibilityLabel(
        activity.mediaControlAccessibilityLabel(
          action: pb.supportsSkip15 ? "Back 15 seconds" : "Previous track"))
      Button {
        if let source { Task { await activity.perform(.togglePlayPause, for: source) } }
      } label: {
        Image(systemName: pb.isPlaying ? "pause.fill" : "play.fill").font(.title2)
      }
      .help(controlHelp(pb.isPlaying ? "Pause" : "Play", source: source))
      .accessibilityLabel(
        activity.mediaControlAccessibilityLabel(action: pb.isPlaying ? "Pause" : "Play"))
      Button {
        guard let source else { return }
        Task {
          await activity.perform(pb.supportsSkip15 ? .skipForward15 : .next, for: source)
        }
      } label: {
        Image(systemName: pb.supportsSkip15 ? "goforward.15" : "forward.fill")
      }
      .help(controlHelp(pb.supportsSkip15 ? "Forward 15 seconds" : "Next track", source: source))
      .accessibilityLabel(
        activity.mediaControlAccessibilityLabel(
          action: pb.supportsSkip15 ? "Forward 15 seconds" : "Next track"))
      Button {
        if let source { Task { await activity.perform(.cycleRepeat, for: source) } }
      } label: {
        Image(systemName: pb.repeatMode == 1 ? "repeat.1" : "repeat")
          .foregroundStyle(pb.repeatMode != 0 ? .green : .secondary)
      }
      .help(
        controlHelp(pb.repeatMode == 0 ? "Turn repeat on" : "Change repeat mode", source: source)
      )
      .accessibilityLabel(
        activity.mediaControlAccessibilityLabel(
          action: pb.repeatMode == 0 ? "Turn repeat on" : "Change repeat mode"))
    }
    .buttonStyle(.plain)
    .frame(maxWidth: .infinity)
    .disabled(pb.isAdvertisement || !controlsAvailable)
    .opacity(pb.isAdvertisement || !controlsAvailable ? 0.4 : 1)
  }

  private func controlHelp(_ action: String, source: SourceID?) -> String {
    guard let source else { return action }
    return activity.mediaControlHelp(action: action, for: source)
  }

  private func format(_ t: TimeInterval) -> String {
    guard t.isFinite else { return "0:00" }
    let s = max(0, Int(t.rounded()))
    return String(format: "%d:%02d", s / 60, s % 60)
  }

}
