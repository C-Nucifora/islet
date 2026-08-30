import Foundation

struct ScreenshotMetadataRecord: Equatable, Sendable {
  let path: String?
  let displayName: String?
  let isScreenCapture: Bool
  let contentCreationDate: Date?
  let fileCreationDate: Date?
  let contentTypeTree: [String]
}

enum ScreenshotQueryPlan {
  static let screenCaptureAttribute = "kMDItemIsScreenCapture"

  /// Spotlight stores screenshot timestamps at whole-second precision on some macOS releases.
  /// Rounding down avoids dropping a capture made in the same second that monitoring starts.
  static func monitoringStart(for date: Date) -> Date {
    Date(timeIntervalSince1970: floor(date.timeIntervalSince1970))
  }

  static func predicate(startedAt: Date) -> NSPredicate {
    NSCompoundPredicate(andPredicateWithSubpredicates: [
      NSPredicate(format: "%K == 1", screenCaptureAttribute),
      NSPredicate(format: "%K == %@", kMDItemContentTypeTree as String, "public.image"),
      NSPredicate(
        format: "%K >= %@", kMDItemContentCreationDate as String, startedAt as NSDate),
    ])
  }

  /// A genuine macOS screenshot has image content and matching content and filesystem creation
  /// times. A copied or imported screenshot can retain `kMDItemIsScreenCapture`, but its filesystem
  /// creation time no longer matches the original capture time.
  static func accepts(_ record: ScreenshotMetadataRecord, startedAt: Date) -> Bool {
    guard record.isScreenCapture,
      record.contentTypeTree.contains("public.image"),
      let path = record.path,
      !path.isEmpty,
      let contentCreationDate = record.contentCreationDate,
      let fileCreationDate = record.fileCreationDate,
      contentCreationDate >= startedAt
    else { return false }

    return abs(contentCreationDate.timeIntervalSince(fileCreationDate)) <= 2
  }

  static func accepted(
    from records: [ScreenshotMetadataRecord], startedAt: Date, excluding seenPaths: Set<String> = []
  ) -> [ScreenshotMetadataRecord] {
    var paths = seenPaths
    return records.filter { record in
      guard accepts(record, startedAt: startedAt), let path = record.path,
        paths.insert(path).inserted
      else { return false }
      return true
    }
  }

  static func record(from item: NSMetadataItem) -> ScreenshotMetadataRecord {
    let flag = item.value(forAttribute: screenCaptureAttribute) as? NSNumber
    return ScreenshotMetadataRecord(
      path: item.value(forAttribute: kMDItemPath as String) as? String,
      displayName: item.value(forAttribute: kMDItemDisplayName as String) as? String,
      isScreenCapture: flag?.boolValue == true,
      contentCreationDate: item.value(forAttribute: kMDItemContentCreationDate as String) as? Date,
      fileCreationDate: item.value(forAttribute: kMDItemFSCreationDate as String) as? Date,
      contentTypeTree: item.value(forAttribute: kMDItemContentTypeTree as String) as? [String] ?? []
    )
  }
}

/// Watches Spotlight for screenshots created after this source starts.
///
/// The user can move macOS's screenshot folder, so this deliberately keeps the user-home search
/// scope. The creation-date predicate makes the initial gather independent of old screenshot
/// history. Metadata validation then rejects imported files that retained the screen-capture flag.
@MainActor
final class ScreenshotEventSource: SystemEventSource {
  enum Status: Equatable {
    case stopped
    case gathering
    case monitoring
    case failed(String)
  }

  let id = "screenshot"
  let displayName = "Screenshots"
  let tier = SystemEventTier.extended

  private(set) var status = Status.stopped

  private let now: () -> Date
  private let startQuery: (NSMetadataQuery) -> Bool
  private let emit: (SystemEvent) -> Void
  private var query: NSMetadataQuery?
  private var observers: [NSObjectProtocol] = []
  private var gathered = false
  private var startedAt: Date?
  private var seenPaths: Set<String> = []

  init(
    now: @escaping () -> Date = Date.init,
    startQuery: @escaping (NSMetadataQuery) -> Bool = { $0.start() },
    emit: @escaping (SystemEvent) -> Void = { SystemEventBus.shared.emit($0) }
  ) {
    self.now = now
    self.startQuery = startQuery
    self.emit = emit
  }

  func start() {
    guard query == nil else { return }
    let monitoringStart = ScreenshotQueryPlan.monitoringStart(for: now())
    let q = NSMetadataQuery()
    q.predicate = ScreenshotQueryPlan.predicate(startedAt: monitoringStart)
    q.searchScopes = [NSMetadataQueryUserHomeScope]

    let center = NotificationCenter.default
    observers.append(
      center.addObserver(
        forName: .NSMetadataQueryDidFinishGathering, object: q, queue: .main
      ) { [weak self] note in
        guard let finishedQuery = note.object as? NSMetadataQuery else { return }
        let queryID = ObjectIdentifier(finishedQuery)
        finishedQuery.disableUpdates()
        let records = (0..<finishedQuery.resultCount).compactMap {
          finishedQuery.result(at: $0) as? NSMetadataItem
        }.map(ScreenshotQueryPlan.record(from:))
        finishedQuery.enableUpdates()
        MainActor.assumeIsolated {
          self?.finishGathering(queryID: queryID, records: records)
        }
      })
    observers.append(
      center.addObserver(
        forName: .NSMetadataQueryDidUpdate, object: q, queue: .main
      ) { [weak self] note in
        // Notification is not Sendable. Read its values on the main queue instead of carrying the
        // notification across an actor hop.
        let records =
          (note.userInfo?[kMDQueryUpdateAddedItems as String] as? [NSMetadataItem] ?? []).map(
            ScreenshotQueryPlan.record(from:))
        MainActor.assumeIsolated { self?.process(records) }
      })

    query = q
    startedAt = monitoringStart
    gathered = false
    seenPaths.removeAll()
    status = .gathering

    guard startQuery(q) else {
      tearDownQuery()
      fail("Spotlight could not start the screenshot query.")
      return
    }
  }

  func stop() {
    tearDownQuery()
    status = .stopped
  }

  private func finishGathering(
    queryID: ObjectIdentifier, records: [ScreenshotMetadataRecord]
  ) {
    guard let query, ObjectIdentifier(query) == queryID else { return }
    gathered = true
    status = .monitoring
    process(records)
  }

  private func process(_ records: [ScreenshotMetadataRecord]) {
    guard gathered, let startedAt else { return }
    let accepted = ScreenshotQueryPlan.accepted(
      from: records, startedAt: startedAt, excluding: seenPaths)
    seenPaths.formUnion(accepted.compactMap(\.path))
    report(accepted)
  }

  private func report(_ records: [ScreenshotMetadataRecord]) {
    guard !records.isEmpty else { return }
    let count = records.count
    emit(
      SystemEvent(
        sourceID: id, icon: "camera.viewfinder",
        title: count > 1 ? "\(count) screenshots" : "Screenshot",
        subtitle: count > 1 ? nil : records[0].displayName ?? "Screenshot",
        accentHex: EventAccent.info, motion: .screenshot,
        urgency: .ambient, duration: 1.5,
        announcement: "Screenshot taken"))
  }

  private func fail(_ message: String) {
    status = .failed(message)
    Log.app.error("Screenshot event source failed: \(message, privacy: .public)")
    emit(
      SystemEvent(
        sourceID: id, icon: "exclamationmark.triangle.fill",
        title: "Screenshot detection unavailable", subtitle: message,
        accentHex: EventAccent.warning, urgency: .alert,
        announcement: "Screenshot detection is unavailable"))
  }

  private func tearDownQuery() {
    query?.stop()
    query = nil
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    observers.removeAll()
    gathered = false
    startedAt = nil
    seenPaths.removeAll()
  }
}
