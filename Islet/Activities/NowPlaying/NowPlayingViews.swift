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
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    TimelineView(
      .animation(
        minimumInterval: 0.15,
        paused: reduceMotion || activity.playback?.isPlaying != true)
    ) { context in
      let t = context.date.timeIntervalSinceReferenceDate
      HStack(spacing: 2) {
        ForEach(0..<4) { i in
          let phase = t * 3 + Double(i) * 0.9
          Capsule()
            .fill(appTheme.color(for: .nowPlaying))
            .frame(
              width: 2.5,
              height: activity.playback?.isPlaying == true && !reduceMotion
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
  @State private var scrubSession = PlaybackScrubSession()

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
    .onChange(of: activity.primaryKey) { _, _ in
      scrubbing = false
      scrubSession.cancel()
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Now Playing")
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
          let notice = activity.mediaControlNotice
          Text(notice ?? activity.mediaControlScopeLabel(for: source))
            .font(.caption2)
            .foregroundStyle(notice == nil ? Color.secondary : Color.yellow)
            .lineLimit(2)
            .accessibilityLabel(
              notice.map { "Media control error: \($0)" }
                ?? activity.mediaControlScopeLabel(for: source))
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
        Text(
          playback.map {
            $0.isPlaying ? String(localized: "Playing") : String(localized: "Paused")
          } ?? String(localized: "Audio detected")
        )
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
      Image(systemName: isPlaying ? "play.fill" : "pause.fill")
        .font(.system(size: 7, weight: .bold))
        .foregroundStyle(isPlaying ? Color.green : Color.secondary)
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

  @ViewBuilder
  private func scrubber(_ pb: PlaybackState, source: SourceID?) -> some View {
    let canSeek =
      pb.seekability == .seekable
      && (source.map { activity.canPerform(.seek(to: 0), for: $0) } ?? false)
    if canSeek {
      // Only tick while actually playing; a paused track's position is fixed, so no redraw is needed.
      TimelineView(.animation(minimumInterval: 0.5, paused: pb.isPlaying == false)) { _ in
        let displayedElapsed =
          scrubbing && scrubSession.source == activity.primaryKey
          ? scrubValue : pb.currentElapsed()
        let elapsedText = MediaDurationFormatter.string(for: displayedElapsed)
        let durationText = MediaDurationFormatter.string(for: pb.duration)
        VStack(spacing: 2) {
          Slider(
            value: Binding(
              get: {
                scrubbing && scrubSession.source == activity.primaryKey
                  ? scrubValue : pb.currentElapsed()
              },
              set: { scrubValue = $0 }),
            in: 0...pb.duration
          ) { editing in
            scrubbing = editing
            if editing {
              scrubValue = pb.currentElapsed()
              scrubSession.begin(for: activity.primaryKey)
            } else if let source = scrubSession.source,
              let target = scrubSession.finish(
                value: scrubValue, currentSource: activity.primaryKey)
            {
              Task { await activity.seek(to: target, for: source) }
            }
          }
          .accessibilityLabel("Playback position")
          .accessibilityValue("\(elapsedText) of \(durationText)")
          HStack {
            Text(MediaDurationFormatter.string(for: pb.currentElapsed())).monospacedDigit()
            Spacer()
            Text(durationText).monospacedDigit()
          }
          .font(.caption2).foregroundStyle(.secondary)
        }
      }
    } else {
      seekUnavailable(pb.seekability == .seekable ? .unavailable : pb.seekability)
    }
  }

  private func seekUnavailable(_ seekability: PlaybackSeekability) -> some View {
    Label(seekability.title, systemImage: seekability.symbol)
      .font(.caption)
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityLabel(seekability.accessibilityLabel)
  }

  private func controls(_ pb: PlaybackState, source: SourceID?) -> some View {
    let backCommand: MediaCommand = pb.supportsSkipBackward15 ? .skipBackward15 : .previous
    let forwardCommand: MediaCommand = pb.supportsSkipForward15 ? .skipForward15 : .next
    let controlsAvailable = source.map { activity.canPerform(.togglePlayPause, for: $0) } ?? false
    return HStack(spacing: 20) {
      Button {
        if let source { Task { await activity.perform(.toggleShuffle, for: source) } }
      } label: {
        toggleStateIcon("shuffle", enabled: pb.isShuffleOn)
      }
      .help(
        controlHelp(
          pb.isShuffleOn
            ? String(localized: "Turn shuffle off") : String(localized: "Turn shuffle on"),
          source: source)
      )
      .accessibilityLabel(
        activity.mediaControlAccessibilityLabel(
          action: pb.isShuffleOn
            ? String(localized: "Turn shuffle off") : String(localized: "Turn shuffle on"))
      )
      .accessibilityValue(pb.isShuffleOn ? String(localized: "On") : String(localized: "Off"))
      // Podcasts/audiobooks get ±15 s skip; music gets prev/next.
      Button {
        guard let source else { return }
        Task {
          await activity.perform(backCommand, for: source)
        }
      } label: {
        Image(systemName: pb.supportsSkipBackward15 ? "gobackward.15" : "backward.fill")
      }
      .help(
        controlHelp(
          pb.supportsSkipBackward15
            ? String(localized: "Back 15 seconds") : String(localized: "Previous track"),
          source: source)
      )
      .accessibilityLabel(
        activity.mediaControlAccessibilityLabel(
          action: pb.supportsSkipBackward15
            ? String(localized: "Back 15 seconds") : String(localized: "Previous track"))
      )
      .disabled(source.map { activity.canPerform(backCommand, for: $0) } != true)
      Button {
        if let source { Task { await activity.perform(.togglePlayPause, for: source) } }
      } label: {
        Image(systemName: pb.isPlaying ? "pause.fill" : "play.fill").font(.title2)
      }
      .help(
        controlHelp(
          pb.isPlaying ? String(localized: "Pause") : String(localized: "Play"), source: source)
      )
      .accessibilityLabel(
        activity.mediaControlAccessibilityLabel(
          action: pb.isPlaying ? String(localized: "Pause") : String(localized: "Play")))
      Button {
        guard let source else { return }
        Task {
          await activity.perform(forwardCommand, for: source)
        }
      } label: {
        Image(systemName: pb.supportsSkipForward15 ? "goforward.15" : "forward.fill")
      }
      .help(
        controlHelp(
          pb.supportsSkipForward15
            ? String(localized: "Forward 15 seconds") : String(localized: "Next track"),
          source: source)
      )
      .accessibilityLabel(
        activity.mediaControlAccessibilityLabel(
          action: pb.supportsSkipForward15
            ? String(localized: "Forward 15 seconds") : String(localized: "Next track"))
      )
      .disabled(source.map { activity.canPerform(forwardCommand, for: $0) } != true)
      Button {
        if let source { Task { await activity.perform(.cycleRepeat, for: source) } }
      } label: {
        toggleStateIcon(pb.repeatMode == 1 ? "repeat.1" : "repeat", enabled: pb.repeatMode != 0)
      }
      .help(
        controlHelp(
          pb.repeatMode == 0
            ? String(localized: "Turn repeat on") : String(localized: "Change repeat mode"),
          source: source)
      )
      .accessibilityLabel(
        activity.mediaControlAccessibilityLabel(
          action: pb.repeatMode == 0
            ? String(localized: "Turn repeat on") : String(localized: "Change repeat mode"))
      )
      .accessibilityValue(repeatAccessibilityValue(pb.repeatMode))
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

  private func toggleStateIcon(_ symbol: String, enabled: Bool) -> some View {
    Image(systemName: symbol)
      .foregroundStyle(enabled ? .green : .secondary)
      .padding(4)
      .background(
        RoundedRectangle(cornerRadius: 5)
          .stroke(enabled ? Color.white.opacity(0.85) : .clear, lineWidth: 1))
  }

  private func repeatAccessibilityValue(_ mode: Int) -> String {
    switch mode {
    case 1: String(localized: "Repeat one")
    case 2: String(localized: "Repeat all")
    default: "Off"
    }
  }
}

enum MediaDurationFormatter {
  static func string(for duration: TimeInterval, locale: Locale = .current) -> String {
    guard duration.isFinite else {
      let zero = localizedInteger(0, locale: locale)
      let paddedZero = localizedInteger(0, minimumDigits: 2, locale: locale)
      return "\(zero):\(paddedZero)"
    }

    let roundedSeconds = max(0, duration.rounded())
    let seconds = Int(roundedSeconds.truncatingRemainder(dividingBy: 60))
    let minutes = Int((roundedSeconds / 60).truncatingRemainder(dividingBy: 60))

    if roundedSeconds < 3_600 {
      let minutesText = localizedInteger(minutes, locale: locale)
      let secondsText = localizedInteger(seconds, minimumDigits: 2, locale: locale)
      return "\(minutesText):\(secondsText)"
    }

    let hours = (roundedSeconds / 3_600).rounded(.down)
    let hoursText = localizedNumber(hours, locale: locale)
    let minutesText = localizedInteger(minutes, minimumDigits: 2, locale: locale)
    let secondsText = localizedInteger(seconds, minimumDigits: 2, locale: locale)
    return "\(hoursText):\(minutesText):\(secondsText)"
  }

  private static func localizedInteger(
    _ value: Int, minimumDigits: Int = 1, locale: Locale
  ) -> String {
    localizedNumber(Double(value), minimumDigits: minimumDigits, locale: locale)
  }

  private static func localizedNumber(
    _ value: Double, minimumDigits: Int = 1, locale: Locale
  ) -> String {
    let formatter = NumberFormatter()
    formatter.locale = locale
    formatter.numberStyle = .decimal
    formatter.usesGroupingSeparator = false
    formatter.minimumIntegerDigits = minimumDigits
    formatter.maximumFractionDigits = 0
    return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.0f", value)
  }
}
