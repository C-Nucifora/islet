import Foundation

/// Everything the island needs to draw one Live Activity, with the app's schema already resolved
/// away. Adapters and the generic reader both produce this, and the views read nothing else.
struct LiveActivityRender: Equatable, Sendable {
  var title: String?
  var subtitle: String?
  /// Clamped to 0...1 by whoever fills it in.
  var progress: Double?
  /// Drives the compact countdown.
  var endDate: Date?
  /// Candidate SF Symbol name. Unvalidated on purpose — checking it needs AppKit, and this type
  /// stays pure so the reader is testable; the view resolves it and falls back if it is not real.
  var symbol: String?

  var isEmpty: Bool {
    title == nil && subtitle == nil && progress == nil && endDate == nil
  }
}
