import Foundation

/// Parses mediaremote-adapter JSON-lines output.
/// Envelope: {"type":"data","diff":Bool,"payload":{...}}
/// diff=false replaces the whole state (empty payload => nothing playing);
/// diff=true merges keys onto the previous state (null value => key removed).
enum AdapterUpdate: Equatable {
  case ignored
  case nowPlaying(PlaybackState)
  case idle
}

enum AdapterParser {
  static func parse(line: String, current: PlaybackState?) -> AdapterUpdate {
    guard let data = line.data(using: .utf8),
      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      obj["type"] as? String == "data",
      let payload = obj["payload"] as? [String: Any]
    else { return .ignored }

    let isDiff = obj["diff"] as? Bool ?? false
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
    return .nowPlaying(state)
  }

  private static func apply(_ payload: [String: Any], to state: inout PlaybackState) {
    if let v = payload["title"] as? String { state.title = v }
    if payload["title"] is NSNull { state.title = "" }
    if let v = payload["artist"] as? String { state.artist = v }
    if let v = payload["album"] as? String { state.album = v }
    if let v = payload["bundleIdentifier"] as? String { state.bundleIdentifier = v }
    if let v = payload["playing"] as? Bool { state.isPlaying = v }
    if let v = payload["duration"] as? Double { state.duration = v }
    if let v = payload["elapsedTime"] as? Double {
      state.elapsed = v
      state.elapsedAt = Date()
    }
    if let v = payload["artworkData"] as? String {
      state.artwork = Data(base64Encoded: v)
    }
    if payload["artworkData"] is NSNull { state.artwork = nil }
  }
}
