# Confirmed media playback design

## Goal

Stop cached Now Playing metadata from making Islet report active playback while preserving the CoreAudio-assisted recovery added in PR #218.

GitHub issue: #224

## Root cause

`AudioProcessMonitor` reports whether an application owns a running CoreAudio output stream. CoreAudio does not say whether that stream contains audible samples.

`MediaSourceTable` currently treats a matching output stream as proof that a paused `PlaybackState` is playing. It rewrites the published state to `isPlaying = true`, ranks it as playing, and removes its idle deadline. A browser or player that retains a silent output stream can therefore keep cached metadata visible and animate the compact equalizer forever.

`MediaWatcher` also accepts a recovery snapshot for an active CoreAudio application without checking the snapshot's playback flag or position. This can restore cached paused metadata after the live stream reports idle.

## State model

The implementation keeps three facts separate:

1. MediaRemote metadata exists.
2. CoreAudio reports a running output stream for the application.
3. Playback has enough evidence to be presented as active.

Canonical table state comes from MediaRemote. CoreAudio never changes `PlaybackState.isPlaying`, ordering, or idle expiry directly.

Playback is confirmed when either condition holds:

- A matching recovery snapshot reports `isPlaying == true`.
- Two bounded recovery snapshots describe the same source and media item, both explicitly contain a raw elapsed position, and the later position is at least 0.5 seconds ahead of the earlier position. A missing field is not treated as zero. The accepted state is normalized to `isPlaying == true` because advancing position is the confirmation signal.

The media identity comparison uses source ID, title, artist, album, and duration. A changed identity replaces the pending evidence instead of comparing unrelated elapsed values.

## Recovery flow

When the live MediaRemote stream reports idle while CoreAudio has an active application:

1. `MediaWatcher` requests a snapshot, preserving the existing stream-generation guard.
2. A snapshot from a different application is rejected through the existing retry and diagnostic path.
3. A matching snapshot with `isPlaying == true` is accepted immediately.
4. A matching paused snapshot becomes pending evidence. The watcher schedules another bounded recovery attempt.
5. A later matching paused snapshot is accepted only if both snapshots supplied elapsed positions and the later position advanced by at least 0.5 seconds.
6. After the existing three-attempt budget is exhausted without confirmation, the watcher stays idle. It does not publish cached metadata as playing.

Initial startup snapshots keep their current behavior. A paused startup item may appear as paused, but it receives the normal 60-second idle deadline. CoreAudio cannot cancel that deadline.

Pending recovery evidence is cleared when the active CoreAudio application set changes, a newer stream record arrives, recovery succeeds, monitoring stops, or the attempt budget ends.

## Presentation consistency

The compact bars, expanded play or pause control, scrubber animation, source status, source ordering, accessibility label, and idle expiry all read the same canonical `PlaybackState.isPlaying` value.

CoreAudio-only source chips remain available. They still mean "audio output stream detected" and do not supply track metadata or transport state.

## Error handling and diagnostics

An unconfirmed paused snapshot is an expected recovery result, not a helper failure. It must not create a persistent adapter error. Invalid output, a helper failure, or a snapshot from an inactive application keeps the current diagnostic behavior.

## Tests

Tests must prove:

- Matching CoreAudio activity does not promote or retain a paused table entry.
- Confirmed playing snapshots recover immediately.
- The first paused snapshot waits for confirmation.
- Unchanged paused snapshots never recover as playing.
- Advancing elapsed position across matching snapshots confirms playback.
- Missing elapsed fields cannot confirm playback against a later position.
- A different media identity resets evidence.
- Stopping CoreAudio and live MediaRemote updates clear pending evidence.
- Malformed-output and timeout exhaustion clear pending evidence.
- Existing source ordering, expiry, and genuine recovery behavior remain intact.

## Non-goals

- Capturing or measuring audio samples.
- Adding a microphone or audio-capture permission.
- Replacing the vendored MediaRemote adapter.
- Treating every CoreAudio-only source as controllable media.
