import Foundation

/// Parses mediaremote-adapter JSON-lines output.
/// Envelope: {"type":"data","diff":Bool,"payload":{...}}
/// diff=false replaces the whole state (empty payload => nothing playing);
/// diff=true merges keys onto the previous state (null value => key removed).
enum AdapterUpdate: Equatable {
  case ignored
  case nowPlaying(SourceID, PlaybackState)
  /// A source Islet was tracking has ended. The vendored adapter cannot report this itself; it is
  /// synthesised by `MediaWatcher.expand` when the adapter's single live record changes hands.
  case sourceGone(SourceID)
  case idle
}

enum AdapterParser {
  static func parse(line: String, current: PlaybackState?) -> AdapterUpdate {
    guard let data = line.data(using: .utf8),
      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      obj["type"] as? String == "data",
      let payload = obj["payload"] as? [String: Any]
    else { return .ignored }

    return parse(payload: payload, isDiff: obj["diff"] as? Bool ?? false, current: current)
  }

  /// The adapter's one-shot `get` command returns the payload without the stream envelope. Islet
  /// uses it once at startup to recover a track that was already playing before the stream began.
  static func parseSnapshot(line: String) -> AdapterUpdate {
    guard let data = line.data(using: .utf8),
      let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return .ignored }
    return parse(payload: payload, isDiff: false, current: nil)
  }

  private static func parse(
    payload: [String: Any], isDiff: Bool, current: PlaybackState?
  ) -> AdapterUpdate {
    var state: PlaybackState
    if isDiff {
      guard let current else { return .ignored }
      state = current
    } else {
      state = PlaybackState()
    }

    apply(payload, to: &state)

    // Mandatory keys per adapter's keys.m: a state without a title is "nothing playing".
    if state.title.isEmpty { return .idle }
    return .nowPlaying(SourceID(state: state), state)
  }

  private static func apply(_ payload: [String: Any], to state: inout PlaybackState) {
    if let v = payload["title"] as? String { state.title = v }
    if payload["title"] is NSNull { state.title = "" }
    if let v = payload["artist"] as? String { state.artist = v }
    if let v = payload["album"] as? String { state.album = v }
    if let v = payload["bundleIdentifier"] as? String { state.bundleIdentifier = v }
    if let v = payload["processIdentifier"] as? Int {
      state.processIdentifier = Int32(truncatingIfNeeded: v)
    }
    if let v = payload["playing"] as? Bool { state.isPlaying = v }
    if let v = payload["duration"] as? Double { state.duration = v }
    if payload["duration"] is NSNull { state.duration = 0 }
    if let v = payload["elapsedTime"] as? Double {
      state.elapsed = v
      state.elapsedAt = Date()
    }
    if payload.keys.contains("isLive") {
      state.isLive = payload["isLive"] as? Bool ?? false
    } else if payload.keys.contains("isLiveStream") {
      state.isLive = payload["isLiveStream"] as? Bool ?? false
    }
    if let v = payload["supportsSeeking"] as? Bool { state.supportsSeeking = v }
    if payload["supportsSeeking"] is NSNull { state.supportsSeeking = nil }
    if let v = payload["artworkData"] as? String {
      let policy = ArtworkDecodePolicy.standard
      state.artwork =
        v.utf8.count <= policy.maximumBase64Characters ? Data(base64Encoded: v) : nil
      if let artwork = state.artwork, artwork.count > policy.maximumEncodedBytes {
        state.artwork = nil
      }
    }
    if payload["artworkData"] is NSNull { state.artwork = nil }
    if let v = payload["shuffleMode"] as? Int { state.shuffleMode = v }
    if let v = payload["repeatMode"] as? Int { state.repeatMode = v }
    if let v = payload["isAdvertisement"] as? Bool { state.isAdvertisement = v }
    if let v = payload["parentApplicationBundleIdentifier"] as? String {
      state.parentBundleIdentifier = v
    }
    if payload["supportsFastForward15Seconds"] != nil {
      state.supportsSkipForward15 = payload["supportsFastForward15Seconds"] as? Bool ?? false
    }
    if payload["supportsRewind15Seconds"] != nil {
      state.supportsSkipBackward15 = payload["supportsRewind15Seconds"] as? Bool ?? false
    }
  }
}
