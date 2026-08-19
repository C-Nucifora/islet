import Foundation

/// Appends every raw activity the daemon sends to a JSONL file, for building test fixtures.
///
/// Payload schemas are app-defined and undocumented, so the only way to write a correct adapter is
/// to look at what an app actually sends. This is how those payloads get out of a live session and
/// into `IsletTests/Fixtures`, the same way `adapter-stream.jsonl` did for MediaRemote.
///
/// Off unless `Defaults[.continuityCapture]` is set, and it records payloads from the user's phone
/// — a shopping order, a ride, a boarding pass — so it is deliberately not discoverable by
/// accident and never runs on its own.
enum ContinuityCapture {
  static let fileName = "live-activity-capture.jsonl"

  static var fileURL: URL? {
    FileManager.default
      .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
      .appendingPathComponent("Islet", isDirectory: true)
      .appendingPathComponent(fileName)
  }

  /// One JSONL record. Blobs are kept base64 alongside their decoded form so a fixture can be
  /// replayed through the real decode path rather than through a pre-parsed convenience shape.
  static func record(kind: String, activity: RawLiveActivity, now: Date = Date()) -> [String: Any] {
    var record: [String: Any] = [
      "kind": kind,
      "t": ISO8601DateFormatter().string(from: now),
      "id": activity.id,
      "isRemote": activity.isRemote,
      "state": activity.state,
      "relevanceScore": activity.relevanceScore,
      "isImportant": activity.isImportant,
      "isMomentary": activity.isMomentary,
      "isEphemeral": activity.isEphemeral,
    ]
    record["bundleIdentifier"] = activity.bundleIdentifier
    record["appName"] = activity.appName
    record["createdDate"] = activity.createdDate.map { $0.timeIntervalSinceReferenceDate }
    record["staleDate"] = activity.staleDate.map { $0.timeIntervalSinceReferenceDate }
    record["attributesData"] = activity.attributesData?.base64EncodedString()
    record["contentData"] = activity.contentData?.base64EncodedString()
    // Decoded alongside the blob so a capture is readable without a decoder to hand.
    record["attributesJSON"] = activity.attributesData.flatMap(jsonPreview)
    record["contentJSON"] = activity.contentData.flatMap(jsonPreview)
    return record
  }

  private static func jsonPreview(_ data: Data) -> Any? {
    try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
  }

  static func append(kind: String, activity: RawLiveActivity) {
    guard let fileURL else { return }
    let record = record(kind: kind, activity: activity)
    guard let line = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
    else { return }
    var blob = line
    blob.append(0x0A)
    do {
      try FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      if FileManager.default.fileExists(atPath: fileURL.path) {
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: blob)
      } else {
        try blob.write(to: fileURL)
      }
    } catch {
      Log.app.error("Continuity capture write failed: \(error.localizedDescription)")
    }
  }
}
