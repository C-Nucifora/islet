import Foundation

enum MediaSourceMode: String, CaseIterable, Codable { case auto, prioritized }

enum SourceFilter {
  /// Whether an update from `bundleID` may replace state currently owned by `currentBundleID`.
  static func shouldAccept(
    bundleID: String, currentBundleID: String?,
    mode: MediaSourceMode, priorityList: [String]
  ) -> Bool {
    switch mode {
    case .auto:
      return true
    case .prioritized:
      guard let rank = priorityList.firstIndex(of: bundleID) else { return false }
      guard let current = currentBundleID, current != bundleID,
        let currentRank = priorityList.firstIndex(of: current)
      else { return true }
      return rank <= currentRank
    }
  }
}
